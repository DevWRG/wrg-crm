-- ============================================================
-- WRG CRM — sales_todo table (Schema Update v3)
-- Tanggal  : 21 Mei 2026
-- Deskripsi: Tabel untuk #PLAN format todo-list (non-AM users).
--            AM tetap pakai sales_plan (customer-visit format).
--            Routing oleh wrg-inbound.sh berdasarkan master_user.role.
-- ============================================================

CREATE TABLE IF NOT EXISTS sales_todo (
  id            SERIAL       PRIMARY KEY,
  user_id       INT          NOT NULL REFERENCES master_user(id) ON DELETE CASCADE,
  tanggal       DATE         NOT NULL,
  items         JSONB        NOT NULL,        -- ["item 1", "item 2", ...]
  total_items   INT          GENERATED ALWAYS AS (jsonb_array_length(items)) STORED,
  raw_body      TEXT,                          -- original WA message body
  message_id    TEXT         UNIQUE,           -- link ke processed_message
  submitted_at  TIMESTAMP    DEFAULT NOW(),
  is_late_plan  BOOLEAN      DEFAULT FALSE,    -- > 08:00 saat submit hari ini
  reported      BOOLEAN      DEFAULT FALSE,
  reported_at   TIMESTAMP,
  created_at    TIMESTAMP    DEFAULT NOW(),
  -- Mencegah double-submit todo list sama oleh user yang sama di tanggal sama
  -- (selain idempotency via message_id, ini guard kalau msg_id mismatch)
  CONSTRAINT sales_todo_user_tgl_unique UNIQUE (user_id, tanggal, message_id)
);

CREATE INDEX IF NOT EXISTS idx_st_user_tgl
  ON sales_todo(user_id, tanggal);

CREATE INDEX IF NOT EXISTS idx_st_reported
  ON sales_todo(reported, tanggal);

-- ============================================================
-- View gabungan: daily_plan_status_all
-- Plan/Report tracking lintas AM (sales_plan) + non-AM (sales_todo).
-- Dipakai oleh wrg-daily.sh plan_check & report_check.
-- ============================================================

CREATE OR REPLACE VIEW daily_plan_status_all AS
SELECT
  mu.id              AS user_id,
  mu.wa_number,
  mu.nama,
  mu.panggilan,
  mu.role,
  mu.cabang,
  mu.last_active_group,
  CURRENT_DATE       AS tanggal,
  -- AM: sales_plan rows
  COALESCE(sp_stats.total_plan, 0)        AS total_plan,
  COALESCE(sp_stats.total_unreported, 0)  AS total_unreported,
  sp_stats.unreported_customers,
  -- Non-AM: sales_todo (1 row per submit, ada items array)
  COALESCE(st_stats.total_todo, 0)        AS total_todo,
  COALESCE(st_stats.total_items, 0)       AS total_todo_items,
  -- Submission times
  COALESCE(sp_stats.first_plan_at, st_stats.first_todo_at) AS first_submit_at,
  COALESCE(sp_stats.last_plan_at, st_stats.last_todo_at)   AS last_submit_at,
  -- Has-plan flag (untuk filter "udah submit apapun hari ini")
  (COALESCE(sp_stats.total_plan, 0) > 0
    OR COALESCE(st_stats.total_todo, 0) > 0) AS has_submission,
  -- Late?
  COALESCE(sp_stats.has_late, st_stats.has_late, FALSE) AS has_late_plan
FROM master_user mu
LEFT JOIN LATERAL (
  SELECT
    COUNT(*)                                    AS total_plan,
    COUNT(*) FILTER (WHERE reported = FALSE)    AS total_unreported,
    ARRAY_AGG(customer_name ORDER BY seq)
      FILTER (WHERE reported = FALSE)           AS unreported_customers,
    MIN(submitted_at)                           AS first_plan_at,
    MAX(submitted_at)                           AS last_plan_at,
    BOOL_OR(is_late_plan)                       AS has_late
  FROM sales_plan
  WHERE user_id = mu.id AND tanggal = CURRENT_DATE
) sp_stats ON TRUE
LEFT JOIN LATERAL (
  SELECT
    COUNT(*)                                    AS total_todo,
    SUM(total_items)                            AS total_items,
    MIN(submitted_at)                           AS first_todo_at,
    MAX(submitted_at)                           AS last_todo_at,
    BOOL_OR(is_late_plan)                       AS has_late
  FROM sales_todo
  WHERE user_id = mu.id AND tanggal = CURRENT_DATE
) st_stats ON TRUE
WHERE mu.aktif = TRUE;

-- ============================================================
-- Verifikasi
-- ============================================================
SELECT 'sales_todo created' AS msg,
       (SELECT COUNT(*) FROM information_schema.columns WHERE table_name = 'sales_todo') AS columns;
