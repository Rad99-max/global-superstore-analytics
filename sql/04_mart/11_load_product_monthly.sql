-- Execute the entire file. Any exception aborts publication; ROLLBACK preserves
-- the previous MART. Product status is checked, never stored.
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;

DO $load$
DECLARE
    v_load_id CONSTANT UUID := COALESCE(NULLIF(current_setting('pipeline.load_id', true), ''), 'pipeline.load_id is not set: run via run_pipeline.py or SET pipeline.load_id')::uuid;
    v_lines BIGINT;
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
    IF EXISTS (SELECT 1 FROM dwh.fact_order_line WHERE _load_id IS DISTINCT FROM v_load_id) THEN
        RAISE EXCEPTION 'Mixed or unexpected source load_id';
    END IF;

    SELECT COUNT(*), SUM(sales), SUM(profit) INTO v_lines, v_sales, v_profit
    FROM dwh.fact_order_line WHERE _load_id = v_load_id;
    IF v_lines <> 51290
       OR v_sales IS DISTINCT FROM 12642501.90988000002174815::numeric
       OR v_profit IS DISTINCT FROM 1467457.2912799999311949806::numeric THEN
        RAISE EXCEPTION 'Source count or totals differ from approved snapshot';
    END IF;

    IF EXISTS (
        SELECT 1 FROM dwh.fact_order_line AS l
        LEFT JOIN dwh.dim_date AS d ON d.date_key = l.order_date_key
        LEFT JOIN dwh.dim_product AS p ON p.product_key = l.product_key
        WHERE l.order_line_key IS NULL OR d.calendar_date IS NULL OR p.product_key IS NULL
           OR p.product_id IS NULL OR p.product_name IS NULL
           OR p.category IS NULL OR p.sub_category IS NULL
           OR l.sales IS NULL OR l.profit IS NULL OR l.discount_group IS NULL
    ) THEN
        RAISE EXCEPTION 'Unresolved Product/Order Date or NULL required source value';
    END IF;
    IF EXISTS (
        SELECT product_id FROM dwh.dim_product
        GROUP BY product_id HAVING COUNT(*) <> 1
    ) OR EXISTS (
        SELECT product_key FROM dwh.dim_product
        GROUP BY product_key
        HAVING COUNT(*) <> 1 OR COUNT(DISTINCT product_name) <> 1
            OR COUNT(DISTINCT category) <> 1 OR COUNT(DISTINCT sub_category) <> 1
    ) THEN
        RAISE EXCEPTION 'Product identity or attribute dependency is not unique';
    END IF;

    SELECT COUNT(*), COUNT(DISTINCT l.order_line_key)
    INTO v_joined_count, v_distinct_lines
    FROM dwh.fact_order_line AS l
    JOIN dwh.dim_date AS d ON d.date_key = l.order_date_key
    JOIN dwh.dim_product AS p ON p.product_key = l.product_key
    WHERE l._load_id = v_load_id;
    IF v_joined_count <> v_lines OR v_distinct_lines <> v_lines THEN
        RAISE EXCEPTION 'Source joins lose or multiply order lines';
    END IF;

    -- Validate all technical intervals before mapping them to business labels.
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
            ELSE '(0.70;1]' END
    ) THEN
        RAISE EXCEPTION 'Unknown discount label or disagreement with numeric interval';
    END IF;

    -- Frozen discount distribution controls for this approved snapshot.
    IF EXISTS (
        WITH source AS (
            SELECT CASE WHEN discount IS NULL THEN 'UNKNOWN'
                        WHEN discount < 0 OR discount > 1 THEN 'INVALID'
                        WHEN discount = 0 THEN '0%'
                        WHEN discount <= 0.10 THEN '0–10%'
                        WHEN discount <= 0.20 THEN '10–20%'
                        WHEN discount <= 0.30 THEN '20–30%'
                        ELSE '30%+' END AS discount_group,
                   sales, profit
            FROM dwh.fact_order_line WHERE _load_id = v_load_id
        ), actual AS (
            SELECT discount_group, COUNT(*) AS lines, SUM(sales) AS sales, SUM(profit) AS profit
            FROM source GROUP BY discount_group
        ), expected (discount_group, lines, sales, profit) AS (
            VALUES
                ('0%', 29009::bigint, 6992410.9499999999879405::numeric,
                 1770695.27319999997965504::numeric),
                ('0–10%', 4679, 1962618.8453800000032540, 338189.2613799999902184716),
                ('10–20%', 6274, 1757261.3354000000456805, 173254.843399999966626845),
                ('20–30%', 967, 382554.689279999981056, -21155.613120000000826496),
                ('30%+', 10361, 1547656.08982000000381715, -793526.473580000004478880)
        )
        (SELECT * FROM expected EXCEPT ALL SELECT * FROM actual)
        UNION ALL
        (SELECT * FROM actual EXCEPT ALL SELECT * FROM expected)
    ) THEN
        RAISE EXCEPTION 'Discount distribution differs from approved snapshot';
    END IF;

    DELETE FROM mart.product_monthly;

    WITH classified AS (
        SELECT date_trunc('month', d.calendar_date::timestamp)::date AS month_date,
               l.product_key,
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
                   WHEN 'INVALID' THEN 'INVALID' END AS discount_group,
               l.sales, l.profit
        FROM dwh.fact_order_line AS l
        JOIN dwh.dim_date AS d ON d.date_key = l.order_date_key
        WHERE l._load_id = v_load_id
    )
    INSERT INTO mart.product_monthly (month_date, product_key, discount_group, sales, profit)
    SELECT month_date, product_key, discount_group, SUM(sales), SUM(profit)
    FROM classified GROUP BY month_date, product_key, discount_group;

    -- Independent numeric classification and month construction. Compare both
    -- directions at the full grain and all required rollups, retaining zero groups.
    IF EXISTS (
        WITH expected_lines AS MATERIALIZED (
            SELECT make_date(EXTRACT(YEAR FROM d.calendar_date)::integer,
                             EXTRACT(MONTH FROM d.calendar_date)::integer, 1) AS month_date,
                   l.product_key,
                   CASE WHEN l.discount IS NULL THEN 'UNKNOWN'
                        WHEN l.discount < 0 OR l.discount > 1 THEN 'INVALID'
                        WHEN l.discount = 0 THEN '0%'
                        WHEN l.discount <= 0.10 THEN '0–10%'
                        WHEN l.discount <= 0.20 THEN '10–20%'
                        WHEN l.discount <= 0.30 THEN '20–30%'
                        ELSE '30%+' END AS discount_group,
                   l.sales, l.profit
            FROM dwh.fact_order_line AS l
            JOIN dwh.dim_date AS d ON d.date_key = l.order_date_key
            WHERE l._load_id = v_load_id
        ), combined AS (
            SELECT 'expected' AS side, month_date, product_key, discount_group, sales, profit
            FROM expected_lines
            UNION ALL
            SELECT 'actual', month_date, product_key, discount_group, sales, profit
            FROM mart.product_monthly
        ), attributed AS (
            SELECT x.*, p.category, p.sub_category,
                   date_trunc('quarter', x.month_date::timestamp)::date AS quarter_date,
                   date_trunc('year', x.month_date::timestamp)::date AS year_date
            FROM combined AS x JOIN dwh.dim_product AS p ON p.product_key = x.product_key
        ), checks AS MATERIALIZED (
            SELECT side,
                   GROUPING(month_date, product_key, discount_group, category,
                            sub_category, quarter_date, year_date) AS level,
                   month_date, product_key, discount_group, category,
                   sub_category, quarter_date, year_date,
                   SUM(sales) AS sales, SUM(profit) AS profit
            FROM attributed
            GROUP BY side, GROUPING SETS (
                (month_date, product_key, discount_group), (product_key),
                (sub_category), (category), (discount_group), (month_date),
                (quarter_date), (year_date), ()
            )
        ), expected AS (
            SELECT level, month_date, product_key, discount_group, category,
                   sub_category, quarter_date, year_date, sales, profit
            FROM checks WHERE side = 'expected'
        ), actual AS (
            SELECT level, month_date, product_key, discount_group, category,
                   sub_category, quarter_date, year_date, sales, profit
            FROM checks WHERE side = 'actual'
        )
        (SELECT * FROM expected EXCEPT ALL SELECT * FROM actual)
        UNION ALL
        (SELECT * FROM actual EXCEPT ALL SELECT * FROM expected)
    ) THEN
        RAISE EXCEPTION 'MART reconciliation failed: grain/Product/Category/discount/time/total';
    END IF;

    IF (SELECT COUNT(*) FROM mart.product_monthly) <> 45768
       OR (SELECT COUNT(DISTINCT product_key) FROM mart.product_monthly) <> 3788
       OR (SELECT COUNT(DISTINCT month_date) FROM mart.product_monthly) <> 48
       OR (SELECT MIN(month_date) FROM mart.product_monthly)
           IS DISTINCT FROM DATE '2012-01-01'
       OR (SELECT MAX(month_date) FROM mart.product_monthly)
           IS DISTINCT FROM DATE '2015-12-01'
       OR (SELECT COUNT(*) FROM mart.product_monthly WHERE profit = 0) <> 521
       OR (SELECT SUM(sales) FROM mart.product_monthly) IS DISTINCT FROM v_sales
       OR (SELECT SUM(profit) FROM mart.product_monthly) IS DISTINCT FROM v_profit THEN
        RAISE EXCEPTION 'Publication counts/coverage/zero profits/totals differ from approved snapshot';
    END IF;
    IF (
        SELECT COUNT(*) FROM (
            SELECT month_date, product_key FROM mart.product_monthly
            GROUP BY month_date, product_key HAVING SUM(profit) = 0
        ) AS zero_month_products
    ) <> 429 THEN
        RAISE EXCEPTION 'Expected 429 zero-profit Month/Product combinations after discount rollup';
    END IF;

    -- Acceptance check only: no product status is materialized in MART.
    IF EXISTS (
        WITH products AS (
            SELECT product_key, SUM(profit) AS profit
            FROM mart.product_monthly GROUP BY product_key
        ), actual AS (
            SELECT CASE WHEN profit > 0 THEN 'PROFITABLE'
                        WHEN profit < 0 THEN 'UNPROFITABLE'
                        WHEN profit = 0 THEN 'BREAK_EVEN' END AS status,
                   COUNT(*) AS products
            FROM products GROUP BY 1
        ), expected (status, products) AS (
            VALUES ('PROFITABLE', 3109::bigint), ('UNPROFITABLE', 677::bigint),
                   ('BREAK_EVEN', 2::bigint)
        )
        (SELECT * FROM expected EXCEPT ALL SELECT * FROM actual)
        UNION ALL
        (SELECT * FROM actual EXCEPT ALL SELECT * FROM expected)
    ) THEN
        RAISE EXCEPTION 'Full-period Product status acceptance check failed';
    END IF;
END;
$load$;

COMMIT;
