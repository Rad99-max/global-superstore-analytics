from db import q, LINES
import pandas as pd, numpy as np
print(q("""SELECT discount, COUNT(*) lines, ROUND(100.0*COUNT(*) FILTER (WHERE profit<0)/COUNT(*),1) neg_pct,
   ROUND(100*SUM(profit)/SUM(sales),1) margin FROM dwh.fact_order_line GROUP BY 1 ORDER BY 1"""))
df = q("""SELECT l.order_line_key, l.product_key, p.category, p.sub_category, g.market, g.region, g.country, l.state,
       d.calendar_date::date dt, l.discount::float discount, l.sales::float sales, l.profit::float profit
FROM dwh.fact_order_line l JOIN dwh.dim_date d ON d.date_key=l.order_date_key
JOIN dwh.dim_product p ON p.product_key=l.product_key JOIN dwh.dim_geography g ON g.geography_key=l.geography_key""")
df.to_pickle(LINES); print(len(df))
