"""SOURCE -> RAW. Importing this module does not connect or load anything.

Execution is deliberately confined to main() and its __main__ guard.
One process is supported; no advisory lock or automatic recovery/deletion.
"""

from dataclasses import dataclass
from datetime import date, datetime, time
from hashlib import sha256
from io import BytesIO
import logging
import math
from pathlib import Path
import re
from uuid import UUID, uuid4

from openpyxl import load_workbook
from openpyxl.utils import get_column_letter
import psycopg
from psycopg import sql
from psycopg.pq import TransactionStatus

from .config import ConfigError, SOURCE_FILE, Settings, load_settings

LOGGER = logging.getLogger(__name__)
ORDERS = (
    ("Row ID", "integer"), ("Order ID", "text"),
    ("Order Date", "date"), ("Ship Date", "date"),
    ("Ship Mode", "text"), ("Customer ID", "text"),
    ("Customer Name", "text"), ("Segment", "text"),
    ("Postal Code", "text"), ("City", "text"), ("State", "text"),
    ("Country", "text"), ("Region", "text"), ("Market", "text"),
    ("Product ID", "text"), ("Category", "text"),
    ("Sub-Category", "text"), ("Product Name", "text"),
    ("Sales", "double precision"), ("Quantity", "integer"),
    ("Discount", "double precision"), ("Profit", "double precision"),
    ("Shipping Cost", "double precision"), ("Order Priority", "text"),
)
SHEETS = {
    "Orders": ("orders", ORDERS),
    "Returns": ("returns", (("Returned", "text"), ("Order ID", "text"), ("Region", "text"))),
    "People": ("people", (("Person", "text"), ("Region", "text"))),
}
TECHNICAL = (
    ("_raw_id", "bigint"), ("_loaded_at", "timestamp with time zone"),
    ("_source_file", "text"), ("_source_sheet", "text"),
    ("_source_row_number", "integer"), ("_load_id", "uuid"),
)
LOG_COLUMNS = (
    ("load_id", "uuid"), ("source_file", "text"), ("source_sha256", "text"),
    ("started_at", "timestamp with time zone"), ("finished_at", "timestamp with time zone"),
    ("status", "text"), ("orders_rows_loaded", "bigint"),
    ("returns_rows_loaded", "bigint"), ("people_rows_loaded", "bigint"),
    ("error_text", "text"),
)
# PostgreSQL 17 deparsed forms of the approved CHECK constraints.
LOG_CHECKS = {
    "load_log_source_file_check": "CHECK ((source_file <> ''::text))",
    "load_log_source_sha256_format_check": "CHECK (((source_sha256 IS NULL) OR ((length(source_sha256) = 64) AND (source_sha256 ~ '^[0-9a-f]{64}$'::text))))",
    "load_log_status_check": "CHECK ((status = ANY (ARRAY['STARTED'::text, 'SUCCESS'::text, 'FAILED'::text, 'SKIPPED'::text])))",
    "load_log_rows_nonnegative_check": "CHECK (((orders_rows_loaded >= 0) AND (returns_rows_loaded >= 0) AND (people_rows_loaded >= 0)))",
    "load_log_unsuccessful_rows_check": "CHECK (((status = 'SUCCESS'::text) OR ((orders_rows_loaded = 0) AND (returns_rows_loaded = 0) AND (people_rows_loaded = 0))))",
    "load_log_finished_at_status_check": "CHECK ((((status = 'STARTED'::text) AND (finished_at IS NULL)) OR ((status = ANY (ARRAY['SUCCESS'::text, 'FAILED'::text, 'SKIPPED'::text])) AND (finished_at IS NOT NULL))))",
    "load_log_time_order_check": "CHECK (((finished_at IS NULL) OR (finished_at >= started_at)))",
    "load_log_terminal_sha256_check": "CHECK (((status <> ALL (ARRAY['SUCCESS'::text, 'SKIPPED'::text])) OR (source_sha256 IS NOT NULL)))",
    "load_log_error_text_check": "CHECK ((((status = 'FAILED'::text) AND (error_text IS NOT NULL) AND (btrim(error_text) <> ''::text)) OR ((status = ANY (ARRAY['STARTED'::text, 'SUCCESS'::text, 'SKIPPED'::text])) AND (error_text IS NULL))))",
}
REFERENCE_COUNTS = {"Orders": 51290, "Returns": 1079, "People": 24}


