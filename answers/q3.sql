-- Task 3(c)(iii). Keep NOT IN, but make the subquery NULL-free.
-- Must return a single scalar: 149960.
SELECT COUNT(*) AS not_held
  FROM orders o
 WHERE o.o_orderkey NOT IN (SELECT ho_orderkey
                              FROM held_order
                             WHERE ho_orderkey IS NOT NULL)
