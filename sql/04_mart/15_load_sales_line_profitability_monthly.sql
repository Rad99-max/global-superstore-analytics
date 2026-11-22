-- Atomic publication. Any exception requires ROLLBACK, preserving the old MART.
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;

DO $load$
DECLARE
    v_load_id CONSTANT UUID := COALESCE(NULLIF(current_setting('pipeline.load_id', true), ''), 'pipeline.load_id is not set: run via run_pipeline.py or SET pipeline.load_id')::uuid;
BEGIN
    IF current_database() <> 'sales_dwh' THEN
        RAISE EXCEPTION 'Expected database sales_dwh';
    END IF;
    PERFORM 1 FROM raw.load_log
    WHERE load_id = v_load_id AND status = 'SUCCESS' FOR SHARE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Approved load % is not SUCCESS', v_load_id;
    END IF;
    LOCK TABLE mart.sales_line_profitability_monthly IN EXCLUSIVE MODE;

    IF (SELECT COUNT(*) FROM dwh.fact_order_line) <> 51290
       OR (SELECT COUNT(DISTINCT order_line_key) FROM dwh.fact_order_line) <> 51290
       OR EXISTS (SELECT 1 FROM dwh.fact_order_line WHERE _load_id IS DISTINCT FROM v_load_id)
       OR EXISTS (SELECT 1 FROM dwh.fact_order WHERE _load_id IS DISTINCT FROM v_load_id)
       OR (SELECT SUM(sales) FROM dwh.fact_order_line)
           IS DISTINCT FROM 12642501.90988000002174815::numeric
       OR (SELECT SUM(profit) FROM dwh.fact_order_line)
           IS DISTINCT FROM 1467457.2912799999311949806::numeric THEN
        RAISE EXCEPTION 'Source differs from approved snapshot';
    END IF;

    IF EXISTS (
        SELECT 1 FROM dwh.fact_order_line AS l
        LEFT JOIN dwh.dim_date AS d ON d.date_key = l.order_date_key
        LEFT JOIN dwh.fact_order AS o USING (order_key)
        WHERE d.calendar_date IS NULL OR o.order_key IS NULL
           OR l.order_date_key IS DISTINCT FROM o.order_date_key
           OR l._load_id IS DISTINCT FROM o._load_id
           OR l.sales IS NULL OR l.profit IS NULL
           OR l.sales::text IN ('NaN', 'Infinity', '-Infinity')
           OR l.profit::text IN ('NaN', 'Infinity', '-Infinity')
    ) THEN
        RAISE EXCEPTION 'Invalid measure, reference, Order Date or snapshot';
    END IF;

    IF EXISTS (
        WITH lines AS (
            SELECT order_key, COUNT(*) AS lines, SUM(sales) AS sales, SUM(profit) AS profit
            FROM dwh.fact_order_line GROUP BY order_key
        )
        SELECT 1 FROM dwh.fact_order AS o FULL JOIN lines AS l USING (order_key)
        WHERE o.order_key IS NULL OR l.order_key IS NULL
           OR o.line_count IS DISTINCT FROM l.lines
           OR o.total_sales IS DISTINCT FROM l.sales
           OR o.total_profit IS DISTINCT FROM l.profit
    ) THEN
        RAISE EXCEPTION 'Order/line coverage or totals do not reconcile';
    END IF;

    DELETE FROM mart.sales_line_profitability_monthly;
    -- Classification uses only the line's own profit. No order status is used.
    INSERT INTO mart.sales_line_profitability_monthly
        (month_date, line_profitability_status, sales_lines, sales, profit)
    SELECT date_trunc('month', d.calendar_date::timestamp)::date,
           CASE WHEN l.profit > 0 THEN 'PROFITABLE'
                WHEN l.profit < 0 THEN 'LOSS_MAKING'
                WHEN l.profit = 0 THEN 'BREAK_EVEN' END,
           COUNT(*), SUM(l.sales), SUM(l.profit)
    FROM dwh.fact_order_line AS l
    JOIN dwh.dim_date AS d ON d.date_key = l.order_date_key
    GROUP BY 1, 2;

    -- Independent classification using disjoint predicates; compare every
    -- status and all-status totals by month, quarter, year and grand total.
    IF EXISTS (
        WITH classified AS (
            SELECT order_date_key, sales, profit, 'PROFITABLE'::text AS status
            FROM dwh.fact_order_line WHERE profit > 0
            UNION ALL
            SELECT order_date_key, sales, profit, 'LOSS_MAKING'
            FROM dwh.fact_order_line WHERE profit < 0
            UNION ALL
            SELECT order_date_key, sales, profit, 'BREAK_EVEN'
            FROM dwh.fact_order_line WHERE profit = 0
        ), combined AS (
            SELECT 'source'::text AS side, d.calendar_date AS dt, l.status,
                   1::bigint AS lines, l.sales, l.profit
            FROM classified AS l JOIN dwh.dim_date AS d ON d.date_key = l.order_date_key
            UNION ALL
            SELECT 'actual', month_date, line_profitability_status, sales_lines, sales, profit
            FROM mart.sales_line_profitability_monthly
        ), checks AS MATERIALIZED (
            SELECT side, p.period,
                   GROUPING(date_trunc(p.period, dt::timestamp)::date, status) AS level,
                   date_trunc(p.period, dt::timestamp)::date AS period_date, status,
                   SUM(lines) AS lines, SUM(sales) AS sales, SUM(profit) AS profit
            FROM combined CROSS JOIN (VALUES ('month'), ('quarter'), ('year')) AS p(period)
            GROUP BY side, p.period, GROUPING SETS (
                (date_trunc(p.period, dt::timestamp)::date, status),
                (date_trunc(p.period, dt::timestamp)::date), (status), ()
            )
        )
        (SELECT period, level, period_date, status, lines, sales, profit FROM checks WHERE side = 'source'
         EXCEPT ALL
         SELECT period, level, period_date, status, lines, sales, profit FROM checks WHERE side = 'actual')
        UNION ALL
        (SELECT period, level, period_date, status, lines, sales, profit FROM checks WHERE side = 'actual'
         EXCEPT ALL
         SELECT period, level, period_date, status, lines, sales, profit FROM checks WHERE side = 'source')
    ) THEN
        RAISE EXCEPTION 'Status/month/quarter/year/total reconciliation failed';
    END IF;

    IF EXISTS (
        WITH expected (status, lines, sales, profit) AS (
            VALUES
                ('PROFITABLE', 38078::numeric, 9999778.6181000000173215::numeric,
                 2388103.44699999994298596::numeric),
                ('LOSS_MAKING', 12544, 2490017.62478000000500115,
                 -920646.1557200000117909794),
                ('BREAK_EVEN', 668, 152705.6669999999994255, 0)
        ), actual AS (
            SELECT line_profitability_status, SUM(sales_lines), SUM(sales), SUM(profit)
            FROM mart.sales_line_profitability_monthly GROUP BY 1
        )
        (SELECT * FROM expected EXCEPT ALL SELECT * FROM actual)
        UNION ALL (SELECT * FROM actual EXCEPT ALL SELECT * FROM expected)
    ) OR (SELECT COUNT(*) FROM mart.sales_line_profitability_monthly) <> 144
       OR (SELECT COUNT(DISTINCT month_date) FROM mart.sales_line_profitability_monthly) <> 48
       OR (SELECT MIN(month_date) FROM mart.sales_line_profitability_monthly) IS DISTINCT FROM DATE '2012-01-01'
       OR (SELECT MAX(month_date) FROM mart.sales_line_profitability_monthly) IS DISTINCT FROM DATE '2015-12-01'
       OR (SELECT SUM(sales_lines) FROM mart.sales_line_profitability_monthly) IS DISTINCT FROM 51290::numeric THEN
        RAISE EXCEPTION 'Publication differs from approved controls';
    END IF;
    RAISE NOTICE 'sales_line_profitability_monthly: DQ/reconciliation PASS; 144 rows, 51290 lines';
END;
$load$;

COMMIT;
