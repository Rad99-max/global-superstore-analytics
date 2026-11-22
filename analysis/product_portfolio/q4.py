from db import LINES
import pandas as pd, numpy as np
df = pd.read_pickle(LINES); df["d30"]=(df.discount>0.30).astype(float)
df["geo"] = np.where(df.country=="United States", "US|"+df.state.fillna(""), df.country)
y=df.d30; sst=((y-y.mean())**2).sum(); n=len(df)
def eps2(col, y=y):
    g=df.groupby(col); k=g.ngroups
    ssb=(g[y.name].transform("mean")-y.mean()).pow(2).sum() if False else ((df.groupby(col)[y.name].transform("mean")-y.mean())**2).sum()
    ssw=sst_y(y)-ssb; msw=ssw/(n-k)
    return k, round(ssb/sst_y(y),3), round((ssb-(k-1)*msw)/sst_y(y),3)
def sst_y(y): return ((y-y.mean())**2).sum()
df["y"]=df.d30
print("== share of 30%+ line variance explained (eta2, epsilon2 adjusted for number of groups)")
for c in ["market","region","country","geo","category","sub_category","product_key"]:
    print(f"{c:13s} groups/eta2/eps2:", eps2(c, df.y))
# product effect after removing country (geo) effect, and vice versa
df["y_geo"]=df.y-df.groupby("geo").y.transform("mean")
df["y_prod"]=df.y-df.groupby("product_key").y.transform("mean")
for c, col in [("product_key","y_geo"),("sub_category","y_geo"),("geo","y_prod")]:
    df["r"]=df[col]; print(f"{c} on residual after {'geo' if col=='y_geo' else 'product'}:", eps2(c, df.r))
# country-level determinism
cs = df.groupby("geo").agg(lines=("y","size"), sh=("y","mean"), ndisc=("discount","nunique"))
big = cs[cs.lines>=100]
print("== geos with >=100 lines:", len(big), "| share==0:", (big.sh==0).sum(), "| share==1:", (big.sh==1).sum(),
      "| 0<share<1:", ((big.sh>0)&(big.sh<1)).sum())
print("lines in geos where 30%+ share is 0:", round(df[df.geo.isin(cs[cs.sh==0].index)].shape[0]/n,3),
      "| in geos where share>=0.5:", round(df[df.geo.isin(cs[cs.sh>=0.5].index)].shape[0]/n,3))
print(big.sort_values("sh", ascending=False).head(12).round(3))
# distinct discount values per country (non-US) - is discount fixed per country?
nonus = df[df.country!="United States"].groupby("country").agg(lines=("y","size"), ndisc=("discount","nunique"),
          top_disc=("discount", lambda x: x.value_counts().index[0]), top_share=("discount", lambda x: x.value_counts(normalize=True).iloc[0]))
print("== non-US countries >=100 lines: median distinct discount values", nonus[nonus.lines>=100].ndisc.median(),
      "| median share of most common discount", round(nonus[nonus.lines>=100].top_share.median(),3))
# same product, different countries: how often mixed
pc = df.groupby(["product_key","geo"]).y.mean().reset_index()
multi = pc.groupby("product_key").filter(lambda x: len(x)>=3)
mix = multi.groupby("product_key").y.agg(lambda x: (x.min()<0.5)&(x.max()>=0.5))
print("== products sold in >=3 geos:", multi.product_key.nunique(), "| sold with 30%+ in one geo and without in another:", round(mix.mean(),3))
# 30%+ sales & profit 2015 by market/country top
d15 = df[pd.to_datetime(df.dt).dt.year==2015]; d30=d15[d15.y==1]
t = d30.groupby("country").agg(sales_k=("sales","sum"), profit_k=("profit","sum")).div(1000).round(1).sort_values("profit_k")
t["share_of_30_loss"]=(t.profit_k/t.profit_k.sum()).round(3); print("== 2015 30%+ by country: countries", len(t)); print(t.head(10))
print("top10 share of 30%+ loss:", t.share_of_30_loss.head(10).sum().round(3))
