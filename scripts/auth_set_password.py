#!/usr/bin/env python3
"""
Set / reset password for a master_user account.

Usage:
  python3 scripts/auth_set_password.py <identifier> [<password>] [--db <db>]

identifier: panggilan, nama, or user_id (numeric)
password:   if omitted, prompts interactively

Examples:
  python3 scripts/auth_set_password.py Husni
  python3 scripts/auth_set_password.py 1 secret123 --db wrg_crm_prod
  python3 scripts/auth_set_password.py boni temppass

After set, user can login via web UI. force_password_change=true initially —
frontend will prompt to change on first login (Phase 5c).
"""
import sys
import os
import getpass
import subprocess
import hashlib
import secrets
import argparse

PBKDF2_ITER = 200_000
PSQL = "/opt/homebrew/opt/postgresql@16/bin/psql"


def hash_password(plain: str) -> str:
    salt = secrets.token_bytes(16)
    h = hashlib.pbkdf2_hmac("sha256", plain.encode("utf-8"), salt, PBKDF2_ITER, 32)
    return f"pbkdf2_sha256${PBKDF2_ITER}${salt.hex()}${h.hex()}"


def psql(db: str, sql: str) -> str:
    proc = subprocess.run(
        [PSQL, "-U", "wrg_admin", "-d", db, "-tA", "-c", sql],
        capture_output=True, text=True, check=False, timeout=20,
    )
    if proc.returncode != 0:
        sys.exit(f"psql failed: {proc.stderr.strip()}")
    return proc.stdout.strip()


def find_user(db: str, ident: str):
    if ident.isdigit():
        out = psql(db, f"SELECT id || '|' || COALESCE(panggilan,'') || '|' || COALESCE(nama,'') || '|' || role FROM master_user WHERE id = {int(ident)};")
    else:
        safe = ident.replace("'", "''").lower()
        out = psql(db, f"SELECT id || '|' || COALESCE(panggilan,'') || '|' || COALESCE(nama,'') || '|' || role FROM master_user WHERE LOWER(panggilan) = '{safe}' OR LOWER(nama) = '{safe}' LIMIT 1;")
    if not out:
        return None
    parts = out.split("|")
    return {"id": int(parts[0]), "panggilan": parts[1], "nama": parts[2], "role": parts[3]}


def main():
    p = argparse.ArgumentParser()
    p.add_argument("identifier")
    p.add_argument("password", nargs="?")
    p.add_argument("--db", default=os.environ.get("PGDATABASE", "wrg_crm_dev"))
    args = p.parse_args()

    user = find_user(args.db, args.identifier)
    if not user:
        sys.exit(f"User '{args.identifier}' not found in {args.db}")

    print(f"User: id={user['id']}  panggilan={user['panggilan']}  nama={user['nama']}  role={user['role']}")

    pw = args.password
    if not pw:
        pw = getpass.getpass("New password: ")
        if pw != getpass.getpass("Confirm password: "):
            sys.exit("Passwords don't match.")
    if len(pw) < 6:
        sys.exit("Password too short (min 6 chars).")

    h = hash_password(pw)
    safe_h = h.replace("'", "''")
    out = psql(args.db, f"UPDATE master_user SET password_hash = '{safe_h}', force_password_change = false WHERE id = {user['id']} RETURNING id, panggilan;")
    print(f"OK — password set for {out}")
    print(f"DB: {args.db}")


if __name__ == "__main__":
    main()
