from db import q
# Loss type 2015, product grain = Prod Loss-Making Products logic
print(q("""
WITH p AS (
  SELECT product_key, SUM(profit) profit, SUM(sales) sales,
         SUM(profit) FILTER (WHERE discount_group='0%') pr_nd,
         SUM(sales)  FILTER (WHERE discount_group='0%') s_nd,
         SUM(profit) FILTER (WHERE discount_group<>'0%') pr_d,
         SUM(profit) FILTER (WHERE discount_group='30%+') pr_30,
         SUM(sales)  FILTER (WHERE discount_group='30%+') s_30
  FROM mart.product_monthly WHERE month_date >= '2015-01-01' AND month_date < '2016-01-01'
  GROUP BY product_key)
SELECT CASE
   WHEN pr_nd < 0 THEN 'A: loss even on no-discount sales'
   WHEN pr_nd IS NULL THEN 'B: sold only with discount'
   ELSE 'C: no-discount sales profitable, discount sales loss' END AS loss_type,
   COUNT(*) products, ROUND(SUM(profit)/1000,1) net_loss_k,
   COUNT(*) FILTER (WHERE s_30>0) with_30plus, ROUND(SUM(COALESCE(pr_30,0))/1000,1) profit_30plus_k,
   ROUND(SUM(sales)/1000,1) sales_k
FROM p WHERE profit < 0 GROUP BY ROLLUP(1) ORDER BY 1
"""))
# where does the 2015 loss in loss-making products come from by discount group
print(q("""
WITH p AS (SELECT product_key FROM mart.product_monthly WHERE month_date BETWEEN '2015-01-01' AND '2015-12-01'
           GROUP BY product_key HAVING SUM(profit)<0)
SELECT m.discount_group, ROUND(SUM(m.sales)/1000,1) sales_k, ROUND(SUM(m.profit)/1000,1) profit_k
FROM mart.product_monthly m JOIN p USING(product_key)
WHERE m.month_date BETWEEN '2015-01-01' AND '2015-12-01' GROUP BY ROLLUP(1) ORDER BY 1
"""))
# all products 2015: profit by discount group (business-wide)
print(q("""
SELECT discount_group, ROUND(SUM(sales)/1000,1) sales_k, ROUND(SUM(profit)/1000,1) profit_k,
       ROUND(100*SUM(profit)/SUM(sales),1) margin_pct
FROM mart.product_monthly WHERE month_date BETWEEN '2015-01-01' AND '2015-12-01' GROUP BY ROLLUP(1) ORDER BY 1
"""))
