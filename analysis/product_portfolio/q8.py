from db import LINES
import pandas as pd
# "New vs PY" products in 2015: how many were sold before 2014 (sparse sales, not launches)
df = pd.read_pickle(LINES); df["y"] = pd.to_datetime(df.dt).dt.year
p = lambda y: set(df[df.y == y].product_key)
new = p(2015) - p(2014); old = new & (p(2012) | p(2013))
print("new vs PY", len(new), "| of them sold in 2012-2013", len(old), "| truly first sale in 2015", len(new - old))
nl = df[df.product_key.isin(new) & (df.y == 2015)].groupby("product_key").size()
print("lines per new product in 2015: median", nl.median(), "share with 1 line", round((nl == 1).mean(), 3))
