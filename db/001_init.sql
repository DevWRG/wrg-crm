-- WRG CRM — initial schema (v4.0)
-- Run as superuser; idempotent where possible.

CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- ── master_user ────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS master_user (
  id          SERIAL PRIMARY KEY,
  wa_number   TEXT UNIQUE NOT NULL,
  nama_am     TEXT NOT NULL,
  area        TEXT,
  role        TEXT NOT NULL DEFAULT 'AM',
  aktif       BOOLEAN NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── sales_plan ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS sales_plan (
  id            SERIAL PRIMARY KEY,
  user_id       INT NOT NULL REFERENCES master_user(id) ON DELETE CASCADE,
  tanggal       DATE NOT NULL,
  customer_name TEXT NOT NULL,
  tujuan        TEXT,
  goal          TEXT,
  seq           INT NOT NULL DEFAULT 1,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (user_id, tanggal, customer_name)
);
CREATE INDEX IF NOT EXISTS idx_sales_plan_tanggal ON sales_plan(tanggal);

-- ── pipeline_tracker ───────────────────────────────────────
CREATE TABLE IF NOT EXISTS pipeline_tracker (
  id            SERIAL PRIMARY KEY,
  user_id       INT NOT NULL REFERENCES master_user(id) ON DELETE CASCADE,
  customer_name TEXT NOT NULL,
  nama_am       TEXT,
  area          TEXT,
  produk        TEXT,
  nilai_deal    NUMERIC(15,2),
  stage         INT NOT NULL DEFAULT 1 CHECK (stage BETWEEN 1 AND 5),
  status        TEXT NOT NULL DEFAULT 'Cold'
                  CHECK (status IN ('Cold','Warm','Hot','Won','Lost')),
  note          TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_pipeline_user ON pipeline_tracker(user_id);
CREATE INDEX IF NOT EXISTS idx_pipeline_cust_trgm
  ON pipeline_tracker USING gin (customer_name gin_trgm_ops);

-- ── activity_log ───────────────────────────────────────────
CREATE TABLE IF NOT EXISTS activity_log (
  id            SERIAL PRIMARY KEY,
  user_id       INT NOT NULL REFERENCES master_user(id) ON DELETE CASCADE,
  pipeline_id   INT REFERENCES pipeline_tracker(id) ON DELETE SET NULL,
  customer_name TEXT NOT NULL,
  tanggal       DATE NOT NULL,
  tujuan        TEXT,
  hasil         TEXT,
  next_action   TEXT,
  source        TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_activity_tanggal ON activity_log(tanggal);
CREATE INDEX IF NOT EXISTS idx_activity_user ON activity_log(user_id);

-- ── deal_closed ────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS deal_closed (
  id             SERIAL PRIMARY KEY,
  pipeline_id    INT REFERENCES pipeline_tracker(id) ON DELETE SET NULL,
  user_id        INT NOT NULL REFERENCES master_user(id) ON DELETE CASCADE,
  customer_name  TEXT NOT NULL,
  nilai_deal     NUMERIC(15,2),
  produk         TEXT,
  tanggal_closed DATE NOT NULL,
  catatan        TEXT,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── audit_log ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS audit_log (
  id              SERIAL PRIMARY KEY,
  wa_number       TEXT,
  nama_am         TEXT,
  hashtag         TEXT NOT NULL,
  status          TEXT NOT NULL,
  customer_count  INT NOT NULL DEFAULT 0,
  payload         JSONB,
  error_detail    TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_audit_created ON audit_log(created_at DESC);

-- ── pending_confirm (for #UPDATE confirm flow) ─────────────
CREATE TABLE IF NOT EXISTS pending_confirm (
  id           SERIAL PRIMARY KEY,
  wa_number    TEXT NOT NULL,
  hashtag      TEXT NOT NULL,
  candidates   JSONB NOT NULL,
  payload      JSONB NOT NULL,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  expires_at   TIMESTAMPTZ NOT NULL DEFAULT (NOW() + INTERVAL '10 minutes')
);
CREATE INDEX IF NOT EXISTS idx_pending_wa ON pending_confirm(wa_number, expires_at DESC);
