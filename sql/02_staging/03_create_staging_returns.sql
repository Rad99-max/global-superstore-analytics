-- One row per source return record; no line-level return facts are inferred.
CREATE TABLE IF NOT EXISTS staging.returns (
    returned TEXT,
    order_id TEXT,
    region TEXT,

    -- Preserve RAW lineage; _raw_id is supplied, not generated again.
    _raw_id BIGINT PRIMARY KEY,
    _load_id UUID NOT NULL,
    _loaded_at TIMESTAMPTZ NOT NULL,
    _source_file TEXT NOT NULL,
    _source_sheet TEXT NOT NULL,
    _source_row_number INTEGER NOT NULL,
    _staged_at TIMESTAMPTZ NOT NULL,
    _dq_flags TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],

    CONSTRAINT returns_raw_id_fkey
        FOREIGN KEY (_raw_id) REFERENCES raw.returns (_raw_id),
    CONSTRAINT returns_load_id_fkey
        FOREIGN KEY (_load_id) REFERENCES raw.load_log (load_id)
);

CREATE INDEX IF NOT EXISTS returns_load_id_order_id_idx
    ON staging.returns (_load_id, order_id);
