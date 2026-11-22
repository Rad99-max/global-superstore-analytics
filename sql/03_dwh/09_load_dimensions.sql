-- Execute the entire file with stop-on-error enabled in the SQL client.
-- On failure the transaction is aborted: issue ROLLBACK, not a partial retry.
-- Only dimensions are written. Existing surrogate keys are never replaced.
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;

DO $dimensions$
DECLARE
    v_load_id CONSTANT UUID := COALESCE(NULLIF(current_setting('pipeline.load_id', true), ''), 'pipeline.load_id is not set: run via run_pipeline.py or SET pipeline.load_id')::uuid;
    v_loaded_at CONSTANT TIMESTAMPTZ := clock_timestamp();
    v_logged_orders BIGINT;
    v_orders BIGINT;
    v_customers BIGINT;
    v_products BIGINT;
    v_geographies BIGINT;
    v_first_date DATE;
    v_last_date DATE;
    v_days BIGINT;
BEGIN
    IF current_database() <> 'sales_dwh' THEN
        RAISE EXCEPTION 'Expected sales_dwh; dimension load cancelled';
    END IF;

    SELECT orders_rows_loaded INTO v_logged_orders
    FROM raw.load_log
    WHERE load_id = v_load_id AND status = 'SUCCESS'
    FOR SHARE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'load_id % does not have a SUCCESS journal entry', v_load_id;
    END IF;

    SELECT count(*), count(DISTINCT customer_id), count(DISTINCT product_id),
           count(DISTINCT (market, region, country))
    INTO v_orders, v_customers, v_products, v_geographies
    FROM staging.orders WHERE _load_id = v_load_id;

    IF v_orders <> v_logged_orders OR v_orders <> 51290
       OR v_customers <> 17415 OR v_products <> 3788 OR v_geographies <> 168 THEN
        RAISE EXCEPTION 'Unexpected source counts: orders %, customers %, products %, geographies %',
            v_orders, v_customers, v_products, v_geographies;
    END IF;

    -- A complete STAGING batch must reference the same successful RAW batch.
    IF (SELECT count(*) FROM raw.orders WHERE _load_id = v_load_id) <> v_orders
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
          AND (customer_id IS NULL OR product_id IS NULL OR market IS NULL
               OR region IS NULL OR country IS NULL OR order_date IS NULL)
    ) THEN
        RAISE EXCEPTION 'Missing required business key or Order Date; DQ decision required';
    END IF;

    -- DISTINCT tuples retain NULL as a value: NULL versus populated attributes
    -- must not evade the dependency checks as COUNT(DISTINCT scalar) would.
    IF EXISTS (
        SELECT customer_id
        FROM (
            SELECT DISTINCT customer_id, customer_name, segment
            FROM staging.orders WHERE _load_id = v_load_id
        ) AS customer_attributes
        GROUP BY customer_id HAVING count(*) > 1
    ) THEN
        RAISE EXCEPTION 'Customer ID does not determine Customer Name and Segment';
    END IF;

    IF EXISTS (
        SELECT product_id
        FROM (
            SELECT DISTINCT product_id, product_name, category, sub_category
            FROM staging.orders WHERE _load_id = v_load_id
        ) AS product_attributes
        GROUP BY product_id HAVING count(*) > 1
    ) THEN
        RAISE EXCEPTION 'Product ID does not determine Product Name, Category and Sub-Category';
    END IF;

    -- MIN/MAX define calendar boundaries only; they never resolve attribute conflicts.
    SELECT min(dt), max(dt) INTO v_first_date, v_last_date
    FROM (
        SELECT order_date AS dt FROM staging.orders WHERE _load_id = v_load_id
        UNION ALL
        SELECT ship_date FROM staging.orders WHERE _load_id = v_load_id
    ) AS source_dates;
    v_days := v_last_date - v_first_date + 1;

    IF v_first_date IS DISTINCT FROM DATE '2012-01-01'
       OR v_last_date IS DISTINCT FROM DATE '2016-01-07'
       OR v_days IS DISTINCT FROM 1468::BIGINT THEN
        RAISE EXCEPTION 'Unexpected source calendar boundaries: % .. %', v_first_date, v_last_date;
    END IF;

    -- Changes of snapshot or descriptive attributes need a separate approved policy.
    -- Reject incompatible existing rows before any write; never silently overwrite
    -- names/classifications or delete entities outside the selected snapshot.
    IF EXISTS (
        SELECT customer_id, customer_name, segment FROM dwh.dim_customer
        EXCEPT
        SELECT customer_id, customer_name, segment
        FROM staging.orders WHERE _load_id = v_load_id
    ) THEN
        RAISE EXCEPTION 'Existing customer dimension differs from snapshot; update policy required';
    END IF;

    IF EXISTS (
        SELECT product_id, product_name, category, sub_category FROM dwh.dim_product
        EXCEPT
        SELECT product_id, product_name, category, sub_category
        FROM staging.orders WHERE _load_id = v_load_id
    ) THEN
        RAISE EXCEPTION 'Existing product dimension differs from snapshot; update policy required';
    END IF;

    IF EXISTS (
        SELECT market, region, country FROM dwh.dim_geography
        EXCEPT
        SELECT market, region, country FROM staging.orders WHERE _load_id = v_load_id
    ) THEN
        RAISE EXCEPTION 'Existing geography dimension contains another snapshot';
    END IF;

    IF EXISTS (
        SELECT 1 FROM dwh.dim_date
        WHERE calendar_date < v_first_date OR calendar_date > v_last_date
           OR calendar_year IS DISTINCT FROM EXTRACT(YEAR FROM calendar_date)::SMALLINT
           OR calendar_quarter IS DISTINCT FROM EXTRACT(QUARTER FROM calendar_date)::SMALLINT
           OR calendar_month IS DISTINCT FROM EXTRACT(MONTH FROM calendar_date)::SMALLINT
           OR day_of_month IS DISTINCT FROM EXTRACT(DAY FROM calendar_date)::SMALLINT
           OR iso_day_of_week IS DISTINCT FROM EXTRACT(ISODOW FROM calendar_date)::SMALLINT
           OR iso_week IS DISTINCT FROM EXTRACT(WEEK FROM calendar_date)::SMALLINT
           OR iso_year IS DISTINCT FROM EXTRACT(ISOYEAR FROM calendar_date)::SMALLINT
    ) THEN
        RAISE EXCEPTION 'Existing calendar differs from source range or calendar rules';
    END IF;

    -- Upsert natural keys. Repeated runs refresh only the publication timestamp;
    -- surrogate keys and existing descriptive attributes remain unchanged.
    INSERT INTO dwh.dim_date (
        calendar_date, calendar_year, calendar_quarter, calendar_month,
        day_of_month, iso_day_of_week, iso_week, iso_year, _dwh_loaded_at
    )
    SELECT dt, EXTRACT(YEAR FROM dt)::SMALLINT, EXTRACT(QUARTER FROM dt)::SMALLINT,
           EXTRACT(MONTH FROM dt)::SMALLINT, EXTRACT(DAY FROM dt)::SMALLINT,
           EXTRACT(ISODOW FROM dt)::SMALLINT, EXTRACT(WEEK FROM dt)::SMALLINT,
           EXTRACT(ISOYEAR FROM dt)::SMALLINT, v_loaded_at
    FROM (
        SELECT v_first_date + offset_days AS dt
        FROM generate_series(0, v_last_date - v_first_date) AS g(offset_days)
    ) AS calendar
    ORDER BY dt
    ON CONFLICT (calendar_date) DO UPDATE
        SET _dwh_loaded_at = EXCLUDED._dwh_loaded_at;

    INSERT INTO dwh.dim_customer (customer_id, customer_name, segment, _dwh_loaded_at)
    SELECT customer_id, customer_name, segment, v_loaded_at
    FROM (
        SELECT DISTINCT customer_id, customer_name, segment
        FROM staging.orders WHERE _load_id = v_load_id
    ) AS customers
    ORDER BY customer_id
    ON CONFLICT (customer_id) DO UPDATE
        SET _dwh_loaded_at = EXCLUDED._dwh_loaded_at;

    INSERT INTO dwh.dim_product (
        product_id, product_name, category, sub_category, _dwh_loaded_at
    )
    SELECT product_id, product_name, category, sub_category, v_loaded_at
    FROM (
        SELECT DISTINCT product_id, product_name, category, sub_category
        FROM staging.orders WHERE _load_id = v_load_id
    ) AS products
    ORDER BY product_id
    ON CONFLICT (product_id) DO UPDATE
        SET _dwh_loaded_at = EXCLUDED._dwh_loaded_at;

    INSERT INTO dwh.dim_geography (market, region, country, _dwh_loaded_at)
    SELECT market, region, country, v_loaded_at
    FROM (
        SELECT DISTINCT market, region, country
        FROM staging.orders WHERE _load_id = v_load_id
    ) AS geographies
    ORDER BY market, region, country
    ON CONFLICT (market, region, country) DO UPDATE
        SET _dwh_loaded_at = EXCLUDED._dwh_loaded_at;

    IF (SELECT count(*) FROM dwh.dim_date) <> v_days
       OR (SELECT count(*) FROM dwh.dim_customer) <> v_customers
       OR (SELECT count(*) FROM dwh.dim_product) <> v_products
       OR (SELECT count(*) FROM dwh.dim_geography) <> v_geographies THEN
        RAISE EXCEPTION 'Dimension counts differ from selected snapshot; load cancelled';
    END IF;

    -- Null-safe attribute reconciliation; no lossy joins or arbitrary selection.
    IF EXISTS (
        SELECT 1 FROM staging.orders AS s
        LEFT JOIN dwh.dim_customer AS d ON d.customer_id = s.customer_id
        WHERE s._load_id = v_load_id
          AND (d.customer_key IS NULL
               OR (d.customer_name, d.segment) IS DISTINCT FROM (s.customer_name, s.segment))
    ) OR EXISTS (
        SELECT 1 FROM staging.orders AS s
        LEFT JOIN dwh.dim_product AS d ON d.product_id = s.product_id
        WHERE s._load_id = v_load_id
          AND (d.product_key IS NULL
               OR (d.product_name, d.category, d.sub_category)
                  IS DISTINCT FROM (s.product_name, s.category, s.sub_category))
    ) OR EXISTS (
        SELECT 1 FROM staging.orders AS s
        LEFT JOIN dwh.dim_geography AS d
          ON (d.market, d.region, d.country) = (s.market, s.region, s.country)
        WHERE s._load_id = v_load_id AND d.geography_key IS NULL
    ) THEN
        RAISE EXCEPTION 'Dimension business attributes do not match selected STAGING rows';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM generate_series(0, v_last_date - v_first_date) AS g(offset_days)
        LEFT JOIN dwh.dim_date AS d ON d.calendar_date = v_first_date + g.offset_days
        WHERE d.date_key IS NULL
    ) OR EXISTS (
        SELECT 1 FROM (
            SELECT _dwh_loaded_at FROM dwh.dim_date
            UNION ALL SELECT _dwh_loaded_at FROM dwh.dim_customer
            UNION ALL SELECT _dwh_loaded_at FROM dwh.dim_product
            UNION ALL SELECT _dwh_loaded_at FROM dwh.dim_geography
        ) AS publications
        WHERE _dwh_loaded_at IS DISTINCT FROM v_loaded_at
    ) THEN
        RAISE EXCEPTION 'Calendar coverage or publication timestamp reconciliation failed';
    END IF;

    RAISE NOTICE 'Dimensions load_id=% loaded_at=% dates=% customers=% products=% geographies=%',
        v_load_id, v_loaded_at, v_days, v_customers, v_products, v_geographies;
END;
$dimensions$ LANGUAGE plpgsql;

COMMIT;
