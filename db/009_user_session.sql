-- Session table untuk Google OAuth login.
-- Token = secure random hex 64-char, disimpan apa adanya (treat sebagai
-- bearer secret — kalau bocor sama bahayanya dengan password). Untuk
-- audit yang lebih ketat bisa di-hash, tapi extra step ini ditunda
-- karena akses dashboard internal saja.

CREATE TABLE IF NOT EXISTS user_session (
  token        TEXT PRIMARY KEY,
  email        TEXT NOT NULL,
  name         TEXT,
  picture      TEXT,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  expires_at   TIMESTAMPTZ NOT NULL DEFAULT (NOW() + INTERVAL '7 days'),
  ip           TEXT,
  user_agent   TEXT
);
CREATE INDEX IF NOT EXISTS idx_user_session_email_created
  ON user_session(email, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_user_session_expires
  ON user_session(expires_at);

-- Audit log untuk login attempts (success + failures).
CREATE TABLE IF NOT EXISTS auth_log (
  id          SERIAL PRIMARY KEY,
  email       TEXT,
  event       TEXT NOT NULL,     -- 'login_success' | 'login_failed' | 'logout' | 'session_expired'
  reason      TEXT,
  ip          TEXT,
  user_agent  TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_auth_log_created ON auth_log(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_auth_log_email ON auth_log(email, created_at DESC);
