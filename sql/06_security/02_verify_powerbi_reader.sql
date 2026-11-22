\set ON_ERROR_STOP on
-- Prepared, NOT RUN. Use a REAL reader login after provisioning and activation.
-- Permission checks, not live destructive probes on application objects.
-- Accepted: PUBLIC TEMPORARY on sales_dwh; PUBLIC USAGE on schema public.
BEGIN READ ONLY;
SET LOCAL statement_timeout = '10s';

DO $verify_reader$
DECLARE
    reader_oid oid;
    object_name text;
    object_oid oid;
    ns record;
    rel record;
    allowed_objects text[] := ARRAY[
        'dwh.dim_customer',
        'dwh.dim_date',
        'dwh.dim_geography',
        'dwh.dim_product',
        'mart.customer_monthly',
        'mart.executive_monthly',
        'mart.geographic_monthly',
        'mart.order_discount_monthly',
        'mart.product_monthly',
        'mart.sales_line_profitability_monthly',
        'mart.sales_profitability_monthly'
    ]::text[];

BEGIN
    IF current_database() <> 'sales_dwh'
       OR session_user <> 'powerbi_reader' OR current_user <> session_user THEN
        RAISE EXCEPTION 'Requires a real powerbi_reader connection to sales_dwh';
    END IF;

    SELECT oid INTO reader_oid FROM pg_roles WHERE rolname = 'powerbi_reader';
    IF reader_oid IS NULL THEN
        RAISE EXCEPTION 'powerbi_reader does not exist';
    END IF;
    IF EXISTS (
        SELECT 1 FROM pg_roles WHERE oid = reader_oid
        AND (rolsuper OR rolinherit OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls)
    ) THEN
        RAISE EXCEPTION 'Unsafe role attributes; review separately, no automatic repair';
    END IF;
    -- NOINHERIT does not prevent SET ROLE; reject every membership.
    -- Also reject downstream members: new grants must not affect another role.
    IF EXISTS (SELECT 1 FROM pg_auth_members WHERE member = reader_oid OR roleid = reader_oid) THEN
        RAISE EXCEPTION 'Membership or downstream users require separate review';
    END IF;
    -- Persistent DROP is governed by ownership/membership, not a DROP ACL bit.
    IF EXISTS (
        SELECT 1 FROM pg_shdepend dep
        WHERE dep.refclassid = 'pg_authid'::regclass
          AND dep.refobjid = reader_oid AND dep.deptype = 'o'
          -- Approved TEMPORARY permits ownership/DROP of this role's temporary
          -- relations and namespace-local objects, never persistent ownership.
          AND NOT (
              dep.dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
              AND (
                  (dep.classid = 'pg_class'::regclass AND EXISTS (
                      SELECT 1 FROM pg_class c
                      WHERE c.oid = dep.objid AND c.relpersistence = 't'))
                  OR (dep.classid = 'pg_namespace'::regclass AND EXISTS (
                      SELECT 1 FROM pg_namespace n WHERE n.oid = dep.objid
                      AND n.nspname ~ '^pg_(toast_)?temp_[0-9]+$'))
                  OR (dep.classid = 'pg_type'::regclass AND EXISTS (
                      SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                      WHERE t.oid = dep.objid AND n.nspname ~ '^pg_(toast_)?temp_[0-9]+$'))
                  OR (dep.classid = 'pg_proc'::regclass AND EXISTS (
                      SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                      WHERE p.oid = dep.objid AND n.nspname ~ '^pg_(toast_)?temp_[0-9]+$'))
              )
          )
    ) THEN
        RAISE EXCEPTION 'Reader owns persistent objects; DROP denial cannot be guaranteed';
    END IF;
    -- PUBLIC TEMPORARY on sales_dwh is approved; CREATE/grant options are not.
    IF NOT has_database_privilege(reader_oid, current_database(), 'CONNECT')
       OR has_database_privilege(reader_oid, current_database(), 'CREATE')
       OR has_database_privilege(reader_oid, current_database(),
           'CONNECT WITH GRANT OPTION,TEMPORARY WITH GRANT OPTION')
    THEN
        RAISE EXCEPTION 'Unsafe database privileges, including PUBLIC/inherited grants';
    END IF;
    -- USAGE on public is the second approved exception. CREATE is still denied.
    FOR ns IN
        SELECT oid, nspname FROM pg_namespace
        WHERE nspname NOT LIKE 'pg_%' AND nspname <> 'information_schema'
    LOOP
        IF has_schema_privilege(reader_oid, ns.oid, 'CREATE')
           OR has_schema_privilege(reader_oid, ns.oid, 'USAGE WITH GRANT OPTION')
           OR (ns.nspname NOT IN ('dwh','mart','public')
               AND has_schema_privilege(reader_oid, ns.oid, 'USAGE'))
        THEN
            RAISE EXCEPTION 'Unexpected effective schema privileges: %', ns.nspname;
        END IF;
    END LOOP;
    FOREACH object_name IN ARRAY allowed_objects LOOP
        object_oid := to_regclass(object_name);
        IF object_oid IS NULL
           OR NOT has_schema_privilege(reader_oid, split_part(object_name,'.',1), 'USAGE')
           OR NOT has_table_privilege(reader_oid, object_oid, 'SELECT')
        THEN
            RAISE EXCEPTION 'Required SELECT/USAGE missing: %', object_name;
        END IF;
    END LOOP;
    FOR rel IN
        SELECT c.oid, c.relkind, n.nspname, c.relname
        FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname NOT LIKE 'pg_%' AND n.nspname <> 'information_schema'
          AND c.relkind IN ('r','p','v','m','f','S')
    LOOP
        IF rel.relkind = 'S' THEN
            IF has_sequence_privilege(reader_oid, rel.oid, 'SELECT,USAGE,UPDATE') THEN
                RAISE EXCEPTION 'Unexpected sequence access: %.%', rel.nspname, rel.relname;
            END IF;
        ELSE
            IF has_table_privilege(reader_oid, rel.oid,
                   'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN')
               OR has_any_column_privilege(reader_oid, rel.oid, 'INSERT,UPDATE,REFERENCES')
               OR has_table_privilege(reader_oid, rel.oid, 'SELECT WITH GRANT OPTION')
               OR has_any_column_privilege(reader_oid, rel.oid, 'SELECT WITH GRANT OPTION')
            THEN
                RAISE EXCEPTION 'Unsafe relation privileges: %.%', rel.nspname, rel.relname;
            END IF;
            IF NOT (rel.nspname || '.' || rel.relname = ANY(allowed_objects))
               AND has_any_column_privilege(reader_oid, rel.oid, 'SELECT')
            THEN
                RAISE EXCEPTION 'SELECT outside allowlist: %.%', rel.nspname, rel.relname;
            END IF;
        END IF;
    END LOOP;
    IF EXISTS (
        SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname NOT LIKE 'pg_%' AND n.nspname <> 'information_schema'
          AND p.prosecdef AND has_schema_privilege(reader_oid,n.oid,'USAGE')
          AND has_function_privilege(reader_oid,p.oid,'EXECUTE')
    ) THEN
        RAISE EXCEPTION 'Accessible user SECURITY DEFINER routine requires review';
    END IF;

    FOREACH object_name IN ARRAY allowed_objects LOOP
        EXECUTE format('SELECT * FROM %I.%I LIMIT 0',
                       split_part(object_name,'.',1),split_part(object_name,'.',2));
    END LOOP;
    RAISE NOTICE 'PASS: 11 SELECT probes; no persistent DML/DDL or membership paths. TEMPORARY/public USAGE accepted.';
END
$verify_reader$;

SELECT current_database() AS database_name, session_user AS authenticated_role,
       current_setting('transaction_read_only') AS transaction_read_only;

-- Informational data smoke test; current 2015 baseline is in the runbook.
SELECT SUM(sales) AS sales_2015, SUM(profit) AS profit_2015
FROM mart.geographic_monthly
WHERE month_date >= DATE '2015-01-01' AND month_date < DATE '2016-01-01';

ROLLBACK;
