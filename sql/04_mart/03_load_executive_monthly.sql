-- Full publication rebuild for the approved SUCCESS snapshot only.
-- Execute this entire file; any exception aborts the transaction.
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;

DO $load$
DECLARE
    v_load_id CONSTANT UUID := COALESCE(NULLIF(current_setting('pipeline.load_id', true), ''), 'pipeline.load_id is not set: run via run_pipeline.py or SET pipeline.load_id')::uuid;
    v_first_month DATE;
    v_last_month DATE;
    v_orders BIGINT;
    v_unprofitable_orders BIGINT;
    v_sales NUMERIC;
    v_profit NUMERIC;
    v_months BIGINT;
BEGIN
    IF current_database() <> 'sales_dwh' THEN
        RAISE EXCEPTION 'Expected database sales_dwh, got %', current_database();
    END IF;

    PERFORM 1
    FROM raw.load_log
    WHERE load_id = v_load_id AND status = 'SUCCESS'
    FOR SHARE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Load % is not SUCCESS', v_load_id;
    END IF;

    -- Reject empty, mixed or incomplete source publications before deleting MART.
    IF NOT EXISTS (SELECT 1 FROM dwh.fact_order)
       OR EXISTS (
           SELECT 1 FROM dwh.fact_order
           WHERE _load_id IS DISTINCT FROM v_load_id
       ) THEN
        RAISE EXCEPTION 'DWH must contain exactly the approved load snapshot';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM dwh.fact_order AS o
        LEFT JOIN dwh.dim_date AS d ON d.date_key = o.order_date_key
        WHERE d.calendar_date IS NULL
           OR o.total_sales IS NULL OR o.total_profit IS NULL
    ) THEN
        RAISE EXCEPTION 'Unresolved Order Date or NULL monetary measure';
    END IF;

    SELECT date_trunc('month', MIN(d.calendar_date)::timestamp)::date,
           date_trunc('month', MAX(d.calendar_date)::timestamp)::date,
           COUNT(*), COUNT(*) FILTER (WHERE o.total_profit < 0),
           SUM(o.total_sales), SUM(o.total_profit)
    INTO v_first_month, v_last_month, v_orders, v_unprofitable_orders,
         v_sales, v_profit
    FROM dwh.fact_order AS o
    JOIN dwh.dim_date AS d ON d.date_key = o.order_date_key
    WHERE o._load_id = v_load_id;

    -- Frozen acceptance controls for this specific published snapshot.
    IF v_first_month IS DISTINCT FROM DATE '2012-01-01'
       OR v_last_month IS DISTINCT FROM DATE '2015-12-01'
       OR v_orders IS DISTINCT FROM 25739::bigint
       OR v_unprofitable_orders IS DISTINCT FROM 6309::bigint
       OR v_sales IS DISTINCT FROM 12642501.90988000002174815::numeric
       OR v_profit IS DISTINCT FROM 1467457.2912799999311949806::numeric THEN
        RAISE EXCEPTION 'DWH snapshot does not match approved coverage and totals';
    END IF;

    DELETE FROM mart.executive_monthly;

    WITH monthly AS (
        SELECT date_trunc('month', d.calendar_date::timestamp)::date AS month_date,
               SUM(o.total_sales) AS sales,
               SUM(o.total_profit) AS profit,
               COUNT(*) AS orders,
               COUNT(*) FILTER (WHERE o.total_profit < 0) AS unprofitable_orders
        FROM dwh.fact_order AS o
        JOIN dwh.dim_date AS d ON d.date_key = o.order_date_key
        WHERE o._load_id = v_load_id
        GROUP BY date_trunc('month', d.calendar_date::timestamp)::date
    ), months AS (
        SELECT g.month_start::date AS month_date
        FROM generate_series(v_first_month::timestamp, v_last_month::timestamp,
                             INTERVAL '1 month') AS g(month_start)
    )
    INSERT INTO mart.executive_monthly
        (month_date, sales, profit, orders, unprofitable_orders)
    SELECT m.month_date,
           COALESCE(a.sales, 0::numeric), COALESCE(a.profit, 0::numeric),
           COALESCE(a.orders, 0::bigint), COALESCE(a.unprofitable_orders, 0::bigint)
    FROM months AS m
    LEFT JOIN monthly AS a USING (month_date);

    -- Reconcile every month independently, including zero-order calendar months.
    IF EXISTS (
        WITH expected AS (
            SELECT make_date(EXTRACT(YEAR FROM d.calendar_date)::integer,
                             EXTRACT(MONTH FROM d.calendar_date)::integer, 1) AS month_date,
                   SUM(o.total_sales) AS sales, SUM(o.total_profit) AS profit,
                   COUNT(*) AS orders,
                   COUNT(*) FILTER (WHERE o.total_profit < 0) AS unprofitable_orders
            FROM dwh.fact_order AS o
            JOIN dwh.dim_date AS d ON d.date_key = o.order_date_key
            WHERE o._load_id = v_load_id
            GROUP BY EXTRACT(YEAR FROM d.calendar_date),
                     EXTRACT(MONTH FROM d.calendar_date)
        ), grid AS (
            SELECT g.month_start::date AS month_date
            FROM generate_series(v_first_month::timestamp, v_last_month::timestamp,
                                 INTERVAL '1 month') AS g(month_start)
        ), expected_publication AS (
            SELECT g.month_date, COALESCE(e.sales, 0::numeric) AS sales,
                   COALESCE(e.profit, 0::numeric) AS profit,
                   COALESCE(e.orders, 0::bigint) AS orders,
                   COALESCE(e.unprofitable_orders, 0::bigint) AS unprofitable_orders
            FROM grid AS g LEFT JOIN expected AS e USING (month_date)
        )
        SELECT 1
        FROM expected_publication AS e
        FULL JOIN mart.executive_monthly AS m USING (month_date)
        WHERE e.month_date IS NULL OR m.month_date IS NULL
           OR m.sales IS DISTINCT FROM e.sales OR m.profit IS DISTINCT FROM e.profit
           OR m.orders IS DISTINCT FROM e.orders
           OR m.unprofitable_orders IS DISTINCT FROM e.unprofitable_orders
    ) THEN
        RAISE EXCEPTION 'Monthly reconciliation failed';
    END IF;

    SELECT COUNT(*) INTO v_months FROM mart.executive_monthly;
    IF v_months <> 48
       OR EXISTS (
           SELECT month_date FROM mart.executive_monthly
           GROUP BY month_date HAVING COUNT(*) <> 1
       )
       OR EXISTS (
           SELECT 1 FROM mart.executive_monthly
           WHERE month_date IS NULL OR EXTRACT(DAY FROM month_date) <> 1
              OR sales IS NULL OR profit IS NULL
              OR orders IS NULL OR orders < 0
              OR unprofitable_orders IS NULL
              OR unprofitable_orders NOT BETWEEN 0 AND orders
       ) THEN
        RAISE EXCEPTION 'Monthly grain or measure validation failed';
    END IF;

    IF (SELECT SUM(sales) FROM mart.executive_monthly) IS DISTINCT FROM v_sales
       OR (SELECT SUM(profit) FROM mart.executive_monthly) IS DISTINCT FROM v_profit
       OR (SELECT SUM(orders) FROM mart.executive_monthly) IS DISTINCT FROM v_orders
       OR (SELECT SUM(unprofitable_orders) FROM mart.executive_monthly)
           IS DISTINCT FROM v_unprofitable_orders THEN
        RAISE EXCEPTION 'Publication totals do not reconcile with DWH';
    END IF;
END;
$load$;

COMMIT;
