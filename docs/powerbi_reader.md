# Power BI reader: audit, implementation and verification

Status: IMPLEMENTED. Deployment date: 2026-11-09.
Recorded on 2026-11-10 from the user's confirmation of successful execution,
verification and Power BI Desktop refresh. No database operations were performed
while recording these results.

Workspace: the global-superstore-analytics repository root.

## Результаты внедрения — 09.11.2026

Результаты подтверждены пользователем после выполнения настройки:

- PostgreSQL 17.4, база sales_dwh.
- Роль powerbi_reader создана и активирована с LOGIN.
- Пароль установлен с использованием SCRAM-SHA-256; пароль и его verifier
  в документацию не записываются.
- Предоставлены права SELECT на 11 аналитических источников Power BI.
- Проверка sql/06_security/02_verify_powerbi_reader.sql завершилась PASS.
- Операции изменения постоянных рабочих таблиц и структуры запрещены в рамках
  проверенной политики прав.
- Согласованные исключения PUBLIC TEMPORARY на sales_dwh и PUBLIC USAGE на
  схему public сохранены.
- Power BI Desktop переключён с postgres на powerbi_reader.
- Обновление данных Power BI выполнено успешно. Все визуализации и Business
  Insights работают после переключения подключения.

Контрольные показатели Market Performance за 2014 год:

| KPI | Значение |
|---|---:|
| Sales | 3 405 746,45 USD |
| Profit | 406 935,23 USD |
| Profit Margin | 11,95% |
| Net Loss | −121,38K USD |
| Active Countries | 143 |

Результат: отдельное подключение Power BI с ограниченными правами внедрено.
Это разделение ролей, а не разделение DEV/PROD. План сред:
[DEV/PROD](dev_prod_plan.md).

## Historical read-only audit (before implementation)

- PostgreSQL 17.4 at localhost:5432, database sales_dwh. All audit transactions
  were READ ONLY. No pipeline, migration, deployment, role or database DDL ran.
- Schemas: raw, staging, dwh, mart, public.
- At audit time powerbi_reader did not exist, so it had no memberships,
  ownership or direct grants. It was subsequently created as recorded above.
- All eleven model sources below are ordinary tables, owned by postgres, with
  no RLS. No source views were found.
- dwh/mart schema and relation ACLs are owner-only defaults.
- No pg_default_acl entries were found.
- PUBLIC has CONNECT and TEMPORARY on sales_dwh, USAGE on public, no CREATE on
  public. Its existing pgcrypto routines are executable by PUBLIC but are not
  SECURITY DEFINER. These are additional rights, not explicit reader grants.
- Loaded pg_hba_file_rules use scram-sha-256; no rule errors were returned.
- Both .env.dev and .env.prod effectively target localhost:5432/sales_dwh and
  use postgres. A password is configured locally; its value was never printed,
  copied into artifacts or changed. The reader must not replace the pipeline
  role: the pipeline needs write privileges.
- The model's source definitions do not reveal Desktop/Gateway saved
  credentials. Those credential stores and existing BI connections were not
  changed.

## Explicit Power BI source allowlist

DWH dimensions:
- dwh.dim_customer
- dwh.dim_date
- dwh.dim_geography
- dwh.dim_product

MART:
- mart.customer_monthly
- mart.executive_monthly
- mart.geographic_monthly
- mart.order_discount_monthly
- mart.product_monthly
- mart.sales_line_profitability_monthly
- mart.sales_profitability_monthly

Derived from PostgreSQL navigation steps in the saved semantic-model TMDL.
DWH facts, RAW, STAGING and sequences are not needed. Calculated tables and the
Measures table require no PostgreSQL access.

## Approved PUBLIC exceptions (2026-11-09)

The user approved preserving these existing PUBLIC grants:
- TEMPORARY on sales_dwh.
- USAGE on schema public.

Neither SQL file changes PUBLIC privileges. CONNECT through PUBLIC is also
normal existing database access and is not a new grant to other working roles.

