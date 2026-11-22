from db import q
print(q("""SELECT product_key, SUM(profit) profit, SUM(sales) sales, COUNT(*) rows
FROM mart.product_monthly WHERE month_date BETWEEN '2015-01-01' AND '2015-12-01'
GROUP BY product_key HAVING SUM(profit) < 0 AND SUM(profit) > -1 ORDER BY 2"""))
print(q("""SELECT discount_group, COUNT(*) FROM mart.product_monthly GROUP BY 1"""))
# pr_nd distribution for group C: how close to zero is no-discount profit
print(q("""
WITH p AS (
  SELECT product_key, SUM(profit) profit,
         SUM(profit) FILTER (WHERE discount_group='0%') pr_nd,
         SUM(sales) FILTER (WHERE discount_group='0%') s_nd,
         SUM(sales) FILTER (WHERE discount_group<>'0%') s_d,
         SUM(profit) FILTER (WHERE discount_group<>'0%') pr_d
  FROM mart.product_monthly WHERE month_date BETWEEN '2015-01-01' AND '2015-12-01' GROUP BY product_key)
SELECT (pr_nd IS NOT NULL) has_nodisc_sales, profit<0 loss_making, COUNT(*) n,
       ROUND(SUM(COALESCE(s_nd,0))/1000,1) s_nd_k, ROUND(SUM(COALESCE(pr_nd,0))/1000,1) pr_nd_k,
       ROUND(SUM(COALESCE(s_d,0))/1000,1) s_d_k, ROUND(SUM(COALESCE(pr_d,0))/1000,1) pr_d_k
FROM p GROUP BY 1,2 ORDER BY 1,2"""))
# Are there ANY no-discount lines with negative profit in the whole data?
print(q("""SELECT COUNT(*) lines, COUNT(*) FILTER (WHERE profit<0) neg_lines,
           COUNT(*) FILTER (WHERE profit=0) zero_lines, MIN(profit) min_profit
FROM dwh.fact_order_line WHERE discount = 0"""))
