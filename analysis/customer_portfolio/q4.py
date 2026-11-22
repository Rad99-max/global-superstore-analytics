# Customer Portfolio: is repeat unprofitability explained by country? Plus 2015 KPI control values.
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "product_portfolio"))
from db import q  # noqa: E402  read-only helper shared with Product Portfolio
Y="""WITH c AS (SELECT customer_key, extract(year from month_date)::int y, SUM(sales) s, SUM(profit) p
 FROM mart.customer_monthly GROUP BY 1,2),
 g AS (SELECT DISTINCT o.customer_key, gg.market, gg.country FROM dwh.fact_order o JOIN dwh.dim_geography gg USING(geography_key)),
 prev AS (SELECT customer_key, SUM((p<0)::int) uy FROM c WHERE y<2015 GROUP BY 1),
 x AS (SELECT c.*, g.market, g.country, CASE WHEN prev.customer_key IS NULL THEN 'new' WHEN uy>0 THEN 'had_unprof' ELSE 'never_unprof' END h
       FROM c JOIN g USING(customer_key) LEFT JOIN prev USING(customer_key) WHERE c.y=2015)"""
print("11. Unprofitable rate 2015 by history within market")
print(q(Y+""" SELECT market, h, COUNT(*) n, ROUND(100.0*SUM((p<0)::int)/COUNT(*),1) rate FROM x GROUP BY 1,2 ORDER BY 1,2""").pivot(index="market", columns="h", values=["n","rate"]))
print("11b. Country-adjusted: expected rate if each customer had own-country 2015 rate")
print(q(Y+""", cr AS (SELECT country, AVG((p<0)::int::numeric) r FROM x GROUP BY 1)
 SELECT h, COUNT(*) n, ROUND(100*AVG((p<0)::int::numeric),2) actual, ROUND(100*AVG(cr.r),2) expected_by_country
 FROM x JOIN cr USING(country) GROUP BY 1"""))
print("12. 2015 KPI control: customers, unprof, loss, avg sales/customer, top 10% share")
print(q(Y+""" SELECT COUNT(*) n, ROUND(AVG(s),2) avg_sales, ROUND(SUM(p)/COUNT(*),2) ppc,
 ROUND(100.0*SUM(CASE WHEN p<0 THEN s END)/SUM(s),2) unprof_sales_share,
 ROUND(-100.0*SUM(CASE WHEN p<0 THEN p END)/SUM(CASE WHEN p>0 THEN p END),2) loss_vs_gross_profit FROM x"""))
