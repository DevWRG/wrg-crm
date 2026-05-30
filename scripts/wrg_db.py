"""WRG CRM — DB helpers (PostgreSQL via psql subprocess).

Shellout pattern: no psycopg2 dependency. All queries flow through psql CLI
with -tA flag (tuples-only, unaligned).

Module config:
- WRG_CRM_PROJECT_DIR env var → PROJECT_DIR for env file resolution
- WRG_DB_OVERRIDE env var → pin specific database (e.g., dev dashboard)
- ENV_FILE (data/state/environment) or ENV_FILE_MIRROR (TCC-friendly fallback)
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
from pathlib import Path

# Project dir resolves in this order:
#   1. $WRG_CRM_PROJECT_DIR (used when running from a relocated path, e.g. launchd)
#   2. ../ relative to script (default — script lives in wrg-crm/scripts/)
_env_dir = os.environ.get("WRG_CRM_PROJECT_DIR", "").strip()
if _env_dir:
    PROJECT_DIR = Path(_env_dir).resolve()
else:
    PROJECT_DIR = Path(__file__).resolve().parent.parent
ENV_FILE = PROJECT_DIR / "data" / "state" / "environment"

# Secondary mirror of env state — written by env-switch.sh to a location the
# launchd-spawned dashboard process can actually read. macOS Sequoia TCC blocks
# launchd-spawned Python.app from reading Documents/, so the dashboard reads
# from this mirror first; falls back to the canonical ENV_FILE if mirror absent.
ENV_FILE_MIRROR = Path(__file__).resolve().parent / "environment"

PG_USER = "wrg_admin"
PSQL_BIN = shutil.which("psql") or "/opt/homebrew/opt/postgresql@16/bin/psql"
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")

# Optional hard override for the underlying DB, bypassing env-state files
# entirely. Set this on a dedicated dashboard instance to pin it to a specific
# database (e.g. WRG_DB_OVERRIDE=wrg_crm_dev for the :8092 dev dashboard).
_DB_OVERRIDE = os.environ.get("WRG_DB_OVERRIDE", "").strip()


def current_env() -> str:
    """Read env state from mirror first (TCC-friendly), then canonical file."""
    for p in (ENV_FILE_MIRROR, ENV_FILE):
        try:
            v = p.read_text().strip().lower()
            if v in ("dev", "prod"):
                return v
        except OSError:
            continue
    return "dev"


def db_name(env: str | None = None) -> str:
    if _DB_OVERRIDE:
        return _DB_OVERRIDE
    env = env or current_env()
    return "wrg_crm_prod" if env == "prod" else "wrg_crm_dev"


def psql_json(sql: str, env: str | None = None):
    """Run a SELECT that must yield ONE row, ONE column of JSON. Return parsed."""
    db = db_name(env)
    proc = subprocess.run(
        [PSQL_BIN, "-U", PG_USER, "-d", db, "-tA", "-c", sql],
        capture_output=True, text=True, timeout=30,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"psql failed (db={db}): {proc.stderr.strip()[:500]}")
    out = proc.stdout.strip()
    if not out:
        return None
    try:
        return json.loads(out)
    except json.JSONDecodeError as e:
        raise RuntimeError(f"psql output not JSON: {out[:200]!r} ({e})")


def psql_exec(sql: str, env: str | None = None):
    """Run INSERT/UPDATE/DELETE. With RETURNING (SELECT row_to_json(t)...) clause,
    returns the parsed JSON row. Strips trailing 'INSERT/UPDATE/DELETE N' status."""
    db = db_name(env)
    proc = subprocess.run(
        [PSQL_BIN, "-U", PG_USER, "-d", db, "-tA", "-c", sql],
        capture_output=True, text=True, timeout=30,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"psql exec failed (db={db}): {proc.stderr.strip()[:500]}")
    out = proc.stdout.strip()
    if not out:
        return None
    # First line is usually the RETURNING result; subsequent lines are status.
    first_line = out.split("\n", 1)[0]
    try:
        return json.loads(first_line)
    except json.JSONDecodeError:
        return first_line  # Plain text fallback


def psql_quote(s) -> str:
    """SQL-escape a string by doubling single quotes. Numeric passed-through."""
    if s is None:
        return "NULL"
    if isinstance(s, (int, float)):
        return str(s)
    return "'" + str(s).replace("'", "''") + "'"


def valid_date(s: str) -> bool:
    return bool(s and DATE_RE.match(s))
