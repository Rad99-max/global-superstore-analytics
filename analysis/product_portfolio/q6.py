from db import LINES
import pandas as pd, numpy as np
pd.set_option("display.width",250)
df = pd.read_pickle(LINES); df["y"]=pd.to_datetime(df.dt).dt.year; df["d30"]=df.discount>0.30
df["geo"]=np.where(df.country=="United States","US|"+df.state.fillna(""),df.country)
p14=set(df[df.y==2014].product_key); d=df[df.y==2015].copy(); d["grp"]=np.where(d.product_key.isin(p14),"sold in PY","new vs PY")
r=d.assign(s30=d.sales*d.d30,p30=d.profit*d.d30).groupby("grp").agg(products=("product_key","nunique"),sales=("sales","sum"),profit=("profit","sum"),s30=("s30","sum"),p30=("p30","sum"),lines=("sales","size"))
r["margin%"]=100*r.profit/r.sales; r["s30%"]=100*r.s30/r.sales; r["margin_excl_30%"]=100*(r.profit-r.p30)/(r.sales-r.s30)
print(r.round(1))
print(d.groupby(["grp","category"]).sales.sum().unstack().div(1000).round(1))
