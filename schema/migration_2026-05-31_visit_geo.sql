-- ============================================================
-- WRG CRM — Visit geotag + timestamp validation (2026-05-31)
-- ============================================================
-- Add visit_lat/lon/timestamp ke sales_plan dari photo geotag.
-- visit_date_mismatch flag = TRUE kalau photo timestamp tanggalnya
-- berbeda dengan sales_plan.tanggal (deteksi backdated report).
-- ============================================================

BEGIN;

ALTER TABLE sales_plan
  ADD COLUMN IF NOT EXISTS visit_lat            NUMERIC(9,6),
  ADD COLUMN IF NOT EXISTS visit_lon            NUMERIC(9,6),
  ADD COLUMN IF NOT EXISTS visit_timestamp      TIMESTAMP,
  ADD COLUMN IF NOT EXISTS visit_date_mismatch  BOOLEAN DEFAULT FALSE;

CREATE INDEX IF NOT EXISTS idx_sales_plan_visit_mismatch
  ON sales_plan ((visit_date_mismatch));

COMMIT;
