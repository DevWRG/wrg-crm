-- ============================================================
-- WRG CRM — Schema Update v2
-- Tanggal  : 21 Mei 2026
-- Deskripsi: Tambahan kolom + tabel baru untuk:
--            - Plan/Report tracking & matching
--            - Last active group per user
--            - Holiday calendar
-- Jalankan : psql -U wrg_admin -d wrg_crm -f schema_update_v2.sql
-- ============================================================

-- Extension (idempotent)
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- ============================================================
-- 1. master_user — tambah last_active_group + rename nama_am
-- ============================================================

-- Rename nama_am → nama (lebih general, bukan AM-centric)
ALTER TABLE master_user RENAME COLUMN nama_am TO nama;

-- Tambah last_active_group: diisi otomatis tiap anggota kirim pesan dari grup
ALTER TABLE master_user
  ADD COLUMN IF NOT EXISTS last_active_group VARCHAR(100),
  ADD COLUMN IF NOT EXISTS last_active_at    TIMESTAMP;

-- ============================================================
-- 2. sales_plan — tambah kolom tracking report
-- ============================================================

ALTER TABLE sales_plan
  ADD COLUMN IF NOT EXISTS reported      BOOLEAN   DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS reported_at   TIMESTAMP,
  ADD COLUMN IF NOT EXISTS activity_id   INT       REFERENCES activity_log(id),
  ADD COLUMN IF NOT EXISTS is_late_plan  BOOLEAN   DEFAULT FALSE,
  -- jam submit plan (untuk deteksi > 08:00)
  ADD COLUMN IF NOT EXISTS submitted_at  TIMESTAMP DEFAULT NOW();

-- Index untuk query harian per user
CREATE INDEX IF NOT EXISTS idx_sp_user_tgl
  ON sales_plan(user_id, tanggal);

-- ============================================================
-- 3. activity_log — tambah kolom untuk unmatched report
-- ============================================================

ALTER TABLE activity_log
  ADD COLUMN IF NOT EXISTS plan_id        INT       REFERENCES sales_plan(id),
  ADD COLUMN IF NOT EXISTS is_unmatched   BOOLEAN   DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS match_score    NUMERIC(4,3); -- pg_trgm similarity score

-- ============================================================
-- 4. master_holiday — kalender libur nasional + custom
-- ============================================================

CREATE TABLE IF NOT EXISTS master_holiday (
  id          SERIAL       PRIMARY KEY,
  tanggal     DATE         UNIQUE NOT NULL,
  keterangan  VARCHAR(100) NOT NULL,  -- "Idul Fitri 1447H", "Libur Nasional", dll
  created_at  TIMESTAMP    DEFAULT NOW()
);

-- Seed: libur nasional 2026 (Indonesia)
INSERT INTO master_holiday (tanggal, keterangan) VALUES
  ('2026-01-01', 'Tahun Baru 2026'),
  ('2026-01-27', 'Isra Miraj'),
  ('2026-01-29', 'Tahun Baru Imlek'),
  ('2026-03-28', 'Hari Raya Nyepi'),
  ('2026-04-03', 'Wafat Isa Almasih'),
  ('2026-04-20', 'Idul Fitri 1447H Hari 1'),
  ('2026-04-21', 'Idul Fitri 1447H Hari 2'),
  ('2026-05-01', 'Hari Buruh Internasional'),
  ('2026-05-14', 'Kenaikan Isa Almasih'),
  ('2026-05-23', 'Hari Raya Waisak'),
  ('2026-06-01', 'Hari Lahir Pancasila'),
  ('2026-06-06', 'Idul Adha 1447H'),
  ('2026-06-26', 'Tahun Baru Islam 1448H'),
  ('2026-08-17', 'HUT Kemerdekaan RI'),
  ('2026-09-04', 'Maulid Nabi Muhammad SAW'),
  ('2026-12-25', 'Hari Raya Natal')
ON CONFLICT (tanggal) DO NOTHING;

-- ============================================================
-- 5. Helper view: daily_plan_report_status
--    Dipakai oleh wrg-daily untuk plan_check & report_check
-- ============================================================

CREATE OR REPLACE VIEW daily_plan_report_status AS
SELECT
  mu.id           AS user_id,
  mu.wa_number,
  mu.nama,
  mu.area,
  mu.role,
  mu.last_active_group,
  sp.tanggal,
  COUNT(sp.id)                                    AS total_plan,
  COUNT(sp.id) FILTER (WHERE sp.reported = TRUE)  AS total_reported,
  COUNT(sp.id) FILTER (WHERE sp.reported = FALSE) AS total_unreported,
  ARRAY_AGG(sp.customer_name ORDER BY sp.seq)
    FILTER (WHERE sp.reported = FALSE)            AS unreported_customers,
  MIN(sp.submitted_at)                            AS first_plan_at,
  MAX(sp.submitted_at)                            AS last_plan_at,
  BOOL_OR(sp.is_late_plan)                        AS has_late_plan
FROM master_user mu
LEFT JOIN sales_plan sp
  ON sp.user_id = mu.id
  AND sp.tanggal = CURRENT_DATE
WHERE mu.aktif = TRUE
GROUP BY mu.id, mu.wa_number, mu.nama, mu.area, mu.role,
         mu.last_active_group, sp.tanggal;

-- ============================================================
-- 6. Helper function: is_working_day(date)
--    TRUE = Senin–Jumat bukan libur nasional
--    FALSE = Sabtu, Minggu, atau libur
-- ============================================================

CREATE OR REPLACE FUNCTION is_working_day(check_date DATE DEFAULT CURRENT_DATE)
RETURNS BOOLEAN AS $$
BEGIN
  -- Sabtu = 6, Minggu = 0
  IF EXTRACT(DOW FROM check_date) IN (0, 6) THEN
    RETURN FALSE;
  END IF;
  -- Cek libur nasional
  IF EXISTS (SELECT 1 FROM master_holiday WHERE tanggal = check_date) THEN
    RETURN FALSE;
  END IF;
  RETURN TRUE;
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- Verifikasi
-- ============================================================

-- Cek semua tabel ada
SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'public'
ORDER BY table_name;

-- Cek kolom baru di sales_plan
SELECT column_name, data_type, column_default
FROM information_schema.columns
WHERE table_name = 'sales_plan'
ORDER BY ordinal_position;

-- Test is_working_day
SELECT
  is_working_day('2026-05-21') AS kamis_biasa,    -- TRUE
  is_working_day('2026-05-23') AS sabtu,           -- FALSE
  is_working_day('2026-05-25') AS waisak;          -- FALSE
