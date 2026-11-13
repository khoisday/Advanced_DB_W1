# Written answers — Tasks 1–3

Student: Nguyễn Phước Khôi · ID: V202603352

Measured on DuckDB 2.0.0 and SQLite 3.49.1, TPC-H sf = 0.1.
Setup fingerprint: `WEEK1-SETUP 147790-148301-3774200-2 (duckdb 2.0.0, sqlite 3.49.1)`.

---

## Task 1 · The clause pipeline (`q1.sql`)

Result (identical in both engines):

| l_returnflag | l_linestatus | cnt | sum_qty | sum_price | avg_disc |
|---|---|---:|---:|---:|---:|
| A | F | 147,790 | 3,774,200 | 5,320,753,880.69 | 0.050145 |
| N | F | 3,765 | 95,257 | 133,737,795.84 | 0.049394 |
| N | O | 291,817 | 7,454,519 | 10,505,523,577.97 | 0.050097 |
| R | F | 148,301 | 3,785,523 | 5,337,950,526.47 | 0.049989 |

**Q1.1** The date restriction belongs in `WHERE`, because `l_shipdate` describes a single line
item and has to filter rows *before* groups are formed. Writing `HAVING l_shipdate <= …` is
**wrong**: after `GROUP BY`, `l_shipdate` is neither a grouping column nor an aggregate, so it
has no single value per group and the query is rejected. The version that does parse,
`HAVING MAX(l_shipdate) <= …`, asks a different question: it keeps or drops *whole groups*
instead of individual rows. Moving a predicate on a *grouping* column into `HAVING` is the case
that is only **wasteful**: it gives the same rows, but the engine aggregates every group first
and then throws some away.

**Q1.2** I checked all 4 rows and every column. The two engines agree exactly; DuckDB returns
`DECIMAL` and SQLite returns `REAL`, so only the printed type differs. They *must* agree
because SQL is declarative. The query text fixes **what** the answer is: a bag of tuples
defined by the relational semantics of `WHERE → GROUP BY → aggregate → ORDER BY`. Storage
layout and execution strategy may only change **how fast** that answer is produced. An engine
that returned different numbers for the same query on the same data would be incorrect, not
just "a different architecture". This is the contract that makes the Task 4 timing comparison
meaningful: both engines do the same logical work.

---

## Task 2 · Joins change the grain (`q2.sql`)

Top row: `8362 | Customer#000008362 | ROMANIA | 35 | 5,793,605.05`. There are 10 rows, ordered by
`total_value DESC, c_custkey ASC`.

**Q2.1** `GROUP BY` must contain **every non-aggregated column in `SELECT`**: `c_custkey,
c_name, n_name`. In this data `c_name` and `n_name` are functionally determined by `c_custkey`
(it is the key, and each customer has one nation). However, the SQL-92 rule is *syntactic*:
it does not let the engine reason about keys and FDs. SQL:1999 allows it when the FD can be
proven from declared constraints, and PostgreSQL and DuckDB do accept a GROUP BY on the PK.
Even so, grouping by `c_custkey` alone fails in SQLite/MySQL-strict/Oracle, or it returns an
arbitrary `c_name`. In addition, `n_name` comes from a *different* table, whose dependency
on `c_custkey` runs through a join and no declared key covers it. Listing all three is
portable and costs nothing, since it creates no extra groups.

**Q2.2** Without the tie-break, `ORDER BY total_value DESC LIMIT 10` is **non-deterministic**
whenever two customers tie on `total_value` at the cut-off: SQL does not define an order among
equal sort keys. The engine may then return either customer as row 10, and the choice can
change between engines, runs, or thread counts, because DuckDB aggregates in parallel. Adding
`c_custkey` (a key) makes the sort order total, so the top-10 *set* and its order are unique.

**Q2.3 — the trap.** After adding `JOIN lineitem l ON l.l_orderkey = o.o_orderkey`:

| | before | after join with `lineitem` |
|---|---|---|
| Customer#000008362 `n_orders` | 35 | **155** |
| Customer#000008362 `total_value` | 5,793,605.05 | **30,993,660.74** (×5.35) |
| top-10 membership | — | changes: 12310, 7600, 7114 enter, 10354, 8761, 11998 leave |

*Exact factor.* The join replaces every order row with one row **per line item of that
order**. `COUNT(*)` becomes the number of line items, and `SUM(o_totalprice)` becomes
Σ_o (o_totalprice × lines(o)). For one customer the growth factor is therefore the
**price-weighted average number of line items per order**,
Σ_o price_o·lines_o / Σ_o price_o. That is 5.35 for customer 8362, not a fixed 4, and up to
about 6.25 for other customers. The global average is 600,572 / 150,000 ≈ 4.0 lines per order,
which is where "≈ 4×" comes from. The factor is above 4 here because orders with more lines
also have a larger `o_totalprice`. The `HAVING COUNT(*) > 15` test also changes meaning: it
now counts line items, so far more customers pass.

