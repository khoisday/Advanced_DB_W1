-- Task 3(c)(i). NOT EXISTS with a correlated subquery.
-- Must return a single scalar: 149960.
SELECT COUNT(*) AS not_held
  FROM orders o
 WHERE NOT EXISTS (SELECT 1
                     FROM held_order h
                    WHERE h.ho_orderkey = o.o_orderkey)
