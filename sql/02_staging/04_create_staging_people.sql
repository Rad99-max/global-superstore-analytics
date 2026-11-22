-- One row per raw.people record; business fields have no uniqueness constraints.
CREATE TABLE IF NOT EXISTS staging.people (
    person TEXT,
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

    CONSTRAINT people_raw_id_fkey
        FOREIGN KEY (_raw_id) REFERENCES raw.people (_raw_id),
    CONSTRAINT people_load_id_fkey
        FOREIGN KEY (_load_id) REFERENCES raw.load_log (load_id)
);

CREATE INDEX IF NOT EXISTS people_load_id_region_idx
    ON staging.people (_load_id, region);
