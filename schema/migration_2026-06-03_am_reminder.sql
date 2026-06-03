-- 2026-06-03: AM reminder table
-- AM bisa attach "note: TGL keterangan" di #REPORT untuk reminder masa depan.
-- Reminder fires H-1 sore (17:00) + H pagi (07:00) ke The ALLIANCE group.

CREATE TABLE IF NOT EXISTS am_reminder (
    id SERIAL PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES master_user(id) ON DELETE CASCADE,
    tanggal_reminder DATE NOT NULL,
    keterangan TEXT NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT now(),
    created_msg_id TEXT,
    source_report_date DATE,
    fired_h_minus_1 BOOLEAN NOT NULL DEFAULT FALSE,
    fired_h BOOLEAN NOT NULL DEFAULT FALSE,
    fired_at TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_am_reminder_tgl
    ON am_reminder (tanggal_reminder)
    WHERE NOT (fired_h_minus_1 AND fired_h);

CREATE INDEX IF NOT EXISTS idx_am_reminder_user
    ON am_reminder (user_id, tanggal_reminder DESC);
