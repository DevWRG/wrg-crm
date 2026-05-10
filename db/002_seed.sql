-- Minimal seed data for smoke testing.
-- WA numbers use international format without '+'.

INSERT INTO master_user (wa_number, nama_am, area, role) VALUES
  ('6281234567890', 'Husni',       'HQ',        'ADMIN'),
  ('6281111111111', 'Andi Pratama', 'Jakarta',  'AM'),
  ('6282222222222', 'Budi Santoso', 'Surabaya', 'AM'),
  ('6283333333333', 'Citra Dewi',   'Bandung',  'AM')
ON CONFLICT (wa_number) DO NOTHING;

-- Seed an existing pipeline for #UPDATE/#REPORT fuzzy-match tests
INSERT INTO pipeline_tracker (user_id, customer_name, nama_am, area, produk, stage, status, note)
SELECT id, 'RS Husada Utama', nama_am, area, 'USG Seri 500', 2, 'Warm', 'Initial seed'
FROM master_user WHERE wa_number = '6281111111111'
ON CONFLICT DO NOTHING;
