CREATE TABLE IF NOT EXISTS mart.sales_profitability_monthly (
    month_date DATE NOT NULL,
    order_profitability_status TEXT NOT NULL,
    discount_group TEXT NOT NULL,
    sales NUMERIC NOT NULL,
    profit NUMERIC NOT NULL,

    PRIMARY KEY (month_date, order_profitability_status, discount_group),
    CONSTRAINT sales_profitability_monthly_first_day_check
        CHECK (EXTRACT(DAY FROM month_date) = 1),
    CONSTRAINT sales_profitability_monthly_status_check
        CHECK (order_profitability_status IN ('PROFITABLE', 'LOSS_MAKING', 'BREAK_EVEN')),
    CONSTRAINT sales_profitability_monthly_discount_group_check
        CHECK (discount_group IN ('0%', '0–10%', '10–20%', '20–30%', '30%+',
                                 'UNKNOWN', 'INVALID'))
);
