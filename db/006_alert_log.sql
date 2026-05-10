-- Alerting log. One row per fired alert, with per-channel delivery results
-- and a payload that includes the high-water-mark of delivery_log.id so the
-- next check can skip rows we already alerted on.

CREATE TABLE IF NOT EXISTS alert_log (
  id                  SERIAL PRIMARY KEY,
  kind                TEXT NOT NULL,                  -- 'exhausted_resend' | 'cleared' | 'test'
  level               TEXT NOT NULL,                  -- 'info' | 'warn' | 'critical'
  title               TEXT NOT NULL,
  body                TEXT NOT NULL,
  payload             JSONB NOT NULL DEFAULT '{}'::jsonb,
  channels_delivered  JSONB NOT NULL DEFAULT '[]'::jsonb,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_alert_kind_created
  ON alert_log(kind, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_alert_created ON alert_log(created_at DESC);
