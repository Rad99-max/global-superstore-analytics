"""Run the approved Global Superstore snapshot; importing performs no work."""

import logging
import re
from time import perf_counter
from uuid import UUID, uuid4

from psycopg.pq import TransactionStatus

from pipeline.config import Settings, load_settings
from pipeline.load_raw import LoaderError, connect, read_source_snapshot, run_load, safe_error

LOGGER = logging.getLogger(__name__)
# SHA-256 of the approved source workbook (Global Superstore 2016, see README "Dataset").
APPROVED_SOURCE_SHA256 = "5ffb10b2b3c34645251b33b91570e153c272639fa2a179c2f8013185e6a0d482"
DOWNLOAD_HINT = (
    "Download the workbook listed in README (Dataset) and save it as "
    "data/source/global_superstore_2016.xlsx."
)
# Each SQL stage must read its snapshot from the session setting set by execute_sql().
SQL_LOAD_ID_LINE = (
    "v_load_id CONSTANT UUID := COALESCE(NULLIF(current_setting('pipeline.load_id', true), ''), "
    "'pipeline.load_id is not set: run via run_pipeline.py or SET pipeline.load_id')::uuid;"
)
SQL_STAGES = (
    ("RAW -> STAGING", "sql/02_staging/05_load_staging.sql"),
    ("DWH Dimensions", "sql/03_dwh/09_load_dimensions.sql"),
    ("DWH Fact Order", "sql/03_dwh/10_load_fact_order.sql"),
    ("DWH Order Lines", "sql/03_dwh/11_load_fact_order_line.sql"),
    ("DWH Return Signal", "sql/03_dwh/12_load_fact_return_signal.sql"),
    ("MART Executive", "sql/04_mart/03_load_executive_monthly.sql"),
    ("MART Sales", "sql/04_mart/05_load_sales_profitability_monthly.sql"),
    ("MART Geographic", "sql/04_mart/07_load_geographic_monthly.sql"),
    ("MART Customer", "sql/04_mart/09_load_customer_monthly.sql"),
    ("MART Product", "sql/04_mart/11_load_product_monthly.sql"),
    ("MART Order Discount", "sql/04_mart/13_load_order_discount_monthly.sql"),
    ("MART Line Profit", "sql/04_mart/15_load_sales_line_profitability_monthly.sql"),
)


def format_elapsed(seconds: float) -> str:
    """Format rounded hundredths, carrying seconds into minutes and hours."""
    hundredths = round(seconds * 100)
    hours, remainder = divmod(hundredths, 360000)
    minutes, remainder = divmod(remainder, 6000)
    seconds_text = f"{remainder / 100:05.2f}s"
    if hours:
        return f"{hours}h {minutes:02d}m {seconds_text}"
    if minutes:
        return f"{minutes}m {seconds_text}"
    return f"{remainder / 100:.2f}s"


def preflight(settings: Settings) -> dict[str, str]:
    """Check the source hash and read all scripts before any database write."""
    if not settings.source_path.is_file():
        raise LoaderError(
            "Source Excel file is missing or is not a regular file. " + DOWNLOAD_HINT
        )
    _, digest = read_source_snapshot(settings.source_path)
    if digest != APPROVED_SOURCE_SHA256:
        raise LoaderError(
            "Source file SHA-256 differs from the approved snapshot: "
            f"expected {APPROVED_SOURCE_SHA256}, got {digest}. {DOWNLOAD_HINT} "
            "Stopped before RAW; nothing was written to the database."
        )
    scripts = {}
    for _, relative_path in SQL_STAGES:
        path = settings.root / relative_path
        if not path.is_file():
            raise LoaderError(f"Required SQL file missing: {relative_path}")
        text = path.read_text(encoding="utf-8-sig")
        hardcoded = re.search(
            r"\bv_load_id\s+CONSTANT\s+UUID\s*:=\s*'[0-9a-f-]+'", text, re.IGNORECASE
        )
        if text.count(SQL_LOAD_ID_LINE) != 1 or hardcoded is not None:
            raise LoaderError(f"SQL snapshot contract differs: {relative_path}")
        scripts[relative_path] = text
    return scripts


