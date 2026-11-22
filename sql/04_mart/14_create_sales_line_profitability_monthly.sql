CREATE TABLE IF NOT EXISTS mart.sales_line_profitability_monthly (
    month_date DATE NOT NULL REFERENCES dwh.dim_date (calendar_date),
    line_profitability_status TEXT NOT NULL,
    sales_lines BIGINT NOT NULL,
    sales NUMERIC NOT NULL,
    profit NUMERIC NOT NULL,
    PRIMARY KEY (month_date, line_profitability_status),
    CHECK (EXTRACT(DAY FROM month_date) = 1),
    CHECK (sales_lines > 0),
    CHECK (line_profitability_status IN ('PROFITABLE', 'LOSS_MAKING', 'BREAK_EVEN')),
    CHECK ((line_profitability_status = 'PROFITABLE' AND profit > 0)
        OR (line_profitability_status = 'LOSS_MAKING' AND profit < 0)
        OR (line_profitability_status = 'BREAK_EVEN' AND profit = 0))
);
