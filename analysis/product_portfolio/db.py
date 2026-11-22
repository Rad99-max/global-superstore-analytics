"""Read-only DB helper for the Product Portfolio analysis.

Connection settings come from pipeline/config.py (.env files); secrets are never printed.
Every query runs in a READ ONLY transaction.
"""
import sys
import tempfile
from pathlib import Path

import pandas as pd
import psycopg

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from pipeline.config import load_settings  # noqa: E402

# Line-level extract written by q2.py and read by q3-q6, q8; kept outside the repository.
LINES = Path(tempfile.gettempdir()) / "gs_product_portfolio_lines.pkl"

pd.set_option("display.width", 250)
pd.set_option("display.max_columns", 30)
pd.set_option("display.max_rows", 200)


def q(sql):
    kw = load_settings().connection_kwargs()
    kw["application_name"] = "product_portfolio_readonly_analysis"
    with psycopg.connect(**kw) as c:
        c.read_only = True
        with c.cursor() as cur:
            cur.execute(sql)
            cols = [d.name for d in cur.description]
            return pd.DataFrame(cur.fetchall(), columns=cols)
