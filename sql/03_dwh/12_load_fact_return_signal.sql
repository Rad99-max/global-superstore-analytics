-- Execute the entire file with stop-on-error enabled. On error issue ROLLBACK.
-- Only fact_return_signal is written. A signal is not a line-level return fact.
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;

DO $return_signals$
DECLARE
    v_load_id CONSTANT UUID := COALESCE(NULLIF(current_setting('pipeline.load_id', true), ''), 'pipeline.load_id is not set: run via run_pipeline.py or SET pipeline.load_id')::uuid;
    v_loaded_at CONSTANT TIMESTAMPTZ := clock_timestamp();
    v_logged_rows BIGINT;
    v_rows BIGINT;
    v_written BIGINT;
    v_differences BIGINT;
    v_matched BIGINT;
    v_region_mismatch BIGINT;
    v_ambiguous BIGINT;
    v_not_found BIGINT;
BEGIN
    IF current_database() <> 'sales_dwh' THEN
        RAISE EXCEPTION 'Expected sales_dwh; return signal load cancelled';
    END IF;

    SELECT returns_rows_loaded INTO v_logged_rows
    FROM raw.load_log
    WHERE load_id = v_load_id AND status = 'SUCCESS'
    FOR SHARE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'load_id % does not have a SUCCESS journal entry', v_load_id;
    END IF;

    SELECT count(*) INTO v_rows FROM staging.returns WHERE _load_id = v_load_id;
    IF v_rows <> v_logged_rows OR v_rows <> 1079 THEN
        RAISE EXCEPTION 'Unexpected STAGING return signal count: %', v_rows;
    END IF;

    IF (SELECT count(*) FROM raw.returns WHERE _load_id = v_load_id) <> v_rows
       OR EXISTS (
           SELECT 1 FROM staging.returns AS s
           LEFT JOIN raw.returns AS r ON r._raw_id = s._raw_id
           WHERE s._load_id = v_load_id
             AND (r._raw_id IS NULL OR r._load_id IS DISTINCT FROM v_load_id)
       ) THEN
        RAISE EXCEPTION 'STAGING Returns coverage differs from selected RAW batch';
    END IF;

    IF (SELECT count(*) FROM dwh.fact_order WHERE _load_id = v_load_id) <> 25739
       OR EXISTS (SELECT 1 FROM dwh.fact_order WHERE _load_id IS DISTINCT FROM v_load_id)
       OR EXISTS (
           SELECT 1 FROM dwh.fact_order AS o
           LEFT JOIN dwh.dim_geography AS g ON g.geography_key = o.geography_key
           WHERE o._load_id = v_load_id AND g.geography_key IS NULL
       ) THEN
        RAISE EXCEPTION 'Selected fact_order snapshot or its geography references are incomplete';
    END IF;

    IF EXISTS (SELECT 1 FROM dwh.fact_return_signal WHERE _load_id IS DISTINCT FROM v_load_id)
       OR EXISTS (
           SELECT _raw_id FROM dwh.fact_return_signal
           EXCEPT SELECT _raw_id FROM staging.returns WHERE _load_id = v_load_id
       ) THEN
        RAISE EXCEPTION 'Existing return signals contain another snapshot or source row';
    END IF;

    WITH order_candidates AS MATERIALIZED (
        -- Count before looking at Region. No candidate is selected by Region.
        SELECT order_id, count(DISTINCT order_key) AS candidate_order_count
        FROM dwh.fact_order WHERE _load_id = v_load_id GROUP BY order_id
    ), resolved AS MATERIALIZED (
        SELECT r.order_id AS source_order_id, r.region AS source_region, r.returned,
               COALESCE(c.candidate_order_count, 0::BIGINT) AS candidate_order_count,
               CASE
                   WHEN COALESCE(c.candidate_order_count, 0) = 0 THEN 'ORDER_NOT_FOUND'
                   WHEN c.candidate_order_count > 1 THEN 'AMBIGUOUS_ORDER_ID'
                   WHEN r.region IS NOT NULL AND r.region <> '' AND r.region = g.region
                       THEN 'MATCHED'
                   ELSE 'REGION_MISMATCH'
               END AS match_status,
               CASE WHEN c.candidate_order_count = 1
                          AND r.region IS NOT NULL AND r.region <> '' AND r.region = g.region
                    THEN o.order_key ELSE NULL::BIGINT END AS order_key,
               r._raw_id, r._load_id, r._dq_flags
        FROM staging.returns AS r
        LEFT JOIN order_candidates AS c ON c.order_id = r.order_id
        -- Only a singleton candidate set permits reading the order reference.
        LEFT JOIN dwh.fact_order AS o
          ON o.order_id = r.order_id AND o._load_id = v_load_id
         AND c.candidate_order_count = 1
        LEFT JOIN dwh.dim_geography AS g ON g.geography_key = o.geography_key
        WHERE r._load_id = v_load_id
    )
    INSERT INTO dwh.fact_return_signal (
        source_order_id, source_region, returned, order_key, match_status,
        candidate_order_count, _raw_id, _load_id, _dq_flags, _dwh_loaded_at
    )
    SELECT source_order_id, source_region, returned, order_key, match_status,
           candidate_order_count, _raw_id, _load_id, _dq_flags, v_loaded_at
    FROM resolved
    ORDER BY _raw_id
    ON CONFLICT (_raw_id) DO UPDATE SET
        source_order_id = EXCLUDED.source_order_id,
        source_region = EXCLUDED.source_region,
        returned = EXCLUDED.returned,
        order_key = EXCLUDED.order_key,
        match_status = EXCLUDED.match_status,
        candidate_order_count = EXCLUDED.candidate_order_count,
        _dq_flags = EXCLUDED._dq_flags,
        _dwh_loaded_at = EXCLUDED._dwh_loaded_at;

    GET DIAGNOSTICS v_written = ROW_COUNT;
    IF v_written <> v_rows
       OR (SELECT count(*) FROM dwh.fact_return_signal WHERE _load_id = v_load_id) <> v_rows
       OR (SELECT count(DISTINCT _raw_id) FROM dwh.fact_return_signal
           WHERE _load_id = v_load_id) <> v_rows THEN
        RAISE EXCEPTION 'Return signal counts show missing or multiplied source rows';
    END IF;

    -- Independently count candidates for each source record, retaining unmatched
    -- and repeated source signals. Geography is read from an existing order only.
    WITH counts_per_signal AS MATERIALIZED (
        SELECT r._raw_id, count(DISTINCT o.order_key) AS candidates
        FROM staging.returns AS r
        LEFT JOIN dwh.fact_order AS o
          ON o.order_id = r.order_id AND o._load_id = v_load_id
        WHERE r._load_id = v_load_id
        GROUP BY r._raw_id
    ), expected AS MATERIALIZED (
        SELECT r.*, c.candidates,
               CASE WHEN c.candidates = 0 THEN 'ORDER_NOT_FOUND'
                    WHEN c.candidates > 1 THEN 'AMBIGUOUS_ORDER_ID'
                    WHEN r.region IS NOT NULL AND r.region <> '' AND r.region = g.region
                        THEN 'MATCHED'
                    ELSE 'REGION_MISMATCH' END AS expected_status,
               CASE WHEN c.candidates = 1
                          AND r.region IS NOT NULL AND r.region <> '' AND r.region = g.region
                    THEN o.order_key ELSE NULL::BIGINT END AS expected_order_key
        FROM staging.returns AS r
        JOIN counts_per_signal AS c ON c._raw_id = r._raw_id
        LEFT JOIN dwh.fact_order AS o
          ON o.order_id = r.order_id AND o._load_id = v_load_id AND c.candidates = 1
        LEFT JOIN dwh.dim_geography AS g ON g.geography_key = o.geography_key
        WHERE r._load_id = v_load_id
    )
    SELECT count(*) INTO v_differences
    FROM expected AS e
    LEFT JOIN dwh.fact_return_signal AS f ON f._raw_id = e._raw_id
    WHERE f.return_signal_key IS NULL
       OR (f.source_order_id, f.source_region, f.returned, f.order_key,
           f.match_status, f.candidate_order_count, f._load_id, f._dq_flags, f._dwh_loaded_at)
          IS DISTINCT FROM
          (e.order_id, e.region, e.returned, e.expected_order_key,
           e.expected_status, e.candidates, e._load_id, e._dq_flags, v_loaded_at);
    IF v_differences <> 0 THEN
        RAISE EXCEPTION '% return signals differ from source or matching rules', v_differences;
    END IF;

    SELECT count(*) FILTER (WHERE match_status = 'MATCHED'),
           count(*) FILTER (WHERE match_status = 'REGION_MISMATCH'),
           count(*) FILTER (WHERE match_status = 'AMBIGUOUS_ORDER_ID'),
           count(*) FILTER (WHERE match_status = 'ORDER_NOT_FOUND')
    INTO v_matched, v_region_mismatch, v_ambiguous, v_not_found
    FROM dwh.fact_return_signal WHERE _load_id = v_load_id;
    IF (v_matched, v_region_mismatch, v_ambiguous, v_not_found)
       IS DISTINCT FROM (1071::BIGINT, 6::BIGINT, 2::BIGINT, 0::BIGINT) THEN
        RAISE EXCEPTION 'Unexpected return signal distribution: matched %, mismatch %, ambiguous %, missing %',
            v_matched, v_region_mismatch, v_ambiguous, v_not_found;
    END IF;

    RAISE NOTICE 'fact_return_signal load_id=% loaded_at=% rows=%', v_load_id, v_loaded_at, v_rows;
    RAISE NOTICE 'MATCHED=% REGION_MISMATCH=% AMBIGUOUS_ORDER_ID=% ORDER_NOT_FOUND=%',
        v_matched, v_region_mismatch, v_ambiguous, v_not_found;
END;
$return_signals$ LANGUAGE plpgsql;

COMMIT;