PostgreSQL combines direct, inherited and PUBLIC privileges; NOINHERIT does not
remove PUBLIC rights. The former strict preflight blocker is removed only for
the two exceptions. The policy was applied on 2026-11-09 as confirmed above.
Any future rerun or policy change still requires separate authorization.

The enforced application-data policy remains:
- Explicit CONNECT, USAGE on dwh/mart and SELECT on exactly eleven sources.
- No INSERT/UPDATE/DELETE/TRUNCATE/REFERENCES/TRIGGER/MAINTAIN, including
  column-level grants; no sequence access or grant options.
- No CREATE DATABASE/schema or CREATE in permanent schemas, including public.
  No persistent ownership or role membership/SET ROLE path enabling DROP.
- No effective SELECT on non-allowlisted application relations.
- No accessible user SECURITY DEFINER routines.
- No blanket/future-table grants.

The reader may create, modify and drop its own temporary objects. This is NOT
a claim that every CREATE/DROP statement is forbidden. Ownership checks exempt
temporary relations and temporary namespace/type/routine objects in this database,
not persistent objects or ownership in other databases. Temporary ownership
does not grant modification rights on permanent analytics tables.

Remaining risks and limits:
- TEMPORARY permits resource/disk consumption. Read-only session defaults are
  defense in depth only; users can reset them. No quotas/global settings change.
- USAGE on public exposes routines executable by PUBLIC. Existing inspected
  pgcrypto routines are not SECURITY DEFINER; their EXECUTE grants are unchanged.
  New routines and ACL changes require a new review. The scripts reject
  accessible application SECURITY DEFINER routines on subsequent checks.
- Use schema-qualified analytics references. The prepared default search_path
  explicitly puts pg_temp last, avoiding implicit temporary-schema precedence.
  A search_path setting is not an authorization boundary.
- Other databases may independently expose PUBLIC CONNECT. This is not
  cluster-wide database isolation. Catalog/system-routine access remains normal.
- No privilege-drift monitor is installed. Recheck after changes to roles, PUBLIC,
  default ACLs or schemas. The audit found no PUBLIC application-relation,
  column or sequence grants and no default ACL entries.

No REVOKE FROM PUBLIC, ownership/membership/global/default ACL change is included.
Existing working roles, table definitions and data remain unaffected.

## Provisioning reference -- future reruns require confirmation

The role is already deployed. The commands below are retained as an operating
reference, not an instruction to recreate it or rerun provisioning now.
Future execution must be separately approved.

Administrator command, from the repository root:

~~~powershell
psql -X -h localhost -p 5432 -U postgres -d sales_dwh -W -v ON_ERROR_STOP=1 -f sql/06_security/01_prepare_powerbi_reader.sql
~~~

Use psql, not a GUI that continues after errors. The transaction and ON_ERROR_STOP
avoid partial application; disconnect on an error to roll back any open
transaction. Grants and settings are idempotent. A new role remains NOLOGIN.

For an existing reader, unsafe attributes, ownership, membership/SET ROLE paths,
downstream members, persistent write/DDL privileges, grant options, unexpected
SELECT/schema access outside the two exceptions, sequence access or accessible
user SECURITY DEFINER routines cause
rollback. The script does not automatically repair a pre-existing working role.
Even downstream membership is rejected so new grants cannot indirectly change
another working role's access.

If an allowed table is dropped and recreated, grants must be re-reviewed and
reapplied. New model sources require a reviewed allowlist change. The script
does not change schema/table owners, business logic or existing data.

## Password and LOGIN activation -- manual, after approval

After successful provisioning, open a private interactive psql session:

~~~powershell
psql -X -h localhost -p 5432 -U postgres -d sales_dwh -W
~~~

Type the following commands interactively:

~~~text
SET password_encryption = 'scram-sha-256';
\password powerbi_reader
ALTER ROLE powerbi_reader LOGIN;
~~~

Enter the password only in the hidden prompt. Never put a password in an ALTER
ROLE literal, shell argument, URI, PGPASSWORD, .env file committed to Git, chat,
screenshot, transcript, repository file or CI log.

