from db import q
for yr, cat in [(2015,None),(2014,None),(2015,'Furniture')]:
    cf = f"AND p.category='{cat}'" if cat else ""
    print(f"===== {yr} {cat or 'All'}")
    print(q(f"""
SELECT ROUND(100*SUM(sales) FILTER (WHERE discount_group='30%+')/SUM(sales),2) s30_share,
 ROUND(SUM(profit) FILTER (WHERE discount_group='30%+')/1000,1) p30_k,
 ROUND(100*(SUM(profit)-SUM(profit) FILTER (WHERE discount_group='30%+'))/(SUM(sales)-SUM(sales) FILTER (WHERE discount_group='30%+')),2) margin_excl30
FROM mart.product_monthly m JOIN dwh.dim_product p USING(product_key)
WHERE month_date BETWEEN '{yr}-01-01' AND '{yr}-12-01' {cf}"""))
    print(q(f"""
WITH pr AS (SELECT m.product_key, SUM(profit) pf, SUM(sales) FILTER (WHERE discount_group='0%') s0
  FROM mart.product_monthly m JOIN dwh.dim_product p USING(product_key)
  WHERE month_date BETWEEN '{yr}-01-01' AND '{yr}-12-01' {cf} GROUP BY 1 HAVING SUM(profit) < -1e-9)
SELECT ROUND(SUM(m.profit) FILTER (WHERE discount_group='30%+')/1000,1) p30_k,
 ROUND(SUM(m.profit) FILTER (WHERE discount_group NOT IN ('30%+','0%'))/1000,1) other_disc_k,
 ROUND(COALESCE(SUM(m.profit) FILTER (WHERE discount_group='0%'),0)/1000,1) nodisc_k,
 (SELECT COUNT(*) FROM pr WHERE s0 IS NULL) only_disc_n, (SELECT ROUND(SUM(pf)/1000,1) FROM pr WHERE s0 IS NULL) only_disc_k,
 (SELECT COUNT(*) FROM pr) loss_products
FROM mart.product_monthly m JOIN pr USING(product_key) WHERE month_date BETWEEN '{yr}-01-01' AND '{yr}-12-01'"""))
print(q("""SELECT p.sub_category, ROUND(SUM(sales)/1000,1) sales_k, ROUND(SUM(profit)/1000,1) profit_k,
 ROUND(SUM(profit) FILTER (WHERE discount_group='30%+')/1000,1) p30_k,
 ROUND((SUM(profit)-COALESCE(SUM(profit) FILTER (WHERE discount_group='30%+'),0))/1000,1) p_excl30_k
FROM mart.product_monthly m JOIN dwh.dim_product p USING(product_key)
WHERE month_date BETWEEN '2015-01-01' AND '2015-12-01' GROUP BY 1 ORDER BY 3"""))
