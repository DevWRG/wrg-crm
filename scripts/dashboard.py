#!/usr/bin/env python3
"""WRG CRM Dashboard — plan & report tracker per orang/divisi/cabang/HOD.

Buka http://127.0.0.1:8091 di browser. Default port bisa di-override via --port.

Sumber data: PostgreSQL (wrg_crm_dev / wrg_crm_prod sesuai data/state/environment).
Tanpa dependency Python eksternal — shellout ke psql untuk eksekusi query.
"""
from __future__ import annotations

import argparse
import datetime
import http.server
import json
import os
import re
import shutil
import socketserver
import subprocess
from pathlib import Path
from urllib.parse import parse_qs, urlparse

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


# ── DB helpers ──────────────────────────────────────────────────────────

def current_env() -> str:
    # Try mirror first (TCC-friendly path), then canonical.
    for p in (ENV_FILE_MIRROR, ENV_FILE):
        try:
            v = p.read_text().strip().lower()
            if v in ("dev", "prod"):
                return v
        except OSError:
            continue
    return "dev"


# Optional hard override for the underlying DB, bypassing env-state files
# entirely. Set this on a dedicated dashboard instance to pin it to a specific
# database (e.g. WRG_DB_OVERRIDE=wrg_crm_dev for the :8092 dev dashboard) so it
# stays on its own DB regardless of env-switch.sh activity affecting prod.
_DB_OVERRIDE = os.environ.get("WRG_DB_OVERRIDE", "").strip()


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


def valid_date(s: str) -> bool:
    return bool(s and DATE_RE.match(s))


def default_range() -> tuple[str, str]:
    """Senin–Jumat minggu berjalan (atau hari ini kalau hari Senin)."""
    today = datetime.date.today()
    monday = today - datetime.timedelta(days=today.weekday())
    friday = monday + datetime.timedelta(days=4)
    end = min(friday, today)
    return monday.isoformat(), end.isoformat()


# ── SQL queries ─────────────────────────────────────────────────────────
#
# Semua query mengembalikan json_agg() — satu JSON blob untuk parsing simpel.
# Date range di-validasi regex di handler sebelum di-substitute ke SQL.

SQL_SUMMARY = """
WITH params AS (SELECT DATE '{d1}' AS d1, DATE '{d2}' AS d2),
working_days AS (
  SELECT COUNT(*) AS n
  FROM generate_series((SELECT d1 FROM params), (SELECT d2 FROM params), '1 day') g
  WHERE is_working_day(g::date)
),
plan_stats AS (
  SELECT
    COUNT(*) AS total_plan_visits,
    COUNT(*) FILTER (WHERE reported)     AS plan_reported,
    COUNT(*) FILTER (WHERE is_late_plan) AS plan_late,
    COUNT(DISTINCT user_id)              AS users_with_plan
  FROM sales_plan sp, params p
  WHERE sp.tanggal BETWEEN p.d1 AND p.d2
),
todo_stats AS (
  SELECT
    COUNT(*)                              AS total_todos,
    COALESCE(SUM(total_items), 0)         AS total_todo_items,
    COUNT(*) FILTER (WHERE reported)      AS todo_reported,
    COUNT(*) FILTER (WHERE is_late_plan)  AS todo_late,
    COUNT(DISTINCT user_id)               AS users_with_todo
  FROM sales_todo st, params p
  WHERE st.tanggal BETWEEN p.d1 AND p.d2
),
activity_stats AS (
  SELECT
    COUNT(*)                                AS total_activity,
    COUNT(*) FILTER (WHERE is_unmatched)    AS unmatched_activity,
    COUNT(*) FILTER (WHERE NOT is_unmatched) AS matched_activity,
    -- users_with_report: union activity_log (AM mode) + sales_todo.reported (TODO mode)
    (SELECT COUNT(DISTINCT user_id) FROM (
       SELECT user_id FROM activity_log, params p2
       WHERE tanggal BETWEEN p2.d1 AND p2.d2
       UNION
       SELECT user_id FROM sales_todo, params p3
       WHERE tanggal BETWEEN p3.d1 AND p3.d2 AND reported
    ) u)                                    AS users_with_report
  FROM activity_log al, params p
  WHERE al.tanggal BETWEEN p.d1 AND p.d2
),
user_counts AS (
  SELECT
    COUNT(*) FILTER (WHERE aktif AND wajib_plan_report) AS users_wajib,
    COUNT(*) FILTER (WHERE aktif)                       AS users_aktif
  FROM master_user
)
SELECT row_to_json(t) FROM (
  SELECT
    (SELECT n FROM working_days)               AS working_days,
    (SELECT total_plan_visits FROM plan_stats) AS total_plan_visits,
    (SELECT plan_reported FROM plan_stats)     AS plan_reported,
    (SELECT plan_late FROM plan_stats)         AS plan_late,
    (SELECT users_with_plan FROM plan_stats)   AS users_with_plan,
    (SELECT total_todos FROM todo_stats)       AS total_todos,
    (SELECT total_todo_items FROM todo_stats)  AS total_todo_items,
    (SELECT todo_reported FROM todo_stats)     AS todo_reported,
    (SELECT todo_late FROM todo_stats)         AS todo_late,
    (SELECT users_with_todo FROM todo_stats)   AS users_with_todo,
    (SELECT total_activity FROM activity_stats)    AS total_activity,
    (SELECT unmatched_activity FROM activity_stats) AS unmatched_activity,
    (SELECT matched_activity FROM activity_stats)  AS matched_activity,
    (SELECT users_with_report FROM activity_stats) AS users_with_report,
    (SELECT users_wajib FROM user_counts)      AS users_wajib,
    (SELECT users_aktif FROM user_counts)      AS users_aktif
) t;
"""


# Per-orang base CTE used in several queries (per-orang, per-divisi, per-cabang).
_PER_ORANG_CTE = """
WITH params AS (SELECT DATE '{d1}' AS d1, DATE '{d2}' AS d2),
per_orang AS (
  SELECT
    mu.id          AS user_id,
    mu.nama,
    mu.panggilan,
    mu.role,
    mu.posisi,
    mu.cabang,
    mu.wa_number,
    mu.last_active_group,
    mu.last_active_at,
    COALESCE(sp.total_plan_visits, 0)      AS total_plan_visits,
    COALESCE(sp.plan_reported, 0)          AS plan_reported,
    COALESCE(sp.plan_late, 0)              AS plan_late,
    COALESCE(st.total_todos, 0)            AS total_todos,
    COALESCE(st.total_todo_items, 0)       AS total_todo_items,
    COALESCE(st.todo_reported, 0)          AS todo_reported,
    COALESCE(st.todo_late, 0)              AS todo_late,
    COALESCE(st.todo_items_matched, 0)     AS todo_items_matched,
    COALESCE(st.todo_items_unmatched, 0)   AS todo_items_unmatched,
    COALESCE(act.total_activity, 0)        AS total_activity,
    COALESCE(act.matched_activity, 0)      AS matched_activity,
    COALESCE(act.unmatched_activity, 0)    AS unmatched_activity,
    COALESCE(d.active_days, 0)             AS active_days,
    is_on_leave(mu.id, CURRENT_DATE)       AS on_leave_today,
    (SELECT jenis FROM v_leave_today WHERE user_id = mu.id LIMIT 1) AS leave_jenis_today
  FROM master_user mu
  LEFT JOIN LATERAL (
    SELECT
      COUNT(*)                              AS total_plan_visits,
      COUNT(*) FILTER (WHERE reported)      AS plan_reported,
      COUNT(*) FILTER (WHERE is_late_plan)  AS plan_late
    FROM sales_plan, params
    WHERE user_id = mu.id AND tanggal BETWEEN params.d1 AND params.d2
  ) sp ON TRUE
  LEFT JOIN LATERAL (
    SELECT
      COUNT(*)                              AS total_todos,
      COALESCE(SUM(total_items), 0)         AS total_todo_items,
      COUNT(*) FILTER (WHERE reported)      AS todo_reported,
      COUNT(*) FILTER (WHERE is_late_plan)  AS todo_late,
      -- Aggregate from report_data jsonb: status 'matched' = report item linked to plan,
      -- 'ambiguous' + 'unmatched' = item user reported that didn't link to plan.
      COALESCE(SUM(
        (SELECT COUNT(*) FROM jsonb_array_elements(COALESCE(report_data, '[]'::jsonb)) AS r
         WHERE r->>'status' = 'matched')
      ), 0)                                  AS todo_items_matched,
      COALESCE(SUM(
        (SELECT COUNT(*) FROM jsonb_array_elements(COALESCE(report_data, '[]'::jsonb)) AS r
         WHERE r->>'status' IN ('ambiguous','unmatched'))
      ), 0)                                  AS todo_items_unmatched
    FROM sales_todo, params
    WHERE user_id = mu.id AND tanggal BETWEEN params.d1 AND params.d2
  ) st ON TRUE
  LEFT JOIN LATERAL (
    SELECT
      COUNT(*)                                  AS total_activity,
      COUNT(*) FILTER (WHERE is_unmatched)      AS unmatched_activity,
      COUNT(*) FILTER (WHERE NOT is_unmatched)  AS matched_activity
    FROM activity_log, params
    WHERE user_id = mu.id AND tanggal BETWEEN params.d1 AND params.d2
  ) act ON TRUE
  LEFT JOIN LATERAL (
    SELECT COUNT(DISTINCT tanggal) AS active_days
    FROM (
      SELECT tanggal FROM sales_plan, params
        WHERE user_id = mu.id AND tanggal BETWEEN params.d1 AND params.d2
      UNION
      SELECT tanggal FROM sales_todo, params
        WHERE user_id = mu.id AND tanggal BETWEEN params.d1 AND params.d2
      UNION
      SELECT tanggal FROM activity_log, params
        WHERE user_id = mu.id AND tanggal BETWEEN params.d1 AND params.d2
    ) days
  ) d ON TRUE
  WHERE mu.aktif AND mu.wajib_plan_report
)
"""


