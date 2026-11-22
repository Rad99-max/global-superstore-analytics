CREATE TABLE IF NOT EXISTS mart.order_discount_monthly (
    month_date DATE NOT NULL,
    order_discount_category TEXT NOT NULL,
    sales NUMERIC NOT NULL,
    profit NUMERIC NOT NULL,
    orders BIGINT NOT NULL,
    loss_making_orders BIGINT NOT NULL,
    loss_making_sales NUMERIC NOT NULL,
    loss NUMERIC NOT NULL,

    PRIMARY KEY (month_date, order_discount_category),
    FOREIGN KEY (month_date) REFERENCES dwh.dim_date (calendar_date),
    CHECK (EXTRACT(DAY FROM month_date) = 1),
    CHECK (order_discount_category IN ('0%', '0–10%', '10–20%', '20–30%', '30%+', 'MIXED')),
    CHECK (orders > 0),
    CHECK (loss_making_orders BETWEEN 0 AND orders),
    CONSTRAINT order_discount_monthly_loss_nonpositive CHECK (loss <= 0)
);
