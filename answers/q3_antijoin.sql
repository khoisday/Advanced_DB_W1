-- Task 3(c)(ii). LEFT JOIN anti-join.
-- Must return a single scalar: 149960.
-- Careful: test IS NULL on the JOIN KEY, not on another column of held_order.
SELECT COUNT(*) AS not_held
  FROM orders o
  LEFT JOIN held_order h ON h.ho_orderkey = o.o_orderkey
 WHERE h.ho_orderkey IS NULL