SQL_PER_ORANG = _PER_ORANG_CTE + """
SELECT COALESCE(json_agg(row_to_json(per_orang) ORDER BY role, panggilan), '[]'::json)
FROM per_orang;
"""


SQL_PER_DIVISI = _PER_ORANG_CTE + """
SELECT COALESCE(json_agg(row_to_json(t) ORDER BY t.role), '[]'::json) FROM (
  SELECT
    role,
    COUNT(*)                                              AS jumlah_orang,
    SUM(total_plan_visits + total_todo_items)             AS total_plan,
    SUM(plan_reported)                                    AS plan_reported,
    SUM(todo_reported)                                    AS todo_reported,
    SUM(todo_items_matched)                               AS todo_items_matched,
    SUM(todo_items_unmatched)                             AS todo_items_unmatched,
    SUM(total_activity)                                   AS total_activity,
    SUM(matched_activity)                                 AS matched_activity,
    SUM(unmatched_activity)                               AS unmatched_activity,
    SUM(plan_late + todo_late)                            AS total_late,
    COUNT(*) FILTER (WHERE total_plan_visits + total_todos > 0) AS orang_dgn_plan,
    COUNT(*) FILTER (WHERE total_activity > 0 OR todo_reported > 0) AS orang_dgn_report
  FROM per_orang
  GROUP BY role
) t;
"""


SQL_PER_CABANG = _PER_ORANG_CTE + """
SELECT COALESCE(json_agg(row_to_json(t) ORDER BY t.cabang), '[]'::json) FROM (
  SELECT
    cabang,
    COUNT(*)                                              AS jumlah_orang,
    SUM(total_plan_visits + total_todo_items)             AS total_plan,
    SUM(plan_reported)                                    AS plan_reported,
    SUM(todo_reported)                                    AS todo_reported,
    SUM(todo_items_matched)                               AS todo_items_matched,
    SUM(todo_items_unmatched)                             AS todo_items_unmatched,
    SUM(total_activity)                                   AS total_activity,
    SUM(matched_activity)                                 AS matched_activity,
    SUM(unmatched_activity)                               AS unmatched_activity,
    SUM(plan_late + todo_late)                            AS total_late,
    COUNT(*) FILTER (WHERE total_plan_visits + total_todos > 0) AS orang_dgn_plan,
    COUNT(*) FILTER (WHERE total_activity > 0 OR todo_reported > 0) AS orang_dgn_report,
    STRING_AGG(DISTINCT role, ', ' ORDER BY role)         AS roles
  FROM per_orang
  GROUP BY cabang
) t;
"""


SQL_PER_HOD = """
WITH params AS (SELECT DATE '{d1}' AS d1, DATE '{d2}' AS d2),
am_user AS (
  SELECT
    mu.id, mu.nama, mu.panggilan, mu.cabang,
    UPPER(mu.panggilan) AS panggilan_uc
  FROM master_user mu
  WHERE mu.role = 'AM' AND mu.aktif AND mu.wajib_plan_report
),
am_hod AS (
  SELECT DISTINCT au.id, au.nama, au.panggilan, au.cabang,
                  t.hod_panggilan
  FROM am_user au
  LEFT JOIN master_territory t ON t.am_panggilan = au.panggilan_uc
),
hod_user AS (
  SELECT id, nama, panggilan, cabang,
         COALESCE(hod_panggilan, '— (tanpa territory)') AS hod_panggilan
  FROM am_hod
),
am_stats AS (
  SELECT
    hu.hod_panggilan,
    COUNT(DISTINCT hu.id)                            AS jumlah_am,
    COALESCE(SUM(sp.total_plan), 0)                  AS total_plan_visits,
    COALESCE(SUM(sp.reported), 0)                    AS plan_reported,
    COALESCE(SUM(sp.late), 0)                        AS plan_late,
    COALESCE(SUM(act.total_activity), 0)             AS total_activity,
    COALESCE(SUM(act.matched), 0)                    AS matched_activity,
    COALESCE(SUM(act.unmatched), 0)                  AS unmatched_activity,
    COUNT(DISTINCT hu.id) FILTER (
      WHERE COALESCE(sp.total_plan, 0) > 0
    )                                                AS am_dgn_plan,
    COUNT(DISTINCT hu.id) FILTER (
      WHERE COALESCE(act.total_activity, 0) > 0
    )                                                AS am_dgn_report
  FROM hod_user hu
  LEFT JOIN LATERAL (
    SELECT
      COUNT(*) AS total_plan,
      COUNT(*) FILTER (WHERE reported)     AS reported,
      COUNT(*) FILTER (WHERE is_late_plan) AS late
    FROM sales_plan, params
    WHERE user_id = hu.id AND tanggal BETWEEN params.d1 AND params.d2
  ) sp ON TRUE
  LEFT JOIN LATERAL (
    SELECT
      COUNT(*) AS total_activity,
      COUNT(*) FILTER (WHERE NOT is_unmatched) AS matched,
      COUNT(*) FILTER (WHERE is_unmatched)     AS unmatched
    FROM activity_log, params
    WHERE user_id = hu.id AND tanggal BETWEEN params.d1 AND params.d2
  ) act ON TRUE
  GROUP BY hu.hod_panggilan
),
hod_label AS (
  -- Tambahkan nama lengkap HOD
  SELECT
    s.*,
    mu.nama AS hod_nama
  FROM am_stats s
  LEFT JOIN master_user mu
    ON UPPER(mu.panggilan) = s.hod_panggilan
   AND mu.role = 'HOD'
)
SELECT COALESCE(json_agg(row_to_json(hod_label) ORDER BY hod_panggilan), '[]'::json)
FROM hod_label;
"""


SQL_DAILY_TREND = """
WITH params AS (SELECT DATE '{d1}' AS d1, DATE '{d2}' AS d2),
days AS (
  SELECT generate_series(params.d1, params.d2, '1 day')::date AS d FROM params
)
SELECT COALESCE(json_agg(row_to_json(t) ORDER BY t.date), '[]'::json) FROM (
  SELECT
    d::text                                                                  AS date,
    EXTRACT(ISODOW FROM d)::int                                              AS isodow,
    is_working_day(d)                                                        AS is_working,
    (SELECT keterangan FROM master_holiday WHERE tanggal = d)                AS holiday,
    (SELECT COUNT(*)::int FROM sales_plan WHERE tanggal = d)                 AS plan_visits,
    (SELECT COUNT(*)::int FROM sales_plan WHERE tanggal = d AND is_late_plan) AS plan_late,
    (SELECT COUNT(*)::int FROM sales_plan WHERE tanggal = d AND reported)    AS plan_reported,
    (SELECT COUNT(*)::int FROM sales_todo WHERE tanggal = d)                 AS todo_count,
    (SELECT COALESCE(SUM(total_items),0)::int FROM sales_todo WHERE tanggal = d) AS todo_items,
    (SELECT COUNT(*)::int FROM sales_todo WHERE tanggal = d AND is_late_plan) AS todo_late,
    (SELECT COUNT(*)::int FROM sales_todo WHERE tanggal = d AND reported)    AS todo_reported,
    (SELECT COUNT(*)::int FROM activity_log WHERE tanggal = d)               AS total_activity,
    (SELECT COUNT(*)::int FROM activity_log WHERE tanggal = d AND is_unmatched) AS unmatched,
    (SELECT COUNT(DISTINCT user_id)::int FROM (
      SELECT user_id FROM sales_plan WHERE tanggal = d
      UNION SELECT user_id FROM sales_todo WHERE tanggal = d
    ) u)                                                                     AS users_submitted,
    (SELECT COUNT(DISTINCT user_id)::int FROM activity_log WHERE tanggal = d) AS users_reported
  FROM days
) t;
"""


SQL_DRILLDOWN_USER = """
WITH params AS (
  SELECT INT '{user_id}' AS uid, DATE '{d1}' AS d1, DATE '{d2}' AS d2
),
user_info AS (
  SELECT json_build_object(
    'id', mu.id,
    'nama', mu.nama,
    'panggilan', mu.panggilan,
    'role', mu.role,
    'posisi', mu.posisi,
    'cabang', mu.cabang,
    'wa_number', mu.wa_number,
    'last_active_group', mu.last_active_group,
    'last_active_at', mu.last_active_at
  ) AS info
  FROM master_user mu, params
  WHERE mu.id = params.uid
),
plan_rows AS (
  SELECT json_agg(row_to_json(t) ORDER BY t.tanggal DESC, t.seq) AS rows FROM (
    SELECT
      sp.id, sp.tanggal, sp.seq,
      sp.customer_name, sp.tujuan, sp.goal,
      sp.reported, sp.reported_at,
      sp.is_late_plan, sp.submitted_at,
      sp.activity_id,
      al.hasil, al.next_action, al.match_score
    FROM sales_plan sp
    CROSS JOIN params
    LEFT JOIN activity_log al ON al.id = sp.activity_id
    WHERE sp.user_id = params.uid
      AND sp.tanggal BETWEEN params.d1 AND params.d2
  ) t
),
todo_rows AS (
  SELECT json_agg(row_to_json(t) ORDER BY t.tanggal DESC, t.id) AS rows FROM (
    SELECT
      st.id, st.tanggal, st.items, st.total_items,
      st.reported, st.reported_at,
      st.is_late_plan, st.submitted_at,
      st.report_data
    FROM sales_todo st, params
    WHERE st.user_id = params.uid
      AND st.tanggal BETWEEN params.d1 AND params.d2
  ) t
),
unmatched_rows AS (
  SELECT json_agg(row_to_json(t) ORDER BY t.tanggal DESC, t.id) AS rows FROM (
    SELECT
      al.id, al.tanggal, al.customer_name,
      al.hasil, al.next_action, al.match_score, al.is_unmatched,
      al.created_at
    FROM activity_log al, params
    WHERE al.user_id = params.uid
      AND al.tanggal BETWEEN params.d1 AND params.d2
      AND al.plan_id IS NULL
  ) t
)
SELECT row_to_json(d) FROM (
  SELECT
    (SELECT info FROM user_info)               AS user,
    COALESCE((SELECT rows FROM plan_rows), '[]'::json)      AS plan,
    COALESCE((SELECT rows FROM todo_rows), '[]'::json)      AS todo,
    COALESCE((SELECT rows FROM unmatched_rows), '[]'::json) AS unmatched_activity
) d;
"""


