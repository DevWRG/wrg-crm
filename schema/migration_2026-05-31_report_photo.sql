-- ============================================================
-- WRG CRM — Photo Geotag untuk #REPORT AM (2026-05-31)
-- ============================================================
-- Add photo_path + photo_geotag columns ke activity_log.
-- File foto sendiri TIDAK disimpan di DB (per user request) — hanya
-- reference path + extracted geotag JSON.
--
-- Format photo_geotag:
--   {"has_geotag": bool, "lat": float, "lon": float,
--    "timestamp": "YYYY/MM/DD HH:MM", "address": str}
--
-- Idempotent.
-- ============================================================

BEGIN;

ALTER TABLE activity_log
  ADD COLUMN IF NOT EXISTS photo_path    TEXT,
  ADD COLUMN IF NOT EXISTS photo_geotag  JSONB;

CREATE INDEX IF NOT EXISTS idx_activity_log_has_photo
  ON activity_log ((photo_path IS NOT NULL));

COMMIT;
