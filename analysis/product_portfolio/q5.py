from db import LINES
import pandas as pd, numpy as np
df = pd.read_pickle(LINES); df["d30"]=(df.discount>0.30).astype(float)
df["geo"]=np.where(df.country=="United States","US|"+df.state.fillna(""),df.country)
d=df[pd.to_datetime(df.dt).dt.year==2015].copy()
geo_rate = d.assign(s30=d.sales*d.d30).groupby("geo").agg(s=("sales","sum"),s30=("s30","sum")); geo_rate["r"]=geo_rate.s30/geo_rate.s
d["exp_s30"]=d.sales*d.geo.map(geo_rate.r)
t=d.assign(s30=d.sales*d.d30, p30=d.profit*d.d30, s30v=d.sales*d.d30).groupby("sub_category").agg(sales_k=("sales","sum"),profit_k=("profit","sum"),s30=("s30","sum"),exp=("exp_s30","sum"),p30=("p30","sum"))
t["margin%"]=100*t.profit_k/t.sales_k; t["s30%"]=100*t.s30/t.sales_k; t["s30_expected_by_geo%"]=100*t.exp/t.sales_k
t["margin_30plus%"]=100*t.p30/t.s30; t["margin_excl_30%"]=100*(t.profit_k-t.p30)/(t.sales_k-t.s30)
t[["sales_k","profit_k"]]/=1000
pd.set_option("display.width",250); pd.set_option("display.max_columns",20)
print(t[["sales_k","profit_k","margin%","s30%","s30_expected_by_geo%","margin_30plus%","margin_excl_30%"]].round(1).sort_values("margin%"))
