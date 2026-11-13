-- Task 1. One SELECT statement. See handout section "Task 1".
-- For every (l_returnflag, l_linestatus) pair over line items with
-- l_shipdate <= '1998-09-01', return:
--   l_returnflag, l_linestatus, cnt, sum_qty, sum_price, avg_disc
-- ordered by l_returnflag, then l_linestatus.
-- The date filter is a row-level predicate, so it belongs in WHERE (applied before grouping).
SELECT l_returnflag,
       l_linestatus,
       COUNT(*)             AS cnt,
       SUM(l_quantity)      AS sum_qty,
       SUM(l_extendedprice) AS sum_price,
       AVG(l_discount)      AS avg_disc
  FROM lineitem
 WHERE l_shipdate <= '1998-09-01'
 GROUP BY l_returnflag, l_linestatus
 ORDER BY l_returnflag, l_linestatus