class LoaderError(Exception):
    """Only loader-authored, value-free diagnostics may use this exception."""


@dataclass
class PreparedSheet:
    name: str
    table: str
    columns: tuple
    rows: list[tuple[int, tuple]]
    expected_count: int


@dataclass(frozen=True)
class LoadResult:
    load_id: UUID
    status: str
    counts: tuple[int, int, int] = (0, 0, 0)
    message: str = ""


def connect(settings: Settings) -> psycopg.Connection:
    return psycopg.connect(**settings.connection_kwargs(), autocommit=True)


def safe_error(stage: str, error: Exception) -> str:
    """Never use a driver's message/context: COPY can include source values."""
    if isinstance(error, (LoaderError, ConfigError)):
        reason = str(error)
    elif isinstance(error, psycopg.Error):
        reason = f"PostgreSQL operation failed; SQLSTATE={error.sqlstate or 'unknown'}"
    elif isinstance(error, OSError):
        reason = f"File/connection operation failed; errno={error.errno}"
    else:
        reason = "Operation failed; original message suppressed"
    return f"stage={stage}; type={type(error).__name__}; {reason}"


def _require_one(cur: psycopg.Cursor) -> None:
    if cur.rowcount != 1:
        raise LoaderError("Expected exactly one STARTED attempt to be updated")


def _table_columns(cur: psycopg.Cursor, table: str) -> list:
    cur.execute(
        """SELECT a.attname, format_type(a.atttypid,a.atttypmod),
                  a.attnotnull, a.attidentity, pg_get_expr(d.adbin,d.adrelid)
           FROM pg_attribute a
           LEFT JOIN pg_attrdef d ON d.adrelid=a.attrelid AND d.adnum=a.attnum
           WHERE a.attrelid=to_regclass(%s) AND a.attnum>0 AND NOT a.attisdropped
           ORDER BY a.attnum""", (f"raw.{table}",),
    )
    return cur.fetchall()


def _check_table(cur: psycopg.Cursor, table: str, expected: tuple) -> None:
    cur.execute("SELECT relkind FROM pg_class WHERE oid=to_regclass(%s)", (f"raw.{table}",))
    if cur.fetchone() != ("r",):
        raise LoaderError(f"Schema contract: raw.{table} must be an ordinary table")
    cols = _table_columns(cur, table)
    if [(r[0], r[1]) for r in cols] != list(expected):
        raise LoaderError(f"Schema contract: columns/types differ in raw.{table}")
    required = (
        {"load_id", "source_file", "started_at", "status", "orders_rows_loaded", "returns_rows_loaded", "people_rows_loaded"}
        if table == "load_log" else {n for n, _ in TECHNICAL}
    )
    identity = {} if table == "load_log" else {"_raw_id": "d"}
    defaults = (
        {"orders_rows_loaded": "0", "returns_rows_loaded": "0", "people_rows_loaded": "0"}
        if table == "load_log" else {}
    )
    if (
        {r[0] for r in cols if r[2]} != required
        or {r[0]: r[3] for r in cols if r[3]} != identity
        or {r[0]: r[4] for r in cols if r[4] is not None} != defaults
    ):
        raise LoaderError(f"Schema contract: nullability/identity/defaults differ in raw.{table}")
    cur.execute(
        """SELECT k.conname,k.contype,pg_get_constraintdef(k.oid),k.confdeltype,
                  k.convalidated,k.condeferrable,
                  ARRAY(SELECT a.attname FROM unnest(k.conkey) WITH ORDINALITY u(num,ord)
                        JOIN pg_attribute a ON a.attrelid=k.conrelid AND a.attnum=u.num ORDER BY u.ord)
           FROM pg_constraint k WHERE k.conrelid=to_regclass(%s)""", (f"raw.{table}",),
    )
    constraints = cur.fetchall()
    pks = [r for r in constraints if r[1] == "p"]
    if (
        len(pks) != 1 or pks[0][6] != (["load_id"] if table == "load_log" else ["_raw_id"])
        or not all(r[4] and not r[5] for r in constraints)
    ):
        raise LoaderError(f"Schema contract: primary key/constraint state differs in raw.{table}")
    if table == "load_log":
        normalize = lambda value: re.sub(r"\s+", "", value)
        actual = {r[0]: normalize(r[2]) for r in constraints if r[1] == "c"}
        if len(constraints) != 10 or actual != {k: normalize(v) for k, v in LOG_CHECKS.items()}:
            raise LoaderError("Schema contract: load_log CHECK constraints differ")
    else:
        fks = [r for r in constraints if r[1] == "f"]
        if (
            len(constraints) != 2 or len(fks) != 1 or fks[0][6] != ["_load_id"]
            or fks[0][2] != "FOREIGN KEY (_load_id) REFERENCES raw.load_log(load_id)"
            or fks[0][3] != "a"
        ):
            raise LoaderError(f"Schema contract: foreign key differs in raw.{table}")
    cur.execute(
        """SELECT i.indisunique,i.indisprimary,i.indisvalid,pg_get_expr(i.indpred,i.indrelid),
                  ARRAY(SELECT a.attname FROM unnest(i.indkey) WITH ORDINALITY u(num,ord)
                        JOIN pg_attribute a ON a.attrelid=i.indrelid AND a.attnum=u.num ORDER BY u.ord)
           FROM pg_index i WHERE i.indrelid=to_regclass(%s)""", (f"raw.{table}",),
    )
    indexes = cur.fetchall()
    secondary = [r for r in indexes if not r[1]]
    expected_index = (
        (True, False, True, "(status = 'SUCCESS'::text)", ["source_sha256"])
        if table == "load_log" else (False, False, True, None, ["_load_id"])
    )
    if len(indexes) != 2 or secondary != [expected_index] or not all(r[2] for r in indexes):
        raise LoaderError(f"Schema contract: indexes differ in raw.{table}")


