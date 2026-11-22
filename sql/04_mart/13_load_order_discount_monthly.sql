-- Atomic publication of the approved snapshot. On error issue ROLLBACK.
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
    -- Serialize refreshes of this publication, without locking other MARTs.
    LOCK TABLE mart.order_discount_monthly IN EXCLUSIVE MODE;

    IF (SELECT COUNT(*) FROM dwh.fact_order) <> 25739
       OR (SELECT COUNT(*) FROM dwh.fact_order_line) <> 51290
       OR EXISTS (SELECT 1 FROM dwh.fact_order WHERE _load_id IS DISTINCT FROM v_load_id)
       OR EXISTS (SELECT 1 FROM dwh.fact_order_line WHERE _load_id IS DISTINCT FROM v_load_id)
       OR (SELECT SUM(total_sales) FROM dwh.fact_order)
           IS DISTINCT FROM 12642501.90988000002174815::numeric
       OR (SELECT SUM(total_profit) FROM dwh.fact_order)
           IS DISTINCT FROM 1467457.2912799999311949806::numeric THEN
        RAISE EXCEPTION 'Source differs from approved snapshot';
    END IF;

    IF EXISTS (
        SELECT 1 FROM dwh.fact_order AS o
        LEFT JOIN dwh.dim_date AS d ON d.date_key = o.order_date_key
        WHERE d.calendar_date IS NULL OR o.total_sales IS NULL OR o.total_profit IS NULL
           OR o.total_sales::text IN ('NaN', 'Infinity', '-Infinity')
           OR o.total_profit::text IN ('NaN', 'Infinity', '-Infinity')
    ) OR EXISTS (
        SELECT 1 FROM dwh.fact_order_line AS l
        LEFT JOIN dwh.fact_order AS o USING (order_key)
        WHERE o.order_key IS NULL OR l.order_date_key IS DISTINCT FROM o.order_date_key
           OR l._load_id IS DISTINCT FROM o._load_id
           OR l.discount IS NULL OR l.discount < 0 OR l.discount > 1
           OR l.discount::text IN ('NaN', 'Infinity', '-Infinity')
           OR l.sales IS NULL OR l.profit IS NULL
           OR l.sales::text IN ('NaN', 'Infinity', '-Infinity')
           OR l.profit::text IN ('NaN', 'Infinity', '-Infinity')
    ) THEN
        RAISE EXCEPTION 'Missing reference, inconsistent date/lineage or invalid measure/Discount';
    END IF;

    -- Line money is used only for DQ, never for publication measures.
    IF EXISTS (
        WITH lines AS (
            SELECT order_key, COUNT(*) AS line_count, SUM(sales) AS sales, SUM(profit) AS profit
            FROM dwh.fact_order_line GROUP BY order_key
        )
        SELECT 1 FROM dwh.fact_order AS o FULL JOIN lines AS l USING (order_key)
        WHERE o.order_key IS NULL OR l.order_key IS NULL
           OR o.line_count IS DISTINCT FROM l.line_count
           OR o.total_sales IS DISTINCT FROM l.sales
           OR o.total_profit IS DISTINCT FROM l.profit
    ) THEN
        RAISE EXCEPTION 'Order/line coverage or monetary reconciliation failed';
    END IF;

    -- Upgrade existing deployments atomically with publication. The default only
    -- backfills the previous snapshot before the complete rebuild below.
    ALTER TABLE mart.order_discount_monthly
        ADD COLUMN IF NOT EXISTS loss NUMERIC NOT NULL DEFAULT 0;
    ALTER TABLE mart.order_discount_monthly ALTER COLUMN loss DROP DEFAULT;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'mart.order_discount_monthly'::regclass
          AND conname = 'order_discount_monthly_loss_nonpositive'
    ) THEN
        ALTER TABLE mart.order_discount_monthly
            ADD CONSTRAINT order_discount_monthly_loss_nonpositive CHECK (loss <= 0);
    END IF;

    DELETE FROM mart.order_discount_monthly;
    WITH discount_sets AS (
        SELECT order_key, COUNT(DISTINCT discount) AS discount_count,
               ARRAY_AGG(DISTINCT discount) AS discounts
        FROM dwh.fact_order_line GROUP BY order_key
    ), classified AS (
        SELECT date_trunc('month', d.calendar_date::timestamp)::date AS month_date,
               CASE WHEN x.discount_count >= 2 THEN 'MIXED'
                    WHEN x.discount_count = 1 THEN
                        CASE WHEN x.discounts[1] = 0 THEN '0%'
                             WHEN x.discounts[1] <= 0.10 THEN '0–10%'
                             WHEN x.discounts[1] <= 0.20 THEN '10–20%'
                             WHEN x.discounts[1] <= 0.30 THEN '20–30%'
                             ELSE '30%+' END
               END AS category,
               o.total_sales, o.total_profit
        FROM dwh.fact_order AS o
        JOIN discount_sets AS x USING (order_key)
        JOIN dwh.dim_date AS d ON d.date_key = o.order_date_key
    )
    INSERT INTO mart.order_discount_monthly
        (month_date, order_discount_category, sales, profit, orders,
         loss_making_orders, loss_making_sales, loss)
    SELECT month_date, category, SUM(total_sales), SUM(total_profit), COUNT(*),
           COUNT(*) FILTER (WHERE total_profit < 0),
           COALESCE(SUM(total_sales) FILTER (WHERE total_profit < 0), 0::numeric),
           COALESCE(SUM(total_profit) FILTER (WHERE total_profit < 0), 0::numeric)
    FROM classified GROUP BY month_date, category;

    -- Independent classification: distinct (order_key, discount) tuples and
    -- explicit intervals. No representative Discount is selected for MIXED.
    IF EXISTS (
        WITH values AS (
            SELECT DISTINCT order_key, discount FROM dwh.fact_order_line
        ), categories AS (
            SELECT order_key,
                   CASE WHEN COUNT(*) > 1 THEN 'MIXED'
                        ELSE (ARRAY_AGG(CASE
                            WHEN discount = 0 THEN '0%'
                            WHEN discount > 0 AND discount <= .10 THEN '0–10%'
                            WHEN discount > .10 AND discount <= .20 THEN '10–20%'
                            WHEN discount > .20 AND discount <= .30 THEN '20–30%'
                            WHEN discount > .30 AND discount <= 1 THEN '30%+'
                        END))[1] END AS category
            FROM values GROUP BY order_key
        ), expected AS (
            SELECT make_date(d.calendar_year::integer, d.calendar_month::integer, 1) AS month_date,
                   c.category, SUM(o.total_sales) AS sales, SUM(o.total_profit) AS profit,
                   COUNT(*) AS orders, COUNT(*) FILTER (WHERE o.total_profit < 0) AS loss_orders,
                   COALESCE(SUM(o.total_sales) FILTER (WHERE o.total_profit < 0), 0::numeric) AS loss_sales,
                   COALESCE(SUM(o.total_profit) FILTER (WHERE o.total_profit < 0), 0::numeric) AS loss
            FROM dwh.fact_order AS o JOIN categories AS c USING (order_key)
            JOIN dwh.dim_date AS d ON d.date_key = o.order_date_key
            GROUP BY 1, 2
        )
        (SELECT * FROM expected EXCEPT ALL SELECT * FROM mart.order_discount_monthly)
        UNION ALL
        (SELECT * FROM mart.order_discount_monthly EXCEPT ALL SELECT * FROM expected)
    ) THEN
        RAISE EXCEPTION 'Independent month/category reconciliation failed';
    END IF;

    -- Check all additive measures by month, quarter, year and grand total.
    IF EXISTS (
        WITH source AS (
            SELECT d.calendar_date AS dt, o.total_sales AS sales, o.total_profit AS profit,
                   1::bigint AS orders, (o.total_profit < 0)::integer AS loss_orders,
                   CASE WHEN o.total_profit < 0 THEN o.total_sales ELSE 0 END AS loss_sales,
                   CASE WHEN o.total_profit < 0 THEN o.total_profit ELSE 0 END AS loss
            FROM dwh.fact_order AS o JOIN dwh.dim_date AS d ON d.date_key = o.order_date_key
        ), actual AS (
            SELECT month_date AS dt, sales, profit, orders, loss_making_orders AS loss_orders,
                   loss_making_sales AS loss_sales, loss FROM mart.order_discount_monthly
        ), periods AS (
            SELECT 'source' AS side, * FROM source
            UNION ALL SELECT 'actual', * FROM actual
        ), checks AS (
            SELECT side, p.period, date_trunc(p.period, dt::timestamp)::date AS period_date,
                   SUM(sales) AS sales, SUM(profit) AS profit, SUM(orders) AS orders,
                   SUM(loss_orders) AS loss_orders, SUM(loss_sales) AS loss_sales,
                   SUM(loss) AS loss
            FROM periods CROSS JOIN (VALUES ('month'), ('quarter'), ('year')) AS p(period)
            GROUP BY side, p.period, GROUPING SETS ((date_trunc(p.period, dt::timestamp)::date), ())
        )
        (SELECT period, period_date, sales, profit, orders, loss_orders, loss_sales, loss
         FROM checks WHERE side = 'source'
         EXCEPT ALL
         SELECT period, period_date, sales, profit, orders, loss_orders, loss_sales, loss
         FROM checks WHERE side = 'actual')
        UNION ALL
        (SELECT period, period_date, sales, profit, orders, loss_orders, loss_sales, loss
         FROM checks WHERE side = 'actual'
         EXCEPT ALL
         SELECT period, period_date, sales, profit, orders, loss_orders, loss_sales, loss
         FROM checks WHERE side = 'source')
    ) THEN
        RAISE EXCEPTION 'Month/quarter/year/total reconciliation failed';
    END IF;

    IF (SELECT SUM(loss) FROM mart.order_discount_monthly)
           IS DISTINCT FROM
           (SELECT COALESCE(SUM(total_profit) FILTER (WHERE total_profit < 0), 0::numeric)
            FROM dwh.fact_order)
       OR (SELECT ROUND(SUM(loss), 2) FROM mart.order_discount_monthly
           WHERE month_date >= DATE '2015-01-01' AND month_date < DATE '2016-01-01')
           IS DISTINCT FROM -284696.03::numeric THEN
        RAISE EXCEPTION 'Order-level loss reconciliation or 2015 control failed';
    END IF;

    IF (SELECT COUNT(*) FROM mart.order_discount_monthly) <> 287
       OR (SELECT COUNT(DISTINCT month_date) FROM mart.order_discount_monthly) <> 48
       OR (SELECT MIN(month_date) FROM mart.order_discount_monthly) IS DISTINCT FROM DATE '2012-01-01'
       OR (SELECT MAX(month_date) FROM mart.order_discount_monthly) IS DISTINCT FROM DATE '2015-12-01'
       OR (SELECT SUM(orders) FROM mart.order_discount_monthly) IS DISTINCT FROM 25739::numeric
       OR (SELECT SUM(loss_making_orders) FROM mart.order_discount_monthly) IS DISTINCT FROM 6309::numeric
       OR (SELECT SUM(orders) FROM mart.order_discount_monthly WHERE order_discount_category <> 'MIXED') IS DISTINCT FROM 21818::numeric
       OR (SELECT SUM(orders) FROM mart.order_discount_monthly WHERE order_discount_category = 'MIXED') IS DISTINCT FROM 3921::numeric
       OR (SELECT SUM(loss_making_orders) FROM mart.order_discount_monthly WHERE order_discount_category = 'MIXED') IS DISTINCT FROM 1416::numeric
       OR (SELECT SUM(orders) FROM mart.order_discount_monthly WHERE order_discount_category = '0%') IS DISTINCT FROM 13332::numeric
       OR (SELECT SUM(loss_making_orders) FROM mart.order_discount_monthly WHERE order_discount_category = '0%') IS DISTINCT FROM 0::numeric
       OR (SELECT SUM(orders) FROM mart.order_discount_monthly WHERE order_discount_category = '30%+') IS DISTINCT FROM 4189::numeric
       OR (SELECT SUM(loss_making_orders) FROM mart.order_discount_monthly WHERE order_discount_category = '30%+') IS DISTINCT FROM 3958::numeric THEN
        RAISE EXCEPTION 'Publication differs from approved category controls';
    END IF;
    RAISE NOTICE 'order_discount_monthly: DQ/reconciliation PASS; 287 rows, 25739 orders';
END;
$load$;

COMMIT;
