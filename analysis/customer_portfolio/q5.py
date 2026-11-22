# Customer Portfolio, step 5.7: control values for the Segment -> New / Returning matrix (Cust Type * measures).
# New = first purchase (whole history) in the selected year; Returning = first purchase earlier.
# PY margin of a type = margin of customers of that type relative to the prior year, in the prior year.
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "product_portfolio"))
from db import q  # noqa: E402  read-only helper shared with Product Portfolio

BASE = """WITH cy AS (
  SELECT m.customer_key, d.segment, extract(year from m.month_date)::int y,
         SUM(m.sales) s, SUM(m.profit) p
  FROM mart.customer_monthly m JOIN dwh.dim_customer d USING (customer_key)
  GROUP BY 1, 2, 3),
 f AS (SELECT customer_key, MIN(y) fy FROM cy GROUP BY 1),
 t AS (
  SELECT cy.*, CASE WHEN f.fy = cy.y THEN 'New' ELSE 'Returning' END ctype,
         MIN(cy.y) OVER (PARTITION BY cy.segment) < cy.y has_hist
  FROM cy JOIN f USING (customer_key)),
 g AS (
  SELECT y, segment, ctype, COUNT(*) n, SUM(s) s, SUM(p) p, SUM((p < 0)::int) u, bool_and(has_hist) hh
  FROM t GROUP BY GROUPING SETS ((y, segment, ctype), (y, segment), (y)))
SELECT g.y, COALESCE(g.segment, 'TOTAL') segment, COALESCE(g.ctype, '-') ctype,
       g.n customers, ROUND(g.s, 2) sales, ROUND(g.p, 2) profit,
       ROUND(100 * g.p / g.s, 2) margin_pct, ROUND(100.0 * g.u / g.n, 2) unprof_pct,
       ROUND(100 * pg.p / pg.s, 2) margin_py_pct,
       ROUND(100 * (g.p / g.s - pg.p / pg.s), 2) margin_d_py_pp,
       g.hh has_history
FROM g LEFT JOIN g pg
  ON pg.y = g.y - 1
 AND pg.segment IS NOT DISTINCT FROM g.segment
 AND pg.ctype IS NOT DISTINCT FROM g.ctype
 AND (g.ctype IS NULL OR pg.hh)
WHERE g.y = {year}
ORDER BY g.segment IS NULL, g.segment, g.ctype NULLS FIRST"""

for year in (2015, 2014, 2013, 2012):
    print(f"\n=== {year}: Segment -> Type (Type rows are BLANK in DAX when has_history = false) ===")
    print(q(BASE.format(year=year)).to_string(index=False))
