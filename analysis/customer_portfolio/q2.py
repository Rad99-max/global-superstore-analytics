# Customer Portfolio: customer -> market / country uniqueness.
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "product_portfolio"))
from db import q  # noqa: E402  read-only helper shared with Product Portfolio
# Each customer_key belongs to exactly one market and one country (fact_order).
print("7. Customer -> market uniqueness (fact_order)")
print(q("""SELECT n_markets, COUNT(*) FROM (SELECT o.customer_key, COUNT(DISTINCT g.market) n_markets
 FROM dwh.fact_order o JOIN dwh.dim_geography g USING(geography_key) GROUP BY 1) t GROUP BY 1"""))
print(q("""SELECT n_countries, COUNT(*) FROM (SELECT o.customer_key, COUNT(DISTINCT g.country) n_countries
 FROM dwh.fact_order o JOIN dwh.dim_geography g USING(geography_key) GROUP BY 1) t GROUP BY 1 ORDER BY 1 LIMIT 5"""))
