-- Accurate Online sales sync — POC schema.
-- Sumber data: zeus.accurate.id/accurate/api/sales-invoice/* (DB id 1664470).

CREATE TABLE IF NOT EXISTS accurate_customer (
    id              INTEGER PRIMARY KEY,           -- Accurate customer.id
    no              TEXT,                          -- customerNo
    name            TEXT,
    branch_id       INTEGER,
    last_synced_at  TIMESTAMP NOT NULL DEFAULT now(),
    raw             JSONB
);
CREATE INDEX IF NOT EXISTS idx_ac_branch ON accurate_customer (branch_id);

CREATE TABLE IF NOT EXISTS accurate_branch (
    id              INTEGER PRIMARY KEY,
    name            TEXT,
    suspended       BOOLEAN NOT NULL DEFAULT FALSE,
    raw             JSONB
);

CREATE TABLE IF NOT EXISTS accurate_item (
    id              INTEGER PRIMARY KEY,
    no              TEXT,
    name            TEXT,
    category        TEXT,
    unit_price      NUMERIC(16, 2),
    raw             JSONB
);

CREATE TABLE IF NOT EXISTS accurate_invoice (
    id                 INTEGER PRIMARY KEY,            -- Accurate sales-invoice.id
    number             TEXT,                            -- invoice number
    customer_id        INTEGER REFERENCES accurate_customer(id) ON DELETE SET NULL,
    branch_id          INTEGER REFERENCES accurate_branch(id) ON DELETE SET NULL,
    tanggal            DATE NOT NULL,
    taxable_amount     NUMERIC(16, 2),
    tax_amount         NUMERIC(16, 2),
    total              NUMERIC(16, 2),                  -- grand total
    paid               NUMERIC(16, 2),
    outstanding        NUMERIC(16, 2),
    status             TEXT,                            -- DRAFT/POSTED/PAID/CANCELLED
    last_synced_at     TIMESTAMP NOT NULL DEFAULT now(),
    raw                JSONB                            -- full response
);
CREATE INDEX IF NOT EXISTS idx_ai_tgl ON accurate_invoice (tanggal DESC);
CREATE INDEX IF NOT EXISTS idx_ai_cust ON accurate_invoice (customer_id);
CREATE INDEX IF NOT EXISTS idx_ai_branch ON accurate_invoice (branch_id);

CREATE TABLE IF NOT EXISTS accurate_invoice_item (
    id                 SERIAL PRIMARY KEY,
    invoice_id         INTEGER NOT NULL REFERENCES accurate_invoice(id) ON DELETE CASCADE,
    item_id            INTEGER REFERENCES accurate_item(id) ON DELETE SET NULL,
    line_no            INTEGER,
    qty                NUMERIC(14, 4),
    unit               TEXT,
    unit_price         NUMERIC(16, 2),
    discount_amount    NUMERIC(16, 2),
    total              NUMERIC(16, 2),
    raw                JSONB
);
CREATE INDEX IF NOT EXISTS idx_aii_inv ON accurate_invoice_item (invoice_id);
CREATE INDEX IF NOT EXISTS idx_aii_item ON accurate_invoice_item (item_id);

-- Sync state — tracking last-seen per entity for incremental polling.
CREATE TABLE IF NOT EXISTS accurate_sync_state (
    entity              TEXT PRIMARY KEY,               -- 'sales-invoice', 'customer', 'item', 'branch'
    last_synced_at      TIMESTAMP,
    last_max_modified   TIMESTAMP,                      -- max(lastUpdate) yang diproses
    next_offset         INTEGER NOT NULL DEFAULT 0,
    last_run_ok         BOOLEAN,
    last_run_summary    JSONB
);

GRANT ALL ON accurate_customer, accurate_branch, accurate_item,
             accurate_invoice, accurate_invoice_item, accurate_sync_state TO wrg_admin;
GRANT USAGE, SELECT ON SEQUENCE accurate_invoice_item_id_seq TO wrg_admin;
