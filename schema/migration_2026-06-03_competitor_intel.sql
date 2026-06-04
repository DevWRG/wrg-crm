-- Competitor Intel: extracted dari activity_log.hasil via LLM (OpenRouter).
-- One activity_log row bisa produce 0..N competitor_intel rows.

CREATE TABLE IF NOT EXISTS competitor_intel (
    id SERIAL PRIMARY KEY,
    activity_id INTEGER NOT NULL REFERENCES activity_log(id) ON DELETE CASCADE,
    user_id INTEGER REFERENCES master_user(id) ON DELETE SET NULL,
    customer_name TEXT,
    tanggal DATE NOT NULL,
    vendor TEXT,
    produk TEXT,
    produk_kategori TEXT,
    harga_text TEXT,
    harga_numeric NUMERIC(14, 2),
    konteks TEXT,
    extracted_at TIMESTAMP NOT NULL DEFAULT now(),
    extraction_model TEXT
);

CREATE INDEX IF NOT EXISTS idx_ci_tanggal ON competitor_intel (tanggal DESC);
CREATE INDEX IF NOT EXISTS idx_ci_vendor  ON competitor_intel (vendor);
CREATE INDEX IF NOT EXISTS idx_ci_user    ON competitor_intel (user_id);
CREATE INDEX IF NOT EXISTS idx_ci_act     ON competitor_intel (activity_id);

-- Tracking extracted activity_log ids — supaya gak re-extract same row.
-- Empty result (LLM return [] / no competitor mentioned) tetap di-track via empty rowset
-- + companion table competitor_extraction_state.
CREATE TABLE IF NOT EXISTS competitor_extraction_state (
    activity_id INTEGER PRIMARY KEY REFERENCES activity_log(id) ON DELETE CASCADE,
    extracted_at TIMESTAMP NOT NULL DEFAULT now(),
    n_mentions INTEGER NOT NULL DEFAULT 0,
    extraction_model TEXT
);

GRANT ALL ON competitor_intel TO wrg_admin;
GRANT USAGE, SELECT ON SEQUENCE competitor_intel_id_seq TO wrg_admin;
GRANT ALL ON competitor_extraction_state TO wrg_admin;
