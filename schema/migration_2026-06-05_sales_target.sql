-- Sales targets per cabang + per area (West/East).
-- Cabang names normalized untuk match Accurate's branch + master_user.cabang.

CREATE TABLE IF NOT EXISTS sales_target_branch (
    cabang        TEXT PRIMARY KEY,
    area          TEXT NOT NULL,          -- 'West' or 'East'
    total_yearly  NUMERIC(15, 2) NOT NULL,
    monthly       NUMERIC(15, 2) NOT NULL,
    notes         TEXT,
    updated_at    TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS sales_target_area (
    area          TEXT PRIMARY KEY,        -- 'West' or 'East'
    yearly        NUMERIC(15, 2) NOT NULL,
    monthly       NUMERIC(15, 2) NOT NULL,
    weekly        NUMERIC(15, 2) NOT NULL,
    daily         NUMERIC(15, 2) NOT NULL,
    updated_at    TIMESTAMP NOT NULL DEFAULT now()
);

-- Seed cabang targets (2026).
-- East: Java Timur + Bali Nusa cluster. West: outside JaTim.
INSERT INTO sales_target_branch (cabang, area, total_yearly, monthly) VALUES
  ('MADURA',       'East', 13808000000, 1150666666.67),
  ('JEMBER',       'East', 13808000000, 1150666666.67),
  ('MALANG',       'East',  9500000000,  791666666.67),
  ('NTB',          'East',  6389000000,  532416666.67),
  ('NTT',          'East',  6205000000,  517083333.33),
  ('BALI',         'East',  5496000000,  458000000.00),
  ('KEDIRI',       'East', 11720000000,  976666666.67),
  ('SURABAYA 2',   'West',  8686000000,  723833333.33),
  ('MADIUN',       'West', 12987000000, 1082250000.00),
  ('LAMONGAN',     'West', 10492000000,  874333333.33),
  ('JAWA TENGAH',  'West',  5297000000,  441416666.67),
  ('PALEMBANG',    'West',  6502000000,  541833333.33),
  ('JAWA BARAT',   'West',  7380000000,  615000000.00),
  ('JAKARTA',      'West',  6732000000,  561000000.00)
ON CONFLICT (cabang) DO UPDATE SET
  area=EXCLUDED.area, total_yearly=EXCLUDED.total_yearly,
  monthly=EXCLUDED.monthly, updated_at=now();

-- Seed area targets (West/East aggregate)
INSERT INTO sales_target_area (area, yearly, monthly, weekly, daily) VALUES
  ('West', 58076000000, 4839666667, 1116846154, 223369231),
  ('East', 66926000000, 5577166667, 1287038462, 257407692)
ON CONFLICT (area) DO UPDATE SET
  yearly=EXCLUDED.yearly, monthly=EXCLUDED.monthly,
  weekly=EXCLUDED.weekly, daily=EXCLUDED.daily, updated_at=now();

GRANT ALL ON sales_target_branch, sales_target_area TO wrg_admin;