def check_database(conn: psycopg.Connection) -> list[str]:
    """Fatal for wrong DB/log; return target errors so T1 -> T4 can record them."""
    target_errors = []
    with conn.transaction(), conn.cursor() as cur:
        cur.execute("SET TRANSACTION READ ONLY")
        cur.execute("SELECT current_database(), current_setting('client_encoding')")
        if cur.fetchone() != ("sales_dwh", "UTF8"):
            raise LoaderError("Expected sales_dwh and UTF8 client encoding")
        _check_table(cur, "load_log", LOG_COLUMNS)
        for table, fields in SHEETS.values():
            try:
                _check_table(cur, table, fields + TECHNICAL)
            except LoaderError as error:
                target_errors.append(str(error))
    return target_errors


def register_started(conn: psycopg.Connection, load_id: UUID) -> None:
    """T1 commits independently, before reading the source file."""
    with conn.transaction(), conn.cursor() as cur:
        cur.execute(
            """INSERT INTO raw.load_log
               (load_id,source_file,started_at,status)
               VALUES (%s,%s,clock_timestamp(),'STARTED')""", (load_id, SOURCE_FILE),
        )


def read_source_snapshot(path: Path) -> tuple[bytes, str]:
    if not path.is_file():
        raise LoaderError("Source is missing or is not a regular file")
    payload = path.read_bytes()
    return payload, sha256(payload).hexdigest()


def check_hash(conn: psycopg.Connection, load_id: UUID, digest: str) -> tuple[bool, str | None]:
    """T2 persists the hash even if a conflicting history requires FAILED."""
    history_error = None
    skipped = False
    with conn.transaction(), conn.cursor() as cur:
        cur.execute(
            """UPDATE raw.load_log SET source_sha256=%s
               WHERE load_id=%s AND status='STARTED'""", (digest, load_id),
        )
        _require_one(cur)
        cur.execute(
            "SELECT load_id,status FROM raw.load_log WHERE source_sha256=%s AND load_id<>%s",
            (digest, load_id),
        )
        history = cur.fetchall()
        if any(status == "SUCCESS" for _, status in history):
            cur.execute(
                """UPDATE raw.load_log SET status='SKIPPED',finished_at=clock_timestamp(),
                   orders_rows_loaded=0,returns_rows_loaded=0,people_rows_loaded=0,error_text=NULL
                   WHERE load_id=%s AND status='STARTED'""", (load_id,),
            )
            _require_one(cur)
            skipped = True
        elif any(status == "SKIPPED" for _, status in history):
            history_error = "SKIPPED history has no corresponding SUCCESS"
        else:
            pending = [str(key) for key, status in history if status == "STARTED"]
            if pending:
                history_error = "Unfinished attempts for this hash: " + ", ".join(pending)
    return skipped, history_error