def resolve_success(settings: Settings, attempt_id: UUID, status: str) -> tuple[UUID, str]:
    """Use the exact attempt's persisted SHA-256, not latest SUCCESS or a new hash.

    Returns the SUCCESS load_id and its source SHA-256.
    """
    with connect(settings) as conn, conn.transaction(), conn.cursor() as cur:
        cur.execute("SET TRANSACTION READ ONLY")
        cur.execute("SELECT current_database()")
        if cur.fetchone() != ("sales_dwh",):
            raise LoaderError("Expected database sales_dwh during snapshot resolution")
        cur.execute(
            "SELECT status, source_sha256 FROM raw.load_log WHERE load_id = %s",
            (attempt_id,),
        )
        attempt = cur.fetchone()
        if attempt is None or attempt[0] != status or not attempt[1]:
            raise LoaderError("RAW attempt status/hash could not be confirmed")
        if status == "SUCCESS":
            return attempt_id, attempt[1]
        if status != "SKIPPED":
            raise LoaderError("Only SUCCESS or SKIPPED can resolve a source snapshot")
        cur.execute(
            """SELECT load_id FROM raw.load_log
               WHERE source_sha256 = %s AND status = 'SUCCESS'""",
            (attempt[1],),
        )
        matches = cur.fetchall()
        if len(matches) != 1:
            raise LoaderError("Expected exactly one SUCCESS for the skipped file SHA-256")
        return matches[0][0], attempt[1]


def execute_sql(settings: Settings, text: str, load_id: UUID) -> None:
    """The complete file owns BEGIN/COMMIT; never wrap or split its statements.

    The snapshot is passed as the session setting pipeline.load_id (autocommit
    connection, set before the script's own BEGIN).
    """
    with connect(settings) as conn:
        try:
            with conn.cursor() as cur:
                cur.execute("SELECT current_database()")
                if cur.fetchone() != ("sales_dwh",):
                    raise LoaderError("Expected database sales_dwh before SQL execution")
                cur.execute(
                    "SELECT set_config('pipeline.load_id', %s, false)", (str(load_id),)
                )
                if cur.fetchone() != (str(load_id),):
                    raise LoaderError("Could not set pipeline.load_id for the SQL stage")
                cur.execute(text, prepare=False)
                while cur.nextset():
                    pass
            if conn.info.transaction_status != TransactionStatus.IDLE:
                raise LoaderError("SQL script did not finish its transaction")
        except BaseException:
            # Preserve the original failure if the connection is already broken.
            try:
                conn.rollback()
            except Exception:
                pass
            raise


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    started = perf_counter()
    results: list[tuple[str, str, float]] = []
    current_stage = "Preflight"

    def stage(name, action):
        nonlocal current_stage
        current_stage = name
        stage_started = perf_counter()
        LOGGER.info("%s START", name)
        try:
            value = action()
        except BaseException:
            elapsed = perf_counter() - stage_started
            results.append((name, "FAILED", elapsed))
            LOGGER.error("%s FAILED elapsed=%s", name, format_elapsed(elapsed))
            raise
        elapsed = perf_counter() - stage_started
        results.append((name, "SUCCESS", elapsed))
        LOGGER.info("%s SUCCESS elapsed=%s", name, format_elapsed(elapsed))
        return value

    def setup():
        settings = load_settings()
        return settings, preflight(settings)

    def load_source():
        result = run_load(settings, uuid4())
        LOGGER.info("RAW attempt=%s status=%s", result.load_id, result.status)
        if result.status not in {"SUCCESS", "SKIPPED"}:
            # run_load's message is deliberately sanitized by the existing loader.
            raise LoaderError(f"RAW status={result.status}; {result.message}")
        return result

    def validate_snapshot():
        success_id, digest = resolve_success(settings, raw_result.load_id, raw_result.status)
        if digest != APPROVED_SOURCE_SHA256:
            raise LoaderError(
                "This orchestrator supports only the approved source SHA-256 "
                f"{APPROVED_SOURCE_SHA256}; resolved SUCCESS load_id={success_id} "
                f"has SHA-256 {digest}. "
                "Stopped before STAGING; no downstream stages were executed."
            )
        LOGGER.info("Source SUCCESS load_id=%s", success_id)
        return success_id

    exit_code = 0
    try:
        settings, scripts = stage("Preflight", setup)
        raw_result = stage("SOURCE -> RAW", load_source)
        load_id = stage("Snapshot validation", validate_snapshot)
        for name, relative_path in SQL_STAGES:
            stage(
                name,
                lambda path=relative_path: execute_sql(settings, scripts[path], load_id),
            )
    except KeyboardInterrupt:
        LOGGER.error("Interrupted at stage=%s; pipeline stopped without retry", current_stage)
        exit_code = 130
    except Exception as error:
        LOGGER.error("%s", safe_error(current_stage, error))
        exit_code = 1

    LOGGER.info("")
    for name, status, elapsed in results:
        LOGGER.info("%-22s %-7s %s", name, status, format_elapsed(elapsed))
    LOGGER.info("PIPELINE %s", "SUCCESS" if exit_code == 0 else "FAILED")
    LOGGER.info("Total elapsed: %s", format_elapsed(perf_counter() - started))
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
