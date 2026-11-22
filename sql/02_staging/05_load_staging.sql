-- Execute the whole file, with stop-on-error enabled in the SQL client.
-- On an error the transaction is aborted: issue ROLLBACK, not a partial retry.
-- RAW is immutable here. Only this explicitly selected STAGING batch is rebuilt.
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;

-- Preserve round-trip float text for out-of-range Discount values.
SET LOCAL extra_float_digits = 3;

DO $staging$
DECLARE
    v_load_id CONSTANT UUID := COALESCE(NULLIF(current_setting('pipeline.load_id', true), ''), 'pipeline.load_id is not set: run via run_pipeline.py or SET pipeline.load_id')::uuid;
    v_staged_at CONSTANT TIMESTAMPTZ := clock_timestamp();
    v_source_file TEXT;
    v_log_orders BIGINT;
    v_log_returns BIGINT;
    v_log_people BIGINT;
    v_expected_orders BIGINT;
    v_expected_returns BIGINT;
    v_expected_people BIGINT;
    v_actual_orders BIGINT;
    v_actual_returns BIGINT;
    v_actual_people BIGINT;
    v_flags JSONB;
BEGIN
    IF current_database() <> 'sales_dwh' THEN
        RAISE EXCEPTION 'Expected database sales_dwh; STAGING rebuild cancelled';
    END IF;

    SELECT source_file, orders_rows_loaded, returns_rows_loaded, people_rows_loaded
    INTO v_source_file, v_log_orders, v_log_returns, v_log_people
    FROM raw.load_log
    WHERE load_id = v_load_id AND status = 'SUCCESS'
    FOR SHARE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'load_id % does not have a SUCCESS journal entry', v_load_id;
    END IF;

    SELECT count(*) INTO v_expected_orders FROM raw.orders WHERE _load_id = v_load_id;
    SELECT count(*) INTO v_expected_returns FROM raw.returns WHERE _load_id = v_load_id;
    SELECT count(*) INTO v_expected_people FROM raw.people WHERE _load_id = v_load_id;

    IF (v_expected_orders, v_expected_returns, v_expected_people)
       IS DISTINCT FROM (v_log_orders, v_log_returns, v_log_people) THEN
        RAISE EXCEPTION 'RAW counts (%, %, %) differ from SUCCESS journal (%, %, %)',
            v_expected_orders, v_expected_returns, v_expected_people,
            v_log_orders, v_log_returns, v_log_people;
    END IF;

    -- Technical provenance failures stop the whole batch, not individual rows.
    IF EXISTS (
        SELECT 1
        FROM (
            SELECT _raw_id, _loaded_at, _source_file, _source_sheet, _source_row_number,
                   'Orders'::TEXT AS expected_sheet
            FROM raw.orders WHERE _load_id = v_load_id
            UNION ALL
            SELECT _raw_id, _loaded_at, _source_file, _source_sheet, _source_row_number, 'Returns'
            FROM raw.returns WHERE _load_id = v_load_id
            UNION ALL
            SELECT _raw_id, _loaded_at, _source_file, _source_sheet, _source_row_number, 'People'
            FROM raw.people WHERE _load_id = v_load_id
        ) AS source_rows
        WHERE _raw_id IS NULL OR _loaded_at IS NULL
           OR _source_file IS DISTINCT FROM v_source_file
           OR _source_sheet IS DISTINCT FROM expected_sheet
           OR _source_row_number IS NULL OR _source_row_number < 2
    ) THEN
        RAISE EXCEPTION 'Invalid RAW provenance for load_id %', v_load_id;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM (
            SELECT 'Orders'::TEXT AS sheet, _source_row_number AS row_number
            FROM raw.orders WHERE _load_id = v_load_id
            UNION ALL
            SELECT 'Returns', _source_row_number FROM raw.returns WHERE _load_id = v_load_id
            UNION ALL
            SELECT 'People', _source_row_number FROM raw.people WHERE _load_id = v_load_id
        ) AS source_rows
        GROUP BY sheet
        HAVING min(row_number) <> 2
            OR max(row_number)::BIGINT <> count(*) + 1
            OR count(DISTINCT row_number) <> count(*)
    ) THEN
        RAISE EXCEPTION 'RAW physical source-row range has gaps or duplicates for load_id %', v_load_id;
    END IF;

    DELETE FROM staging.orders WHERE _load_id = v_load_id;
    DELETE FROM staging.returns WHERE _load_id = v_load_id;
    DELETE FROM staging.people WHERE _load_id = v_load_id;

    WITH
    clean_orders AS MATERIALIZED (
        SELECT
            r."Row ID" AS row_id,
            NULLIF(btrim(r."Order ID", ' '), '') AS order_id,
            r."Order Date" AS order_date,
            r."Ship Date" AS ship_date,
            NULLIF(btrim(r."Ship Mode", ' '), '') AS ship_mode,
            NULLIF(btrim(r."Customer ID", ' '), '') AS customer_id,
            NULLIF(btrim(r."Customer Name", ' '), '') AS customer_name,
            NULLIF(btrim(r."Segment", ' '), '') AS segment,
            NULLIF(btrim(r."Postal Code", ' '), '') AS postal_code,
            NULLIF(btrim(r."City", ' '), '') AS city,
            NULLIF(btrim(r."State", ' '), '') AS state,
            NULLIF(btrim(r."Country", ' '), '') AS country,
            NULLIF(btrim(r."Region", ' '), '') AS region,
            NULLIF(btrim(r."Market", ' '), '') AS market,
            NULLIF(btrim(r."Product ID", ' '), '') AS product_id,
            NULLIF(btrim(r."Category", ' '), '') AS category,
            NULLIF(btrim(r."Sub-Category", ' '), '') AS sub_category,
            NULLIF(btrim(replace(r."Product Name", chr(160), ' '), ' '), '') AS product_name,
            r."Sales" AS sales,
            r."Quantity" AS quantity,
            CASE
                WHEN r."Discount" IS NULL
                  OR r."Discount" IN ('NaN'::FLOAT8, 'Infinity'::FLOAT8, '-Infinity'::FLOAT8)
                    THEN NULL::NUMERIC
                WHEN r."Discount" BETWEEN 0 AND 1
                    THEN ROUND(r."Discount"::NUMERIC, 3)
                ELSE r."Discount"::TEXT::NUMERIC
            END AS discount,
            r."Profit" AS profit,
            r."Shipping Cost" AS shipping_cost,
            NULLIF(btrim(r."Order Priority", ' '), '') AS order_priority,
            r._raw_id, r._load_id, r._loaded_at,
            r._source_file, r._source_sheet, r._source_row_number,
            r."Discount" AS source_discount,
            strpos(r."Product Name", chr(160)) > 0 AS nbsp_normalized,
            ARRAY[
                r."Order ID", r."Ship Mode", r."Customer ID", r."Customer Name",
                r."Segment", r."Postal Code", r."City", r."State", r."Country",
                r."Region", r."Market", r."Product ID", r."Category", r."Sub-Category",
                replace(r."Product Name", chr(160), ' '), r."Order Priority"
            ] AS text_inputs,
            -- Duplicate content is measured on source business values, not
            -- on values that might coincide only after Discount rounding.
            to_jsonb(r) - ARRAY[
                'Row ID', '_raw_id', '_load_id', '_loaded_at',
                '_source_file', '_source_sheet', '_source_row_number'
            ]::TEXT[] AS source_content
        FROM raw.orders AS r
        WHERE r._load_id = v_load_id
    ),
    clean_returns AS MATERIALIZED (
        SELECT
            NULLIF(btrim(r."Returned", ' '), '') AS returned,
            NULLIF(btrim(r."Order ID", ' '), '') AS order_id,
            NULLIF(btrim(r."Region", ' '), '') AS region,
            r._raw_id, r._load_id, r._loaded_at,
            r._source_file, r._source_sheet, r._source_row_number,
            ARRAY[r."Returned", r."Order ID", r."Region"] AS text_inputs,
            to_jsonb(r) - ARRAY[
                '_raw_id', '_load_id', '_loaded_at',
                '_source_file', '_source_sheet', '_source_row_number'
            ]::TEXT[] AS source_content
        FROM raw.returns AS r
        WHERE r._load_id = v_load_id
    ),
    clean_people AS MATERIALIZED (
        SELECT
            NULLIF(btrim(replace(r."Person", chr(160), ' '), ' '), '') AS person,
            NULLIF(btrim(r."Region", ' '), '') AS region,
            r._raw_id, r._load_id, r._loaded_at,
            r._source_file, r._source_sheet, r._source_row_number,
            strpos(r."Person", chr(160)) > 0 AS nbsp_normalized,
            ARRAY[replace(r."Person", chr(160), ' '), r."Region"] AS text_inputs,
            to_jsonb(r) - ARRAY[
                '_raw_id', '_load_id', '_loaded_at',
                '_source_file', '_source_sheet', '_source_row_number'
            ]::TEXT[] AS source_content
        FROM raw.people AS r
        WHERE r._load_id = v_load_id
    ),
    conflicting_orders AS MATERIALIZED (
        SELECT order_id
        FROM clean_orders
        WHERE order_id IS NOT NULL
        GROUP BY order_id
        HAVING count(DISTINCT customer_id) > 1 OR count(DISTINCT region) > 1
    ),
    ambiguous_people_regions AS MATERIALIZED (
        SELECT region
        FROM clean_people
        WHERE region IS NOT NULL
        GROUP BY region
        HAVING count(DISTINCT person) > 1
    ),
    ambiguous_person_regions AS MATERIALIZED (
        SELECT person
        FROM clean_people
        WHERE person IS NOT NULL
        GROUP BY person
        HAVING count(DISTINCT region) > 1
    ),
    -- Materialize mismatch row keys once instead of rescanning the opposite
    -- sheet for every row. DISTINCT keeps multiple matches from multiplying rows.
    mismatch_orders AS MATERIALIZED (
        SELECT DISTINCT o._raw_id
        FROM clean_orders AS o
        JOIN clean_returns AS r ON r.order_id = o.order_id
        WHERE r.region IS DISTINCT FROM o.region
    ),
    mismatch_returns AS MATERIALIZED (
        SELECT DISTINCT r._raw_id
        FROM clean_returns AS r
        JOIN clean_orders AS o ON o.order_id = r.order_id
        WHERE o.region IS DISTINCT FROM r.region
    ),
    orders_analyzed AS (
        SELECT o.*,
               count(*) OVER (PARTITION BY row_id) AS row_id_count,
               count(*) OVER (PARTITION BY source_content) AS source_content_count
        FROM clean_orders AS o
    ),
    returns_analyzed AS (
        SELECT r.*, count(*) OVER (PARTITION BY source_content) AS source_content_count
        FROM clean_returns AS r
    ),
    people_analyzed AS (
        SELECT p.*, count(*) OVER (PARTITION BY source_content) AS source_content_count
        FROM clean_people AS p
    ),
    insert_orders AS (
        INSERT INTO staging.orders (
            row_id, order_id, order_date, ship_date, ship_mode, customer_id, customer_name,
            segment, postal_code, city, state, country, region, market, product_id,
            category, sub_category, product_name, sales, quantity, discount, profit,
            shipping_cost, order_priority,
            _raw_id, _load_id, _loaded_at, _source_file, _source_sheet,
            _source_row_number, _staged_at, _dq_flags
        )
        SELECT
            o.row_id, o.order_id, o.order_date, o.ship_date, o.ship_mode,
            o.customer_id, o.customer_name, o.segment, o.postal_code, o.city,
            o.state, o.country, o.region, o.market, o.product_id, o.category,
            o.sub_category, o.product_name, o.sales, o.quantity, o.discount,
            o.profit, o.shipping_cost, o.order_priority,
            o._raw_id, o._load_id, o._loaded_at, o._source_file, o._source_sheet,
            o._source_row_number, v_staged_at,
            array_remove(ARRAY[
                CASE WHEN EXISTS (
                    SELECT 1 FROM conflicting_orders AS c WHERE c.order_id = o.order_id
                ) THEN 'ORDER_ID_CUSTOMER_REGION_CONFLICT' END,
                CASE WHEN EXISTS (
                    SELECT 1 FROM mismatch_orders AS m WHERE m._raw_id = o._raw_id
                ) THEN 'RETURN_REGION_MISMATCH' END,
                CASE WHEN EXISTS (
                    SELECT 1 FROM conflicting_orders AS c WHERE c.order_id = o.order_id
                ) AND EXISTS (
                    SELECT 1 FROM clean_returns AS r WHERE r.order_id = o.order_id
                ) THEN 'RETURN_REFERENCE_AMBIGUOUS' END,
                CASE WHEN NOT EXISTS (
                    SELECT 1 FROM clean_people AS p
                    WHERE p.region = o.region AND p.person IS NOT NULL
                ) THEN 'PEOPLE_REGION_UNMATCHED' END,
                CASE WHEN EXISTS (
                    SELECT 1 FROM ambiguous_people_regions AS p WHERE p.region = o.region
                ) THEN 'PEOPLE_REGION_AMBIGUOUS' END,
                CASE WHEN EXISTS (
                    SELECT 1 FROM unnest(o.text_inputs) AS t(value)
                    WHERE t.value IS DISTINCT FROM btrim(t.value, ' ')
                ) THEN 'TEXT_TRIMMED' END,
                CASE WHEN o.nbsp_normalized THEN 'NBSP_NORMALIZED' END,
                CASE WHEN EXISTS (
                    SELECT 1 FROM unnest(o.text_inputs) AS t(value)
                    WHERE btrim(t.value, ' ') = ''
                ) THEN 'EMPTY_TEXT_NORMALIZED' END,
                CASE WHEN o.source_discount BETWEEN 0 AND 1
                    AND o.source_discount IS DISTINCT FROM o.discount::DOUBLE PRECISION
                    THEN 'DISCOUNT_FLOAT_CANONICALIZED' END,
                CASE WHEN o.source_discount NOT IN (
                    'NaN'::FLOAT8, 'Infinity'::FLOAT8, '-Infinity'::FLOAT8
                ) AND (o.source_discount < 0 OR o.source_discount > 1)
                    THEN 'DISCOUNT_OUT_OF_RANGE' END,
                CASE WHEN o.sales IN ('NaN'::FLOAT8, 'Infinity'::FLOAT8, '-Infinity'::FLOAT8)
                    OR o.profit IN ('NaN'::FLOAT8, 'Infinity'::FLOAT8, '-Infinity'::FLOAT8)
                    OR o.shipping_cost IN ('NaN'::FLOAT8, 'Infinity'::FLOAT8, '-Infinity'::FLOAT8)
                    OR o.source_discount IN ('NaN'::FLOAT8, 'Infinity'::FLOAT8, '-Infinity'::FLOAT8)
                    THEN 'NONFINITE_MEASURE' END,
                CASE WHEN o.row_id IS NULL OR o.order_id IS NULL
                    OR o.customer_id IS NULL OR o.product_id IS NULL
                    THEN 'MISSING_BUSINESS_ID' END,
                CASE WHEN o.order_date IS NULL OR o.ship_date IS NULL
                    OR o.sales IS NULL OR o.quantity IS NULL
                    OR o.source_discount IS NULL OR o.profit IS NULL OR o.shipping_cost IS NULL
                    OR EXISTS (
                        SELECT 1 FROM unnest(ARRAY[
                            o.ship_mode, o.customer_name, o.segment, o.city, o.state,
                            o.country, o.region, o.market, o.category, o.sub_category,
                            o.product_name, o.order_priority
                        ]) AS t(value) WHERE t.value IS NULL
                    ) THEN 'MISSING_BUSINESS_VALUE' END,
                CASE WHEN o.ship_date < o.order_date THEN 'SHIP_DATE_BEFORE_ORDER' END,
                -- These are review flags, not rejection criteria. Profit < 0 is valid.
                CASE WHEN o.sales <= 0 OR o.quantity <= 0 OR o.shipping_cost < 0
                    THEN 'MEASURE_VALUE_REVIEW' END,
                CASE WHEN o.row_id IS NOT NULL AND o.row_id_count > 1 THEN 'NONUNIQUE_ROW_ID' END,
                CASE WHEN o.source_content_count > 1 THEN 'DUPLICATE_SOURCE_CONTENT' END,
                CASE WHEN EXISTS (
                    SELECT 1 FROM unnest(ARRAY[
                        o.order_id, o.ship_mode, o.customer_id, o.customer_name,
                        o.segment, o.postal_code, o.city, o.state, o.country, o.region,
                        o.market, o.product_id, o.category, o.sub_category,
                        o.product_name, o.order_priority
                    ]) AS t(value)
                    WHERE t.value ~ '[[:cntrl:]]'
                       OR t.value ~ U&'[\00A0\1680\180E\2000-\200F\2028-\202F\205F\2060-\206F\3000\FEFF]'
                ) THEN 'UNUSUAL_TEXT_REVIEW' END
            ]::TEXT[], NULL)
        FROM orders_analyzed AS o
        RETURNING _raw_id
    ),
    insert_returns AS (
        INSERT INTO staging.returns (
            returned, order_id, region, _raw_id, _load_id, _loaded_at,
            _source_file, _source_sheet, _source_row_number, _staged_at, _dq_flags
        )
        SELECT
            r.returned, r.order_id, r.region, r._raw_id, r._load_id, r._loaded_at,
            r._source_file, r._source_sheet, r._source_row_number, v_staged_at,
            array_remove(ARRAY[
                CASE WHEN EXISTS (
                    SELECT 1 FROM mismatch_returns AS m WHERE m._raw_id = r._raw_id
                ) THEN 'RETURN_REGION_MISMATCH' END,
                CASE WHEN EXISTS (
                    SELECT 1 FROM conflicting_orders AS c WHERE c.order_id = r.order_id
                ) THEN 'ORDER_REFERENCE_AMBIGUOUS' END,
                CASE WHEN NOT EXISTS (
                    SELECT 1 FROM clean_orders AS o WHERE o.order_id = r.order_id
                ) THEN 'ORDER_NOT_FOUND' END,
                CASE WHEN r.returned IS DISTINCT FROM 'Yes' THEN 'RETURNED_VALUE_REVIEW' END,
                CASE WHEN r.order_id IS NULL THEN 'MISSING_BUSINESS_ID' END,
                CASE WHEN r.returned IS NULL OR r.region IS NULL THEN 'MISSING_BUSINESS_VALUE' END,
                CASE WHEN EXISTS (
                    SELECT 1 FROM unnest(r.text_inputs) AS t(value)
                    WHERE t.value IS DISTINCT FROM btrim(t.value, ' ')
                ) THEN 'TEXT_TRIMMED' END,
                CASE WHEN EXISTS (
                    SELECT 1 FROM unnest(r.text_inputs) AS t(value)
                    WHERE btrim(t.value, ' ') = ''
                ) THEN 'EMPTY_TEXT_NORMALIZED' END,
                CASE WHEN r.source_content_count > 1 THEN 'DUPLICATE_SOURCE_CONTENT' END,
                CASE WHEN EXISTS (
                    SELECT 1 FROM unnest(ARRAY[r.returned, r.order_id, r.region]) AS t(value)
                    WHERE t.value ~ '[[:cntrl:]]'
                       OR t.value ~ U&'[\00A0\1680\180E\2000-\200F\2028-\202F\205F\2060-\206F\3000\FEFF]'
                ) THEN 'UNUSUAL_TEXT_REVIEW' END
            ]::TEXT[], NULL)
        FROM returns_analyzed AS r
        RETURNING _raw_id
    ),
    insert_people AS (
        INSERT INTO staging.people (
            person, region, _raw_id, _load_id, _loaded_at,
            _source_file, _source_sheet, _source_row_number, _staged_at, _dq_flags
        )
        SELECT
            p.person, p.region, p._raw_id, p._load_id, p._loaded_at,
            p._source_file, p._source_sheet, p._source_row_number, v_staged_at,
            array_remove(ARRAY[
                CASE WHEN p.person IS NULL OR p.region IS NULL THEN 'MISSING_BUSINESS_VALUE' END,
                CASE WHEN EXISTS (
                    SELECT 1 FROM ambiguous_people_regions AS a WHERE a.region = p.region
                ) THEN 'PEOPLE_REGION_AMBIGUOUS' END,
                CASE WHEN EXISTS (
                    SELECT 1 FROM ambiguous_person_regions AS a WHERE a.person = p.person
                ) THEN 'PERSON_REGION_AMBIGUOUS' END,
                CASE WHEN EXISTS (
                    SELECT 1 FROM unnest(p.text_inputs) AS t(value)
                    WHERE t.value IS DISTINCT FROM btrim(t.value, ' ')
                ) THEN 'TEXT_TRIMMED' END,
                CASE WHEN p.nbsp_normalized THEN 'NBSP_NORMALIZED' END,
                CASE WHEN EXISTS (
                    SELECT 1 FROM unnest(p.text_inputs) AS t(value)
                    WHERE btrim(t.value, ' ') = ''
                ) THEN 'EMPTY_TEXT_NORMALIZED' END,
                CASE WHEN p.source_content_count > 1 THEN 'DUPLICATE_SOURCE_CONTENT' END,
                CASE WHEN EXISTS (
                    SELECT 1 FROM unnest(ARRAY[p.person, p.region]) AS t(value)
                    WHERE t.value ~ '[[:cntrl:]]'
                       OR t.value ~ U&'[\00A0\1680\180E\2000-\200F\2028-\202F\205F\2060-\206F\3000\FEFF]'
                ) THEN 'UNUSUAL_TEXT_REVIEW' END
            ]::TEXT[], NULL)
        FROM people_analyzed AS p
        RETURNING _raw_id
    )
    SELECT (SELECT count(*) FROM insert_orders),
           (SELECT count(*) FROM insert_returns),
           (SELECT count(*) FROM insert_people)
    INTO v_actual_orders, v_actual_returns, v_actual_people;

    IF (v_actual_orders, v_actual_returns, v_actual_people)
       IS DISTINCT FROM (v_expected_orders, v_expected_returns, v_expected_people) THEN
        RAISE EXCEPTION 'Inserted counts (%, %, %) differ from RAW (%, %, %)',
            v_actual_orders, v_actual_returns, v_actual_people,
            v_expected_orders, v_expected_returns, v_expected_people;
    END IF;

    -- A separate statement sees all inserts and reconciles persisted batch counts.
    SELECT count(*) INTO v_actual_orders FROM staging.orders WHERE _load_id = v_load_id;
    SELECT count(*) INTO v_actual_returns FROM staging.returns WHERE _load_id = v_load_id;
    SELECT count(*) INTO v_actual_people FROM staging.people WHERE _load_id = v_load_id;

    IF (v_actual_orders, v_actual_returns, v_actual_people)
       IS DISTINCT FROM (v_expected_orders, v_expected_returns, v_expected_people) THEN
        RAISE EXCEPTION 'STAGING batch counts do not match RAW; rebuild cancelled';
    END IF;

    -- Counts + unchanged lineage ensure physical source-row coverage per sheet.
    IF EXISTS (
        SELECT 1
        FROM (
            SELECT s._raw_id, s._load_id, s._loaded_at, s._source_file,
                   s._source_sheet, s._source_row_number, s._staged_at,
                   r._load_id AS raw_load_id, r._loaded_at AS raw_loaded_at,
                   r._source_file AS raw_source_file, r._source_sheet AS raw_source_sheet,
                   r._source_row_number AS raw_source_row_number
            FROM staging.orders AS s JOIN raw.orders AS r ON r._raw_id = s._raw_id
            WHERE s._load_id = v_load_id
            UNION ALL
            SELECT s._raw_id, s._load_id, s._loaded_at, s._source_file,
                   s._source_sheet, s._source_row_number, s._staged_at,
                   r._load_id, r._loaded_at, r._source_file, r._source_sheet, r._source_row_number
            FROM staging.returns AS s JOIN raw.returns AS r ON r._raw_id = s._raw_id
            WHERE s._load_id = v_load_id
            UNION ALL
            SELECT s._raw_id, s._load_id, s._loaded_at, s._source_file,
                   s._source_sheet, s._source_row_number, s._staged_at,
                   r._load_id, r._loaded_at, r._source_file, r._source_sheet, r._source_row_number
            FROM staging.people AS s JOIN raw.people AS r ON r._raw_id = s._raw_id
            WHERE s._load_id = v_load_id
        ) AS lineage
        WHERE (_load_id, _loaded_at, _source_file, _source_sheet, _source_row_number)
           IS DISTINCT FROM (raw_load_id, raw_loaded_at, raw_source_file, raw_source_sheet, raw_source_row_number)
           OR _staged_at IS DISTINCT FROM v_staged_at
    ) THEN
        RAISE EXCEPTION 'STAGING lineage differs from RAW; rebuild cancelled';
    END IF;

    RAISE NOTICE 'STAGING load_id=% staged_at=% orders=% returns=% people=%',
        v_load_id, v_staged_at, v_actual_orders, v_actual_returns, v_actual_people;

    SELECT COALESCE(jsonb_object_agg(sheet || ':' || flag, occurrences), '{}'::JSONB)
    INTO v_flags
    FROM (
        SELECT sheet, flag, count(*) AS occurrences
        FROM (
            SELECT 'orders'::TEXT AS sheet, unnest(_dq_flags) AS flag
            FROM staging.orders WHERE _load_id = v_load_id
            UNION ALL
            SELECT 'returns', unnest(_dq_flags) FROM staging.returns WHERE _load_id = v_load_id
            UNION ALL
            SELECT 'people', unnest(_dq_flags) FROM staging.people WHERE _load_id = v_load_id
        ) AS flags
        GROUP BY sheet, flag
    ) AS counts;
    RAISE NOTICE 'STAGING DQ flags: %', v_flags;
END;
$staging$ LANGUAGE plpgsql;

COMMIT;
