-- Execute the entire file. Any exception aborts publication; ROLLBACK preserves
-- the previous MART. Source reads use one consistent snapshot.
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;

DO $load$
DECLARE
    v_load_id CONSTANT UUID := COALESCE(NULLIF(current_setting('pipeline.load_id', true), ''), 'pipeline.load_id is not set: run via run_pipeline.py or SET pipeline.load_id')::uuid;
    v_line_count BIGINT;
    v_joined_count BIGINT;
    v_distinct_lines BIGINT;
    v_sales NUMERIC;
    v_profit NUMERIC;
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

    IF EXISTS (SELECT 1 FROM dwh.fact_order WHERE _load_id IS DISTINCT FROM v_load_id)
       OR EXISTS (
           SELECT 1 FROM dwh.fact_order_line WHERE _load_id IS DISTINCT FROM v_load_id
       ) THEN
        RAISE EXCEPTION 'Mixed or unexpected source load_id';
    END IF;

    SELECT COUNT(*), SUM(sales), SUM(profit)
    INTO v_line_count, v_sales, v_profit
    FROM dwh.fact_order_line WHERE _load_id = v_load_id;
    IF v_line_count <> 51290
       OR (SELECT COUNT(*) FROM dwh.fact_order WHERE _load_id = v_load_id) <> 25739
       OR v_sales IS DISTINCT FROM 12642501.90988000002174815::numeric
       OR v_profit IS DISTINCT FROM 1467457.2912799999311949806::numeric THEN
        RAISE EXCEPTION 'Source counts or monetary totals differ from approved snapshot';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM dwh.fact_order_line AS l
        LEFT JOIN dwh.fact_order AS o ON o.order_key = l.order_key
        LEFT JOIN dwh.dim_date AS d ON d.date_key = o.order_date_key
        WHERE o.order_key IS NULL OR d.calendar_date IS NULL
           OR l.order_date_key IS DISTINCT FROM o.order_date_key
           OR l._load_id IS DISTINCT FROM o._load_id
           OR l.sales IS NULL OR l.profit IS NULL
           OR o.total_sales IS NULL OR o.total_profit IS NULL
           OR NOT (o.total_profit > 0 OR o.total_profit < 0 OR o.total_profit = 0)
           OR l.discount_group IS NULL
           OR l.discount_group NOT IN (
               '0', '(0;0.10]', '(0.10;0.20]', '(0.20;0.30]', '(0.30;0.40]',
               '(0.40;0.50]', '(0.50;0.60]', '(0.60;0.70]', '(0.70;1]',
               'UNKNOWN', 'INVALID'
           )
    ) THEN
        RAISE EXCEPTION 'Unresolved reference, inconsistent lineage/date, NULL measure or unknown class';
    END IF;

    SELECT COUNT(*), COUNT(DISTINCT l.order_line_key)
    INTO v_joined_count, v_distinct_lines
    FROM dwh.fact_order_line AS l
    JOIN dwh.fact_order AS o ON o.order_key = l.order_key
    JOIN dwh.dim_date AS d ON d.date_key = o.order_date_key
    WHERE l._load_id = v_load_id;
    IF v_joined_count <> v_line_count OR v_distinct_lines <> v_line_count THEN
        RAISE EXCEPTION 'Source join loses or multiplies order lines';
    END IF;

    -- Independently validate every technical discount interval, including DQ classes.
    IF EXISTS (
        SELECT 1 FROM dwh.fact_order_line
        WHERE discount_group IS DISTINCT FROM CASE
            WHEN discount IS NULL THEN 'UNKNOWN'
            WHEN discount < 0 OR discount > 1 THEN 'INVALID'
            WHEN discount = 0 THEN '0'
            WHEN discount <= 0.10 THEN '(0;0.10]'
            WHEN discount <= 0.20 THEN '(0.10;0.20]'
            WHEN discount <= 0.30 THEN '(0.20;0.30]'
            WHEN discount <= 0.40 THEN '(0.30;0.40]'
            WHEN discount <= 0.50 THEN '(0.40;0.50]'
            WHEN discount <= 0.60 THEN '(0.50;0.60]'
            WHEN discount <= 0.70 THEN '(0.60;0.70]'
            ELSE '(0.70;1]'
        END
    ) THEN
        RAISE EXCEPTION 'Discount technical group disagrees with its numeric interval';
    END IF;

    IF EXISTS (
        WITH lines AS (
            SELECT order_key, COUNT(*) AS line_count, SUM(sales) AS sales, SUM(profit) AS profit
            FROM dwh.fact_order_line WHERE _load_id = v_load_id GROUP BY order_key
        )
        SELECT 1 FROM dwh.fact_order AS o
        FULL JOIN lines AS l USING (order_key)
        WHERE o.order_key IS NULL OR l.order_key IS NULL
           OR o.line_count IS DISTINCT FROM l.line_count
           OR o.total_sales IS DISTINCT FROM l.sales
           OR o.total_profit IS DISTINCT FROM l.profit
    ) THEN
        RAISE EXCEPTION 'Order totals do not reconcile with their lines';
    END IF;

    DELETE FROM mart.sales_profitability_monthly;

    WITH classified AS (
        SELECT date_trunc('month', d.calendar_date::timestamp)::date AS month_date,
               CASE WHEN o.total_profit > 0 THEN 'PROFITABLE'
                    WHEN o.total_profit < 0 THEN 'LOSS_MAKING'
                    WHEN o.total_profit = 0 THEN 'BREAK_EVEN' END AS status,
               CASE l.discount_group
                   WHEN '0' THEN '0%'
                   WHEN '(0;0.10]' THEN '0–10%'
                   WHEN '(0.10;0.20]' THEN '10–20%'
                   WHEN '(0.20;0.30]' THEN '20–30%'
                   WHEN '(0.30;0.40]' THEN '30%+'
                   WHEN '(0.40;0.50]' THEN '30%+'
                   WHEN '(0.50;0.60]' THEN '30%+'
                   WHEN '(0.60;0.70]' THEN '30%+'
                   WHEN '(0.70;1]' THEN '30%+'
                   WHEN 'UNKNOWN' THEN 'UNKNOWN'
                   WHEN 'INVALID' THEN 'INVALID'
               END AS discount_group,
               l.sales, l.profit
        FROM dwh.fact_order_line AS l
        JOIN dwh.fact_order AS o ON o.order_key = l.order_key
        JOIN dwh.dim_date AS d ON d.date_key = o.order_date_key
        WHERE l._load_id = v_load_id AND o._load_id = v_load_id
    )
    INSERT INTO mart.sales_profitability_monthly
        (month_date, order_profitability_status, discount_group, sales, profit)
    SELECT month_date, status, discount_group, SUM(sales), SUM(profit)
    FROM classified
    GROUP BY month_date, status, discount_group;

    -- Independent numeric-interval classification for reconciliation.
    -- GROUPING SETS checks the full grain, month, status, discount, quarter, year,
    -- and grand total in both directions, including unexpected publication rows.
    IF EXISTS (
        WITH expected_lines AS MATERIALIZED (
            SELECT make_date(EXTRACT(YEAR FROM d.calendar_date)::integer,
                             EXTRACT(MONTH FROM d.calendar_date)::integer, 1) AS month_date,
                   CASE WHEN o.total_profit = 0 THEN 'BREAK_EVEN'
                        WHEN o.total_profit < 0 THEN 'LOSS_MAKING'
                        WHEN o.total_profit > 0 THEN 'PROFITABLE' END AS status,
                   CASE WHEN l.discount IS NULL THEN 'UNKNOWN'
                        WHEN l.discount < 0 OR l.discount > 1 THEN 'INVALID'
                        WHEN l.discount = 0 THEN '0%'
                        WHEN l.discount <= 0.10 THEN '0–10%'
                        WHEN l.discount <= 0.20 THEN '10–20%'
                        WHEN l.discount <= 0.30 THEN '20–30%'
                        ELSE '30%+' END AS discount_group,
                   l.sales, l.profit
            FROM dwh.fact_order_line AS l
            JOIN dwh.fact_order AS o ON o.order_key = l.order_key
            JOIN dwh.dim_date AS d ON d.date_key = o.order_date_key
            WHERE l._load_id = v_load_id AND o._load_id = v_load_id
        ), combined AS (
            SELECT 'expected' AS side, month_date, status, discount_group, sales, profit
            FROM expected_lines
            UNION ALL
            SELECT 'actual', month_date, order_profitability_status, discount_group, sales, profit
            FROM mart.sales_profitability_monthly
        ), periods AS (
            SELECT *, date_trunc('quarter', month_date::timestamp)::date AS quarter_date,
                      date_trunc('year', month_date::timestamp)::date AS year_date
            FROM combined
        ), checks AS MATERIALIZED (
            SELECT side, GROUPING(month_date, status, discount_group, quarter_date, year_date) AS level,
                   month_date, status, discount_group, quarter_date, year_date,
                   SUM(sales) AS sales, SUM(profit) AS profit
            FROM periods
            GROUP BY side, GROUPING SETS (
                (month_date, status, discount_group), (month_date), (status),
                (discount_group), (quarter_date), (year_date), ()
            )
        ), expected AS (
            SELECT level, month_date, status, discount_group, quarter_date, year_date, sales, profit
            FROM checks WHERE side = 'expected'
        ), actual AS (
            SELECT level, month_date, status, discount_group, quarter_date, year_date, sales, profit
            FROM checks WHERE side = 'actual'
        )
        (SELECT * FROM expected EXCEPT ALL SELECT * FROM actual)
        UNION ALL
        (SELECT * FROM actual EXCEPT ALL SELECT * FROM expected)
    ) THEN
        RAISE EXCEPTION 'MART reconciliation failed: grain, month, status, discount, quarter, year or total';
    END IF;

    IF (SELECT COUNT(*) FROM mart.sales_profitability_monthly) <> 542
       OR (SELECT COUNT(DISTINCT month_date) FROM mart.sales_profitability_monthly) <> 48
       OR (SELECT MIN(month_date) FROM mart.sales_profitability_monthly)
           IS DISTINCT FROM DATE '2012-01-01'
       OR (SELECT MAX(month_date) FROM mart.sales_profitability_monthly)
           IS DISTINCT FROM DATE '2015-12-01' THEN
        RAISE EXCEPTION 'Publication grain/count/coverage differs from approved snapshot';
    END IF;

    IF (SELECT SUM(sales) FROM mart.sales_profitability_monthly) IS DISTINCT FROM v_sales
       OR (SELECT SUM(profit) FROM mart.sales_profitability_monthly) IS DISTINCT FROM v_profit
       OR (SELECT SUM(total_sales) FROM dwh.fact_order) IS DISTINCT FROM v_sales
       OR (SELECT SUM(total_profit) FROM dwh.fact_order) IS DISTINCT FROM v_profit THEN
        RAISE EXCEPTION 'Grand totals differ between MART, order lines and orders';
    END IF;
END;
$load$;

COMMIT;
