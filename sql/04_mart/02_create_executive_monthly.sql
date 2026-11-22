-- One calendar month of Order Date, across the whole business.
CREATE TABLE IF NOT EXISTS mart.executive_monthly (
    month_date DATE NOT NULL PRIMARY KEY,
    sales NUMERIC NOT NULL,
    profit NUMERIC NOT NULL,
    orders BIGINT NOT NULL,
    unprofitable_orders BIGINT NOT NULL,

    CONSTRAINT executive_monthly_first_day_check
        CHECK (EXTRACT(DAY FROM month_date) = 1),
    CONSTRAINT executive_monthly_orders_check CHECK (orders >= 0),
    CONSTRAINT executive_monthly_unprofitable_orders_check
        CHECK (unprofitable_orders BETWEEN 0 AND orders)
);
