-- Audit log untuk pengiriman email otomatis (digest, dll).
CREATE TABLE IF NOT EXISTS email_log (
  id          SERIAL PRIMARY KEY,
  kind        TEXT NOT NULL,                   -- 'weekly_digest' | 'test' | ...
  recipients  JSONB NOT NULL,                  -- array of strings
  subject     TEXT NOT NULL,
  range_from  DATE,
  range_to    DATE,
  delivered   BOOLEAN NOT NULL,
  message_id  TEXT,
  error       TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_email_log_created ON email_log(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_email_log_kind ON email_log(kind, created_at DESC);