def convert_cell(cell, kind: str, sheet: str, coordinate: str, *, postal: bool = False):
    """Strict type adaptation; no source value is included in an error."""
    location = f"{sheet}!{coordinate}"
    value = cell.value
    cell_type = cell.data_type
    if cell_type in {"f", "e"}:
        raise LoaderError(f"{location}: formula or Excel error is not allowed")
    if cell_type not in {"n", "s", "inlineStr", "d", "b"}:
        raise LoaderError(f"{location}: unsupported Excel cell type")
    if value is None:
        if cell_type in {"s", "inlineStr"}:
            raise LoaderError(f"{location}: ambiguous empty-text representation")
        return None
    if postal:
        if isinstance(value, str):
            result = value
        elif type(value) is int and cell_type == "n":
            result = str(value)
        else:
            raise LoaderError(f"{location}: Postal Code must be original text or an integer cell")
    elif kind == "text":
        if not isinstance(value, str):
            raise LoaderError(f"{location}: expected text")
        result = value
    elif kind == "integer":
        if type(value) not in {int, float} or cell_type != "n":
            raise LoaderError(f"{location}: expected numeric integer, not text/bool")
        if type(value) is float and (not math.isfinite(value) or not value.is_integer()):
            raise LoaderError(f"{location}: fractional or non-finite integer")
        result = int(value)
        if not -(2**31) <= result < 2**31:
            raise LoaderError(f"{location}: INTEGER overflow")
    elif kind == "date":
        if isinstance(value, datetime):
            if value.tzinfo is not None or value.time() != time(0):
                raise LoaderError(f"{location}: DATE would discard time/timezone")
            result = value.date()
        elif type(value) is date:
            result = value
        else:
            raise LoaderError(f"{location}: expected an Excel date")
    elif kind == "double precision":
        if type(value) not in {int, float} or cell_type != "n":
            raise LoaderError(f"{location}: expected a numeric measure")
        try:
            result = float(value)
        except OverflowError:
            raise LoaderError(f"{location}: DOUBLE PRECISION overflow") from None
        if not math.isfinite(result):
            raise LoaderError(f"{location}: non-finite numeric measure")
    else:
        raise LoaderError(f"{location}: unknown target type")
    if isinstance(result, str) and "\x00" in result:
        raise LoaderError(f"{location}: text contains a PostgreSQL-incompatible NUL character")
    return result


def prepare_workbook(payload: bytes) -> list[PreparedSheet]:
    """Read only the hashed snapshot; retain every physical data row."""
    prepared = []
    with BytesIO(payload) as stream:
        workbook = load_workbook(stream, read_only=True, data_only=False)
        try:
            if not set(SHEETS).issubset(workbook.sheetnames):
                raise LoaderError("Workbook is missing one or more required sheets")
            for sheet_name, (table, fields) in SHEETS.items():
                sheet = workbook[sheet_name]
                if sheet.max_column != len(fields) or sheet.max_row is None or sheet.max_row < 1:
                    raise LoaderError(f"{sheet_name}: unexpected worksheet dimensions/extra columns")
                physical_rows = sheet.iter_rows(min_row=1, max_row=sheet.max_row, max_col=len(fields))
                header = next(physical_rows)
                names = tuple(
                    convert_cell(cell, "text", sheet_name, f"{get_column_letter(i)}1")
                    for i, cell in enumerate(header, 1)
                )
                if names != tuple(name for name, _ in fields):
                    raise LoaderError(f"{sheet_name}: headers/order differ from the approved contract")
                rows = []
                expected_count = 0
                for row_number, cells in enumerate(physical_rows, 2):
                    expected_count += 1  # Count source rows before adapting/sending records.
                    values = tuple(
                        convert_cell(
                            cell, kind, sheet_name, f"{get_column_letter(index)}{row_number}",
                            postal=(sheet_name == "Orders" and name == "Postal Code"),
                        )
                        for index, (cell, (name, kind)) in enumerate(zip(cells, fields), 1)
                    )
                    rows.append((row_number, values))
                if expected_count != sheet.max_row - 1 or len(rows) != expected_count:
                    raise LoaderError(f"{sheet_name}: physical row range was not fully read")
                if expected_count != REFERENCE_COUNTS[sheet_name]:
                    LOGGER.warning(
                        "%s source count differs from reference: expected_reference=%d read=%d",
                        sheet_name, REFERENCE_COUNTS[sheet_name], expected_count,
                    )
                prepared.append(PreparedSheet(sheet_name, table, fields, rows, expected_count))
        finally:
            workbook.close()
    return prepared


