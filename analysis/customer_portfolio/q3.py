# Customer Portfolio: status transitions PY -> CY, loss history, 30%+ discount share of customer loss, market, sales bands.
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "product_portfolio"))
from db import q  # noqa: E402  read-only helper shared with Product Portfolio
Y="""WITH c AS (SELECT customer_key, extract(year from month_date)::int y, SUM(sales) s, SUM(profit) p
 FROM mart.customer_monthly GROUP BY 1,2)"""
def st(t): return f"CASE WHEN {t}.customer_key IS NULL THEN '-' WHEN {t}.p>0 THEN 'P' WHEN {t}.p<0 THEN 'U' ELSE 'B' END"
for y0 in (2014,2013):
  print(f"6. Transition {y0} -> {y0+1}")
  print(q(Y+f""", a AS (SELECT * FROM c WHERE y={y0}), b AS (SELECT * FROM c WHERE y={y0+1})
   SELECT {st('a')} s0, {st('b')} s1, COUNT(*) n, ROUND(SUM(b.p),0) p1, ROUND(SUM(b.s),0) s1_sales, ROUND(SUM(a.p),0) p0
   FROM a FULL JOIN b ON a.customer_key=b.customer_key GROUP BY 1,2 ORDER BY 1,2"""))
print("6c. Ever active before 2015 (any year) -> 2015 status")
print(q(Y+""", prev AS (SELECT customer_key, SUM(p) pp, SUM((p<0)::int) unprof_years FROM c WHERE y<2015 GROUP BY 1)
 SELECT CASE WHEN prev.customer_key IS NULL THEN 'new' WHEN unprof_years>0 THEN 'had unprof year' ELSE 'never unprof' END h,
 COUNT(*) n, SUM((c.p<0)::int) unprof15, ROUND(100.0*SUM((c.p<0)::int)/COUNT(*),2) rate, ROUND(SUM(CASE WHEN c.p<0 THEN c.p END),0) loss15
 FROM c LEFT JOIN prev USING(customer_key) WHERE c.y=2015 GROUP BY 1"""))
print("8. 2015 loss of unprofitable customers: 30%+ discount lines vs other lines")
print(q("""WITH l AS (SELECT l.customer_key, l.sales, l.profit, l.discount>0.30 d30
 FROM dwh.fact_order_line l JOIN dwh.dim_date d ON d.date_key=l.order_date_key WHERE extract(year from d.calendar_date)=2015),
 cp AS (SELECT customer_key, SUM(profit) p FROM l GROUP BY 1)
 SELECT CASE WHEN cp.p>0 THEN 'P' WHEN cp.p<0 THEN 'U' ELSE 'B' END st, COUNT(DISTINCT l.customer_key) n,
 COUNT(DISTINCT CASE WHEN d30 THEN l.customer_key END) n_with30,
 ROUND(SUM(CASE WHEN d30 THEN l.sales END),0) s30, ROUND(SUM(CASE WHEN d30 THEN l.profit END),0) p30,
 ROUND(SUM(CASE WHEN NOT d30 THEN l.sales END),0) s_oth, ROUND(SUM(CASE WHEN NOT d30 THEN l.profit END),0) p_oth,
 ROUND(SUM(l.profit),0) p
 FROM l JOIN cp USING(customer_key) GROUP BY 1"""))
print("8b. Unprofitable 2015 customers with NO 30%+ line: their loss and discount levels")
print(q("""WITH l AS (SELECT l.customer_key, l.sales, l.profit, l.discount
 FROM dwh.fact_order_line l JOIN dwh.dim_date d ON d.date_key=l.order_date_key WHERE extract(year from d.calendar_date)=2015),
 cp AS (SELECT customer_key, SUM(profit) p, MAX(discount) md FROM l GROUP BY 1)
 SELECT CASE WHEN md>0.30 THEN '30+' WHEN md>0 THEN '0-30' ELSE 'no discount' END maxdisc, COUNT(*) n, ROUND(SUM(p),0) loss
 FROM cp WHERE p<0 GROUP BY 1"""))
print("9. Unprofitable customers by market 2015")
print(q(Y+""", m AS (SELECT DISTINCT o.customer_key, g.market FROM dwh.fact_order o JOIN dwh.dim_geography g USING(geography_key))
 SELECT market, COUNT(*) cust, ROUND(100.0*SUM((p<0)::int)/COUNT(*),2) unprof_rate, ROUND(SUM(CASE WHEN p<0 THEN p END),0) loss,
 ROUND(100*SUM(p)/SUM(s),2) margin FROM c JOIN m USING(customer_key) WHERE y=2015 GROUP BY 1 ORDER BY 3 DESC"""))
print("10. Customer sales band 2015")
print(q(Y+""" SELECT CASE WHEN s<100 THEN '1 <100' WHEN s<500 THEN '2 100-500' WHEN s<1000 THEN '3 500-1K' WHEN s<2500 THEN '4 1K-2.5K' ELSE '5 2.5K+' END band,
 COUNT(*) n, ROUND(100.0*SUM((p<0)::int)/COUNT(*),2) unprof_rate, ROUND(SUM(s),0) s, ROUND(SUM(p),0) p, ROUND(100*SUM(p)/SUM(s),2) margin,
 ROUND(SUM(CASE WHEN p<0 THEN p END),0) loss FROM c WHERE y=2015 GROUP BY 1 ORDER BY 1"""))
