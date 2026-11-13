# Task 4 — Same SQL, two architectures

Student: Nguyễn Phước Khôi · ID: V202603352

Machine: Intel Core i7-13620H (10 cores / 16 threads), 16 GB RAM, Windows 11 Home, **plugged in** (AC)
DuckDB version: 2.0.0        SQLite version: 3.49.1        Scale factor: 0.1

## 4a · The matrix

I wrote the *Guess* column before running anything. The timings are the **median of four
`bench.py` runs** (each run is itself a median after warm-up). The *Speed-up* column shows the
spread across those four runs in brackets, because DuckDB's millisecond-scale queries had a
30–60% run-to-run spread on this laptop.

| Query | Guess: who wins? | DuckDB (ms) | SQLite (ms) | Speed-up | Winner |
|---|---|---|---|---|---|
| S1-scan-agg | DuckDB, ~20× | 3.4 | 431 | **~126×** (105–134×) | DuckDB |
| S2-scan-agg-filtered | DuckDB, ~20× (same as S1) | 7.5 | 3,950 | **~525×** (267–1032×) | DuckDB |
| S3-one-column | DuckDB, ~50× (larger than S1) | 1.1 | 127 | **~107×** (101–121×) | DuckDB |
| P1-point-order | SQLite, ~3× | 1.95 | 0.083 | **~25×** (21–43×) | SQLite |
| P2-point-customer | SQLite, ~3× | 0.75 | 0.075 | **~11×** (8–20×) | SQLite |

What I got wrong: I underestimated every gap by roughly an order of magnitude, and I expected
S3 to show a *larger* advantage than S1. Under the default (multi-threaded) settings it did
not. 4b explains why.

## 4b · Why one engine wins the scans

**Mechanism 1: bytes read (layout and projection pushdown).** `lineitem` has 16 columns. A
row store keeps each tuple's 16 values together in a B-tree leaf page, so to read
`l_extendedprice` SQLite must still bring every page of the table through its pager and step
through each record header to reach the right field. DuckDB stores each column as its own
compressed segment, and its plan's `Projections:` line lists only the columns the query
needs. S3 reads 1 column out of 16, and S1 reads 5.

**Mechanism 2: work per value (execution model).** SQLite's VDBE interprets about a dozen
bytecode instructions *per row* (`Column`, `Ge`, `AggStep`, `Next`, …), with dynamic type
checks and record decoding each time. DuckDB runs each operator over a vector of 2,048 values
in a tight, type-specialised loop, so interpretation overhead is paid once per vector instead
of once per value, and the loop is cache- and SIMD-friendly. DuckDB is also **parallel**
(16 threads) while SQLite uses one core. I measured that confound separately: with
`SET threads=1`, DuckDB's S1 goes from 2.4 ms to 6.2 ms. Parallelism therefore explains only
~2.6× of the ~126× gap.

**The S3-vs-S1 check.** If bytes read dominate, DuckDB's advantage should *grow* when the
query touches fewer columns: S3 needs 1/16 of the data, S1 needs 5/16, and SQLite reads all
16/16 in both. With default settings the ratio did **not** grow (S3 ~107× vs S1 ~126×). The
reason is that DuckDB's S3 takes only 0.6–1.1 ms, which is close to its **fixed per-query
floor** of ~0.5 ms (the cost DuckDB pays even for a single-row lookup in P1/P2). That floor
caps the ratio. To remove it, I re-measured in the same session with DuckDB on **one thread**:

| | DuckDB 1 thread | SQLite | ratio |
|---|---|---|---|
| S1 (5 columns + GROUP BY) | 6.19 ms | 349 ms | **56×** |
| S3 (1 column) | 0.93 ms | 144 ms | **154×** |

Measured fairly, the ratio **does** move in the direction the bytes-read argument predicts:
2.7× larger for the 1-column query. The per-engine costs show the mechanism directly.
DuckDB's S3 costs **15%** of its S1 (cost scales with the columns read), while SQLite's S3
still costs **41%** of its S1, because it pays a per-*row* floor however few columns it uses.
**Projection pushdown** is therefore what turns "fewer columns" into "less work". It is only
effective in a column store; in a row store the other 15 columns are physically in the way.
The work-per-value mechanism, however, accounts for most of the *absolute* gap. The data
(sf 0.1) is in page cache in both cases, so this is CPU work, not disk I/O (see extension E4).

## 4c · Why the other wins the point lookups

SQLite has a B-tree on `o_orderkey`. A lookup descends about 3 levels (log_fanout 150,000),
touching ~3 pages, and lands on **one leaf page that holds the whole tuple contiguously**, so
`SELECT *` gets all 9 columns from one place. Cost: tens of microseconds (0.03–0.12 ms
measured). DuckDB has no index. Its zone maps (per-row-group min/max) can skip row groups
whose range excludes 300001, but it still has to set up a full scan pipeline, read and
decompress the surviving row group's vector **for each of the 9 columns separately**, apply
the filter, and reassemble 1 tuple from 9 columns. That fixed cost is ~0.5–2 ms, whatever
the result size. No amount of vectorised scanning wins here: vectorisation amortises cost
*over many values*, and a point lookup has only one.

**Would an index close the gap?** I tested it. I copied `orders` into an in-memory DuckDB and
ran `CREATE UNIQUE INDEX … (o_orderkey)` (an ART index). P1 went from 0.44 ms to only
**0.51 ms**, and `EXPLAIN` still shows a `Seq Scan`: DuckDB's planner did not choose the
index for this query. SQLite stays 5–10× faster. The gap is **per-query overhead**
(parsing, planning, pipeline and thread setup, column reassembly), not the access path.
**So the missing index is a design choice, not an oversight.** An OLAP engine optimises
throughput over large scans. Zone maps are almost free to maintain, help any range predicate
on a roughly sorted column, and cost nothing on writes. Secondary indexes cost memory and
write throughput and do not help the workloads DuckDB is built for.

