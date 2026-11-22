-- One row per raw.orders row. Business fields remain nullable for DQ reporting.
CREATE TABLE IF NOT EXISTS staging.orders (
    row_id INTEGER,
    order_id TEXT,
    order_date DATE,
    ship_date DATE,
    ship_mode TEXT,
    customer_id TEXT,
    customer_name TEXT,
    segment TEXT,
    postal_code TEXT,
    city TEXT,
    state TEXT,
    country TEXT,
    region TEXT,
    market TEXT,
    product_id TEXT,
    category TEXT,
    sub_category TEXT,
    product_name TEXT,
    sales DOUBLE PRECISION,
    quantity INTEGER,
    discount NUMERIC,
    profit DOUBLE PRECISION,
    shipping_cost DOUBLE PRECISION,
    order_priority TEXT,

    -- Preserve RAW lineage; _raw_id is supplied, not generated again.
    _raw_id BIGINT PRIMARY KEY,
    _load_id UUID NOT NULL,
    _loaded_at TIMESTAMPTZ NOT NULL,
    _source_file TEXT NOT NULL,
    _source_sheet TEXT NOT NULL,
    _source_row_number INTEGER NOT NULL,
    _staged_at TIMESTAMPTZ NOT NULL,
    _dq_flags TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],

    CONSTRAINT orders_raw_id_fkey
        FOREIGN KEY (_raw_id) REFERENCES raw.orders (_raw_id),
    CONSTRAINT orders_load_id_fkey
        FOREIGN KEY (_load_id) REFERENCES raw.load_log (load_id)
);

CREATE INDEX IF NOT EXISTS orders_load_id_order_id_idx
    ON staging.orders (_load_id, order_id);
