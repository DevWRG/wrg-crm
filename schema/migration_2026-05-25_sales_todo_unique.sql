-- ============================================================
-- WRG CRM — sales_todo unique constraint refactor (2026-05-25)
-- ============================================================
-- Day 1 prod issue: tiap re-submit #PLAN bikin row baru karena
-- ON CONFLICT pakai message_id (per-message dedup). User yg
-- re-submit setelah dapat false alarm reminder → duplicate row
-- dgn late=TRUE menutupi yg ontime.
--
-- Fix:
-- 1. Drop UNIQUE (user_id, tanggal, message_id) → too granular
-- 2. Drop UNIQUE (message_id) → redundant (processed_message
--    table sudah handle msg dedup)
-- 3. Add UNIQUE (user_id, tanggal) → 1 row per user per hari
--
-- Apply ke prod DB:
--   psql -U wrg_admin -d wrg_crm_prod -f schema/migration_2026-05-25_sales_todo_unique.sql
-- ============================================================

BEGIN;

-- Drop old over-granular constraint
ALTER TABLE sales_todo DROP CONSTRAINT IF EXISTS sales_todo_user_tgl_unique;

-- Drop redundant message_id unique (replaced by non-unique index for lookups)
ALTER TABLE sales_todo DROP CONSTRAINT IF EXISTS sales_todo_message_id_key;
CREATE INDEX IF NOT EXISTS idx_st_message_id ON sales_todo(message_id);

-- New: one row per user per day
ALTER TABLE sales_todo ADD CONSTRAINT sales_todo_user_tgl_unique UNIQUE (user_id, tanggal);

-- Cleanup any pre-existing duplicates today (keep earliest submission per user/day)
DELETE FROM sales_todo
WHERE id IN (
  SELECT id FROM (
    SELECT id, ROW_NUMBER() OVER (PARTITION BY user_id, tanggal ORDER BY submitted_at ASC) AS rn
    FROM sales_todo
  ) ranked
  WHERE rn > 1
);

COMMIT;

-- Verify
SELECT 'unique constraint' AS check, indexname
FROM pg_indexes
WHERE tablename='sales_todo' AND indexname LIKE '%user_tgl%';
