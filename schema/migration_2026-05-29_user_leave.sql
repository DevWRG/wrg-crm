-- ============================================================
-- WRG CRM — Leave Tracking (2026-05-29)
-- ============================================================
-- Track ijin/sakit/cuti per user per tanggal supaya:
--   1. plan_check / report_check / daily_summary skip user on leave
--   2. dashboard tampilkan "ijin" badge (bukan "no plan")
--   3. denominator metrics exclude on-leave (gak distort % selesai)
--
-- Data entry: SQL INSERT manual oleh admin. Helper script (kalau
-- volumes naik) bisa di-add nanti.
--
-- Idempotent.
-- Apply: psql -U wrg_admin -d <db> -f schema/migration_2026-05-29_user_leave.sql
-- ============================================================

BEGIN;

CREATE TABLE IF NOT EXISTS user_leave (
  id          SERIAL PRIMARY KEY,
  user_id     INTEGER NOT NULL REFERENCES master_user(id) ON DELETE CASCADE,
  start_date  DATE NOT NULL,
  end_date    DATE NOT NULL,
  jenis       TEXT NOT NULL CHECK (jenis IN ('sakit','cuti','ijin')),
  keterangan  TEXT,
  created_at  TIMESTAMP DEFAULT NOW(),
  CONSTRAINT chk_date_range CHECK (end_date >= start_date)
);

CREATE INDEX IF NOT EXISTS idx_user_leave_lookup
  ON user_leave (user_id, start_date, end_date);

-- Stable so optimizer can inline in queries.
CREATE OR REPLACE FUNCTION is_on_leave(p_user_id INTEGER, p_date DATE)
RETURNS BOOLEAN
LANGUAGE SQL STABLE AS $$
  SELECT EXISTS (
    SELECT 1 FROM user_leave
    WHERE user_id = p_user_id
      AND p_date BETWEEN start_date AND end_date
  );
$$;

-- Convenience view: who's on leave today (for dashboard or quick checks)
CREATE OR REPLACE VIEW v_leave_today AS
  SELECT mu.id AS user_id, mu.nama, mu.panggilan, mu.role,
         ul.jenis, ul.start_date, ul.end_date, ul.keterangan
  FROM user_leave ul
  JOIN master_user mu ON mu.id = ul.user_id
  WHERE CURRENT_DATE BETWEEN ul.start_date AND ul.end_date;

COMMIT;

-- ============================================================
-- Sample data-entry patterns:
--
-- One-day sick leave:
--   INSERT INTO user_leave (user_id, start_date, end_date, jenis, keterangan)
--   VALUES (40, '2026-05-29', '2026-05-29', 'sakit', 'flu');
--
-- Multi-day cuti:
--   INSERT INTO user_leave (user_id, start_date, end_date, jenis, keterangan)
--   VALUES (54, '2026-06-02', '2026-06-04', 'cuti', 'cuti tahunan');
--
-- Cancel/correct leave:
--   DELETE FROM user_leave WHERE id = <id>;
-- ============================================================
