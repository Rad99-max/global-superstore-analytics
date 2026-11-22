-- One row per attempt to load the complete source workbook.
CREATE TABLE IF NOT EXISTS raw.load_log (
    load_id UUID PRIMARY KEY,
    source_file TEXT NOT NULL,
    source_sha256 TEXT,
    started_at TIMESTAMPTZ NOT NULL,
    finished_at TIMESTAMPTZ,
    status TEXT NOT NULL,
    orders_rows_loaded BIGINT NOT NULL DEFAULT 0,
    returns_rows_loaded BIGINT NOT NULL DEFAULT 0,
    people_rows_loaded BIGINT NOT NULL DEFAULT 0,
    error_text TEXT,

    CONSTRAINT load_log_source_file_check
        CHECK (source_file <> ''),
    CONSTRAINT load_log_source_sha256_format_check
        CHECK (
            source_sha256 IS NULL
            OR (
                length(source_sha256) = 64
                AND source_sha256 ~ '^[0-9a-f]{64}$'
            )
        ),
    CONSTRAINT load_log_status_check
        CHECK (status IN ('STARTED', 'SUCCESS', 'FAILED', 'SKIPPED')),
    CONSTRAINT load_log_rows_nonnegative_check
        CHECK (
            orders_rows_loaded >= 0
            AND returns_rows_loaded >= 0
            AND people_rows_loaded >= 0
        ),
    CONSTRAINT load_log_unsuccessful_rows_check
        CHECK (
            status = 'SUCCESS'
            OR (
                orders_rows_loaded = 0
                AND returns_rows_loaded = 0
                AND people_rows_loaded = 0
            )
        ),
    CONSTRAINT load_log_finished_at_status_check
        CHECK (
            (status = 'STARTED' AND finished_at IS NULL)
            OR (
                status IN ('SUCCESS', 'FAILED', 'SKIPPED')
                AND finished_at IS NOT NULL
            )
        ),
    CONSTRAINT load_log_time_order_check
        CHECK (finished_at IS NULL OR finished_at >= started_at),
    CONSTRAINT load_log_terminal_sha256_check
        CHECK (
            status NOT IN ('SUCCESS', 'SKIPPED')
            OR source_sha256 IS NOT NULL
        ),
    CONSTRAINT load_log_error_text_check
        CHECK (
            (
                status = 'FAILED'
                AND error_text IS NOT NULL
                AND btrim(error_text) <> ''
            )
            OR (
                status IN ('STARTED', 'SUCCESS', 'SKIPPED')
                AND error_text IS NULL
            )
        )
);

-- Failed attempts and skipped reruns may share a hash; successes may not.
CREATE UNIQUE INDEX IF NOT EXISTS load_log_success_sha256_uidx
    ON raw.load_log (source_sha256)
    WHERE status = 'SUCCESS';