## 4d · The optimiser's mistake

Plan line for S2 in SQLite:
`SEARCH lineitem USING INDEX idx_lineitem_ship (l_shipdate<?)`. For S1 it is
`SCAN lineitem`. Both then show `USE TEMP B-TREE FOR GROUP BY`.

Why it is catastrophic at 98.5% selectivity:
The index contains only `(l_shipdate, rowid)`. For **each** of the 591,673 matching entries,
SQLite must take the rowid and do a **separate descent of the table B-tree** to fetch
`l_returnflag, l_linestatus, l_quantity, l_extendedprice, l_discount`. That is ~591k
**random** lookups of ~3 pages each. The index is in ship-date order but the table is in
`l_orderkey` order, so consecutive entries land on unrelated pages and there is no locality.
A sequential scan reads each page **once**, in order. An index only pays off when the
predicate is selective (roughly < 5–10% of rows); at 98.5% it does strictly more work than
a scan. The root cause is a **cardinality-estimation error**. `sqlite_stat1` stores only
`600572 238` for this index (the average number of rows per distinct `l_shipdate`) and no
histogram, because this build has no `sqlite_stat4`. For a range predicate SQLite therefore
falls back to a fixed heuristic that assumes `<=` is selective, when it actually matches
almost everything.

Measured in one session (same method: warm-up, median):

| | SQLite |
|---|---|
| S1 (no WHERE, `SCAN`) | 371 ms |
| S2 (WHERE, `SEARCH … USING INDEX`) | **5,057 ms** (13.6× *slower* than S1) |
| S2 with `FROM lineitem NOT INDEXED` (`SCAN`) | **662 ms** |

Time with `NOT INDEXED`: **662 ms**. Factor recovered: **7.6×** (5,057 → 662 ms).

The penalty here (S2 ≈ 13.6× S1) is much larger than the handout's "about 3×". My hypothesis
is that the random-lookup cost depends heavily on the machine. SQLite's default page cache
is only 2 MB, so each of the ~600k lookups goes through `read()` system calls into the OS
page cache, which is expensive on Windows. The E4 extension supports this: with the database
in memory, the same indexed plan drops from ~5.5 s to ~1.2 s. The `NOT INDEXED` time is still
1.8× slower than S1 because SQLite now evaluates the date comparison (a text compare) on all
600k rows, which S1 does not do.

Why DuckDB barely changes:
In the same session, DuckDB took 6.8 ms for S1 and 10.3 ms for S2. That is the same order of
magnitude; the difference is the cost of evaluating the filter. DuckDB has **no secondary
index on `l_shipdate`**, so its only access path is a sequential column scan with the
predicate pushed into it (plus zone-map pruning, which cannot prune anything at 98.5%
selectivity). **With only one access path there is no access-path decision for a bad
cardinality estimate to spoil.**

Comment on `bench.py`'s method: warm-up plus median plus a spread column is sound for
*warm-cache* CPU cost. Note, however, that (1) it compares 16-thread DuckDB with
single-thread SQLite, so the ratios are not per core; (2) it never measures cold I/O; and
(3) `--sql` sends the *same text* to both engines, so the handout's `NOT INDEXED` command
crashes in DuckDB with `Parser Error: syntax error at or near "NOT"`. I timed the
`NOT INDEXED` variant in SQLite directly with the same warm-up/median method.

## 4e · The covering index

| SQLite query | plan | time |
|---|---|---|
| `SELECT COUNT(*) … WHERE l_shipdate <= '1998-09-01'` | `SEARCH lineitem USING COVERING INDEX idx_lineitem_ship` | **20.6 ms** |
| same with `NOT INDEXED` | `SCAN lineitem` | 82.2 ms |

Resolve the contradiction:
The word is **COVERING**. `COUNT(*)` with this predicate needs **only `l_shipdate`**, and that
column is stored in the index itself. SQLite therefore answers the query from the index
alone: an *index-only scan* over a narrow, sorted structure, with **no lookup into the table**.
That makes it 4.0× faster than scanning the full-width table. In 4d, S2 needs 5 further
columns that are *not* in the index, so each index entry forces a random fetch of the full
row from the table. The same index helps or hurts depending on whether it contains **every
column the query needs**. On this machine, removing the per-row table lookup is the
difference between 5,057 ms (S2 via the index) and 20.6 ms (counting via the same index):
roughly 245× here, compared with the handout's ~60×.

In what sense is a covering index a row store imitating a column store?
A covering index is a separate, narrow copy of just the columns a query reads, stored
together and in sorted order, so a scan touches only those bytes. That is exactly what a
column store keeps for **every** column by default. A column store gives you this projection
for every column and every query automatically, with compression (dictionary/RLE on sorted
columns), zone maps and vectorised execution on top. In a row store you build such an index
**one query pattern at a time**, store the data twice, and pay for it on every `INSERT` or
`UPDATE`.

## 4f · Conclusion (<=150 words)

*"Given a workload, I would choose a row store over a column store when the dominant
operations read or write a few complete rows found by key (OLTP lookups, inserts and
updates), because there the B-tree reaches one contiguous tuple in microseconds while a column
store pays a fixed pipeline cost and must reassemble the tuple from separate columns. I
measured SQLite winning point lookups by ~11–25× (8–43× across runs), and an ART index did
not close the gap in DuckDB. When the workload scans many rows but few columns and aggregates
them (S1/S3: DuckDB ~105–135×, and 154× for one column on one thread), the column store wins
by two orders of magnitude, because it reads only the needed columns and does vectorised work
per value. A mixed workload is a matter of proportion, not a ranking: neither engine is
faster in general."*