def raw_counts(cur: psycopg.Cursor, load_id: UUID) -> tuple[int, int, int]:
    counts = []
    for table, _ in SHEETS.values():
        cur.execute(
            sql.SQL("SELECT count(*) FROM {} WHERE _load_id=%s").format(sql.Identifier("raw", table)),
            (load_id,),
        )
        counts.append(cur.fetchone()[0])
    return tuple(counts)


def copy_sheet(cur: psycopg.Cursor, sheet: PreparedSheet, load_id: UUID, loaded_at: datetime) -> None:
    columns = [name for name, _ in sheet.columns] + [name for name, _ in TECHNICAL[1:]]
    command = sql.SQL("COPY {} ({}) FROM STDIN").format(
        sql.Identifier("raw", sheet.table), sql.SQL(", ").join(map(sql.Identifier, columns)),
    )
    # write_row handles None, Unicode, dates, floats and UUID without a CSV intermediate.
    with cur.copy(command) as copy:
        for row_number, values in sheet.rows:
            try:
                copy.write_row(values + (loaded_at, SOURCE_FILE, sheet.name, row_number, load_id))
            except Exception as error:
                raise LoaderError(safe_error(f"COPY {sheet.name} row={row_number}", error)) from None


def load_atomic(conn: psycopg.Connection, load_id: UUID, digest: str, prepared: list[PreparedSheet]) -> tuple:
    """T3: all three COPY operations, count reconciliation and SUCCESS share one commit."""
    if [sheet.name for sheet in prepared] != list(SHEETS):
        raise LoaderError("Prepared sheets are missing or out of order")
    with conn.transaction(), conn.cursor() as cur:
        cur.execute("SELECT status,source_sha256 FROM raw.load_log WHERE load_id=%s", (load_id,))
        if cur.fetchone() != ("STARTED", digest):
            raise LoaderError("Attempt is not STARTED with the expected source hash")
        if any(raw_counts(cur, load_id)):
            raise LoaderError("Unexpected committed RAW rows already belong to the new load_id")
        cur.execute("SELECT clock_timestamp()")
        loaded_at = cur.fetchone()[0]
        for sheet in prepared:
            copy_sheet(cur, sheet, load_id, loaded_at)
        actual = raw_counts(cur, load_id)
        expected = tuple(sheet.expected_count for sheet in prepared)
        if actual != expected:
            details = "; ".join(
                f"{sheet.name}: expected={want} actual={got}"
                for sheet, want, got in zip(prepared, expected, actual)
            )
            raise LoaderError("Row count mismatch; transaction will roll back: " + details)
        cur.execute(
            """UPDATE raw.load_log SET status='SUCCESS',finished_at=clock_timestamp(),
               orders_rows_loaded=%s,returns_rows_loaded=%s,people_rows_loaded=%s,error_text=NULL
               WHERE load_id=%s AND status='STARTED' AND source_sha256=%s""",
            (*actual, load_id, digest),
        )
        _require_one(cur)
    return actual


def finish_failed(
    conn: psycopg.Connection, load_id: UUID, digest: str | None, message: str,
    *, verify_raw: bool = True,
) -> None:
    """T4: call only after T3 is fully rolled back and its outcome is known."""
    if conn.info.transaction_status != TransactionStatus.IDLE:
        raise LoaderError("Cannot record FAILED while an earlier transaction is unresolved")
    with conn.transaction(), conn.cursor() as cur:
        # A preflight failure may mean a target table is missing. No COPY was
        # attempted in that case, so do not query the invalid target contract.
        if verify_raw and any(raw_counts(cur, load_id)):
            raise LoaderError("RAW rows exist for an unsuccessful attempt; manual review required")
        cur.execute(
            """UPDATE raw.load_log SET status='FAILED',finished_at=clock_timestamp(),
               source_sha256=COALESCE(source_sha256,%s),error_text=%s,
               orders_rows_loaded=0,returns_rows_loaded=0,people_rows_loaded=0
               WHERE load_id=%s AND status='STARTED'""", (digest, message, load_id),
        )
        _require_one(cur)


