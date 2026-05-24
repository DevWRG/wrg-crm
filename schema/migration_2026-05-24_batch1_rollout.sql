-- ============================================================
-- WRG CRM — Batch 1 Rollout (2026-05-24)
-- ============================================================
-- Soft go-live: bot WA live di semua grup tapi cron reminder
-- (plan_check / report_check / daily_summary) cuma target subset
-- karyawan. AM & Teknisi DITUNDA ke batch 2 sampai format edukasi
-- selesai untuk role-role tsb.
--
-- Effect: cron reminder hari kerja target 37 orang non-AM/non-Teknisi
--         (turun dari 54 wajib default).
--
-- Idempotent: bisa di-rerun aman.
-- Apply ke prod DB:
--   psql -U wrg_admin -d wrg_crm_prod -f schema/migration_2026-05-24_batch1_rollout.sql
-- ============================================================

BEGIN;

-- AM (12 orang) — batch 2
UPDATE master_user SET wajib_plan_report = FALSE WHERE role = 'AM';

-- Teknisi (5 orang) — batch 2
UPDATE master_user SET wajib_plan_report = FALSE WHERE role = 'Teknisi';

-- Verify
SELECT role,
       COUNT(*) AS total,
       COUNT(*) FILTER (WHERE wajib_plan_report) AS batch1_wajib,
       COUNT(*) FILTER (WHERE NOT wajib_plan_report) AS exempt
FROM master_user
WHERE aktif
GROUP BY role
ORDER BY role;

COMMIT;

-- ============================================================
-- Reversal kalau batch 2 ready (sertakan AM + Teknisi):
--
--   UPDATE master_user SET wajib_plan_report = TRUE
--   WHERE role IN ('AM', 'Teknisi');
-- ============================================================