The psql password command encrypts it client-side so the cleartext password does
not enter SQL command history or server SQL logs. Verifiers are also sensitive:
review external terminal/audit recording policies before password setup.
No password or verifier is present in these artifacts.

Do not activate LOGIN after a failed preflight. A rerun preserves any existing
LOGIN/password state; it does not rotate or reset a working credential.

## Verification -- real reader login after approval and activation

~~~powershell
psql -X -h localhost -p 5432 -U powerbi_reader -d sales_dwh -W -v ON_ERROR_STOP=1 -f sql/06_security/02_verify_powerbi_reader.sql
~~~

The test requires a REAL powerbi_reader session; administrator SET ROLE is
rejected. It runs in BEGIN READ ONLY and verifies:

1. Authentication/CONNECT and correct database/user.
2. SELECT * LIMIT 0 for all eleven Power BI sources (real permission/metadata
   probes, not just catalog ACL display).
3. No table-level or column-level INSERT, UPDATE, DELETE and related write/
   maintenance privileges, including grants inherited through PUBLIC/roles.
4. No database/permanent-schema CREATE, grant options or sequence access.
   TEMPORARY on sales_dwh and USAGE on public are accepted exceptions.
5. No persistent ownership or membership enabling DROP/SET ROLE escalation.
   Accepted temporary-object ownership does not fail this check.
6. No accessible user SECURITY DEFINER routine creating an alternative route.
7. A geographic 2015 smoke query. Current expected totals are approximately
   Sales 4,299,865.87 and Profit 504,165.97.

Permanent CREATE/DROP are checked through authorization paths, without creating
or dropping a real analytics object. DROP has no separate ACL privilege bit.
CREATE/DROP of reader-owned temporary objects is an accepted exception.
The permission functions inspect real effective rights; READ ONLY therefore
does not conceal an accidentally granted write ACL.

No live INSERT/UPDATE/DELETE/CREATE/DROP rejection probe is included: even a
rolled-back probe can fire statement triggers, advance sequences or take DDL
locks. If literal operation-rejection tests are required, obtain separate
approval for disposable fixtures. Do not use working analytics tables as
destructive test targets.

The smoke query is informational, not an immutable assertion about a dataset
that may legitimately change later. No query results are persisted.

## Power BI integration result and scope

The user confirmed a successful Power BI Desktop refresh under powerbi_reader,
including working visuals and Business Insights. This is a completed Desktop
integration check in addition to the SQL verification PASS.
No Power BI Service or Gateway validation is implied by this confirmation.

Do not change the working Desktop connection or Gateway credentials without
separate approval. The ETL profiles .env.dev/.env.prod still use their existing
write-capable account; they must not be replaced with powerbi_reader.

## Verification history

- Before deployment: live read-only catalog audit completed.
- Scripts statically checked against the saved model-source allowlist (11 objects).
- Updated policy predicates tested with read-only catalog/VALUES queries.
- Idempotence reviewed statically: conditional role creation, repeatable narrow
  GRANTs/settings, no password reset or forced LOGIN change, one transaction.
  Actual repeated provisioning was NOT tested during that pre-deployment review.
- Final pre-deployment review: both SQL files and all four DO blocks passed
  offline parsing with the PostgreSQL-17-compatible pglast 7.22 parser.
  No SQL was executed during that review.
- 2026-11-09: the user confirmed actual role creation, LOGIN activation, SCRAM
  password setup, verification PASS and successful Power BI Desktop refresh.
- 2026-11-10: these implementation results were documented from user
  confirmation. No PostgreSQL operation, refresh or pipeline run was performed.

## Official PostgreSQL 17 references

- Additive permissions / REVOKE:
  https://www.postgresql.org/docs/17/sql-revoke.html
- psql password command:
  https://www.postgresql.org/docs/17/app-psql.html
- Effective privilege inquiry functions:
  https://www.postgresql.org/docs/17/functions-info.html

