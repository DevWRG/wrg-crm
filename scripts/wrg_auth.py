"""WRG CRM — Auth helpers.

pbkdf2_sha256 password hashing (Python stdlib, no bcrypt dependency).
Session model: random token stored di wrg_user_session table, 24h TTL.
Cookies httponly, SameSite=Lax.
"""
from __future__ import annotations

import hashlib
import secrets

from wrg_db import psql_quote, psql_exec, psql_json

PBKDF2_ITER = 200_000
SESSION_COOKIE = "wrg_session"


def hash_password(plain: str) -> str:
    """Returns pbkdf2_sha256$<iter>$<salt_hex>$<hash_hex>"""
    salt = secrets.token_bytes(16)
    h = hashlib.pbkdf2_hmac("sha256", plain.encode("utf-8"), salt, PBKDF2_ITER, 32)
    return f"pbkdf2_sha256${PBKDF2_ITER}${salt.hex()}${h.hex()}"


def verify_password(plain: str, hashed: str) -> bool:
    try:
        algo, iters, salt_hex, h_hex = hashed.split("$", 3)
        if algo != "pbkdf2_sha256":
            return False
        salt = bytes.fromhex(salt_hex)
        expected = bytes.fromhex(h_hex)
        h = hashlib.pbkdf2_hmac("sha256", plain.encode("utf-8"), salt, int(iters), len(expected))
        return secrets.compare_digest(h, expected)
    except Exception:
        return False


def create_session(user_id: int, env: str, ua: str = "", ip: str = "") -> str:
    """Insert wrg_user_session row, return token (expires in 24h)."""
    token = secrets.token_urlsafe(32)
    sql = (
        "INSERT INTO wrg_user_session (token, user_id, expires_at, user_agent, ip) VALUES ("
        f"{psql_quote(token)}, {int(user_id)}, NOW() + INTERVAL '24 hours', "
        f"{psql_quote(ua[:200])}, {psql_quote(ip[:64])});"
    )
    psql_exec(sql, env=env)
    psql_exec(f"UPDATE master_user SET last_login_at = NOW() WHERE id = {int(user_id)};", env=env)
    return token


def validate_session(token: str, env: str):
    """Return user row dict if valid + not expired, else None."""
    if not token or len(token) < 20:
        return None
    safe = psql_quote(token)
    sql = (
        "SELECT row_to_json(t) FROM ("
        "  SELECT mu.id, mu.nama, mu.panggilan, mu.role, mu.posisi, mu.cabang, "
        "         mu.wa_number, mu.aktif, mu.wajib_plan_report, mu.force_password_change "
        "  FROM wrg_user_session s "
        "  JOIN master_user mu ON mu.id = s.user_id "
        f"  WHERE s.token = {safe} AND s.expires_at > NOW() "
        "  LIMIT 1"
        ") t;"
    )
    return psql_json(sql, env=env)


def destroy_session(token: str, env: str):
    if not token:
        return
    psql_exec(f"DELETE FROM wrg_user_session WHERE token = {psql_quote(token)};", env=env)


def is_admin_role(role: str) -> bool:
    """HOD + Direksi treated as admin (full access). Others = regular user."""
    return role in ("HOD", "Direksi")


def get_cookie(handler, name: str) -> str:
    """Parse single cookie value from BaseHTTPRequestHandler headers."""
    raw = handler.headers.get("Cookie", "")
    for part in raw.split(";"):
        part = part.strip()
        if part.startswith(name + "="):
            return part[len(name) + 1:]
    return ""