def resolve_interruption(settings: Settings, load_id: UUID, old_pid: int) -> LoadResult:
    """Read-only reconciliation; never retry COPY or change an uncertain attempt."""
    with connect(settings) as conn, conn.transaction(), conn.cursor() as cur:
        cur.execute("SET TRANSACTION READ ONLY")
        cur.execute("SELECT current_database()")
        if cur.fetchone() != ("sales_dwh",):
            raise LoaderError("Wrong database while resolving connection interruption")
        cur.execute(
            """SELECT status,orders_rows_loaded,returns_rows_loaded,people_rows_loaded
               FROM raw.load_log WHERE load_id=%s""", (load_id,),
        )
        row = cur.fetchone()
        if row and row[0] in {"SUCCESS", "SKIPPED", "FAILED"}:
            counts = raw_counts(cur, load_id)
            if counts == tuple(row[1:]) and (row[0] == "SUCCESS" or not any(counts)):
                return LoadResult(load_id, row[0], counts, "Terminal state confirmed after interruption")
            raise LoaderError("Journal/RAW mismatch after interruption; manual review required")
        cur.execute("SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE pid=%s)", (old_pid,))
        backend_exists = cur.fetchone()[0]
        counts = raw_counts(cur, load_id)
        if row and row[0] == "STARTED" and not backend_exists and not any(counts):
            return LoadResult(load_id, "STARTED", message="Original backend ended; no RAW rows committed")
        return LoadResult(load_id, "UNKNOWN", message="Outcome unresolved; do not retry automatically")


def _is_connection_interruption(conn: psycopg.Connection, error: Exception) -> bool:
    return conn.closed or conn.broken or (
        isinstance(error, psycopg.Error)
        and (error.sqlstate is None or error.sqlstate.startswith("08"))
    )


def run_load(settings: Settings, load_id: UUID) -> LoadResult:
    """The only orchestration function that can write to PostgreSQL."""
    conn = None
    registered = False
    registration_attempted = False
    raw_attempted = False
    digest = None
    stage = "connect/preflight"
    old_pid = 0
    try:
        conn = connect(settings)
        old_pid = conn.info.backend_pid
        target_errors = check_database(conn)
        stage = "T1 STARTED"
        registration_attempted = True
        register_started(conn, load_id)
        registered = True
        if target_errors:
            raise LoaderError("; ".join(target_errors))
        stage = "source snapshot"
        payload, digest = read_source_snapshot(settings.source_path)
        stage = "T2 hash/idempotency"
        skipped, history_error = check_hash(conn, load_id, digest)
        if skipped:
            return LoadResult(load_id, "SKIPPED")
        if history_error:
            raise LoaderError(history_error)
        stage = "Excel preparation"
        prepared = prepare_workbook(payload)
        stage = "T3 COPY/counts/SUCCESS"
        raw_attempted = True
        counts = load_atomic(conn, load_id, digest, prepared)
        return LoadResult(load_id, "SUCCESS", counts)
    except Exception as error:
        message = safe_error(stage, error)
        if conn is not None and registration_attempted and _is_connection_interruption(conn, error):
            conn.close()  # No further writes until old backend termination is confirmed.
            try:
                resolved = resolve_interruption(settings, load_id, old_pid)
                if resolved.status in {"SUCCESS", "SKIPPED", "FAILED"}:
                    return resolved
                if resolved.status == "STARTED":
                    with connect(settings) as recovery:
                        finish_failed(recovery, load_id, digest, message)
                    return LoadResult(load_id, "FAILED", message=message)
                return resolved
            except Exception as recovery_error:
                return LoadResult(load_id, "UNKNOWN", message=safe_error("reconciliation", recovery_error))
        if conn is not None and registered:
            try:
                finish_failed(conn, load_id, digest, message, verify_raw=raw_attempted)
                return LoadResult(load_id, "FAILED", message=message)
            except Exception as log_error:
                return LoadResult(load_id, "UNKNOWN", message=message + "; " + safe_error("T4 FAILED", log_error))
        # No journal entry is promised if connection/preflight/T1 failed.
        return LoadResult(load_id, "UNKNOWN", message=message + "; STARTED not confirmed")
    finally:
        if conn is not None:
            conn.close()


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    load_id = uuid4()
    try:
        settings = load_settings()
    except Exception as error:
        LOGGER.error("load_id=%s %s", load_id, safe_error("configuration", error))
        return 1
    result = run_load(settings, load_id)
    LOGGER.info(
        "load_id=%s status=%s orders=%d returns=%d people=%d %s",
        result.load_id, result.status, *result.counts, result.message,
    )
    return 0 if result.status in {"SUCCESS", "SKIPPED"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
