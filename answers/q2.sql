-- Task 2. One SELECT statement. See handout section "Task 2".
-- Customers with MORE THAN 15 orders: c_custkey, c_name, n_name,
-- n_orders, total_value. Top 10 by total_value, ties broken by c_custkey ASC.
-- Every non-aggregated column in SELECT is listed in GROUP BY (SQL-92 rule).
SELECT c.c_custkey,
       c.c_name,
       n.n_name,
       COUNT(*)            AS n_orders,
       SUM(o.o_totalprice) AS total_value
  FROM customer c
  JOIN nation   n ON n.n_nationkey = c.c_nationkey
  JOIN orders   o ON o.o_custkey   = c.c_custkey
 GROUP BY c.c_custkey, c.c_name, n.n_name
HAVING COUNT(*) > 15
 ORDER BY total_value DESC, c.c_custkey ASC
 LIMIT 10
