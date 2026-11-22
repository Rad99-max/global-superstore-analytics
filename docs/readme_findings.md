# README material: discounts and geography, Customer Portfolio

English | [Русский](readme_findings.ru.md)

Draft section for the project README. Sources: [product_portfolio_plan.md](product_portfolio_plan.md) (analysis results, items 1, 5, 6) and the analysis scripts in [analysis/product_portfolio/](../analysis/product_portfolio/).

30%+ = discount above 30% (> 0.30); lines at exactly 30% belong to the 20–30% group.

### Key finding: deep discounts are driven by geography, not by products

- **Losses come almost entirely from discounts.** No sales line without a discount is unprofitable (0 of 29,009 lines). At exactly 30% (part of the 20–30% group) 83% of lines lose money; at 50% and above, 100% do.
- **Whether a line gets a 30%+ discount depends mainly on where it is sold.** About 60% of the variation is explained by country (state for the US), compared with about 3% by product and 1–2% by sub-category. Among 86 countries/states with at least 100 lines, 43 never had a 30%+ discount and 11 had it on every line (Turkey and Nigeria: the same discount on all sales). 69% of products sold in 3 or more locations are sold with a 30%+ discount in one place and without it in another.
- **In 2015, 30%+ discounts made up 12.2% of sales and −264.6K of profit.** Ten countries account for 63% of that loss (United States −43.7K, Turkey −30.5K, Nigeria −23.3K). The share of 30%+ sales by country is shown in the Market Performance report page.
- **No signs of clearance sales.** The share of 30%+ lines is the same in a product's first, middle and last months of sales (19–20%) and stable across years (19.8–20.5%).
- **Exception: Tables.** 31.9% of Tables sales carry a 30%+ discount, against 12.9% expected from its sales geography. Without those sales, its margin is 8.3%, the lowest of 17 sub-categories.

**Limitations.** The dataset is likely synthetic, so the strict discount–loss rule may not hold in real data. It has no inventory, price lists or product lifecycle data, so the reasons for discounts cannot be determined. The product mart has no geography, so the Product Portfolio page cannot show the product × country link; it is documented here as an analysis result. The People sheet (regional managers) is loaded only into RAW/STAGING and is not part of DWH, MART or the Power BI model: the Canada region in Orders does not match Eastern/Western Canada in People.

### Customer Portfolio: key facts

Sources: [customer_portfolio_plan.md](customer_portfolio_plan.md) and the analysis scripts in [analysis/customer_portfolio/](../analysis/customer_portfolio/). Values for 2015, compared with 2014. A customer's status is based on their total profit for the year.

- **One in four customers is unprofitable.** 1,896 of 7,624 customers in 2015 (24.87%; 2014: 1,513 of 6,113, 24.75%; 2012–2013: 24.8–25.3%). Their net loss is −274.1K, equal to 35.2% of the profit from profitable customers (2014: −219.5K, 35.0%).
- **Most of this loss comes from sales lines with a 30%+ discount.** In 2015 those lines account for −257.3K of the −274.1K (93.9%; 2014: 96.2%). 1,579 of the 1,896 unprofitable customers (83.3%) have such lines (2014: 1,273 of 1,513, 84.1%). No unprofitable customer bought without a discount.
- **Return rate: 25.4% of 2014 customers bought again in 2015.** 1,552 of the 6,113 customers from 2014 bought again in 2015 (25.4%; 2013 → 2014: 21.1%). New customers made up 60.8% of the 2015 customer base (4,635), compared with 72.3% in 2014 (4,419). New customers' margin was 10.6% vs 13.2% for returning customers (2014: 11.3% vs 13.5%). 87% of 2015 customers bought in only one month.
- **Profit is concentrated in larger customers.** Customers with yearly sales under 100 USD were 31.1% of customers and earned −0.04% of profit (margin −0.18%; 2014: 30.8%, +0.06%). Customers with sales of 1K USD or more were 17.0% of customers and earned 77.0% of profit (2014: 17.1%, 75.5%).
- **Repeat unprofitability vs country average.** Among 2015 customers who had at least one unprofitable year before, 42.9% were unprofitable again (355 of 828), against 15.1% for customers with no unprofitable year before. The average unprofitable share in these customers' countries is 41.1% (2014: 47.1% actual vs 45.2% country average). The share of unprofitable customers by country is shown in the Market Performance report page.
- **Segments: unprofitable share 23.2–25.5%, margin 10.8–12.3%.** In 2015 the unprofitable share ranges from 23.2% to 25.5% across Consumer, Corporate and Home Office, and margin from 10.8% to 12.3%. The largest change from 2014 is Corporate: margin 10.84% (−0.96 pp), net loss of unprofitable customers −88.2K (+33%).

**Limitations.** The same buyer has a separate Customer ID in each country, so a customer counted as "new" may be a known buyer making a first purchase in another country. The customer mart has no order count, no discount levels other than 30%+, and no country, so the page cannot show the customer × country link; this link is documented here as an analysis result. 2012 has no purchase history, so all its customers count as new.
