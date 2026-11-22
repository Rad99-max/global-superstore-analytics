"""Explicit, file-based connection settings without ambient env overrides."""

from dataclasses import dataclass, field
from pathlib import Path

from dotenv import dotenv_values

PROJECT_ROOT = Path(__file__).resolve().parents[1]
SOURCE_FILE = "data/source/global_superstore_2016.xlsx"


class ConfigError(ValueError):
    """A configuration error whose message never includes setting values."""


@dataclass(frozen=True, repr=False)
class Settings:
    root: Path
    host: str
    port: int
    database: str
    user: str
    password: str = field(repr=False)

    @property
    def source_path(self) -> Path:
        return self.root / SOURCE_FILE

    def connection_kwargs(self) -> dict:
        return {
            "host": self.host,
            "port": self.port,
            "dbname": self.database,
            "user": self.user,
            "password": self.password,
            "connect_timeout": 10,
            "application_name": "global_superstore_raw_loader",
            "client_encoding": "UTF8",
        }


def _read_env(path: Path) -> dict:
    if not path.is_file():
        raise ConfigError(f"Required configuration file missing: {path.name}")
    try:
        # No ${...} expansion against os.environ, and no load_dotenv side effects.
        return dict(dotenv_values(path, encoding="utf-8-sig", interpolate=False))
    except (OSError, UnicodeError):
        raise ConfigError(f"Cannot read configuration file: {path.name}") from None


def load_settings(root: Path = PROJECT_ROOT) -> Settings:
    values = _read_env(root / ".env")
    switch = _read_env(root / ".env.local").get("USE_PROD_ENV")
    if switch not in {"0", "1"}:
        raise ConfigError("USE_PROD_ENV must be explicitly 0 or 1")
    overlay = ".env.prod" if switch == "1" else ".env.dev"
    values.update({k: v for k, v in _read_env(root / overlay).items() if v is not None})
    required = (
        "POSTGRES_HOST", "POSTGRES_PORT", "POSTGRES_DB",
        "POSTGRES_USER", "POSTGRES_PASSWORD",
    )
    for name in required:
        if not isinstance(values.get(name), str) or not values[name]:
            raise ConfigError(f"Required setting missing: {name}")
    if values["POSTGRES_DB"] != "sales_dwh":
        raise ConfigError("POSTGRES_DB must be sales_dwh")
    try:
        port = int(values["POSTGRES_PORT"])
    except ValueError:
        raise ConfigError("POSTGRES_PORT must be an integer") from None
    if not 1 <= port <= 65535:
        raise ConfigError("POSTGRES_PORT is outside the valid range")
    return Settings(
        root=root.resolve(), host=values["POSTGRES_HOST"], port=port,
        database=values["POSTGRES_DB"], user=values["POSTGRES_USER"],
        password=values["POSTGRES_PASSWORD"],
    )
