-- Execute the entire file. Any exception aborts publication; ROLLBACK preserves
-- the previous MART. Customer statuses below are acceptance checks only.
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;

DO $load$
DECLARE
    v_load_id CONSTANT UUID := COALESCE(NULLIF(current_setting('pipeline.load_id', true), ''), 'pipeline.load_id is not set: run via run_pipeline.py or SET pipeline.load_id')::uuid;
    v_orders BIGINT;
    v_joined_count BIGINT;
    v_distinct_orders BIGINT;
    v_sales NUMERIC;
    v_profit NUMERIC;
    -- Frozen 30%+ controls (discount > 0.30); same as 07_load_geographic_monthly.sql.
    v_sales_30plus CONSTANT NUMERIC := 1547656.08982000000381715;
    v_profit_30plus CONSTANT NUMERIC := -793526.473580000004478880;
BEGIN
    IF current_database() <> 'sales_dwh' THEN
        RAISE EXCEPTION 'Expected database sales_dwh';
    END IF;

    PERFORM 1 FROM raw.load_log
    WHERE load_id = v_load_id AND status = 'SUCCESS'
    FOR SHARE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Approved load % is not SUCCESS', v_load_id;
    END IF;
    IF EXISTS (SELECT 1 FROM dwh.fact_order WHERE _load_id IS DISTINCT FROM v_load_id) THEN
        RAISE EXCEPTION 'Mixed or unexpected source load_id';
    END IF;

    SELECT COUNT(*), SUM(total_sales), SUM(total_profit)
    INTO v_orders, v_sales, v_profit
    FROM dwh.fact_order WHERE _load_id = v_load_id;
    IF v_orders <> 25739
       OR v_sales IS DISTINCT FROM 12642501.90988000002174815::numeric
       OR v_profit IS DISTINCT FROM 1467457.2912799999311949806::numeric THEN
        RAISE EXCEPTION 'Source count or totals differ from approved snapshot';
    END IF;

    IF EXISTS (
        SELECT 1 FROM dwh.fact_order AS o
        LEFT JOIN dwh.dim_date AS d ON d.date_key = o.order_date_key
        LEFT JOIN dwh.dim_customer AS c ON c.customer_key = o.customer_key
        WHERE o.order_key IS NULL OR d.calendar_date IS NULL OR c.customer_key IS NULL
           OR c.customer_id IS NULL OR c.segment IS NULL
           OR o.total_sales IS NULL OR o.total_profit IS NULL
    ) THEN
        RAISE EXCEPTION 'Unresolved date/customer or NULL required source value';
    END IF;

    IF EXISTS (
        SELECT customer_id FROM dwh.dim_customer
        GROUP BY customer_id HAVING COUNT(*) <> 1
    ) OR EXISTS (
        SELECT customer_key FROM dwh.dim_customer
        GROUP BY customer_key HAVING COUNT(*) <> 1 OR COUNT(DISTINCT segment) <> 1
    ) THEN
        RAISE EXCEPTION 'Customer identity or Segment dependency is not unique';
    END IF;

    SELECT COUNT(*), COUNT(DISTINCT o.order_key)
    INTO v_joined_count, v_distinct_orders
    FROM dwh.fact_order AS o
    JOIN dwh.dim_date AS d ON d.date_key = o.order_date_key
    JOIN dwh.dim_customer AS c ON c.customer_key = o.customer_key
    WHERE o._load_id = v_load_id;
    IF v_joined_count <> v_orders OR v_distinct_orders <> v_orders THEN
        RAISE EXCEPTION 'Source joins lose or multiply orders';
    END IF;

    -- Order lines are used for the 30%+ columns only; sales and profit come
    -- from fact_order. Lines must belong to their order's customer and date.
    IF EXISTS (
        SELECT 1 FROM dwh.fact_order_line AS l
        LEFT JOIN dwh.fact_order AS o ON o.order_key = l.order_key
        WHERE l._load_id = v_load_id
          AND (o.order_key IS NULL
               OR (l.customer_key, l.order_date_key)
                  IS DISTINCT FROM (o.customer_key, o.order_date_key))
    ) THEN
        RAISE EXCEPTION 'Order lines disagree with order customer/date';
    END IF;

    -- 30%+ is built from discount_group labels; validate them against numeric discount.
    IF EXISTS (
        SELECT 1 FROM dwh.fact_order_line
        WHERE _load_id = v_load_id
          AND (discount_group IN ('(0.30;0.40]', '(0.40;0.50]', '(0.50;0.60]',
                                  '(0.60;0.70]', '(0.70;1]'))
              IS DISTINCT FROM COALESCE(discount > 0.30 AND discount <= 1, FALSE)
    ) THEN
        RAISE EXCEPTION 'Line discount_group disagrees with numeric discount for 30%%+';
    END IF;

    IF (SELECT SUM(sales) FROM dwh.fact_order_line
        WHERE _load_id = v_load_id AND discount > 0.30 AND discount <= 1)
           IS DISTINCT FROM v_sales_30plus
       OR (SELECT SUM(profit) FROM dwh.fact_order_line
           WHERE _load_id = v_load_id AND discount > 0.30 AND discount <= 1)
           IS DISTINCT FROM v_profit_30plus THEN
        RAISE EXCEPTION '30%%+ line totals differ from approved snapshot';
    END IF;

    DELETE FROM mart.customer_monthly;

    -- No grid, no status column, and no HAVING filter: retain actual zero profits.
    WITH order_months AS (
        SELECT date_trunc('month', d.calendar_date::timestamp)::date AS month_date,
               o.customer_key, SUM(o.total_sales) AS sales, SUM(o.total_profit) AS profit
        FROM dwh.fact_order AS o
        JOIN dwh.dim_date AS d ON d.date_key = o.order_date_key
        WHERE o._load_id = v_load_id
        GROUP BY date_trunc('month', d.calendar_date::timestamp)::date, o.customer_key
    ), discount_30plus_months AS (
        SELECT date_trunc('month', d.calendar_date::timestamp)::date AS month_date,
               l.customer_key,
               SUM(l.sales) AS sales_30plus, SUM(l.profit) AS profit_30plus
        FROM dwh.fact_order_line AS l
        JOIN dwh.dim_date AS d ON d.date_key = l.order_date_key
        WHERE l._load_id = v_load_id
          AND l.discount_group IN ('(0.30;0.40]', '(0.40;0.50]', '(0.50;0.60]',
                                   '(0.60;0.70]', '(0.70;1]')
        GROUP BY date_trunc('month', d.calendar_date::timestamp)::date, l.customer_key
    )
    INSERT INTO mart.customer_monthly
        (month_date, customer_key, sales, profit, sales_30plus, profit_30plus)
    SELECT om.month_date, om.customer_key, om.sales, om.profit,
           COALESCE(dm.sales_30plus, 0::numeric), COALESCE(dm.profit_30plus, 0::numeric)
    FROM order_months AS om
    LEFT JOIN discount_30plus_months AS dm
        ON dm.month_date = om.month_date AND dm.customer_key = om.customer_key;

    -- Independently construct calendar months; compare every combination and
    -- customer, month, quarter, year, Segment and total in both directions.
    IF EXISTS (
        WITH expected_orders AS MATERIALIZED (
            SELECT make_date(EXTRACT(YEAR FROM d.calendar_date)::integer,
                             EXTRACT(MONTH FROM d.calendar_date)::integer, 1) AS month_date,
                   o.customer_key, o.total_sales AS sales, o.total_profit AS profit,
                   0::numeric AS sales_30plus, 0::numeric AS profit_30plus
            FROM dwh.fact_order AS o
            JOIN dwh.dim_date AS d ON d.date_key = o.order_date_key
            WHERE o._load_id = v_load_id
            UNION ALL
            -- 30%+ from numeric discount, independent of discount_group labels.
            SELECT make_date(EXTRACT(YEAR FROM d.calendar_date)::integer,
                             EXTRACT(MONTH FROM d.calendar_date)::integer, 1),
                   l.customer_key, 0::numeric, 0::numeric, l.sales, l.profit
            FROM dwh.fact_order_line AS l
            JOIN dwh.dim_date AS d ON d.date_key = l.order_date_key
            WHERE l._load_id = v_load_id AND l.discount > 0.30 AND l.discount <= 1
        ), combined AS (
            SELECT 'expected' AS side, month_date, customer_key, sales, profit,
                   sales_30plus, profit_30plus
            FROM expected_orders
            UNION ALL
            SELECT 'actual', month_date, customer_key, sales, profit,
                   sales_30plus, profit_30plus
            FROM mart.customer_monthly
        ), attributed AS (
            SELECT x.*, c.segment,
                   date_trunc('quarter', x.month_date::timestamp)::date AS quarter_date,
                   date_trunc('year', x.month_date::timestamp)::date AS year_date
            FROM combined AS x
            JOIN dwh.dim_customer AS c ON c.customer_key = x.customer_key
        ), checks AS MATERIALIZED (
            SELECT side,
                   GROUPING(month_date, customer_key, quarter_date, year_date, segment) AS level,
                   month_date, customer_key, quarter_date, year_date, segment,
                   SUM(sales) AS sales, SUM(profit) AS profit,
                   SUM(sales_30plus) AS sales_30plus, SUM(profit_30plus) AS profit_30plus
            FROM attributed
            GROUP BY side, GROUPING SETS (
                (month_date, customer_key), (customer_key), (month_date),
                (quarter_date), (year_date), (segment), ()
            )
        ), expected AS (
            SELECT level, month_date, customer_key, quarter_date, year_date, segment,
                   sales, profit, sales_30plus, profit_30plus
            FROM checks WHERE side = 'expected'
        ), actual AS (
            SELECT level, month_date, customer_key, quarter_date, year_date, segment,
                   sales, profit, sales_30plus, profit_30plus
            FROM checks WHERE side = 'actual'
        )
        (SELECT * FROM expected EXCEPT ALL SELECT * FROM actual)
        UNION ALL
        (SELECT * FROM actual EXCEPT ALL SELECT * FROM expected)
    ) THEN
        RAISE EXCEPTION 'MART reconciliation failed: grain/customer/time/Segment/total';
    END IF;

    IF EXISTS (
        SELECT 1 FROM mart.customer_monthly
        WHERE sales_30plus < 0 OR sales_30plus > sales
    ) THEN
        RAISE EXCEPTION 'sales_30plus is outside [0, sales]';
    END IF;

    IF (SELECT COUNT(*) FROM mart.customer_monthly) <> 25450
       OR (SELECT COUNT(DISTINCT customer_key) FROM mart.customer_monthly) <> 17415
       OR (SELECT COUNT(DISTINCT month_date) FROM mart.customer_monthly) <> 48
       OR (SELECT MIN(month_date) FROM mart.customer_monthly)
           IS DISTINCT FROM DATE '2012-01-01'
       OR (SELECT MAX(month_date) FROM mart.customer_monthly)
           IS DISTINCT FROM DATE '2015-12-01'
       OR (SELECT COUNT(*) FROM mart.customer_monthly WHERE profit = 0) <> 159
       OR (SELECT SUM(sales) FROM mart.customer_monthly) IS DISTINCT FROM v_sales
       OR (SELECT SUM(profit) FROM mart.customer_monthly) IS DISTINCT FROM v_profit
       OR (SELECT SUM(sales_30plus) FROM mart.customer_monthly)
           IS DISTINCT FROM v_sales_30plus
       OR (SELECT SUM(profit_30plus) FROM mart.customer_monthly)
           IS DISTINCT FROM v_profit_30plus THEN
        RAISE EXCEPTION 'Publication counts/coverage/zero profits/totals differ from approved snapshot';
    END IF;

    -- Full-period customer classification is checked, never stored in MART.
    IF EXISTS (
        WITH customer_profits AS (
            SELECT customer_key, SUM(profit) AS profit
            FROM mart.customer_monthly GROUP BY customer_key
        ), actual AS (
            SELECT CASE WHEN profit > 0 THEN 'PROFITABLE'
                        WHEN profit < 0 THEN 'UNPROFITABLE'
                        WHEN profit = 0 THEN 'BREAK_EVEN' END AS status,
                   COUNT(*) AS customers, SUM(profit) AS profit
            FROM customer_profits
            GROUP BY 1
        ), expected (status, customers, profit) AS (
            VALUES ('PROFITABLE', 12909::bigint, 2240659.0067799999398005176::numeric),
                   ('UNPROFITABLE', 4427::bigint, -773201.715500000008605537::numeric),
                   ('BREAK_EVEN', 79::bigint, 0::numeric)
        )
        (SELECT * FROM expected EXCEPT ALL SELECT * FROM actual)
        UNION ALL
        (SELECT * FROM actual EXCEPT ALL SELECT * FROM expected)
    ) THEN
        RAISE EXCEPTION 'Full-period customer cohort acceptance check failed';
    END IF;
END;
$load$;

COMMIT;
