# Customer Portfolio, 2015: status by year, months active, profit/loss concentration, Segment, new vs returning.
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "product_portfolio"))
from db import q  # noqa: E402  read-only helper shared with Product Portfolio
Y="""WITH c AS (SELECT customer_key, extract(year from month_date)::int y, SUM(sales) s, SUM(profit) p, COUNT(*) months
 FROM mart.customer_monthly GROUP BY 1,2)"""
print("1. Status by year")
print(q(Y+""" SELECT y, COUNT(*) cust, SUM((p>0)::int) prof, SUM((p<0)::int) unprof, SUM((p=0)::int) be,
 ROUND(100.0*SUM((p<0)::int)/COUNT(*),2) unprof_rate, ROUND(SUM(s),0) sales, ROUND(SUM(p),0) profit,
 ROUND(SUM(p)/COUNT(*),2) ppc, ROUND(SUM(CASE WHEN p<0 THEN p END),0) loss_unprof,
 ROUND(SUM(CASE WHEN p<0 THEN s END),0) sales_unprof, ROUND(SUM(CASE WHEN p>0 THEN p END),0) gross_prof
 FROM c GROUP BY y ORDER BY y"""))
print("2. Months active per customer, 2015")
print(q(Y+""" SELECT months, COUNT(*) n, ROUND(SUM(s),0) s, ROUND(SUM(p),0) p, ROUND(100*SUM(p)/SUM(s),2) m FROM c WHERE y=2015 GROUP BY 1 ORDER BY 1"""))
print("3. Profit concentration 2015: top customers by profit")
print(q(Y+""", r AS (SELECT p, s, ROW_NUMBER() OVER (ORDER BY p DESC) rn, COUNT(*) OVER () n FROM c WHERE y=2015)
 SELECT k, ROUND(100.0*SUM(CASE WHEN rn<=k THEN p END)/SUM(p),2) top_share_of_total_profit,
 ROUND(100.0*SUM(CASE WHEN rn<=k THEN s END)/SUM(s),2) top_share_sales
 FROM r, (VALUES (100),(500),(1000),(1500)) v(k) GROUP BY k ORDER BY k"""))
print("3b. Loss concentration 2015: worst N unprofitable customers share of their total loss")
print(q(Y+""", r AS (SELECT p, ROW_NUMBER() OVER (ORDER BY p) rn FROM c WHERE y=2015 AND p<0)
 SELECT k, (SELECT COUNT(*) FROM r) n_unprof, ROUND(100.0*SUM(CASE WHEN rn<=k THEN p END)/SUM(p),2) share
 FROM r, (VALUES (10),(50),(100),(200),(500)) v(k) GROUP BY k ORDER BY k"""))
print("4. Segment 2015 vs 2014")
print(q(Y+""" SELECT y, d.segment, COUNT(*) cust, ROUND(100.0*SUM((p<0)::int)/COUNT(*),2) unprof_rate,
 ROUND(SUM(s),0) s, ROUND(SUM(p),0) p, ROUND(100*SUM(p)/SUM(s),2) margin, ROUND(SUM(p)/COUNT(*),2) ppc,
 ROUND(SUM(CASE WHEN p<0 THEN p END),0) loss
 FROM c JOIN dwh.dim_customer d USING(customer_key) WHERE y IN (2014,2015) GROUP BY 1,2 ORDER BY 2,1"""))
print("5. New vs returning 2015 (first year of activity)")
print(q(Y+""", f AS (SELECT customer_key, MIN(y) fy FROM c GROUP BY 1)
 SELECT y, CASE WHEN fy=y THEN 'new' ELSE 'returning' END t, COUNT(*) cust, ROUND(100.0*SUM((p<0)::int)/COUNT(*),2) unprof_rate,
 ROUND(SUM(s),0) s, ROUND(SUM(p),0) p, ROUND(100*SUM(p)/SUM(s),2) margin, ROUND(SUM(s)/COUNT(*),0) spc
 FROM c JOIN f USING(customer_key) WHERE y IN (2014,2015) GROUP BY 1,2 ORDER BY 1,2"""))
