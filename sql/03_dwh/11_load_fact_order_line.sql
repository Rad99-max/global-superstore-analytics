-- Execute the entire file with stop-on-error enabled. On error issue ROLLBACK.
-- Only fact_order_line is written; no source row is deduplicated or aggregated.
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;
SET LOCAL extra_float_digits = 3;

DO $order_lines$
DECLARE
    v_load_id CONSTANT UUID := COALESCE(NULLIF(current_setting('pipeline.load_id', true), ''), 'pipeline.load_id is not set: run via run_pipeline.py or SET pipeline.load_id')::uuid;
    v_loaded_at CONSTANT TIMESTAMPTZ := clock_timestamp();
    v_logged_lines BIGINT;
    v_lines BIGINT;
    v_written BIGINT;
    v_differences BIGINT;
    v_source_totals RECORD;
    v_fact_totals RECORD;
    v_expected_groups JSONB;
    v_actual_groups JSONB;
BEGIN
    IF current_database() <> 'sales_dwh' THEN
        RAISE EXCEPTION 'Expected sales_dwh; fact_order_line load cancelled';
    END IF;

    SELECT orders_rows_loaded INTO v_logged_lines
    FROM raw.load_log
    WHERE load_id = v_load_id AND status = 'SUCCESS'
    FOR SHARE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'load_id % does not have a SUCCESS journal entry', v_load_id;
    END IF;

    SELECT count(*) INTO v_lines FROM staging.orders WHERE _load_id = v_load_id;
    IF v_lines <> v_logged_lines OR v_lines <> 51290 THEN
        RAISE EXCEPTION 'Unexpected STAGING line count: %', v_lines;
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
          AND (order_id IS NULL OR customer_id IS NULL OR product_id IS NULL
               OR market IS NULL OR region IS NULL OR country IS NULL OR order_date IS NULL)
    ) THEN
        RAISE EXCEPTION 'Missing required business key or Order Date; DQ decision required';
    END IF;

    IF EXISTS (
        SELECT 1 FROM staging.orders
        WHERE _load_id = v_load_id
          AND (sales IN ('NaN'::FLOAT8, 'Infinity'::FLOAT8, '-Infinity'::FLOAT8)
               OR profit IN ('NaN'::FLOAT8, 'Infinity'::FLOAT8, '-Infinity'::FLOAT8)
               OR shipping_cost IN ('NaN'::FLOAT8, 'Infinity'::FLOAT8, '-Infinity'::FLOAT8))
    ) THEN
        RAISE EXCEPTION 'Nonfinite monetary measure requires a DQ decision';
    END IF;

    IF (SELECT count(*) FROM dwh.fact_order WHERE _load_id = v_load_id) <> 25739
       OR EXISTS (SELECT 1 FROM dwh.fact_order WHERE _load_id IS DISTINCT FROM v_load_id) THEN
        RAISE EXCEPTION 'fact_order must contain the selected 25739-order snapshot';
    END IF;

    -- Validate every reference before INNER JOIN resolution. A NULL Ship Date
    -- remains NULL; a populated date missing from the calendar is an error.
    IF EXISTS (
        SELECT 1 FROM staging.orders AS s
        LEFT JOIN dwh.dim_customer AS c ON c.customer_id = s.customer_id
        LEFT JOIN dwh.dim_product AS p ON p.product_id = s.product_id
        LEFT JOIN dwh.dim_geography AS g
          ON (g.market, g.region, g.country) = (s.market, s.region, s.country)
        LEFT JOIN dwh.dim_date AS od ON od.calendar_date = s.order_date
        LEFT JOIN dwh.dim_date AS sd ON sd.calendar_date = s.ship_date
        LEFT JOIN dwh.fact_order AS o
          ON o.order_id = s.order_id AND o.customer_key = c.customer_key
        WHERE s._load_id = v_load_id
          AND (c.customer_key IS NULL OR p.product_key IS NULL OR g.geography_key IS NULL
               OR od.date_key IS NULL OR (s.ship_date IS NOT NULL AND sd.date_key IS NULL)
               OR o.order_key IS NULL OR o._load_id IS DISTINCT FROM v_load_id
               OR (o.customer_key, o.geography_key, o.order_date_key)
                  IS DISTINCT FROM (c.customer_key, g.geography_key, od.date_key)
               OR (c.customer_name, c.segment) IS DISTINCT FROM (s.customer_name, s.segment)
               OR (p.product_name, p.category, p.sub_category)
                  IS DISTINCT FROM (s.product_name, s.category, s.sub_category))
    ) THEN
        RAISE EXCEPTION 'Missing dimension/order reference or inconsistent line-to-order attributes';
    END IF;

    IF EXISTS (SELECT 1 FROM dwh.fact_order_line WHERE _load_id IS DISTINCT FROM v_load_id)
       OR EXISTS (
           SELECT _raw_id FROM dwh.fact_order_line
           EXCEPT SELECT _raw_id FROM staging.orders WHERE _load_id = v_load_id
       ) THEN
        RAISE EXCEPTION 'Existing order lines contain another snapshot or source row';
    END IF;

    INSERT INTO dwh.fact_order_line (
        order_key, customer_key, product_key, geography_key, order_date_key, ship_date_key,
        row_id, quantity, sales, profit, shipping_cost, discount, discount_group,
        ship_mode, order_priority, city, state, postal_code,
        _raw_id, _load_id, _dq_flags, _dwh_loaded_at
    )
    SELECT o.order_key, c.customer_key, p.product_key, g.geography_key, od.date_key, sd.date_key,
           s.row_id, s.quantity, s.sales::TEXT::NUMERIC, s.profit::TEXT::NUMERIC,
           s.shipping_cost::TEXT::NUMERIC, s.discount,
           CASE
               WHEN s.discount IS NULL THEN 'UNKNOWN'
               WHEN s.discount < 0 OR s.discount > 1 THEN 'INVALID'
               WHEN s.discount = 0 THEN '0'
               WHEN s.discount <= 0.10 THEN '(0;0.10]'
               WHEN s.discount <= 0.20 THEN '(0.10;0.20]'
               WHEN s.discount <= 0.30 THEN '(0.20;0.30]'
               WHEN s.discount <= 0.40 THEN '(0.30;0.40]'
               WHEN s.discount <= 0.50 THEN '(0.40;0.50]'
               WHEN s.discount <= 0.60 THEN '(0.50;0.60]'
               WHEN s.discount <= 0.70 THEN '(0.60;0.70]'
               ELSE '(0.70;1]'
           END,
           s.ship_mode, s.order_priority, s.city, s.state, s.postal_code,
           s._raw_id, s._load_id, s._dq_flags, v_loaded_at
    FROM staging.orders AS s
    LEFT JOIN dwh.dim_customer AS c ON c.customer_id = s.customer_id
    LEFT JOIN dwh.dim_product AS p ON p.product_id = s.product_id
    LEFT JOIN dwh.dim_geography AS g
      ON (g.market, g.region, g.country) = (s.market, s.region, s.country)
    LEFT JOIN dwh.dim_date AS od ON od.calendar_date = s.order_date
    LEFT JOIN dwh.dim_date AS sd ON sd.calendar_date = s.ship_date
    JOIN dwh.fact_order AS o
      ON o.order_id = s.order_id AND o.customer_key = c.customer_key
    WHERE s._load_id = v_load_id
    ORDER BY s._raw_id
    ON CONFLICT (_raw_id) DO UPDATE SET
        order_key = EXCLUDED.order_key,
        customer_key = EXCLUDED.customer_key,
        product_key = EXCLUDED.product_key,
        geography_key = EXCLUDED.geography_key,
        order_date_key = EXCLUDED.order_date_key,
        ship_date_key = EXCLUDED.ship_date_key,
        row_id = EXCLUDED.row_id,
        quantity = EXCLUDED.quantity,
        sales = EXCLUDED.sales,
        profit = EXCLUDED.profit,
        shipping_cost = EXCLUDED.shipping_cost,
        discount = EXCLUDED.discount,
        discount_group = EXCLUDED.discount_group,
        ship_mode = EXCLUDED.ship_mode,
        order_priority = EXCLUDED.order_priority,
        city = EXCLUDED.city,
        state = EXCLUDED.state,
        postal_code = EXCLUDED.postal_code,
        _dq_flags = EXCLUDED._dq_flags,
        _dwh_loaded_at = EXCLUDED._dwh_loaded_at;

    GET DIAGNOSTICS v_written = ROW_COUNT;
    IF v_written <> v_lines
       OR (SELECT count(*) FROM dwh.fact_order_line WHERE _load_id = v_load_id) <> v_lines
       OR (SELECT count(DISTINCT _raw_id) FROM dwh.fact_order_line
           WHERE _load_id = v_load_id) <> v_lines THEN
        RAISE EXCEPTION 'Order line counts show missing or multiplied source rows';
    END IF;

    -- Compare every source row, its keys, measures, text, flags and provenance.
    SELECT count(*) INTO v_differences
    FROM staging.orders AS s
    JOIN dwh.dim_customer AS c ON c.customer_id = s.customer_id
    JOIN dwh.dim_product AS p ON p.product_id = s.product_id
    JOIN dwh.dim_geography AS g
      ON (g.market, g.region, g.country) = (s.market, s.region, s.country)
    JOIN dwh.dim_date AS od ON od.calendar_date = s.order_date
    LEFT JOIN dwh.dim_date AS sd ON sd.calendar_date = s.ship_date
    JOIN dwh.fact_order AS o
      ON o.order_id = s.order_id AND o.customer_key = c.customer_key
    LEFT JOIN dwh.fact_order_line AS f ON f._raw_id = s._raw_id
    WHERE s._load_id = v_load_id
      AND (f.order_line_key IS NULL
           OR (f.order_key, f.customer_key, f.product_key, f.geography_key,
               f.order_date_key, f.ship_date_key, f.row_id, f.quantity,
               f.sales, f.profit, f.shipping_cost, f.discount,
               f.ship_mode, f.order_priority, f.city, f.state, f.postal_code,
               f._load_id, f._dq_flags, f._dwh_loaded_at)
              IS DISTINCT FROM
              (o.order_key, c.customer_key, p.product_key, g.geography_key,
               od.date_key, sd.date_key, s.row_id, s.quantity,
               s.sales::TEXT::NUMERIC, s.profit::TEXT::NUMERIC,
               s.shipping_cost::TEXT::NUMERIC, s.discount,
               s.ship_mode, s.order_priority, s.city, s.state, s.postal_code,
               s._load_id, s._dq_flags, v_loaded_at));
    IF v_differences <> 0 THEN
        RAISE EXCEPTION '% order lines differ from STAGING', v_differences;
    END IF;

    IF EXISTS (
        SELECT 1 FROM dwh.fact_order_line AS f
        JOIN dwh.fact_order AS o ON o.order_key = f.order_key
        WHERE f._load_id = v_load_id
          AND (f.customer_key, f.geography_key, f.order_date_key, f._load_id)
              IS DISTINCT FROM (o.customer_key, o.geography_key, o.order_date_key, o._load_id)
    ) THEN
        RAISE EXCEPTION 'Line-to-order customer, geography, date or batch differs';
    END IF;

    SELECT sum(quantity) AS quantity, sum(sales::TEXT::NUMERIC) AS sales,
           sum(profit::TEXT::NUMERIC) AS profit,
           sum(shipping_cost::TEXT::NUMERIC) AS shipping_cost
    INTO v_source_totals FROM staging.orders WHERE _load_id = v_load_id;
    SELECT sum(quantity) AS quantity, sum(sales) AS sales, sum(profit) AS profit,
           sum(shipping_cost) AS shipping_cost
    INTO v_fact_totals FROM dwh.fact_order_line WHERE _load_id = v_load_id;
    IF (v_source_totals.quantity, v_source_totals.sales,
        v_source_totals.profit, v_source_totals.shipping_cost)
       IS DISTINCT FROM
       (v_fact_totals.quantity, v_fact_totals.sales,
        v_fact_totals.profit, v_fact_totals.shipping_cost) THEN
        RAISE EXCEPTION 'Order line quantity or monetary totals differ from STAGING';
    END IF;

    WITH line_totals AS MATERIALIZED (
        SELECT order_key, count(*) AS line_count, sum(quantity) AS total_quantity,
               sum(sales) AS total_sales, sum(profit) AS total_profit,
               sum(shipping_cost) AS total_shipping_cost
        FROM dwh.fact_order_line WHERE _load_id = v_load_id GROUP BY order_key
    )
    SELECT count(*) INTO v_differences
    FROM dwh.fact_order AS o
    LEFT JOIN line_totals AS t ON t.order_key = o.order_key
    WHERE o._load_id = v_load_id
      AND (t.order_key IS NULL
           OR (t.line_count, t.total_quantity, t.total_sales, t.total_profit, t.total_shipping_cost)
              IS DISTINCT FROM
              (o.line_count, o.total_quantity, o.total_sales, o.total_profit, o.total_shipping_cost));
    IF v_differences <> 0 THEN
        RAISE EXCEPTION '% orders differ from their line aggregates', v_differences;
    END IF;

    -- A range-based check independently verifies every assigned group.
    -- VALUES define labels/bounds only; they create no database objects.
    WITH ranges(label, lower_bound, upper_bound) AS (
        VALUES ('(0;0.10]', 0::NUMERIC, 0.10::NUMERIC),
               ('(0.10;0.20]', 0.10, 0.20), ('(0.20;0.30]', 0.20, 0.30),
               ('(0.30;0.40]', 0.30, 0.40), ('(0.40;0.50]', 0.40, 0.50),
               ('(0.50;0.60]', 0.50, 0.60), ('(0.60;0.70]', 0.60, 0.70),
               ('(0.70;1]', 0.70, 1.00)
    ), expected AS MATERIALIZED (
        SELECT s._raw_id,
               CASE WHEN s.discount IS NULL THEN 'UNKNOWN'
                    WHEN s.discount < 0 OR s.discount > 1 THEN 'INVALID'
                    WHEN s.discount = 0 THEN '0'
                    ELSE r.label END AS label
        FROM staging.orders AS s
        LEFT JOIN ranges AS r
          ON s.discount > r.lower_bound AND s.discount <= r.upper_bound
        WHERE s._load_id = v_load_id
    ), distribution AS (
        SELECT label, count(*) AS rows FROM expected GROUP BY label
    )
    SELECT (SELECT count(*) FROM expected AS e
            LEFT JOIN dwh.fact_order_line AS f ON f._raw_id = e._raw_id
            WHERE e.label IS NULL OR f.order_line_key IS NULL
               OR f.discount_group IS DISTINCT FROM e.label),
           (SELECT jsonb_object_agg(label, rows) FROM distribution)
    INTO v_differences, v_expected_groups;
    IF v_differences <> 0 THEN
        RAISE EXCEPTION '% lines have an incorrect Discount Group', v_differences;
    END IF;

    SELECT jsonb_object_agg(discount_group, rows) INTO v_actual_groups
    FROM (
        SELECT discount_group, count(*) AS rows
        FROM dwh.fact_order_line WHERE _load_id = v_load_id GROUP BY discount_group
    ) AS distribution;
    IF v_actual_groups IS DISTINCT FROM v_expected_groups THEN
        RAISE EXCEPTION 'Discount Group distribution differs from selected STAGING batch';
    END IF;

    RAISE NOTICE 'fact_order_line load_id=% loaded_at=% lines=%', v_load_id, v_loaded_at, v_lines;
    RAISE NOTICE 'Discount Group distribution: %', v_actual_groups;
END;
$order_lines$ LANGUAGE plpgsql;

COMMIT;