*General rule.* A join with a table on the **many** side of a 1:N relationship multiplies
each row on the 1 side by its number of matches. Any aggregate over a 1-side column (`SUM`,
`COUNT`, `AVG` weighted by fan-out) is then computed at the **wrong grain**. Aggregate each
table at its own grain *before* joining, or join only along N:1 paths.

*Fix that keeps `lineitem`* (aggregate the line items to one row per order first):

```sql
WITH ol AS (SELECT l_orderkey, COUNT(*) AS n_lines
              FROM lineitem GROUP BY l_orderkey)
SELECT c.c_custkey, c.c_name, n.n_name,
       COUNT(*) AS n_orders, SUM(o.o_totalprice) AS total_value,
       SUM(ol.n_lines) AS n_lines          -- line-item info, now at the right grain
  FROM customer c
  JOIN nation n ON n.n_nationkey = c.c_nationkey
  JOIN orders o ON o.o_custkey   = c.c_custkey
  JOIN ol       ON ol.l_orderkey = o.o_orderkey
 GROUP BY c.c_custkey, c.c_name, n.n_name
HAVING COUNT(*) > 15
 ORDER BY total_value DESC, c.c_custkey
 LIMIT 10
```

This returns 35 orders and 5,793,605.05 again for customer 8362. The join with `ol` is N:1
(one `ol` row per order), so it cannot multiply rows.

*Something I noticed.* `orders` contains only **10,000 distinct `o_custkey`** values, while
`customer` has **15,000 rows**. The inner join silently drops the 5,000 customers with no
orders. That has no effect here, because `HAVING > 15` would exclude them anyway, but the same
join in a "revenue per customer" report would make them disappear rather than show 0. That
report needs a `LEFT JOIN` with `COALESCE`.

---

## Task 3 · A query that lies to you (`q3*.sql`)

**(a)** Both engines return **0**, not 149,960 (DuckDB 0, SQLite 0).

**(b) Diagnosis:**

```sql
SELECT COUNT(*)                     AS total_rows,      -- 42
       COUNT(ho_orderkey)           AS non_null_keys,   -- 40
       COUNT(*) - COUNT(ho_orderkey) AS null_keys,      -- 2
       COUNT(DISTINCT ho_orderkey)  AS distinct_keys    -- 40
  FROM held_order;
```

`held_order` contains **2 rows whose `ho_orderkey` is NULL**: one with `ho_reason =
'manual_review'` and one where both columns are NULL.
`x NOT IN (v1, …, vn)` means `x <> v1 AND … AND x <> vn`. For any order, for example key 150,
`150 <> NULL` evaluates to **UNKNOWN**, so the whole conjunction can only be FALSE (if 150 is
held) or UNKNOWN (otherwise). It is never TRUE. `WHERE` keeps a row **only if the predicate is
TRUE**; it discards both FALSE and UNKNOWN, so every row is filtered out and the count is 0.

**(c) Three repairs**, all returning **149,960** and all passing the autograder:
`q3_notexists.sql` (i), `q3_antijoin.sql` (ii), and `q3.sql` (iii, `NOT IN … WHERE
ho_orderkey IS NOT NULL`).
For comparison, the near-miss `LEFT JOIN … WHERE h.ho_reason IS NULL` returns **149,961**. It
tests a non-key column that is NULL in a matched row, so one held order is counted as
"not held".

**(d) Which to ship: `NOT EXISTS` (i).** It is **robust by construction**. The correlated
predicate `h.ho_orderkey = o.o_orderkey` is UNKNOWN for a NULL key, so a NULL row simply never
*matches*, and "no matching row exists" stays TRUE. However many NULL rows tomorrow's ETL job
writes, a third or a thousandth, the answer stays correct. The anti-join (ii) is also robust
for the same reason, *provided* the `IS NULL` test is on the join key, which is an easy
condition to get wrong (see the 149,961 near-miss). Repair (iii) is robust only **by
vigilance**: it is correct only because someone remembered the `IS NOT NULL` filter, and
anyone who copies the `NOT IN` pattern without it brings the bug back. A secondary point:
modern optimisers plan `NOT EXISTS` and the anti-join as the same hash anti-join, so (i) costs
nothing in speed.

**(e) Bridge to Part B.** SQL is **not** an implementation of the relational model: it adds
NULL, three-valued logic and bag semantics, and it is in those additions, not in the algebra,
that this failure exists. In RA the same query is simply `π_orderkey(orders) −
π_orderkey(held_order)`, which cannot give 0.
