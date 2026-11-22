-- Execute the entire file with stop-on-error enabled. On error issue ROLLBACK.
-- Only fact_order is written; dimensions and source layers remain unchanged.
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;
SET LOCAL extra_float_digits = 3;

DO $orders$
DECLARE
    v_load_id CONSTANT UUID := COALESCE(NULLIF(current_setting('pipeline.load_id', true), ''), 'pipeline.load_id is not set: run via run_pipeline.py or SET pipeline.load_id')::uuid;
    v_loaded_at CONSTANT TIMESTAMPTZ := clock_timestamp();
    v_logged_lines BIGINT;
    v_lines BIGINT;
    v_orders BIGINT;
    v_written BIGINT;
BEGIN
    IF current_database() <> 'sales_dwh' THEN
        RAISE EXCEPTION 'Expected sales_dwh; fact_order load cancelled';
    END IF;

    SELECT orders_rows_loaded INTO v_logged_lines
    FROM raw.load_log
    WHERE load_id = v_load_id AND status = 'SUCCESS'
    FOR SHARE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'load_id % does not have a SUCCESS journal entry', v_load_id;
    END IF;

    SELECT count(*), count(DISTINCT (order_id, customer_id))
    INTO v_lines, v_orders
    FROM staging.orders WHERE _load_id = v_load_id;
    IF v_lines <> v_logged_lines OR v_lines <> 51290 OR v_orders <> 25739 THEN
        RAISE EXCEPTION 'Unexpected source counts: lines %, orders %', v_lines, v_orders;
    END IF;

    IF (SELECT count(*) FROM raw.orders WHERE _load_id = v_load_id) <> v_lines
       OR EXISTS (
           SELECT 1 FROM staging.orders AS s
           LEFT JOIN raw.orders AS r ON r._raw_id = s._raw_id
           WHERE s._load_id = v_load_id
             AND (r._raw_id IS NULL OR r._load_id IS DISTINCT FROM v_load_id)
       ) THEN
        RAISE EXCEPTION 'STAGING coverage differs from selected RAW batch';
    END IF;

    IF EXISTS (
        SELECT 1 FROM staging.orders
        WHERE _load_id = v_load_id
          AND (order_id IS NULL OR customer_id IS NULL OR order_date IS NULL
               OR market IS NULL OR region IS NULL OR country IS NULL)
    ) THEN
        RAISE EXCEPTION 'Missing order business key, Order Date or Geography; DQ decision required';
    END IF;

    -- Validate dependency on the full order business key, not Order ID alone.
    -- DISTINCT tuples detect conflicting attributes without choosing MIN/MAX.
    IF EXISTS (
        SELECT order_id, customer_id
        FROM (
            SELECT DISTINCT order_id, customer_id, order_date, market, region, country
            FROM staging.orders WHERE _load_id = v_load_id
        ) AS order_attributes
        GROUP BY order_id, customer_id HAVING count(*) > 1
    ) THEN
        RAISE EXCEPTION 'Order does not determine one Order Date and Geography';
    END IF;

    IF EXISTS (
        SELECT 1 FROM staging.orders
        WHERE _load_id = v_load_id
          AND (sales IN ('NaN'::FLOAT8, 'Infinity'::FLOAT8, '-Infinity'::FLOAT8)
               OR profit IN ('NaN'::FLOAT8, 'Infinity'::FLOAT8, '-Infinity'::FLOAT8)
               OR shipping_cost IN ('NaN'::FLOAT8, 'Infinity'::FLOAT8, '-Infinity'::FLOAT8))
    ) THEN
        RAISE EXCEPTION 'Nonfinite monetary measure requires a DQ decision before aggregation';
    END IF;

    -- LEFT JOIN checks run before the resolving INNER JOIN, so no line is lost.
    IF EXISTS (
        SELECT 1 FROM staging.orders AS s
        LEFT JOIN dwh.dim_customer AS c ON c.customer_id = s.customer_id
        LEFT JOIN dwh.dim_geography AS g
          ON (g.market, g.region, g.country) = (s.market, s.region, s.country)
        LEFT JOIN dwh.dim_date AS d ON d.calendar_date = s.order_date
        WHERE s._load_id = v_load_id
          AND (c.customer_key IS NULL OR g.geography_key IS NULL OR d.date_key IS NULL
               OR (c.customer_name, c.segment) IS DISTINCT FROM (s.customer_name, s.segment))
    ) THEN
        RAISE EXCEPTION 'Required dimension key is missing or customer attributes differ';
    END IF;

    -- Other snapshots require a separately approved publication policy.
    IF EXISTS (SELECT 1 FROM dwh.fact_order WHERE _load_id IS DISTINCT FROM v_load_id)
       OR EXISTS (
           SELECT order_id, customer_key FROM dwh.fact_order
           EXCEPT
           SELECT s.order_id, c.customer_key
           FROM staging.orders AS s
           JOIN dwh.dim_customer AS c ON c.customer_id = s.customer_id
           WHERE s._load_id = v_load_id
       ) THEN
        RAISE EXCEPTION 'Existing fact_order contains another snapshot or source key';
    END IF;

    WITH source_lines AS MATERIALIZED (
        SELECT s.order_id, s.customer_id, c.customer_key, g.geography_key,
               d.date_key AS order_date_key, s.quantity,
               s.sales::TEXT::NUMERIC AS sales,
               s.profit::TEXT::NUMERIC AS profit,
               s.shipping_cost::TEXT::NUMERIC AS shipping_cost,
               s._dq_flags
        FROM staging.orders AS s
        JOIN dwh.dim_customer AS c ON c.customer_id = s.customer_id
        JOIN dwh.dim_geography AS g
          ON (g.market, g.region, g.country) = (s.market, s.region, s.country)
        JOIN dwh.dim_date AS d ON d.calendar_date = s.order_date
        WHERE s._load_id = v_load_id
    ), order_totals AS (
        SELECT order_id, customer_id, customer_key, geography_key, order_date_key,
               count(*) AS line_count, sum(quantity) AS total_quantity,
               sum(sales) AS total_sales, sum(profit) AS total_profit,
               sum(shipping_cost) AS total_shipping_cost
        FROM source_lines
        GROUP BY order_id, customer_id, customer_key, geography_key, order_date_key
    ), order_flags AS (
        -- Unnest separately: multiple flags must never multiply monetary measures.
        SELECT s.order_id, s.customer_id,
               array_agg(DISTINCT f.flag ORDER BY f.flag) AS flags
        FROM source_lines AS s
        CROSS JOIN LATERAL unnest(s._dq_flags) AS f(flag)
        GROUP BY s.order_id, s.customer_id
    )
    INSERT INTO dwh.fact_order (
        order_id, customer_key, geography_key, order_date_key, line_count,
        total_quantity, total_sales, total_profit, total_shipping_cost,
        _load_id, _dq_flags, _dwh_loaded_at
    )
    SELECT t.order_id, t.customer_key, t.geography_key, t.order_date_key, t.line_count,
           t.total_quantity, t.total_sales, t.total_profit, t.total_shipping_cost,
           v_load_id, COALESCE(f.flags, ARRAY[]::TEXT[]), v_loaded_at
    FROM order_totals AS t
    LEFT JOIN order_flags AS f
      ON f.order_id = t.order_id AND f.customer_id = t.customer_id
    ORDER BY t.order_id, t.customer_key
    ON CONFLICT (order_id, customer_key) DO UPDATE SET
        geography_key = EXCLUDED.geography_key,
        order_date_key = EXCLUDED.order_date_key,
        line_count = EXCLUDED.line_count,
        total_quantity = EXCLUDED.total_quantity,
        total_sales = EXCLUDED.total_sales,
        total_profit = EXCLUDED.total_profit,
        total_shipping_cost = EXCLUDED.total_shipping_cost,
        _dq_flags = EXCLUDED._dq_flags,
        _dwh_loaded_at = EXCLUDED._dwh_loaded_at;

    GET DIAGNOSTICS v_written = ROW_COUNT;
    IF v_written <> v_orders
       OR (SELECT count(*) FROM dwh.fact_order WHERE _load_id = v_load_id) <> v_orders THEN
        RAISE EXCEPTION 'fact_order count differs from % expected orders', v_orders;
    END IF;

    -- Independently reconstruct each expected order, including its flag union.
    WITH expected_totals AS (
        SELECT order_id, customer_id, order_date, market, region, country,
               count(*) AS line_count, sum(quantity) AS total_quantity,
               sum(sales::TEXT::NUMERIC) AS total_sales,
               sum(profit::TEXT::NUMERIC) AS total_profit,
               sum(shipping_cost::TEXT::NUMERIC) AS total_shipping_cost
        FROM staging.orders WHERE _load_id = v_load_id
        GROUP BY order_id, customer_id, order_date, market, region, country
    ), expected_flags AS MATERIALIZED (
        SELECT s.order_id, s.customer_id,
               array_agg(DISTINCT f.flag ORDER BY f.flag) AS flags
        FROM staging.orders AS s
        CROSS JOIN LATERAL unnest(s._dq_flags) AS f(flag)
        WHERE s._load_id = v_load_id
        GROUP BY s.order_id, s.customer_id
    )
    SELECT count(*) INTO v_written
    FROM expected_totals AS e
    JOIN dwh.dim_customer AS c ON c.customer_id = e.customer_id
    JOIN dwh.dim_geography AS g
      ON (g.market, g.region, g.country) = (e.market, e.region, e.country)
    JOIN dwh.dim_date AS d ON d.calendar_date = e.order_date
    LEFT JOIN expected_flags AS flags
      ON flags.order_id = e.order_id AND flags.customer_id = e.customer_id
    LEFT JOIN dwh.fact_order AS f
      ON f.order_id = e.order_id AND f.customer_key = c.customer_key
    WHERE f.order_key IS NULL
       OR (f.geography_key, f.order_date_key, f.line_count, f.total_quantity,
           f.total_sales, f.total_profit, f.total_shipping_cost,
           f._load_id, f._dq_flags, f._dwh_loaded_at)
          IS DISTINCT FROM
          (g.geography_key, d.date_key, e.line_count, e.total_quantity,
           e.total_sales, e.total_profit, e.total_shipping_cost,
           v_load_id, COALESCE(flags.flags, ARRAY[]::TEXT[]), v_loaded_at);

    IF v_written <> 0 THEN
        RAISE EXCEPTION '% fact_order rows differ from STAGING aggregates', v_written;
    END IF;

    IF (SELECT sum(line_count) FROM dwh.fact_order WHERE _load_id = v_load_id)
       IS DISTINCT FROM v_lines::NUMERIC THEN
        RAISE EXCEPTION 'fact_order line coverage differs from selected STAGING batch';
    END IF;

    RAISE NOTICE 'fact_order load_id=% loaded_at=% orders=% source_lines=%',
        v_load_id, v_loaded_at, v_orders, v_lines;
END;
$orders$ LANGUAGE plpgsql;

COMMIT;
