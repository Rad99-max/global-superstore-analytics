CREATE TABLE IF NOT EXISTS mart.geographic_monthly (
    month_date DATE NOT NULL,
    geography_key BIGINT NOT NULL,
    sales NUMERIC NOT NULL,
    profit NUMERIC NOT NULL,
    loss_making_sales NUMERIC NOT NULL,
    orders BIGINT NOT NULL,
    unprofitable_orders BIGINT NOT NULL,
    sales_30plus NUMERIC NOT NULL,
    profit_30plus NUMERIC NOT NULL,

    PRIMARY KEY (month_date, geography_key),
    CONSTRAINT geographic_monthly_geography_key_fkey
        FOREIGN KEY (geography_key) REFERENCES dwh.dim_geography (geography_key),
    CONSTRAINT geographic_monthly_first_day_check
        CHECK (EXTRACT(DAY FROM month_date) = 1),
    CONSTRAINT geographic_monthly_orders_check CHECK (orders >= 0),
    CONSTRAINT geographic_monthly_unprofitable_orders_check
        CHECK (unprofitable_orders BETWEEN 0 AND orders)
);

CREATE INDEX IF NOT EXISTS geographic_monthly_geography_key_idx
    ON mart.geographic_monthly (geography_key);

-- Step 1a: sales and profit of order lines with discount > 0.30 (group 30%+).
-- CREATE TABLE IF NOT EXISTS does not add columns to an existing table.
-- DEFAULT 0 only fills existing rows; it is dropped so the load must set values.
ALTER TABLE mart.geographic_monthly
    ADD COLUMN IF NOT EXISTS sales_30plus NUMERIC NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS profit_30plus NUMERIC NOT NULL DEFAULT 0;

ALTER TABLE mart.geographic_monthly
    ALTER COLUMN sales_30plus DROP DEFAULT,
    ALTER COLUMN profit_30plus DROP DEFAULT;
