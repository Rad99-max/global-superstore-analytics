from db import LINES
import pandas as pd, numpy as np
df = pd.read_pickle(LINES); df["dt"]=pd.to_datetime(df["dt"]); df["d30"]=(df.discount>0.30).astype(int)
df["ym"]=df.dt.dt.to_period("M")
print("== overall 30%+ line share by year"); print(df.groupby(df.dt.dt.year).d30.mean().round(3).to_dict())
g = df.groupby("product_key")
pp = pd.DataFrame({"lines":g.size(),"first":g.dt.min(),"last":g.dt.max(),"months":g.ym.nunique()})
print("== lines per product"); print(pp.lines.describe().round(1).to_dict())
# median gap between consecutive sale months of a product
s = df[["product_key","ym"]].drop_duplicates().sort_values(["product_key","ym"])
gap = s.groupby("product_key").ym.diff().dropna().map(lambda x:x.n)
print("== gap between sale months (months): median", gap.median(), "p75", gap.quantile(.75), "p90", gap.quantile(.9))
# (a) last sale month vs first sale month vs other months: share of 30%+ lines (product-level)
pm = df.groupby(["product_key","ym"]).agg(d30=("d30","mean"), sales=("sales","sum"), s30=("sales", lambda x: 0)).reset_index()
pm["s30"] = df.assign(s=df.sales*df.d30).groupby(["product_key","ym"]).s.sum().values
pm = pm.merge(pp, left_on="product_key", right_index=True)
pm["pos"] = np.where(pm.ym==pm["last"].dt.to_period("M"),"last", np.where(pm.ym==pm["first"].dt.to_period("M"),"first","middle"))
gone = pp["last"] < "2015-07-01"
print("== products: total", len(pp), "| last sale before 2015-07 ('gone')", gone.sum(), "| with >=4 sale months", (pp.months>=4).sum())
for label, mask in [("all products >=4 months", pm.months>=4), ("gone & >=4 months", pm.product_key.isin(pp[gone].index)&(pm.months>=4)),
                    ("still selling & >=4 months", ~pm.product_key.isin(pp[gone].index)&(pm.months>=4))]:
    t = pm[mask].groupby("pos").agg(n=("d30","size"), month_30_line_share=("d30","mean"), sales=("sales","sum"), s30=("s30","sum"))
    t["sales_30_share"]=t.s30/t.sales
    print("--", label); print(t[["n","month_30_line_share","sales_30_share"]].round(3))
# share of products whose last sale month is ALL 30%+ lines
last = pm[pm.pos=="last"]; first = pm[pm.pos=="first"]
for lab, m in [("gone", last.product_key.isin(pp[gone].index)), ("still", ~last.product_key.isin(pp[gone].index))]:
    print(lab, "last month 100% 30%+:", round((last[m].d30==1).mean(),3), "| first month 100% 30%+:", round((first[first.product_key.isin(last[m].product_key)].d30==1).mean(),3))
# streak: last 2 sale months both 30%+ for gone products with >=4 months
pm = pm.sort_values(["product_key","ym"])
pm["rk"] = pm.groupby("product_key").ym.rank(ascending=False)
two = pm[(pm.rk<=2)&(pm.months>=4)].groupby("product_key").d30.min()
print("last 2 months both fully 30%+: gone", round(two[two.index.isin(pp[gone].index)].eq(1).mean(),3), "still", round(two[~two.index.isin(pp[gone].index)].eq(1).mean(),3))
twof = pm[(pm.groupby("product_key").ym.rank()<=2)&(pm.months>=4)].groupby("product_key").d30.min()
print("first 2 months both fully 30%+ (placebo): all", round(twof.eq(1).mean(),3))
