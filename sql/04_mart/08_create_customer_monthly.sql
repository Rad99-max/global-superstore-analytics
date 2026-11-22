CREATE TABLE IF NOT EXISTS mart.customer_monthly (
    month_date DATE NOT NULL,
    customer_key BIGINT NOT NULL,
    sales NUMERIC NOT NULL,
    profit NUMERIC NOT NULL,
    sales_30plus NUMERIC NOT NULL,
    profit_30plus NUMERIC NOT NULL,

    PRIMARY KEY (month_date, customer_key),
    CONSTRAINT customer_monthly_customer_key_fkey
        FOREIGN KEY (customer_key) REFERENCES dwh.dim_customer (customer_key),
    CONSTRAINT customer_monthly_first_day_check
        CHECK (EXTRACT(DAY FROM month_date) = 1)
);

CREATE INDEX IF NOT EXISTS customer_monthly_customer_key_idx
    ON mart.customer_monthly (customer_key);

-- Customer Portfolio step 1 (variant A): sales and profit of order lines with
-- discount > 0.30 (group 30%+), same definition as mart.geographic_monthly.
-- CREATE TABLE IF NOT EXISTS does not add columns to an existing table.
-- DEFAULT 0 only fills existing rows; it is dropped so the load must set values.
ALTER TABLE mart.customer_monthly
    ADD COLUMN IF NOT EXISTS sales_30plus NUMERIC NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS profit_30plus NUMERIC NOT NULL DEFAULT 0;

ALTER TABLE mart.customer_monthly
    ALTER COLUMN sales_30plus DROP DEFAULT,
    ALTER COLUMN profit_30plus DROP DEFAULT;
