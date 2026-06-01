-- 2026-06-01: Photo follow-up pairing for AM #REPORT
-- Cumulative report workflow: text-only #REPORT followed by image
-- messages with numbered captions ("1.", "2.", "3.") for geotag verification.

ALTER TABLE activity_log
  ADD COLUMN IF NOT EXISTS sender_wa_number TEXT;

CREATE INDEX IF NOT EXISTS idx_activity_sender_wa
  ON activity_log (sender_wa_number, tanggal)
  WHERE photo_path IS NULL;
