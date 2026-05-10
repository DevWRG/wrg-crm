-- Idempotency table for inbound webhook deduplication.
-- A row is claimed before processing; on conflict, the request is treated
-- as a duplicate and skipped (no second WA reply, no second DB write).

CREATE TABLE IF NOT EXISTS processed_message (
  message_id      TEXT PRIMARY KEY,
  wa_number       TEXT NOT NULL,
  hashtag         TEXT,
  status          TEXT NOT NULL DEFAULT 'PROCESSING',
  result_summary  JSONB,
  processed_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  finished_at     TIMESTAMPTZ,
  expires_at      TIMESTAMPTZ NOT NULL DEFAULT (NOW() + INTERVAL '7 days')
);
CREATE INDEX IF NOT EXISTS idx_processed_msg_expires
  ON processed_message(expires_at);
CREATE INDEX IF NOT EXISTS idx_processed_msg_wa
  ON processed_message(wa_number, processed_at DESC);
