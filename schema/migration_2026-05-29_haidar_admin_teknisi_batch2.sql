-- ============================================================
-- WRG CRM — Defer Haidar (Admin Teknisi) ke batch 2 (2026-05-29)
-- ============================================================
-- Haidar Maut (id=39) posisinya "Admin Teknisi" — secara role di
-- master_user dia "Admin" jadi gak ke-cover migration batch 1 sebelumnya
-- yang exclude role='AM'/'Teknisi'. Tapi job function-nya support tim
-- Teknisi, dan dia gak punya last_active_group (gak di-invite ke grup mana
-- pun) → reminder gak nyampe. Defer ke batch 2 bareng Teknisi family.
--
-- Effect: cron reminder turun dari 38 → 37 wajib. Haidar boleh aja submit
-- voluntarily kalau mau, tapi gak dapat reminder & gak masuk no-plan list.
--
-- Idempotent.
-- Apply: psql -U wrg_admin -d wrg_crm_prod -f schema/migration_2026-05-29_haidar_admin_teknisi_batch2.sql
-- ============================================================

BEGIN;

UPDATE master_user
SET wajib_plan_report = FALSE
WHERE id = 39 AND nama = 'Haidar Maut';

-- Verify
SELECT id, nama, panggilan, role, posisi, wajib_plan_report
FROM master_user WHERE id = 39;

-- Batch 1 wajib count (should now be 37)
SELECT COUNT(*) AS batch1_wajib
FROM master_user
WHERE aktif AND wajib_plan_report;

COMMIT;

-- ============================================================
-- Reversal (kalau Haidar nanti di-invite ke grup & masuk batch):
--
--   UPDATE master_user SET wajib_plan_report = TRUE WHERE id = 39;
-- ============================================================
