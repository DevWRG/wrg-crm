-- Auto-resend tracking for failed deliveries.
--
-- Each ATTEMPT writes its own delivery_log row. A failed row is "the parent";
-- subsequent resend attempts are children that point back via
-- parent_delivery_id and use source='resend'. When any child succeeds, the
-- parent gets resolved=TRUE so we stop picking it.

ALTER TABLE delivery_log
  ADD COLUMN IF NOT EXISTS text_full          TEXT,
  ADD COLUMN IF NOT EXISTS resend_count       INT NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS last_resend_at     TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS resolved           BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS parent_delivery_id INT REFERENCES delivery_log(id) ON DELETE SET NULL;

-- Backfill text_full untuk baris lama (preview saja yang tersedia).
UPDATE delivery_log
   SET text_full = text_preview
 WHERE text_full IS NULL;

-- Partial index: hanya kandidat resend yang relevan.
CREATE INDEX IF NOT EXISTS idx_delivery_pending_resend
  ON delivery_log(last_resend_at NULLS FIRST, created_at)
  WHERE delivered = FALSE AND resolved = FALSE;
