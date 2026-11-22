CREATE TABLE IF NOT EXISTS mart.product_monthly (
    month_date DATE NOT NULL,
    product_key BIGINT NOT NULL,
    discount_group TEXT NOT NULL,
    sales NUMERIC NOT NULL,
    profit NUMERIC NOT NULL,

    PRIMARY KEY (month_date, product_key, discount_group),
    CONSTRAINT product_monthly_product_key_fkey
        FOREIGN KEY (product_key) REFERENCES dwh.dim_product (product_key),
    CONSTRAINT product_monthly_first_day_check
        CHECK (EXTRACT(DAY FROM month_date) = 1),
    CONSTRAINT product_monthly_discount_group_check
        CHECK (discount_group IN ('0%', '0–10%', '10–20%', '20–30%', '30%+',
                                 'UNKNOWN', 'INVALID'))
);

CREATE INDEX IF NOT EXISTS product_monthly_product_key_idx
    ON mart.product_monthly (product_key);
