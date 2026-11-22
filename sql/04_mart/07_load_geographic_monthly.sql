-- Execute the entire file. An exception aborts the transaction; ROLLBACK
-- preserves the previous publication. No source data is modified.
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;

DO $load$
DECLARE
    v_load_id CONSTANT UUID := COALESCE(NULLIF(current_setting('pipeline.load_id', true), ''), 'pipeline.load_id is not set: run via run_pipeline.py or SET pipeline.load_id')::uuid;
    v_orders BIGINT;
    v_unprofitable_orders BIGINT;
    v_sales NUMERIC;
    v_profit NUMERIC;
    v_loss_making_sales NUMERIC;
    v_joined_count BIGINT;
    v_distinct_orders BIGINT;
    -- Frozen 30%+ controls (discount > 0.30); same as 11_load_product_monthly.sql.
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

    IF EXISTS (SELECT 1 FROM dwh.fact_order WHERE _load_id IS DISTINCT FROM v_load_id)
       OR EXISTS (
           SELECT 1 FROM dwh.fact_order_line WHERE _load_id IS DISTINCT FROM v_load_id
       ) THEN
        RAISE EXCEPTION 'Mixed or unexpected source load_id';
    END IF;

    SELECT COUNT(*), COUNT(*) FILTER (WHERE total_profit < 0),
           SUM(total_sales), SUM(total_profit),
           COALESCE(SUM(total_sales) FILTER (WHERE total_profit < 0), 0::numeric)
    INTO v_orders, v_unprofitable_orders, v_sales, v_profit, v_loss_making_sales
    FROM dwh.fact_order WHERE _load_id = v_load_id;
    IF v_orders <> 25739 OR v_unprofitable_orders <> 6309
       OR v_sales IS DISTINCT FROM 12642501.90988000002174815::numeric
       OR v_profit IS DISTINCT FROM 1467457.2912799999311949806::numeric
       OR v_loss_making_sales IS DISTINCT FROM 2372832.6364000000007972::numeric
       OR (SELECT COUNT(*) FROM dwh.fact_order_line WHERE _load_id = v_load_id) <> 51290 THEN
        RAISE EXCEPTION 'Source counts or totals differ from approved snapshot';
    END IF;

    IF EXISTS (
        SELECT 1 FROM dwh.fact_order AS o
        LEFT JOIN dwh.dim_date AS d ON d.date_key = o.order_date_key
        LEFT JOIN dwh.dim_geography AS g ON g.geography_key = o.geography_key
        WHERE o.order_key IS NULL OR d.calendar_date IS NULL OR g.geography_key IS NULL
           OR g.market IS NULL OR g.region IS NULL OR g.country IS NULL
           OR o.total_sales IS NULL OR o.total_profit IS NULL
    ) THEN
        RAISE EXCEPTION 'Unresolved Order Date/geography or NULL required source value';
    END IF;

    SELECT COUNT(*), COUNT(DISTINCT o.order_key)
    INTO v_joined_count, v_distinct_orders
    FROM dwh.fact_order AS o
    JOIN dwh.dim_date AS d ON d.date_key = o.order_date_key
    JOIN dwh.dim_geography AS g ON g.geography_key = o.geography_key
    WHERE o._load_id = v_load_id;
    IF v_joined_count <> v_orders OR v_distinct_orders <> v_orders THEN
        RAISE EXCEPTION 'Order/dimension joins lose or multiply orders';
    END IF;

    -- Order lines are used for independent source checks and for the 30%+
    -- columns only; all other MART measures come from fact_order.
    IF EXISTS (
        SELECT 1 FROM dwh.fact_order_line AS l
        LEFT JOIN dwh.fact_order AS o ON o.order_key = l.order_key
        LEFT JOIN dwh.dim_geography AS g ON g.geography_key = l.geography_key
        WHERE o.order_key IS NULL OR g.geography_key IS NULL
           OR g.market IS NULL OR g.region IS NULL OR g.country IS NULL
           OR l.geography_key IS DISTINCT FROM o.geography_key
           OR l.order_date_key IS DISTINCT FROM o.order_date_key
           OR l._load_id IS DISTINCT FROM o._load_id
           OR l.sales IS NULL OR l.profit IS NULL
    ) THEN
        RAISE EXCEPTION 'Line geography/date/lineage is inconsistent with its order';
    END IF;

    IF EXISTS (
        WITH lines AS (
            SELECT order_key, COUNT(*) AS line_count,
                   COUNT(DISTINCT geography_key) AS geography_count,
                   SUM(sales) AS sales, SUM(profit) AS profit
            FROM dwh.fact_order_line WHERE _load_id = v_load_id GROUP BY order_key
        )
        SELECT 1 FROM dwh.fact_order AS o
        FULL JOIN lines AS l USING (order_key)
        WHERE o.order_key IS NULL OR l.order_key IS NULL OR l.geography_count <> 1
           OR o.line_count IS DISTINCT FROM l.line_count
           OR o.total_sales IS DISTINCT FROM l.sales
           OR o.total_profit IS DISTINCT FROM l.profit
    ) THEN
        RAISE EXCEPTION 'Order geography/count/totals do not reconcile with lines';
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

    DELETE FROM mart.geographic_monthly;

    WITH order_months AS (
        SELECT date_trunc('month', d.calendar_date::timestamp)::date AS month_date,
               o.geography_key,
               SUM(o.total_sales) AS sales, SUM(o.total_profit) AS profit,
               COALESCE(SUM(o.total_sales) FILTER (WHERE o.total_profit < 0), 0::numeric)
                   AS loss_making_sales,
               COUNT(*) AS orders,
               COUNT(*) FILTER (WHERE o.total_profit < 0) AS unprofitable_orders
        FROM dwh.fact_order AS o
        JOIN dwh.dim_date AS d ON d.date_key = o.order_date_key
        WHERE o._load_id = v_load_id
        GROUP BY date_trunc('month', d.calendar_date::timestamp)::date, o.geography_key
    ), discount_30plus_months AS (
        SELECT date_trunc('month', d.calendar_date::timestamp)::date AS month_date,
               l.geography_key,
               SUM(l.sales) AS sales_30plus, SUM(l.profit) AS profit_30plus
        FROM dwh.fact_order_line AS l
        JOIN dwh.dim_date AS d ON d.date_key = l.order_date_key
        WHERE l._load_id = v_load_id
          AND l.discount_group IN ('(0.30;0.40]', '(0.40;0.50]', '(0.50;0.60]',
                                   '(0.60;0.70]', '(0.70;1]')
        GROUP BY date_trunc('month', d.calendar_date::timestamp)::date, l.geography_key
    )
    INSERT INTO mart.geographic_monthly
        (month_date, geography_key, sales, profit, loss_making_sales, orders,
         unprofitable_orders, sales_30plus, profit_30plus)
    SELECT om.month_date, om.geography_key, om.sales, om.profit, om.loss_making_sales,
           om.orders, om.unprofitable_orders,
           COALESCE(dm.sales_30plus, 0::numeric), COALESCE(dm.profit_30plus, 0::numeric)
    FROM order_months AS om
    LEFT JOIN discount_30plus_months AS dm
        ON dm.month_date = om.month_date AND dm.geography_key = om.geography_key;

    -- Independent month construction and conditional measures for reconciliation.
    -- Check full grain plus month, Market, Region, Country, quarter, year and total.
    IF EXISTS (
        WITH expected_orders AS MATERIALIZED (
            SELECT make_date(EXTRACT(YEAR FROM d.calendar_date)::integer,
                             EXTRACT(MONTH FROM d.calendar_date)::integer, 1) AS month_date,
                   o.geography_key, o.total_sales AS sales, o.total_profit AS profit,
                   CASE WHEN o.total_profit < 0 THEN o.total_sales ELSE 0::numeric END
                       AS loss_making_sales,
                   1::bigint AS orders,
                   CASE WHEN o.total_profit < 0 THEN 1::bigint ELSE 0::bigint END
                       AS unprofitable_orders,
                   0::numeric AS sales_30plus, 0::numeric AS profit_30plus
            FROM dwh.fact_order AS o
            JOIN dwh.dim_date AS d ON d.date_key = o.order_date_key
            WHERE o._load_id = v_load_id
            UNION ALL
            -- 30%+ from numeric discount, independent of discount_group labels.
            SELECT make_date(EXTRACT(YEAR FROM d.calendar_date)::integer,
                             EXTRACT(MONTH FROM d.calendar_date)::integer, 1),
                   l.geography_key, 0::numeric, 0::numeric, 0::numeric,
                   0::bigint, 0::bigint, l.sales, l.profit
            FROM dwh.fact_order_line AS l
            JOIN dwh.dim_date AS d ON d.date_key = l.order_date_key
            WHERE l._load_id = v_load_id AND l.discount > 0.30 AND l.discount <= 1
        ), combined AS (
            SELECT 'expected' AS side, month_date, geography_key,
                   sales, profit, loss_making_sales, orders, unprofitable_orders,
                   sales_30plus, profit_30plus
            FROM expected_orders
            UNION ALL
            SELECT 'actual', month_date, geography_key,
                   sales, profit, loss_making_sales, orders, unprofitable_orders,
                   sales_30plus, profit_30plus
            FROM mart.geographic_monthly
        ), attributed AS (
            SELECT c.*, g.market, g.region, g.country,
                   date_trunc('quarter', c.month_date::timestamp)::date AS quarter_date,
                   date_trunc('year', c.month_date::timestamp)::date AS year_date
            FROM combined AS c
            JOIN dwh.dim_geography AS g ON g.geography_key = c.geography_key
        ), checks AS MATERIALIZED (
            SELECT side,
                   GROUPING(month_date, geography_key, market, region, country,
                            quarter_date, year_date) AS level,
                   month_date, geography_key, market, region, country, quarter_date, year_date,
                   SUM(sales) AS sales, SUM(profit) AS profit,
                   SUM(loss_making_sales) AS loss_making_sales,
                   SUM(orders) AS orders, SUM(unprofitable_orders) AS unprofitable_orders,
                   SUM(sales_30plus) AS sales_30plus, SUM(profit_30plus) AS profit_30plus
            FROM attributed
            GROUP BY side, GROUPING SETS (
                (month_date, geography_key), (month_date), (market), (region), (country),
                (quarter_date), (year_date), ()
            )
        ), expected AS (
            SELECT level, month_date, geography_key, market, region, country,
                   quarter_date, year_date, sales, profit, loss_making_sales,
                   orders, unprofitable_orders, sales_30plus, profit_30plus
            FROM checks WHERE side = 'expected'
        ), actual AS (
            SELECT level, month_date, geography_key, market, region, country,
                   quarter_date, year_date, sales, profit, loss_making_sales,
                   orders, unprofitable_orders, sales_30plus, profit_30plus
            FROM checks WHERE side = 'actual'
        )
        (SELECT * FROM expected EXCEPT ALL SELECT * FROM actual)
        UNION ALL
        (SELECT * FROM actual EXCEPT ALL SELECT * FROM expected)
    ) THEN
        RAISE EXCEPTION 'MART reconciliation failed: grain/time/geography/total';
    END IF;

    IF EXISTS (
        SELECT 1 FROM mart.geographic_monthly
        WHERE sales_30plus < 0 OR sales_30plus > sales
    ) THEN
        RAISE EXCEPTION 'sales_30plus is outside [0, sales]';
    END IF;

    IF (SELECT COUNT(*) FROM mart.geographic_monthly) <> 3841
       OR (SELECT COUNT(DISTINCT month_date) FROM mart.geographic_monthly) <> 48
       OR (SELECT MIN(month_date) FROM mart.geographic_monthly)
           IS DISTINCT FROM DATE '2012-01-01'
       OR (SELECT MAX(month_date) FROM mart.geographic_monthly)
           IS DISTINCT FROM DATE '2015-12-01' THEN
        RAISE EXCEPTION 'Publication grain/count/coverage differs from approved snapshot';
    END IF;

    IF (SELECT SUM(sales) FROM mart.geographic_monthly) IS DISTINCT FROM v_sales
       OR (SELECT SUM(profit) FROM mart.geographic_monthly) IS DISTINCT FROM v_profit
       OR (SELECT SUM(loss_making_sales) FROM mart.geographic_monthly)
           IS DISTINCT FROM v_loss_making_sales
       OR (SELECT SUM(orders) FROM mart.geographic_monthly) IS DISTINCT FROM v_orders
       OR (SELECT SUM(unprofitable_orders) FROM mart.geographic_monthly)
           IS DISTINCT FROM v_unprofitable_orders
       OR (SELECT SUM(sales) FROM dwh.fact_order_line WHERE _load_id = v_load_id)
           IS DISTINCT FROM v_sales
       OR (SELECT SUM(profit) FROM dwh.fact_order_line WHERE _load_id = v_load_id)
           IS DISTINCT FROM v_profit
       OR (SELECT SUM(sales_30plus) FROM mart.geographic_monthly)
           IS DISTINCT FROM v_sales_30plus
       OR (SELECT SUM(profit_30plus) FROM mart.geographic_monthly)
           IS DISTINCT FROM v_profit_30plus THEN
        RAISE EXCEPTION 'Grand totals differ between MART, orders or order lines';
    END IF;
END;
$load$;

COMMIT;