# ── HTTP handler ────────────────────────────────────────────────────────


def parse_range(qs: dict) -> tuple[str, str] | None:
    d1 = (qs.get("from") or [""])[0]
    d2 = (qs.get("to") or [""])[0]
    if not d1 or not d2:
        d1, d2 = default_range()
    if not (valid_date(d1) and valid_date(d2)):
        return None
    if d1 > d2:
        d1, d2 = d2, d1
    return d1, d2


def parse_env(qs: dict) -> str:
    """Allow per-request env override via ?env=dev|prod. Default = current global env."""
    v = (qs.get("env") or [""])[0].strip().lower()
    if v in ("dev", "prod"):
        return v
    return current_env()


def json_response(handler, payload, status=200):
    body = json.dumps(payload).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json; charset=utf-8")
    handler.send_header("Content-Length", str(len(body)))
    handler.send_header("Cache-Control", "no-store")
    handler.end_headers()
    handler.wfile.write(body)


def text_response(handler, body, ctype="text/plain; charset=utf-8", status=200):
    if isinstance(body, str):
        body = body.encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", ctype)
    handler.send_header("Content-Length", str(len(body)))
    handler.send_header("Cache-Control", "no-store")
    handler.end_headers()
    handler.wfile.write(body)


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        parsed = urlparse(self.path)
        qs = parse_qs(parsed.query)
        path = parsed.path

        try:
            if path == "/" or path == "/index.html":
                return text_response(self, INDEX_HTML, "text/html; charset=utf-8")

            if path == "/api/env":
                default = current_env()
                viewing = parse_env(qs)
                d1, d2 = default_range()
                return json_response(self, {
                    "env": viewing, "db": db_name(viewing),
                    "default_env": default,
                    "is_preview": viewing != default,
                    "default_from": d1, "default_to": d2,
                    "today": datetime.date.today().isoformat(),
                })

            rng = parse_range(qs)
            if rng is None:
                return json_response(self, {"error": "invalid date"}, 400)
            d1, d2 = rng
            env = parse_env(qs)

            if path == "/api/summary":
                data = psql_json(SQL_SUMMARY.format(d1=d1, d2=d2), env=env)
                return json_response(self, {"from": d1, "to": d2, "env": env, "summary": data or {}})

            if path == "/api/per-orang":
                data = psql_json(SQL_PER_ORANG.format(d1=d1, d2=d2), env=env)
                return json_response(self, {"from": d1, "to": d2, "env": env, "rows": data or []})

            if path == "/api/per-divisi":
                data = psql_json(SQL_PER_DIVISI.format(d1=d1, d2=d2), env=env)
                return json_response(self, {"from": d1, "to": d2, "env": env, "rows": data or []})

            if path == "/api/per-cabang":
                data = psql_json(SQL_PER_CABANG.format(d1=d1, d2=d2), env=env)
                return json_response(self, {"from": d1, "to": d2, "env": env, "rows": data or []})

            if path == "/api/per-hod":
                data = psql_json(SQL_PER_HOD.format(d1=d1, d2=d2), env=env)
                return json_response(self, {"from": d1, "to": d2, "env": env, "rows": data or []})

            if path == "/api/daily-trend":
                data = psql_json(SQL_DAILY_TREND.format(d1=d1, d2=d2), env=env)
                return json_response(self, {"from": d1, "to": d2, "env": env, "days": data or []})

            if path == "/api/drilldown":
                uid = (qs.get("user_id") or [""])[0]
                if not uid.isdigit():
                    return json_response(self, {"error": "user_id required"}, 400)
                data = psql_json(SQL_DRILLDOWN_USER.format(user_id=int(uid), d1=d1, d2=d2), env=env)
                return json_response(self, {"from": d1, "to": d2, "env": env, "detail": data or {}})

            return text_response(self, "not found", status=404)

        except RuntimeError as e:
            return json_response(self, {"error": str(e)}, 500)
        except Exception as e:
            return json_response(self, {"error": f"{type(e).__name__}: {e}"}, 500)

    def log_message(self, format, *args):
        pass


class ReusableTCPServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


# ── HTML ────────────────────────────────────────────────────────────────

