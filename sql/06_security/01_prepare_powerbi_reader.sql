\set ON_ERROR_STOP on
-- PREPARED ONLY. Execute only after separate user approval.
-- PostgreSQL 17+, administrator connection to sales_dwh.
-- Approved PUBLIC exceptions: sales_dwh TEMPORARY; public schema USAGE.
-- No PUBLIC ACL is changed. Unexpected permanent-object rights still abort.
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';

DO $preflight$
DECLARE
    db_rights text;
    schema_rights text;
    item text;
BEGIN
    IF current_database() <> 'sales_dwh' THEN
        RAISE EXCEPTION 'Connect to sales_dwh; no changes made';
    END IF;
    IF current_setting('server_version_num')::integer < 170000 THEN
        RAISE EXCEPTION 'PostgreSQL 17 or later required';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = current_user AND rolsuper) THEN
        RAISE EXCEPTION 'Administrator execution required';
    END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended('sales_dwh:prepare:powerbi_reader',0));
    SELECT string_agg(a.privilege_type, ', ' ORDER BY a.privilege_type)
      INTO db_rights
      FROM pg_database d
      CROSS JOIN LATERAL aclexplode(COALESCE(d.datacl,acldefault('d',d.datdba))) a
      WHERE d.datname = current_database() AND a.grantee = 0
        AND (a.privilege_type NOT IN ('CONNECT','TEMPORARY') OR a.is_grantable);
    SELECT string_agg(n.nspname || ':' || a.privilege_type, ', ' ORDER BY n.nspname,a.privilege_type)
      INTO schema_rights
      FROM pg_namespace n
      CROSS JOIN LATERAL aclexplode(COALESCE(n.nspacl,acldefault('n',n.nspowner))) a
      WHERE n.nspname NOT LIKE 'pg_%' AND n.nspname <> 'information_schema'
        AND a.grantee = 0
        AND (a.is_grantable OR a.privilege_type = 'CREATE'
             OR (n.nspname NOT IN ('dwh','mart','public') AND a.privilege_type = 'USAGE'));
    IF db_rights IS NOT NULL OR schema_rights IS NOT NULL THEN
        RAISE EXCEPTION 'Unexpected PUBLIC privileges. Database: %. Schemas: %.',
            COALESCE(db_rights,'none'), COALESCE(schema_rights,'none')
            USING HINT = 'Only database TEMPORARY and public schema USAGE are approved exceptions; no global REVOKE is authorized.';
    END IF;
    FOREACH item IN ARRAY ARRAY[
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
    ]::text[] LOOP
        IF to_regclass(item) IS NULL OR NOT EXISTS (
            SELECT 1 FROM pg_class WHERE oid = to_regclass(item)
              AND relkind IN ('r','p','v','m') AND NOT relrowsecurity
        ) THEN
            RAISE EXCEPTION 'Missing/unsupported/RLS-enabled source: %', item;
        END IF;
    END LOOP;
END
$preflight$;

DO $create_reader$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'powerbi_reader') THEN
        CREATE ROLE powerbi_reader NOLOGIN NOSUPERUSER NOINHERIT NOCREATEDB
            NOCREATEROLE NOREPLICATION NOBYPASSRLS;
    END IF;
END
$create_reader$;

GRANT CONNECT ON DATABASE sales_dwh TO powerbi_reader;
GRANT USAGE ON SCHEMA dwh, mart TO powerbi_reader;
GRANT SELECT ON TABLE
    dwh.dim_customer,
    dwh.dim_date,
    dwh.dim_geography,
    dwh.dim_product,
    mart.customer_monthly,
    mart.executive_monthly,
    mart.geographic_monthly,
    mart.order_discount_monthly,
    mart.product_monthly,
    mart.sales_line_profitability_monthly,
    mart.sales_profitability_monthly
TO powerbi_reader;

-- Defense in depth only: users can reset their session setting.
ALTER ROLE powerbi_reader IN DATABASE sales_dwh SET default_transaction_read_only = on;
ALTER ROLE powerbi_reader IN DATABASE sales_dwh SET search_path = pg_catalog, mart, dwh, pg_temp;

-- Unsafe pre-existing privileges cause FULL ROLLBACK, never silent repair.
DO $assert_reader$
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

END
$assert_reader$;

COMMIT;
\echo 'Prepared privileges. A new role remains NOLOGIN; password/activation are separate manual steps.'
