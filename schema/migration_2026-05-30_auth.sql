-- ============================================================
-- WRG CRM — Auth foundation (2026-05-30)
-- ============================================================
-- Adds password_hash to master_user + session table for cookie-based
-- login. Used by Adminator-based frontend Phase 5.
--
-- Idempotent.
-- Apply: psql -U wrg_admin -d <db> -f schema/migration_2026-05-30_auth.sql
-- ============================================================

BEGIN;

-- Add password fields to master_user (nullable initially — populated via
-- admin reset flow or first-login set-password).
ALTER TABLE master_user
  ADD COLUMN IF NOT EXISTS password_hash         TEXT,
  ADD COLUMN IF NOT EXISTS last_login_at         TIMESTAMP,
  ADD COLUMN IF NOT EXISTS force_password_change BOOLEAN DEFAULT TRUE;

-- Lightweight session table. token = secrets.token_urlsafe(32).
-- expires_at typically NOW() + 24 hours. Cleanup via cron weekly.
CREATE TABLE IF NOT EXISTS wrg_user_session (
  token       TEXT PRIMARY KEY,
  user_id     INTEGER NOT NULL REFERENCES master_user(id) ON DELETE CASCADE,
  created_at  TIMESTAMP DEFAULT NOW(),
  expires_at  TIMESTAMP NOT NULL,
  user_agent  TEXT,
  ip          TEXT
);

CREATE INDEX IF NOT EXISTS idx_wrg_user_session_user ON wrg_user_session (user_id, expires_at);

-- Helper: prune expired sessions (call periodically).
CREATE OR REPLACE FUNCTION prune_expired_sessions() RETURNS INTEGER
LANGUAGE plpgsql AS $$
DECLARE n INTEGER;
BEGIN
  DELETE FROM wrg_user_session WHERE expires_at < NOW();
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END;
$$;

COMMIT;

-- ============================================================
-- Bootstrap: set initial password for admin (Husni id=1).
-- Use the included `python3 scripts/auth_set_password.py <user_id>` helper
-- (added in Phase 5b) — never store plain text passwords here.
-- ============================================================
