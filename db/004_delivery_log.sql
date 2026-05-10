-- Per-send-attempt audit. One row per WhatsApp message *outbound*.
-- Linked back to audit_log when the send is triggered by an inbound
-- message; left NULL for scheduler/manual originated sends (e.g. daily
-- summary).

CREATE TABLE IF NOT EXISTS delivery_log (
  id              SERIAL PRIMARY KEY,
  audit_id        INT REFERENCES audit_log(id) ON DELETE SET NULL,
  source          TEXT NOT NULL,                   -- 'inbound' | 'scheduler' | 'manual'
  message_id_in   TEXT,                            -- gateway's inbound msgId (for joins)
  wa_number       TEXT,                            -- inbound sender, if any
  to_kind         TEXT NOT NULL,                   -- 'group' | 'dm'
  target          TEXT NOT NULL,
  text_preview    TEXT,                            -- first ~200 chars
  delivered       BOOLEAN NOT NULL,
  attempts        INT NOT NULL DEFAULT 1,
  message_id_out  TEXT,                            -- gateway's outbound msgId from response
  error           TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_delivery_created ON delivery_log(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_delivery_failed
  ON delivery_log(created_at DESC) WHERE delivered = FALSE;
CREATE INDEX IF NOT EXISTS idx_delivery_audit ON delivery_log(audit_id);