INDEX_HTML = r"""<!doctype html>
<html lang="id">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="theme-color" content="#e2e8ef">
<title>WRG CRM — Plan & Report Dashboard</title>
<style>
* { box-sizing: border-box; }
body {
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
  margin: 0; background: #e2e8ef; color: #1f2933; line-height: 1.5;
}
header {
  background: #d4dbe5; padding: 12px 20px; display: flex; align-items: center;
  gap: 14px; border-bottom: 1px solid #b5c0cd;
  position: sticky; top: 0; z-index: 100; flex-wrap: wrap;
}
header h1 { font-size: 17px; margin: 0; color: #5a7a1a; }
header .meta { font-size: 11px; color: #4a5568; }
.env-badge {
  font-size: 10px; font-weight: 700; padding: 2px 8px; border-radius: 10px;
  text-transform: uppercase; letter-spacing: 0.5px;
}
.env-badge.dev  { background: #fde68a; color: #78350f; }
.env-badge.prod { background: #bbf7d0; color: #14532d; }
.env-badge.preview {
  margin-left: -8px; background: #fee2e2; color: #991b1b;
  border: 1px solid #fca5a5;
}

nav.tabs {
  display: flex; gap: 4px; background: #ffffff; padding: 4px;
  border-radius: 6px; border: 1px solid #b5c0cd;
}
nav.tabs button {
  background: transparent; color: #4a5568; border: none;
  padding: 6px 14px; border-radius: 4px; font-size: 13px;
  font-weight: 500; cursor: pointer;
}
nav.tabs button.active { background: #b5c0cd; color: #1f2933; }
nav.tabs button:hover:not(.active) { background: #eef2f7; }

.range-bar {
  display: flex; gap: 8px; align-items: center; flex-wrap: wrap;
  background: #ffffff; padding: 6px 10px; border-radius: 6px;
  border: 1px solid #b5c0cd;
}
.range-bar label { font-size: 12px; color: #4a5568; }
.range-bar input[type="date"] {
  font-size: 12px; padding: 3px 6px; border: 1px solid #b5c0cd;
  border-radius: 4px; background: #fff; font-family: inherit;
}
.range-bar .presets { display: flex; gap: 4px; flex-wrap: wrap; }
.range-bar .presets button {
  font-size: 11px; padding: 3px 8px; border: 1px solid #b5c0cd;
  background: #f7fafc; border-radius: 3px; cursor: pointer; color: #4a5568;
}
.range-bar .presets button:hover { background: #e2e8ef; }
.range-bar .presets button.active { background: #5a7a1a; color: #fff; border-color: #5a7a1a; }

main { padding: 16px 20px 40px; max-width: 1500px; margin: 0 auto; }

.kpi-grid {
  display: grid; grid-template-columns: repeat(auto-fill, minmax(180px, 1fr));
  gap: 10px; margin-bottom: 18px;
}
.kpi {
  background: #fff; border: 1px solid #b5c0cd; border-radius: 6px;
  padding: 10px 12px;
}
.kpi .label { font-size: 11px; color: #4a5568; text-transform: uppercase; letter-spacing: 0.4px; }
.kpi .value { font-size: 22px; font-weight: 600; color: #1f2933; margin-top: 2px; }
.kpi .sub   { font-size: 11px; color: #5a7a1a; margin-top: 1px; }

.tab-panel { display: none; }
.tab-panel.active { display: block; }

.table-wrap { background: #fff; border: 1px solid #b5c0cd; border-radius: 6px; overflow: auto; }
table { width: 100%; border-collapse: collapse; font-size: 13px; }
th, td { padding: 8px 10px; text-align: left; vertical-align: top; border-bottom: 1px solid #eef2f7; }
th {
  background: #eef2f7; font-weight: 600; color: #1f2933;
  position: sticky; top: 0; cursor: pointer; user-select: none; white-space: nowrap;
}
th:hover { background: #d4dbe5; }
th.sort-asc::after  { content: " ▲"; font-size: 10px; color: #5a7a1a; }
th.sort-desc::after { content: " ▼"; font-size: 10px; color: #5a7a1a; }
tr.row-clickable:hover { background: #f7fafc; cursor: pointer; }
td.num { text-align: right; font-variant-numeric: tabular-nums; }
td.pct { text-align: right; font-variant-numeric: tabular-nums; }
.bar {
  display: inline-block; height: 6px; background: #5a7a1a; border-radius: 3px;
  vertical-align: middle; margin-right: 4px; min-width: 1px;
}
.bar-track {
  display: inline-block; width: 60px; height: 6px; background: #e2e8ef;
  border-radius: 3px; vertical-align: middle; overflow: hidden;
}
.bar-track .bar { height: 100%; display: block; border-radius: 0; margin: 0; }
.tag {
  display: inline-block; font-size: 10px; padding: 1px 6px; border-radius: 9px;
  background: #eef2f7; color: #4a5568; margin-right: 4px;
}
.tag.role-AM       { background: #ddd6fe; color: #5b21b6; }
.tag.role-HOD      { background: #fed7aa; color: #9a3412; }
.tag.role-Admin    { background: #c7d2fe; color: #3730a3; }
.tag.warn          { background: #fde68a; color: #78350f; }
.tag.late          { background: #fecaca; color: #991b1b; }
.tag.leave         { background: #ddd6fe; color: #5b21b6; }
.tag.ok            { background: #bbf7d0; color: #14532d; }

#search-input {
  font-size: 12px; padding: 4px 8px; border: 1px solid #b5c0cd;
  border-radius: 4px; background: #fff; min-width: 180px; font-family: inherit;
}

.loading, .empty, .error {
  padding: 24px; text-align: center; color: #4a5568;
}
.error { color: #991b1b; }

/* Trend chart */
.chart-card {
  background: #fff; border: 1px solid #b5c0cd; border-radius: 6px;
  padding: 12px 16px 16px; margin-bottom: 18px; position: relative;
}
.chart-card .chart-head {
  display: flex; justify-content: space-between; align-items: center;
  flex-wrap: wrap; gap: 8px; margin-bottom: 8px;
}
.chart-card .chart-title {
  font-size: 13px; font-weight: 600; color: #1f2933;
  text-transform: uppercase; letter-spacing: 0.4px;
}
.chart-legend { display: flex; gap: 12px; font-size: 11px; color: #4a5568; flex-wrap: wrap; }
.chart-legend .item { display: flex; align-items: center; gap: 4px; }
.chart-legend .swatch {
  width: 12px; height: 3px; border-radius: 2px; display: inline-block;
}
.chart-legend .swatch.dashed {
  background: repeating-linear-gradient(90deg, currentColor 0 4px, transparent 4px 7px);
  height: 2px;
}
#trend-svg { width: 100%; height: 240px; display: block; user-select: none; }
#trend-svg .grid-line { stroke: #eef2f7; stroke-width: 1; }
#trend-svg .axis-text { font-size: 10px; fill: #94a3b8; font-family: inherit; }
#trend-svg .axis-text.dow { fill: #cbd5e0; }
#trend-svg .axis-text.today { fill: #5a7a1a; font-weight: 700; }
#trend-svg .nonwork { fill: #f1f5f9; }
#trend-svg .holiday-marker { fill: #fde68a; font-size: 9px; }
#trend-svg .series-line { fill: none; stroke-width: 2; }
#trend-svg .series-line.dashed { stroke-dasharray: 4 3; stroke-width: 1.5; }
#trend-svg .point { stroke: #fff; stroke-width: 1.5; cursor: pointer; }
#trend-svg .hover-guide {
  stroke: #94a3b8; stroke-width: 1; stroke-dasharray: 2 3;
  pointer-events: none; opacity: 0;
}
#trend-svg.has-hover .hover-guide { opacity: 1; }
.chart-tooltip {
  position: absolute; background: #1f2933; color: #fff; padding: 6px 9px;
  border-radius: 4px; font-size: 11px; pointer-events: none;
  opacity: 0; transition: opacity 0.1s; white-space: nowrap; z-index: 50;
  box-shadow: 0 2px 8px rgba(0,0,0,0.2);
}
.chart-tooltip.show { opacity: 1; }
.chart-tooltip b { color: #fde68a; }
.chart-tooltip .tt-row {
  display: flex; justify-content: space-between; gap: 12px;
  font-variant-numeric: tabular-nums;
}
.chart-tooltip .tt-row .lbl { color: #cbd5e0; }
.chart-empty {
  padding: 40px 16px; text-align: center; color: #94a3b8; font-style: italic; font-size: 12px;
}

/* Section titles — hidden in normal mode (tabs handle that), shown in PDF export */
.section-title { display: none; }

/* ─────────────────── PDF Export Mode ─────────────────── */
/* Activated by ?export=pdf — flattens tabs into stacked sections */
body.export-pdf { background: #fff; }
body.export-pdf header { background: #fff; border-bottom: 2px solid #5a7a1a; padding: 14px 24px; }
body.export-pdf header h1 { font-size: 20px; }
body.export-pdf nav.tabs,
body.export-pdf #search-input,
body.export-pdf .range-bar .presets,
body.export-pdf #modal-overlay { display: none !important; }
body.export-pdf .range-bar { background: transparent; border: none; padding: 0; }
body.export-pdf .range-bar input[type="date"] {
  border: none; background: transparent; pointer-events: none; padding: 0 4px;
}
body.export-pdf main { max-width: none; padding: 12px 16px 24px; }
body.export-pdf .tab-panel { display: block !important; margin-bottom: 12px; }
body.export-pdf .section-title {
  display: block; font-size: 14px; font-weight: 700; color: #5a7a1a;
  text-transform: uppercase; letter-spacing: 0.5px; margin: 18px 0 6px;
  border-bottom: 1px solid #b5c0cd; padding-bottom: 4px;
  page-break-after: avoid; break-after: avoid;
}
body.export-pdf .kpi { box-shadow: none; }
body.export-pdf .chart-card { box-shadow: none; padding: 10px 14px; }
body.export-pdf #trend-svg { height: 200px; }
body.export-pdf .table-wrap { border-radius: 0; overflow: visible; }
body.export-pdf table { font-size: 11px; }
body.export-pdf th { background: #eef2f7 !important; -webkit-print-color-adjust: exact; print-color-adjust: exact; }
body.export-pdf th { cursor: default; }
body.export-pdf .row-clickable { cursor: default; }
body.export-pdf .bar-track, body.export-pdf .bar,
body.export-pdf .tag, body.export-pdf .nonwork {
  -webkit-print-color-adjust: exact; print-color-adjust: exact;
}
body.export-pdf .pdf-footer {
  display: block; font-size: 10px; color: #94a3b8;
  margin-top: 18px; text-align: center; border-top: 1px solid #eef2f7; padding-top: 8px;
}
.pdf-footer { display: none; }

/* Page break rules for print */
@media print {
  body.export-pdf .chart-card,
  body.export-pdf .tab-panel { page-break-inside: avoid; }
  body.export-pdf .tab-panel + .tab-panel { page-break-before: auto; }
  body.export-pdf tbody tr { page-break-inside: avoid; }
  body.export-pdf thead { display: table-header-group; }
}

/* Drilldown modal */
#modal-overlay {
  position: fixed; inset: 0; background: rgba(15, 23, 42, 0.5);
  display: none; z-index: 200; padding: 24px;
}
#modal-overlay.open { display: flex; align-items: flex-start; justify-content: center; }
#modal {
  background: #fff; border-radius: 8px; max-width: 1100px; width: 100%;
  max-height: calc(100vh - 48px); overflow: auto; box-shadow: 0 10px 30px rgba(0,0,0,0.25);
}
#modal header {
  position: sticky; top: 0; background: #d4dbe5; padding: 12px 16px;
  display: flex; justify-content: space-between; align-items: center;
}
#modal header h2 { margin: 0; font-size: 16px; color: #1f2933; }
#modal-close {
  background: transparent; border: none; font-size: 20px; cursor: pointer;
  color: #4a5568; padding: 0 8px;
}
#modal .body { padding: 16px; }
#modal h3 {
  font-size: 13px; margin: 16px 0 6px; color: #5a7a1a;
  text-transform: uppercase; letter-spacing: 0.4px;
}
#modal h3:first-child { margin-top: 0; }
#modal .info-grid {
  display: grid; grid-template-columns: repeat(auto-fill, minmax(160px, 1fr));
  gap: 6px 14px; margin-bottom: 12px; font-size: 12px;
}
#modal .info-grid b { color: #4a5568; font-weight: 500; }
#modal table { font-size: 12px; }
#modal .empty-mini {
  padding: 8px 12px; font-size: 12px; color: #94a3b8; font-style: italic;
}
</style>
</head>
<body>

<header>
  <h1>WRG CRM — Plan &amp; Report</h1>
  <span id="env-badge" class="env-badge dev">DEV</span>
  <span id="env-preview-badge" class="env-badge preview" style="display:none">PREVIEW</span>
  <span class="meta" id="env-meta"></span>

  <div class="range-bar">
    <label>Dari: <input type="date" id="date-from"></label>
    <label>Sampai: <input type="date" id="date-to"></label>
    <div class="presets" id="presets">
      <button data-preset="today">Hari ini</button>
      <button data-preset="yesterday">Kemarin</button>
      <button data-preset="this-week" class="active">Minggu ini</button>
      <button data-preset="last-week">Minggu lalu</button>
      <button data-preset="last-7">7 hari</button>
      <button data-preset="this-month">Bulan ini</button>
      <button data-preset="last-month">Bulan lalu</button>
    </div>
  </div>

  <nav class="tabs">
    <button data-tab="orang" class="active">Per Orang</button>
    <button data-tab="divisi">Per Divisi</button>
    <button data-tab="cabang">Per Cabang</button>
    <button data-tab="hod">Per HOD Sales</button>
  </nav>

  <input id="search-input" placeholder="Filter (nama/cabang/role)…">
</header>

<main>
  <div class="kpi-grid" id="kpi-grid"><div class="loading">Memuat…</div></div>

  <section class="chart-card" id="trend-chart">
    <div class="chart-head">
      <div class="chart-title">Tren Plan &amp; Report Harian</div>
      <div class="chart-legend">
        <span class="item"><span class="swatch" style="background:#5a7a1a"></span>Plan (kunjungan + todo items)</span>
        <span class="item"><span class="swatch" style="background:#2563eb"></span>Report (aktivitas)</span>
        <span class="item" style="color:#dc2626"><span class="swatch dashed"></span>Late submission</span>
        <span class="item"><span class="swatch" style="background:#f1f5f9; border:1px solid #cbd5e0"></span>Non-working day</span>
      </div>
    </div>
    <div id="trend-container" style="position:relative">
      <svg id="trend-svg"></svg>
      <div class="chart-tooltip" id="trend-tooltip"></div>
    </div>
  </section>

  <h2 class="section-title">Per Orang</h2>
  <section class="tab-panel active" id="panel-orang">
    <div class="table-wrap"><table id="tbl-orang">
      <thead><tr>
        <th data-sort="panggilan">Panggilan</th>
        <th data-sort="nama">Nama</th>
        <th data-sort="role">Role</th>
        <th data-sort="cabang">Cabang</th>
        <th data-sort="active_days" class="num">Hari aktif</th>
        <th data-sort="plan_count"  class="num">Plan</th>
        <th data-sort="report_count" class="num">Report</th>
        <th data-sort="completion" class="pct">% Selesai</th>
        <th data-sort="late"       class="num">Late</th>
        <th data-sort="unmatched"  class="num">Unmatched</th>
      </tr></thead>
      <tbody><tr><td colspan="10" class="loading">Memuat…</td></tr></tbody>
    </table></div>
  </section>

  <h2 class="section-title">Per Divisi / Role</h2>
  <section class="tab-panel" id="panel-divisi">
    <div class="table-wrap"><table id="tbl-divisi">
      <thead><tr>
        <th data-sort="role">Role/Divisi</th>
        <th data-sort="jumlah_orang" class="num">Anggota</th>
        <th data-sort="orang_dgn_plan" class="num">Submit Plan</th>
        <th data-sort="orang_dgn_report" class="num">Kirim Report</th>
        <th data-sort="total_plan" class="num">Total Plan</th>
        <th data-sort="reported" class="num">Reported</th>
        <th data-sort="completion" class="pct">% Selesai</th>
        <th data-sort="total_late" class="num">Late</th>
        <th data-sort="unmatched_activity" class="num">Unmatched</th>
      </tr></thead>
      <tbody><tr><td colspan="9" class="loading">Memuat…</td></tr></tbody>
    </table></div>
  </section>

  <h2 class="section-title">Per Cabang</h2>
  <section class="tab-panel" id="panel-cabang">
    <div class="table-wrap"><table id="tbl-cabang">
      <thead><tr>
        <th data-sort="cabang">Cabang</th>
        <th data-sort="jumlah_orang" class="num">Anggota</th>
        <th data-sort="roles">Role aktif</th>
        <th data-sort="orang_dgn_plan" class="num">Submit Plan</th>
        <th data-sort="total_plan" class="num">Total Plan</th>
        <th data-sort="reported" class="num">Reported</th>
        <th data-sort="completion" class="pct">% Selesai</th>
        <th data-sort="total_late" class="num">Late</th>
      </tr></thead>
      <tbody><tr><td colspan="8" class="loading">Memuat…</td></tr></tbody>
    </table></div>
  </section>

  <h2 class="section-title">Per HOD Sales (East/West)</h2>
  <section class="tab-panel" id="panel-hod">
    <div class="table-wrap"><table id="tbl-hod">
      <thead><tr>
        <th data-sort="hod_panggilan">HOD</th>
        <th data-sort="hod_nama">Nama Lengkap</th>
        <th data-sort="jumlah_am" class="num">Jumlah AM</th>
        <th data-sort="am_dgn_plan" class="num">AM Submit Plan</th>
        <th data-sort="total_plan_visits" class="num">Total Kunjungan Plan</th>
        <th data-sort="plan_reported" class="num">Reported</th>
        <th data-sort="completion" class="pct">% Selesai</th>
        <th data-sort="plan_late" class="num">Late</th>
        <th data-sort="unmatched_activity" class="num">Unmatched</th>
      </tr></thead>
      <tbody><tr><td colspan="9" class="loading">Memuat…</td></tr></tbody>
    </table></div>
  </section>

  <footer class="pdf-footer" id="pdf-footer"></footer>
</main>

<div id="modal-overlay">
  <div id="modal" role="dialog" aria-modal="true">
    <header>
      <h2 id="modal-title">Detail</h2>
      <button id="modal-close" aria-label="Close">×</button>
    </header>
    <div class="body" id="modal-body"></div>
  </div>
</div>

<script>
// ── State ─────────────────────────────────────────────────────────────
const state = {
  env: null,           // viewing env (dev|prod)
  defaultEnv: null,    // global env (from server)
  isPreview: false,    // viewing != defaultEnv
  from: null,
  to: null,
  activeTab: "orang",
  search: "",
  sort: {
    orang:  { key: "panggilan", dir: 1 },
    divisi: { key: "role",      dir: 1 },
    cabang: { key: "cabang",    dir: 1 },
    hod:    { key: "hod_panggilan", dir: 1 },
  },
  rows: { orang: [], divisi: [], cabang: [], hod: [] },
};

// ── Date helpers ──────────────────────────────────────────────────────
function fmt(d) {
  // Local date components (NOT toISOString — that converts ke UTC, bikin midnight
  // WIB jadi previous day di UTC).
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, '0');
  const day = String(d.getDate()).padStart(2, '0');
  return `${y}-${m}-${day}`;
}
function parseDate(s) { return new Date(s + "T00:00:00"); }
function today() { return new Date(new Date().toDateString()); }

function presetRange(name) {
  const t = today();
  const day = t.getDay(); // 0=Sun
  const isoDow = day === 0 ? 7 : day; // 1=Mon..7=Sun
  if (name === "today")     return [fmt(t), fmt(t)];
  if (name === "yesterday") { const y = new Date(t); y.setDate(y.getDate()-1); return [fmt(y), fmt(y)]; }
  if (name === "this-week") {
    const mon = new Date(t); mon.setDate(t.getDate() - (isoDow - 1));
    const fri = new Date(mon); fri.setDate(mon.getDate() + 4);
    const end = fri > t ? t : fri;
    return [fmt(mon), fmt(end)];
  }
  if (name === "last-week") {
    const mon = new Date(t); mon.setDate(t.getDate() - (isoDow - 1) - 7);
    const fri = new Date(mon); fri.setDate(mon.getDate() + 4);
    return [fmt(mon), fmt(fri)];
  }
  if (name === "last-7")    { const d = new Date(t); d.setDate(d.getDate()-6); return [fmt(d), fmt(t)]; }
  if (name === "this-month") {
    const first = new Date(t.getFullYear(), t.getMonth(), 1);
    return [fmt(first), fmt(t)];
  }
  if (name === "last-month") {
    const first = new Date(t.getFullYear(), t.getMonth()-1, 1);
    const last  = new Date(t.getFullYear(), t.getMonth(), 0);
    return [fmt(first), fmt(last)];
  }
  return [fmt(t), fmt(t)];
}

// ── Fetch wrappers ────────────────────────────────────────────────────
async function fetchJSON(url) {
  const res = await fetch(url);
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`HTTP ${res.status}: ${text.slice(0, 200)}`);
  }
  return res.json();
}

function apiParams() {
  let qs = `from=${state.from}&to=${state.to}`;
  if (state.env) qs += `&env=${encodeURIComponent(state.env)}`;
  return "?" + qs;
}

async function loadAll() {
  const params = apiParams();
  setLoading();
  try {
    const [summary, trend, orang, divisi, cabang, hod] = await Promise.all([
      fetchJSON("/api/summary" + params),
      fetchJSON("/api/daily-trend" + params),
      fetchJSON("/api/per-orang" + params),
      fetchJSON("/api/per-divisi" + params),
      fetchJSON("/api/per-cabang" + params),
      fetchJSON("/api/per-hod" + params),
    ]);
    renderKPI(summary.summary || {});
    renderTrend(trend.days || []);
    state.rows.orang  = (orang.rows  || []).map(enrichOrang);
    state.rows.divisi = (divisi.rows || []).map(enrichDivisi);
    state.rows.cabang = (cabang.rows || []).map(enrichCabang);
    state.rows.hod    = (hod.rows    || []).map(enrichHod);
    renderTable("orang");
    renderTable("divisi");
    renderTable("cabang");
    renderTable("hod");
  } catch (e) {
    document.querySelectorAll("tbody").forEach(tb => {
      tb.innerHTML = `<tr><td colspan="10" class="error">Gagal memuat: ${escapeHtml(e.message)}</td></tr>`;
    });
    document.getElementById("kpi-grid").innerHTML = `<div class="error">${escapeHtml(e.message)}</div>`;
    document.getElementById("trend-svg").innerHTML = "";
  }
}

function setLoading() {
  document.querySelectorAll("tbody").forEach(tb => {
    tb.innerHTML = `<tr><td colspan="10" class="loading">Memuat…</td></tr>`;
  });
  document.getElementById("kpi-grid").innerHTML = `<div class="loading">Memuat…</div>`;
}

// ── Enrichment (computed fields used for sorting & display) ──────────
function pct(num, denom) {
  if (!denom || denom <= 0) return null;
  return Math.round((num / denom) * 100);
}

function enrichOrang(r) {
  r.is_am   = r.role === "AM";
  r.plan_count   = r.is_am ? r.total_plan_visits : r.total_todo_items;
  // For TODO mode (non-AM), use actual matched item count from report_data jsonb
  // instead of (todo_reported/total_todos) ratio approximation.
  r.report_count = r.is_am ? r.plan_reported : r.todo_items_matched;
  r.late      = r.plan_late + r.todo_late;
  // Unmatched: AM from activity_log.is_unmatched; TODO from report_data status != 'matched'.
  r.unmatched = r.is_am ? r.unmatched_activity : r.todo_items_unmatched;
  r.completion = pct(r.report_count, r.plan_count);
  return r;
}

function enrichDivisi(r) {
  // Reported items = AM plan_reported (AM mode visits reported) + actual matched TODO items
  r.reported = (r.plan_reported || 0) + (r.todo_items_matched || 0);
  r.unmatched_activity = (r.unmatched_activity || 0) + (r.todo_items_unmatched || 0);
  r.completion = pct(r.reported, r.total_plan);
  return r;
}

function enrichCabang(r) {
  // Same as divisi: report count = actual matched (AM plan_reported + TODO matched items)
  r.reported = (r.plan_reported || 0) + (r.todo_items_matched || 0);
  r.completion = pct(r.reported, r.total_plan);
  return r;
}

function enrichHod(r) {
  r.completion = pct(r.plan_reported, r.total_plan_visits);
  return r;
}

// ── KPI rendering ─────────────────────────────────────────────────────
function renderKPI(s) {
  const totalPlan = (s.total_plan_visits || 0) + (s.total_todo_items || 0);
  const totalReportedApprox = (s.plan_reported || 0) + (s.todo_reported || 0);
  const totalLate = (s.plan_late || 0) + (s.todo_late || 0);
  const compPct = totalPlan > 0 ? Math.round(totalReportedApprox / totalPlan * 100) : null;
  const matchPct = s.total_activity > 0 ? Math.round(s.matched_activity / s.total_activity * 100) : null;

  const kpis = [
    { label: "Hari kerja", value: s.working_days || 0, sub: `${state.from} → ${state.to}` },
    { label: "Karyawan wajib", value: s.users_wajib || 0, sub: `dari ${s.users_aktif || 0} aktif` },
    { label: "Total Plan", value: totalPlan,
      sub: `${s.total_plan_visits||0} kunjungan + ${s.total_todo_items||0} todo` },
    { label: "Reported", value: totalReportedApprox,
      sub: compPct !== null ? `${compPct}% selesai` : "—" },
    { label: "Late submission", value: totalLate, sub: "submit > 08:00" },
    { label: "Aktivitas (report)", value: s.total_activity || 0,
      sub: matchPct !== null ? `${matchPct}% matched ke plan` : "—" },
    { label: "Unmatched report", value: s.unmatched_activity || 0,
      sub: "tidak match plan hari itu" },
  ];

  document.getElementById("kpi-grid").innerHTML = kpis.map(k => `
    <div class="kpi">
      <div class="label">${escapeHtml(k.label)}</div>
      <div class="value">${k.value}</div>
      <div class="sub">${escapeHtml(k.sub || "")}</div>
    </div>
  `).join("");
}

// ── Trend chart rendering ─────────────────────────────────────────────
const DOW_ID = ["", "Sen", "Sel", "Rab", "Kam", "Jum", "Sab", "Min"];

function renderTrend(days) {
  const svg = document.getElementById("trend-svg");
  const tooltip = document.getElementById("trend-tooltip");
  if (!days || days.length === 0) {
    svg.innerHTML = `<text x="50%" y="50%" text-anchor="middle" class="axis-text">Tidak ada data pada periode ini.</text>`;
    return;
  }

  // Enrich each day with derived totals
  const enriched = days.map(d => ({
    ...d,
    plan_total:   (d.plan_visits || 0) + (d.todo_items || 0),
    report_total: d.total_activity || 0,
    late_total:   (d.plan_late || 0) + (d.todo_late || 0),
  }));

  // Layout constants
  const rect = svg.getBoundingClientRect();
  const W = Math.max(rect.width || 800, 300);
  const H = 240;
  const padL = 40, padR = 12, padT = 16, padB = 36;
  const innerW = W - padL - padR;
  const innerH = H - padT - padB;
  const n = enriched.length;
  const step = n > 1 ? innerW / (n - 1) : 0;

  // Y-axis scale — auto from max of plan_total
  const maxRaw = Math.max(
    1,
    ...enriched.map(d => Math.max(d.plan_total, d.report_total, d.late_total))
  );
  // Round up to nice number
  const niceMax = niceCeil(maxRaw);
  const tickCount = 4;
  const ticks = [];
  for (let i = 0; i <= tickCount; i++) ticks.push(Math.round((niceMax * i) / tickCount));

  const yScale = v => padT + innerH - (v / niceMax) * innerH;
  const xAt = i => padL + i * step;

  // Build SVG markup
  const parts = [];
  parts.push(`<svg viewBox="0 0 ${W} ${H}" preserveAspectRatio="none" width="100%" height="${H}" xmlns="http://www.w3.org/2000/svg">`);

  // Non-working day backdrop bands
  enriched.forEach((d, i) => {
    if (!d.is_working) {
      const x = xAt(i) - step / 2;
      const w = step;
      parts.push(`<rect class="nonwork" x="${Math.max(padL, x)}" y="${padT}" width="${Math.min(w, innerW)}" height="${innerH}"/>`);
    }
  });

  // Y-axis grid + labels
  ticks.forEach(t => {
    const y = yScale(t);
    parts.push(`<line class="grid-line" x1="${padL}" x2="${padL + innerW}" y1="${y}" y2="${y}"/>`);
    parts.push(`<text class="axis-text" x="${padL - 6}" y="${y + 3}" text-anchor="end">${t}</text>`);
  });

  // X-axis date labels (sparse if many days)
  const labelEvery = Math.max(1, Math.ceil(n / 14));
  const today = fmt(new Date());
  enriched.forEach((d, i) => {
    if (i % labelEvery !== 0 && i !== n - 1) return;
    const x = xAt(i);
    const day = parseInt(d.date.slice(8, 10), 10);
    const mon = parseInt(d.date.slice(5, 7), 10);
    const isToday = d.date === today;
    const cls = isToday ? "axis-text today" : "axis-text";
    parts.push(`<text class="${cls}" x="${x}" y="${padT + innerH + 14}" text-anchor="middle">${day}/${mon}</text>`);
    parts.push(`<text class="axis-text dow" x="${x}" y="${padT + innerH + 26}" text-anchor="middle">${DOW_ID[d.isodow] || ""}</text>`);
  });

  // Holiday marker (yellow dot above)
  enriched.forEach((d, i) => {
    if (d.holiday) {
      const x = xAt(i);
      parts.push(`<circle class="holiday-marker" cx="${x}" cy="${padT - 4}" r="3" />`);
      parts.push(`<title>${escapeHtml(d.holiday)}</title>`);
    }
  });

  // Series helper
  function linePath(values) {
    if (n === 0) return "";
    let path = "";
    values.forEach((v, i) => {
      const x = xAt(i);
      const y = yScale(v);
      path += (i === 0 ? "M" : "L") + x + "," + y + " ";
    });
    return path;
  }

  // Draw lines (late dashed first, then report, then plan on top)
  parts.push(`<path class="series-line dashed" stroke="#dc2626" d="${linePath(enriched.map(d => d.late_total))}"/>`);
  parts.push(`<path class="series-line" stroke="#2563eb" d="${linePath(enriched.map(d => d.report_total))}"/>`);
  parts.push(`<path class="series-line" stroke="#5a7a1a" d="${linePath(enriched.map(d => d.plan_total))}"/>`);

  // Points (plan = green dot, report = blue dot) — late skipped to avoid clutter
  enriched.forEach((d, i) => {
    const x = xAt(i);
    parts.push(`<circle class="point" cx="${x}" cy="${yScale(d.plan_total)}" r="3.5" fill="#5a7a1a"/>`);
    parts.push(`<circle class="point" cx="${x}" cy="${yScale(d.report_total)}" r="3" fill="#2563eb"/>`);
  });

  // Hover guide (vertical line) — manipulated on mousemove
  parts.push(`<line class="hover-guide" id="hover-guide" x1="0" x2="0" y1="${padT}" y2="${padT + innerH}"/>`);

  // Invisible hit rects for hover (one per day)
  enriched.forEach((d, i) => {
    const cx = xAt(i);
    const x = cx - step / 2;
    parts.push(`<rect x="${Math.max(padL, x)}" y="${padT}" width="${step}" height="${innerH}" fill="transparent" data-i="${i}"/>`);
  });

  parts.push(`</svg>`);
  svg.innerHTML = parts.join("");

  // Hover interactions
  const guide = document.getElementById("hover-guide");
  svg.querySelectorAll("rect[data-i]").forEach(r => {
    r.addEventListener("mousemove", e => {
      const i = parseInt(r.dataset.i, 10);
      const d = enriched[i];
      const cx = xAt(i);
      guide.setAttribute("x1", cx);
      guide.setAttribute("x2", cx);
      svg.classList.add("has-hover");
      const dt = new Date(d.date + "T00:00:00");
      const wd = ["Min","Sen","Sel","Rab","Kam","Jum","Sab"][dt.getDay()];
      const holidayLine = d.holiday ? `<div class="tt-row"><span class="lbl">📅</span><span><b>${escapeHtml(d.holiday)}</b></span></div>` : "";
      const workLine = !d.is_working && !d.holiday ? `<div class="tt-row"><span class="lbl">📅</span><span style="color:#cbd5e0">akhir pekan</span></div>` : "";
      tooltip.innerHTML = `
        <div><b>${wd}, ${escapeHtml(d.date)}</b></div>
        ${holidayLine}${workLine}
        <div class="tt-row"><span class="lbl">Plan total:</span><span>${d.plan_total}</span></div>
        <div class="tt-row" style="padding-left:8px;color:#94a3b8;font-size:10px">
          <span>kunjungan ${d.plan_visits}</span>
          <span>todo ${d.todo_items} (${d.todo_count} list)</span>
        </div>
        <div class="tt-row"><span class="lbl">Report:</span><span>${d.report_total}</span></div>
        <div class="tt-row"><span class="lbl">Late submit:</span><span>${d.late_total}</span></div>
        <div class="tt-row"><span class="lbl">Unmatched:</span><span>${d.unmatched}</span></div>
        <div class="tt-row"><span class="lbl">Orang submit/report:</span><span>${d.users_submitted}/${d.users_reported}</span></div>
      `;
      const container = document.getElementById("trend-container");
      const cRect = container.getBoundingClientRect();
      const sRect = svg.getBoundingClientRect();
      // Position tooltip; clamp to container width
      const ttWidth = 220;
      let tx = cx * (sRect.width / W) + 12;
      if (tx + ttWidth > cRect.width) tx = cx * (sRect.width / W) - ttWidth - 12;
      tooltip.style.left = `${Math.max(0, tx)}px`;
      tooltip.style.top = `${e.clientY - cRect.top + 10}px`;
      tooltip.classList.add("show");
    });
    r.addEventListener("mouseleave", () => {
      svg.classList.remove("has-hover");
      tooltip.classList.remove("show");
    });
  });
}

function niceCeil(v) {
  if (v <= 5) return Math.max(1, Math.ceil(v));
  const mag = Math.pow(10, Math.floor(Math.log10(v)));
  const norm = v / mag;
  let nice;
  if (norm <= 1) nice = 1;
  else if (norm <= 2) nice = 2;
  else if (norm <= 5) nice = 5;
  else nice = 10;
  return nice * mag;
}

// Re-render trend on window resize (debounced)
let _resizeTO = null;
window.addEventListener("resize", () => {
  clearTimeout(_resizeTO);
  _resizeTO = setTimeout(() => {
    // Re-fetch isn't needed; we kept the last days in DOM through SVG. Easier: re-load.
    if (state.from && state.to) {
      fetch(`/api/daily-trend${apiParams()}`)
        .then(r => r.json())
        .then(t => renderTrend(t.days || []))
        .catch(() => {});
    }
  }, 200);
});

// ── Table rendering ───────────────────────────────────────────────────
function applyFilter(rows) {
  const q = state.search.trim().toLowerCase();
  if (!q) return rows;
  return rows.filter(r => {
    return Object.values(r).some(v => {
      if (v == null) return false;
      return String(v).toLowerCase().includes(q);
    });
  });
}

function applySort(tab, rows) {
  const cfg = state.sort[tab];
  if (!cfg || !cfg.key) return rows;
  const k = cfg.key, dir = cfg.dir;
  const copy = rows.slice();
  copy.sort((a, b) => {
    const av = a[k], bv = b[k];
    if (av == null && bv == null) return 0;
    if (av == null) return 1;
    if (bv == null) return -1;
    if (typeof av === "number" && typeof bv === "number") return (av - bv) * dir;
    return String(av).localeCompare(String(bv), "id") * dir;
  });
  return copy;
}

function renderTable(tab) {
  const tbody = document.querySelector(`#tbl-${tab} tbody`);
  let rows = applyFilter(state.rows[tab]);
  rows = applySort(tab, rows);
  if (rows.length === 0) {
    const cols = document.querySelectorAll(`#tbl-${tab} thead th`).length;
    tbody.innerHTML = `<tr><td colspan="${cols}" class="empty">Tidak ada data pada periode ini.</td></tr>`;
    return;
  }
  const renderer = {
    orang:  rowOrang,
    divisi: rowDivisi,
    cabang: rowCabang,
    hod:    rowHod,
  }[tab];
  tbody.innerHTML = rows.map(renderer).join("");
  // Update sort indicator
  document.querySelectorAll(`#tbl-${tab} thead th`).forEach(th => {
    th.classList.remove("sort-asc", "sort-desc");
    if (th.dataset.sort === state.sort[tab].key) {
      th.classList.add(state.sort[tab].dir === 1 ? "sort-asc" : "sort-desc");
    }
  });
}

function pctBar(pctVal) {
  if (pctVal == null) return `<span style="color:#94a3b8">—</span>`;
  const w = Math.max(0, Math.min(100, pctVal));
  const color = w >= 80 ? "#5a7a1a" : (w >= 50 ? "#d97706" : "#dc2626");
  return `<span class="bar-track"><span class="bar" style="width:${w}%;background:${color}"></span></span> ${w}%`;
}

function rowOrang(r) {
  const roleTag = `<span class="tag role-${escapeHtml(r.role)}">${escapeHtml(r.role)}</span>`;
  const lateTag = r.late > 0 ? `<span class="tag late">${r.late}</span>` : `<span style="color:#94a3b8">0</span>`;
  const unmTag  = r.unmatched > 0 ? `<span class="tag warn">${r.unmatched}</span>` : `<span style="color:#94a3b8">0</span>`;
  const leaveTag = r.on_leave_today
    ? ` <span class="tag leave" title="ijin hari ini">ijin ${escapeHtml(r.leave_jenis_today || "")}</span>`
    : "";
  return `<tr class="row-clickable" data-user-id="${r.user_id}">
    <td><b>${escapeHtml(r.panggilan || "")}</b>${leaveTag}</td>
    <td>${escapeHtml(r.nama || "")}</td>
    <td>${roleTag}<div style="font-size:11px;color:#94a3b8">${escapeHtml(r.posisi || "")}</div></td>
    <td>${escapeHtml(r.cabang || "")}</td>
    <td class="num">${r.active_days}</td>
    <td class="num">${r.plan_count}
      <div style="font-size:10px;color:#94a3b8">${r.is_am ? "kunjungan" : `${r.total_todos} list / ${r.total_todo_items} item`}</div>
    </td>
    <td class="num">${r.report_count}
      <div style="font-size:10px;color:#94a3b8">${r.total_activity} aktivitas</div>
    </td>
    <td class="pct">${pctBar(r.completion)}</td>
    <td class="num">${lateTag}</td>
    <td class="num">${unmTag}</td>
  </tr>`;
}

function rowDivisi(r) {
  return `<tr>
    <td><b>${escapeHtml(r.role || "")}</b></td>
    <td class="num">${r.jumlah_orang}</td>
    <td class="num">${r.orang_dgn_plan} / ${r.jumlah_orang}</td>
    <td class="num">${r.orang_dgn_report} / ${r.jumlah_orang}</td>
    <td class="num">${r.total_plan}</td>
    <td class="num">${r.reported}</td>
    <td class="pct">${pctBar(r.completion)}</td>
    <td class="num">${r.total_late}</td>
    <td class="num">${r.unmatched_activity}</td>
  </tr>`;
}

function rowCabang(r) {
  return `<tr>
    <td><b>${escapeHtml(r.cabang || "")}</b></td>
    <td class="num">${r.jumlah_orang}</td>
    <td style="font-size:11px">${escapeHtml(r.roles || "")}</td>
    <td class="num">${r.orang_dgn_plan} / ${r.jumlah_orang}</td>
    <td class="num">${r.total_plan}</td>
    <td class="num">${r.reported}</td>
    <td class="pct">${pctBar(r.completion)}</td>
    <td class="num">${r.total_late}</td>
  </tr>`;
}

function rowHod(r) {
  return `<tr>
    <td><b>${escapeHtml(r.hod_panggilan || "")}</b></td>
    <td>${escapeHtml(r.hod_nama || "")}</td>
    <td class="num">${r.jumlah_am}</td>
    <td class="num">${r.am_dgn_plan} / ${r.jumlah_am}</td>
    <td class="num">${r.total_plan_visits}</td>
    <td class="num">${r.plan_reported}</td>
    <td class="pct">${pctBar(r.completion)}</td>
    <td class="num">${r.plan_late}</td>
    <td class="num">${r.unmatched_activity}</td>
  </tr>`;
}

// ── Drilldown ─────────────────────────────────────────────────────────
async function openDrilldown(userId) {
  document.getElementById("modal-title").textContent = "Memuat detail…";
  document.getElementById("modal-body").innerHTML = `<div class="loading">Memuat…</div>`;
  document.getElementById("modal-overlay").classList.add("open");
  try {
    const res = await fetchJSON(`/api/drilldown${apiParams()}&user_id=${userId}`);
    const d = res.detail || {};
    const u = d.user || {};
    document.getElementById("modal-title").textContent =
      `${u.panggilan || ""} — ${u.nama || ""} (${u.role || ""})`;
    document.getElementById("modal-body").innerHTML = renderDrilldown(d);
  } catch (e) {
    document.getElementById("modal-body").innerHTML =
      `<div class="error">Gagal: ${escapeHtml(e.message)}</div>`;
  }
}

function renderDrilldown(d) {
  const u = d.user || {};
  const plan = d.plan || [];
  const todo = d.todo || [];
  const unmatched = d.unmatched_activity || [];

  const lastAct = u.last_active_at
    ? new Date(u.last_active_at).toLocaleString("id-ID")
    : "—";

  const info = `
    <div class="info-grid">
      <div><b>Nama:</b> ${escapeHtml(u.nama || "")}</div>
      <div><b>Panggilan:</b> ${escapeHtml(u.panggilan || "")}</div>
      <div><b>Role:</b> ${escapeHtml(u.role || "")}</div>
      <div><b>Posisi:</b> ${escapeHtml(u.posisi || "")}</div>
      <div><b>Cabang:</b> ${escapeHtml(u.cabang || "")}</div>
      <div><b>WA:</b> ${escapeHtml(u.wa_number || "")}</div>
      <div><b>Last active group:</b> ${escapeHtml(u.last_active_group || "—")}</div>
      <div><b>Last active at:</b> ${escapeHtml(lastAct)}</div>
      <div><b>Periode:</b> ${escapeHtml(state.from)} → ${escapeHtml(state.to)}</div>
    </div>
  `;

  let planTable = `<div class="empty-mini">Tidak ada plan (#PLAN) di periode ini.</div>`;
  if (plan.length > 0) {
    planTable = `<div class="table-wrap"><table>
      <thead><tr>
        <th>Tanggal</th><th>#</th><th>Customer</th><th>Tujuan</th><th>Goal</th>
        <th>Status</th><th>Hasil</th><th>Next</th>
      </tr></thead><tbody>
      ${plan.map(p => `<tr>
        <td>${escapeHtml(p.tanggal)}</td>
        <td class="num">${p.seq}</td>
        <td><b>${escapeHtml(p.customer_name)}</b></td>
        <td>${escapeHtml(p.tujuan || "")}</td>
        <td>${escapeHtml(p.goal || "")}</td>
        <td>${p.reported
          ? `<span class="tag ok">reported</span>`
          : `<span class="tag warn">pending</span>`}
          ${p.is_late_plan ? `<span class="tag late">late submit</span>` : ""}
        </td>
        <td>${escapeHtml(p.hasil || "")}</td>
        <td>${escapeHtml(p.next_action || "")}</td>
      </tr>`).join("")}
      </tbody></table></div>`;
  }

  let todoTable = `<div class="empty-mini">Tidak ada todo (#PLAN format list) di periode ini.</div>`;
  if (todo.length > 0) {
    todoTable = `<div class="table-wrap"><table>
      <thead><tr>
        <th>Tanggal</th><th class="num">Items</th><th>Daftar</th>
        <th>Status</th><th>Submit</th>
      </tr></thead><tbody>
      ${todo.map(t => `<tr>
        <td>${escapeHtml(t.tanggal)}</td>
        <td class="num">${t.total_items}</td>
        <td><ul style="margin:0; padding-left:18px">${
          (t.items || []).map(it => `<li>${escapeHtml(String(it))}</li>`).join("")
        }</ul></td>
        <td>${t.reported
          ? `<span class="tag ok">reported</span>`
          : `<span class="tag warn">pending</span>`}
          ${t.is_late_plan ? `<span class="tag late">late</span>` : ""}
        </td>
        <td style="font-size:11px;color:#94a3b8">${escapeHtml(t.submitted_at || "")}</td>
      </tr>`).join("")}
      </tbody></table></div>`;
  }

  let unmTable = `<div class="empty-mini">Tidak ada aktivitas unmatched.</div>`;
  if (unmatched.length > 0) {
    unmTable = `<div class="table-wrap"><table>
      <thead><tr>
        <th>Tanggal</th><th>Customer</th><th>Hasil</th><th>Next</th>
        <th class="num">Match score</th>
      </tr></thead><tbody>
      ${unmatched.map(a => `<tr>
        <td>${escapeHtml(a.tanggal)}</td>
        <td><b>${escapeHtml(a.customer_name)}</b></td>
        <td>${escapeHtml(a.hasil || "")}</td>
        <td>${escapeHtml(a.next_action || "")}</td>
        <td class="num">${a.match_score != null ? Number(a.match_score).toFixed(3) : "—"}</td>
      </tr>`).join("")}
      </tbody></table></div>`;
  }

  return `${info}
    <h3>Plan kunjungan (sales_plan)</h3>${planTable}
    <h3>Todo list (sales_todo)</h3>${todoTable}
    <h3>Unmatched / extra activity</h3>${unmTable}
  `;
}

// ── Utility ───────────────────────────────────────────────────────────
function escapeHtml(s) {
  if (s == null) return "";
  return String(s).replace(/[&<>"']/g, c => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
  }[c]));
}

// ── Event wiring ──────────────────────────────────────────────────────
document.querySelectorAll("nav.tabs button").forEach(btn => {
  btn.addEventListener("click", () => {
    document.querySelectorAll("nav.tabs button").forEach(b => b.classList.remove("active"));
    btn.classList.add("active");
    const tab = btn.dataset.tab;
    state.activeTab = tab;
    document.querySelectorAll(".tab-panel").forEach(p => p.classList.remove("active"));
    document.getElementById(`panel-${tab}`).classList.add("active");
    renderTable(tab);
  });
});

document.querySelectorAll("#presets button").forEach(btn => {
  btn.addEventListener("click", () => {
    document.querySelectorAll("#presets button").forEach(b => b.classList.remove("active"));
    btn.classList.add("active");
    const [d1, d2] = presetRange(btn.dataset.preset);
    state.from = d1; state.to = d2;
    document.getElementById("date-from").value = d1;
    document.getElementById("date-to").value   = d2;
    loadAll();
  });
});

["date-from", "date-to"].forEach(id => {
  document.getElementById(id).addEventListener("change", () => {
    const d1 = document.getElementById("date-from").value;
    const d2 = document.getElementById("date-to").value;
    if (!d1 || !d2) return;
    state.from = d1 < d2 ? d1 : d2;
    state.to   = d1 < d2 ? d2 : d1;
    document.querySelectorAll("#presets button").forEach(b => b.classList.remove("active"));
    loadAll();
  });
});

document.querySelectorAll("table th[data-sort]").forEach(th => {
  th.addEventListener("click", () => {
    // Find which tab this th belongs to
    const tableId = th.closest("table").id;
    const tab = tableId.replace("tbl-", "");
    const key = th.dataset.sort;
    if (state.sort[tab].key === key) {
      state.sort[tab].dir = -state.sort[tab].dir;
    } else {
      state.sort[tab].key = key;
      state.sort[tab].dir = 1;
    }
    renderTable(tab);
  });
});

document.getElementById("search-input").addEventListener("input", e => {
  state.search = e.target.value;
  renderTable(state.activeTab);
});

document.body.addEventListener("click", e => {
  const tr = e.target.closest("tr.row-clickable");
  if (tr && tr.dataset.userId) {
    openDrilldown(tr.dataset.userId);
  }
});

document.getElementById("modal-close").addEventListener("click", () => {
  document.getElementById("modal-overlay").classList.remove("open");
});
document.getElementById("modal-overlay").addEventListener("click", e => {
  if (e.target.id === "modal-overlay") {
    document.getElementById("modal-overlay").classList.remove("open");
  }
});
document.addEventListener("keydown", e => {
  if (e.key === "Escape") {
    document.getElementById("modal-overlay").classList.remove("open");
  }
});

// ── URL fragment parser (for deep-linking & headless screenshot) ──────
// Supports: #tab=orang|divisi|cabang|hod  &  #drilldown=<user_id>  &  #from=YYYY-MM-DD&to=YYYY-MM-DD
function parseHash() {
  const h = (location.hash || "").replace(/^#/, "");
  if (!h) return {};
  const out = {};
  h.split("&").forEach(p => {
    const [k, v] = p.split("=");
    if (k) out[decodeURIComponent(k)] = decodeURIComponent(v || "");
  });
  return out;
}

// ── Init ──────────────────────────────────────────────────────────────
(async function init() {
  try {
    // Detect env override + PDF export mode from query string
    const urlParams = new URLSearchParams(location.search);
    const envOverride = urlParams.get("env");
    const envReq = (envOverride === "prod" || envOverride === "dev") ? envOverride : "";
    const isExport = urlParams.get("export") === "pdf";
    if (isExport) document.body.classList.add("export-pdf");
    const envInfo = await fetchJSON("/api/env" + (envReq ? `?env=${envReq}` : ""));
    state.env = envInfo.env;
    state.defaultEnv = envInfo.default_env;
    state.isPreview = !!envInfo.is_preview;
    const h = parseHash();
    state.from = (h.from && /^\d{4}-\d{2}-\d{2}$/.test(h.from)) ? h.from : envInfo.default_from;
    state.to   = (h.to   && /^\d{4}-\d{2}-\d{2}$/.test(h.to))   ? h.to   : envInfo.default_to;
    const badge = document.getElementById("env-badge");
    badge.textContent = state.env.toUpperCase();
    badge.classList.remove("dev", "prod"); badge.classList.add(state.env);
    const previewBadge = document.getElementById("env-preview-badge");
    if (state.isPreview) {
      previewBadge.style.display = "inline-block";
      previewBadge.textContent = `PREVIEW (default: ${state.defaultEnv.toUpperCase()})`;
    } else {
      previewBadge.style.display = "none";
    }
    document.getElementById("env-meta").textContent = `DB: ${envInfo.db} · Hari ini: ${envInfo.today}`;
    document.getElementById("date-from").value = state.from;
    document.getElementById("date-to").value   = state.to;
    await loadAll();
    // Apply tab from hash, if any
    if (h.tab && ["orang","divisi","cabang","hod"].includes(h.tab)) {
      const tabBtn = document.querySelector(`nav.tabs button[data-tab="${h.tab}"]`);
      if (tabBtn) tabBtn.click();
    }
    // Open drilldown from hash, if any
    if (h.drilldown && /^\d+$/.test(h.drilldown)) {
      openDrilldown(h.drilldown);
    }
    // Populate PDF footer once data is loaded
    if (isExport) {
      const footer = document.getElementById("pdf-footer");
      const ts = new Date().toLocaleString("id-ID", { dateStyle: "full", timeStyle: "short" });
      footer.textContent =
        `WRG CRM Plan & Report Dashboard · Generated ${ts} · ` +
        `Source: ${envInfo.db} · Periode: ${state.from} → ${state.to}`;
      // Signal completion for headless capture
      document.body.setAttribute("data-ready", "1");
    }
  } catch (e) {
    document.getElementById("kpi-grid").innerHTML =
      `<div class="error">Init gagal: ${escapeHtml(e.message)}</div>`;
  }
})();
</script>
</body>
</html>
"""


def main():
    parser = argparse.ArgumentParser(description="WRG CRM Plan & Report Dashboard")
    parser.add_argument("--port", type=int, default=8091)
    parser.add_argument("--bind", default="127.0.0.1")
    args = parser.parse_args()

    env = current_env()
    db = db_name(env)
    print(f"WRG CRM Dashboard listening at http://{args.bind}:{args.port}/")
    print(f"  PROJECT_DIR = {PROJECT_DIR}")
    print(f"  ENV         = {env}")
    print(f"  DATABASE    = {db}")
    print(f"  PSQL_BIN    = {PSQL_BIN}")

    with ReusableTCPServer((args.bind, args.port), Handler) as srv:
        try:
            srv.serve_forever()
        except KeyboardInterrupt:
            print("\nshutdown")


if __name__ == "__main__":
    main()
