# Extension E4 · In-memory vs on-disk

Student: Nguyễn Phước Khôi · ID: V202603352
Machine: i7-13620H, 16 GB RAM, Windows 11, AC power · DuckDB 2.0.0, SQLite 3.49.1, sf 0.1

## Method

The same Task 4 query set (`starter/bench.py`'s `QUERIES`) was run against four
configurations in one Python process:

- **Duck disk**: `data/tpch.duckdb`, read-only.
- **Duck mem**: `duckdb.connect()` (`:memory:`) then `ATTACH … ; COPY FROM DATABASE src TO memory`.
- **SQLite disk**: `data/tpch.sqlite`.
- **SQLite mem**: `sqlite3.connect(':memory:')` then `disk.backup(mem)`. This is a full copy that keeps all indexes.

Timing: 3 discarded warm-ups, then a median over enough repetitions to fill ~0.5 s. The
whole matrix was repeated twice. Both rounds are shown, because the ms-scale DuckDB numbers
are noisy.

## Measurements (median ms)

| Query | Duck disk | Duck mem | SQLite disk | SQLite mem | SQLite disk/mem |
|---|---:|---:|---:|---:|---:|
| S1-scan-agg | 3.5 / 6.4 | 6.8 / 16.6 | 671 / 746 | 673 / 734 | **1.0×** |
| S2-scan-agg-filtered | 10.0 / 10.2 | 16.4 / 13.5 | 5,764 / 5,362 | 1,416 / 984 | **4–5×** |
| S3-one-column | 1.7 / 1.7 | 1.7 / 1.1 | 173 / 154 | 64 / 57 | **2.7×** |
| P1-point-order | 3.1 / 2.3 | 1.5 / 1.1 | 0.156 / 0.092 | 0.008 / 0.006 | **15–20×** |
| P2-point-customer | 0.95 / 0.91 | 1.00 / 0.89 | 0.113 / 0.092 | 0.004 / 0.004 | **25×** |

## What changes, and what does not

**DuckDB: no improvement, and S1 is slightly slower in memory.** DuckDB already keeps the
hot segments in its own buffer manager after the warm-up, so the "disk" runs never touched
the disk. The in-memory copy is, if anything, slower on S1. My hypothesis is that in-memory
tables are not checkpointed into compressed, zone-mapped segments the way the file is, so
the scan processes more bytes. Since the DuckDB numbers are flat, its scans are **CPU-bound
on this workload**.

**SQLite: it depends entirely on how many page accesses the plan makes.**
- **S1, a sequential scan: unchanged (1.0×).** A sequential scan accesses each page once and
  then spends its time interpreting about a dozen VDBE instructions per row. That is pure CPU,
  so moving the bytes into RAM changes nothing.
- **S2, the bad indexed plan: 4–5× faster.** ~591k random rowid lookups, each a B-tree descent.
  On disk, every page access goes through SQLite's pager, and SQLite's default cache is only
  2 MB for a 137 MB file, so most accesses become a `read()` syscall into the OS page cache.
  In memory, a page access is a pointer dereference.
- **P1/P2: 15–25× faster.** A point lookup is so small that its on-disk cost is almost
  entirely fixed overhead: acquiring the file lock, checking the schema cookie, and ~3 pager
  reads through syscalls. In memory, that overhead disappears and the lookup takes **4–8 µs**.

## I/O-bound or CPU-bound?

At sf 0.1 the whole database fits in the OS page cache, so **no measurement here is
bound by disk I/O**. The scans (S1 in both engines, all DuckDB queries) are **CPU-bound**: the
in-memory copies did not make them faster. What the in-memory copy *did* speed up is
**the buffer-management layer itself**: the pager, page lookups, latches and syscalls that a
disk-oriented engine pays *per page access, even when the page is already cached*.

This supports the lecture's claim that in-memory is an **architecture, not a bigger cache**.
A bigger cache (the OS page cache, which already held everything) did not remove these costs;
removing the disk-oriented machinery did. The benefit is largest for **access-heavy, OLTP-style
work** with many small random page accesses (point lookups: 15–25×; random index lookups:
4–5×), and close to zero for **scan-heavy analytics**, where per-value CPU work dominates and
the remedy is the column layout and vectorised execution instead (Task 4b). In-memory
architecture pays off when the workload's cost is in *getting to the data* rather than
*computing on it*. This matches the result of Harizopoulos et al., "OLTP Through the Looking
Glass" (SIGMOD 2008), that buffer management, locking and latching account for most of the
instructions in a disk-based OLTP engine.

**Limitation.** sf 0.1 is too small to show the opposite regime. A dataset larger than RAM
would make the on-disk scans truly I/O-bound, and an in-memory engine could then not hold it
at all.
