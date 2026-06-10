-- ============================================================
-- WRG CRM — Master Data Seed
-- Tanggal  : 21 Mei 2026
-- Deskripsi: Seed master_user (semua karyawan) + master_territory (area AM)
-- Jalankan : psql -U wrg_admin -d wrg_crm -f master_data_seed.sql
-- ============================================================

-- ============================================================
-- REFERENSI ROLE
-- ============================================================
-- HOD              → exempt dari plan/report (wajib = FALSE)
-- AM               → wajib plan/report, punya territory
-- Semua lainnya    → wajib plan/report, tidak punya territory

-- ============================================================
-- 1. TRUNCATE (hati-hati — hanya untuk fresh seed)
-- ============================================================
-- TRUNCATE master_user RESTART IDENTITY CASCADE;

-- ============================================================
-- 1.5. ALTER master_user — tambah kolom baru (HARUS sebelum INSERT)
-- Note: dipindah ke sini dari section 3 karena INSERT di section 2
-- referensi kolom panggilan/posisi/cabang/wajib_plan_report.
-- Original file punya bug ordering — fix 2026-05-21.
-- ============================================================
ALTER TABLE master_user
  ADD COLUMN IF NOT EXISTS panggilan          VARCHAR(50),
  ADD COLUMN IF NOT EXISTS posisi             VARCHAR(100),
  ADD COLUMN IF NOT EXISTS cabang             VARCHAR(50),
  ADD COLUMN IF NOT EXISTS wajib_plan_report  BOOLEAN DEFAULT TRUE;

-- ============================================================
-- 2. INSERT master_user
-- ============================================================
-- Kolom: wa_number, nama, panggilan, posisi, cabang, role, wajib_plan_report, aktif

INSERT INTO master_user (wa_number, nama, panggilan, posisi, cabang, role, wajib_plan_report, aktif) VALUES

-- ── HOD (exempt) ────────────────────────────────────────────
('6285733048855', 'Muhammad Husni Mubarrok',    'Husni',  'HOD BD & GA',               'Pusat', 'HOD', FALSE, TRUE),
('6281358857217', 'Ahmad Muzaqin Mufid',         'Mufid',  'HOD Business IVD',          'Pusat', 'HOD', FALSE, TRUE),
('6281336530830', 'Arif Rahman Hakim',           'Arman',  'HOD Business Medical',      'Pusat', 'HOD', FALSE, TRUE),
('6281332170240', 'Muhid',                       'Muhid',  'HOD Aftersales',            'Pusat', 'HOD', FALSE, TRUE),
('6281248476085', 'Ika Purwaningsari',           'Ika',    'HOD Finance & Supply Chain','Pusat', 'HOD', FALSE, TRUE),
('6281333029926', 'Nurul Fadhilah',              'Fafa',   'HOD Accounting',            'Pusat', 'HOD', FALSE, TRUE),
('6285704142027', 'Rocky Gunawan',               'Rocky',  'HOD Sales East Area',       'Pusat', 'HOD', FALSE, TRUE),
('6281330088773', 'Yogi Nugroho',                'Yogi',   'HOD Sales West Area',       'Pusat', 'HOD', FALSE, TRUE),

-- ── AM (wajib plan/report + punya territory) ────────────────
('6282131121079', 'Akhmad Iqbal Asshiddiqi',    'Iqbal',  'AM', 'Cirebon',             'AM',  TRUE, TRUE),
('6287860059055', 'Angga Adhitya Bramansyah',   'Angga',  'AM', 'Madura',              'AM',  TRUE, TRUE),
('6285778991341', 'Ari Kurnia Yuda',            'Ari',    'AM', 'Bali',                'AM',  TRUE, TRUE),
('6289999303274', 'Aulia Ghozalina',            'Aulia',  'AM', 'Kediri',              'AM',  TRUE, TRUE),
('6281230791487', 'Choirul Huda Setyawan',      'Irul',   'AM', 'Lamongan',            'AM',  TRUE, TRUE),
('6285864407545', 'Firmansyah',                 'Firman', 'AM', 'Malang',              'AM',  TRUE, TRUE),
('6282178705010', 'Luri Anpulan Mulia Pohan',   'Luri',   'AM', 'Jember',              'AM',  TRUE, TRUE),
('6282326239278', 'Miftahul Wildha Saputra',    'Wildha', 'AM', 'Madiun',              'AM',  TRUE, TRUE),
('6282273757478', 'Muhammad Arif Prayogi',      'Arif',   'AM', 'SBY 2',               'AM',  TRUE, TRUE),
('6281228983310', 'Muhammad Prayugo',           'Yugo',   'AM', 'Palembang',           'AM',  TRUE, TRUE),
('6282979472943', 'Moch. Sidqi Settyawan',      'Sidqi',  'AM', 'Solo & Yogyakarta',   'AM',  TRUE, TRUE),
('6285878287784', 'Vicky Adi Nugroho',          'Vicky',  'AM', 'NTB',                 'AM',  TRUE, TRUE),

-- ── Operasional & Support (wajib plan/report) ───────────────
('6288810361879', 'Abib Robi Nurhamsa',         'Abib',   'Admin Sales & Penawaran',   'Pusat',  'Admin',       TRUE, TRUE),
('6285856613533', 'Achmad Fahruddin Arrazzy',   'Boni',   'Logistik',                  'Pusat',  'Logistik',    TRUE, TRUE),
('6289580690991', 'Achmad Miftahul Munir',      'Munir',  'Kirim Tagih',               'SBY 2',  'Operasional', TRUE, TRUE),
('6281216995625', 'Achmad Surya Nugraha',       'Surya',  'Kirim Tagih',               'Jember', 'Operasional', TRUE, TRUE),
('6285755706014', 'Agus Joni Setiawan',         'Agus',   'Kirim Tagih & Admin Cabang','Madiun', 'Operasional', TRUE, TRUE),
('6289541825940', 'Ahmad Abdul Hanif',          'Hanif',  'Kirim Tagih',               'Madura', 'Operasional', TRUE, TRUE),
('6285773000833', 'Ayu Karisma',                'Ayu',    'AR',                        'Pusat',  'Finance',     TRUE, TRUE),
('6289834510670', 'Baginda Naufal',             'Baginda','Kirim Tagih & Admin Cabang','NTB',    'Operasional', TRUE, TRUE),
('6285262444989', 'Claudya Fikayanti',          'Claudya','Purchasing',                'Pusat',  'Purchasing',  TRUE, TRUE),
('6285648575326', 'Denys Chandra Irawan',       'Denys',  'Admin Gudang',              'Pusat',  'Admin',       TRUE, TRUE),
('6285257118107', 'Diana Agustina',             'Diana',  'Admin Shipping',            'Pusat',  'Admin',       TRUE, TRUE),
('6281234504296', 'Dimas Bagus Prakoso',        'Dimas',  'Kirim Tagih',               'Jember', 'Operasional', TRUE, TRUE),
('6289605483157', 'Dito Anggara',               'Dito',   'GA',                        'Pusat',  'GA',          TRUE, TRUE),
('6285233838478', 'Elok Kurniawati',            'Elok',   'Admin Cabang',              'Jember', 'Admin',       TRUE, TRUE),
('6285656002508', 'Maskhanudin',                'Udin',   'Kirim Tagih',               'SBY 2',  'Operasional', TRUE, TRUE),
('6285331769132', 'Enggar Robbi Novianto',      'Enggar', 'Teknisi',                   'Pusat',  'Teknisi',     TRUE, TRUE),
('6289532825558', 'Fanessa Rahayu Putri',       'Fanessa','Accounting',                'Pusat',  'Accounting',  TRUE, TRUE),
('6289863386350', 'Galih Aldy Prasetyo',        'Galih',  'Teknisi',                   'Pusat',  'Teknisi',     TRUE, TRUE),
('6282229891108', 'Haidar Maut',                'Haidar', 'Admin Teknisi',             'Pusat',  'Admin',       TRUE, TRUE),
('6285742339221', 'Hanasta Januar Alfitri',     'Anas',   'Kirim Tagih',               'Madiun', 'Operasional', TRUE, TRUE),
('6289602081239', 'Haris Zul Hilmi',            'Haris',  'Kirim Tagih',               'Malang', 'Operasional', TRUE, TRUE),
('6288217207854', 'Ibnu Mashabi',               'Ibnu',   'Kirim Tagih & Admin Cabang','Jakarta','Operasional', TRUE, TRUE),
('6289688034365', 'Isteffany Chindyliani',      'Chindy', 'Admin Distribusi',          'Pusat',  'Admin',       TRUE, TRUE),
('6282277400079', 'Kadek Heriadi',              'Adi',    'Kirim Tagih',               'SBY 2',  'Operasional', TRUE, TRUE),
('6282336177459', 'Karib Fardian',              'Karib',  'Kirim Tagih & Admin Cabang','Malang', 'Operasional', TRUE, TRUE),
('6281336663933', 'Martin Adi Pratama',         'Martin', 'Teknisi',                   'Pusat',  'Teknisi',     TRUE, TRUE),
('6285853772380', 'Maslikha Purnamasari',       'Sari',   'Admin Fakturis',            'Pusat',  'Admin',       TRUE, TRUE),
('6285755602302', 'Mochamad Jasyim',            'Jasyim', 'Admin Sales & Penawaran',   'Pusat',  'Admin',       TRUE, TRUE),
('6281232554911', 'Ekba Prastia',               'Ekba',   'Kirim Tagih & Admin Cabang','SBY 2',  'Operasional', TRUE, TRUE),
('6282331319794', 'Muhammad Halim Prayogo',     'Halim',  'Teknisi',                   'Pusat',  'Teknisi',     TRUE, TRUE),
('6282132233560', 'Najmi Putri Harini',         'Puput',  'Admin Sales & Penawaran',   'Pusat',  'Admin',       TRUE, TRUE),
('6282229459206', 'Navisa Tristiana Ramadini',  'Navisa', 'AR',                        'Pusat',  'Finance',     TRUE, TRUE),
('6282140803327', 'Nopa Andriawan',             'Nopa',   'Teknisi',                   'Pusat',  'Teknisi',     TRUE, TRUE),
('6285649206602', 'Nungky Hendarti',            'Nungky', 'Admin Cabang',              'Kediri', 'Admin',       TRUE, TRUE),
('6287742151755', 'Nur Rahmalia Zunisa',        'Rahma',  'Procurement',               'Pusat',  'Purchasing',  TRUE, TRUE),
('6283840115994', 'Puspita Dewi Oktorani',      'Pita',   'Supply Chain',              'Pusat',  'Supply Chain',TRUE, TRUE),
('6283851703968', 'Putri Diana',                'Putri',  'Accounting',                'Pusat',  'Accounting',  TRUE, TRUE),
('6287860367707', 'Reka Arya Prapandega',       'Reka',   'Kirim Tagih',               'Kediri', 'Operasional', TRUE, TRUE),
('6281916630446', 'Rengga Marantika Wicaksono', 'Rengga', 'Kirim Tagih',               'Kediri', 'Operasional', TRUE, TRUE),
('6289675945698', 'Rizal Ardiansyah',           'Rizal',  'Kirim Tagih & Admin Cabang','Madura', 'Operasional', TRUE, TRUE),
('6285854718057', 'Siti Nurkolis',              'Kolis',  'Finance',                   'Pusat',  'Finance',     TRUE, TRUE),
('6285785307719', 'Yugi Dwi Bagus Juliawan',   'Yugi',   'Admin Gudang',              'Pusat',  'Admin',       TRUE, TRUE)

ON CONFLICT (wa_number) DO UPDATE SET
  nama               = EXCLUDED.nama,
  panggilan          = EXCLUDED.panggilan,
  posisi             = EXCLUDED.posisi,
  cabang             = EXCLUDED.cabang,
  role               = EXCLUDED.role;
  -- NOTE: wajib_plan_report sengaja TIDAK di-overwrite di ON CONFLICT,
  -- supaya operator override (mis. batch rollout via migration file)
  -- tidak ke-revert saat seed di-rerun. Untuk fresh install, default
  -- dari VALUES tetap berlaku.

-- ============================================================
-- 3. (REMOVED — ALTER pindah ke section 1.5 di atas)
-- ============================================================

-- ============================================================
-- 4. CREATE master_territory — area coverage per AM
-- ============================================================
CREATE TABLE IF NOT EXISTS master_territory (
  id          SERIAL PRIMARY KEY,
  am_panggilan VARCHAR(20) NOT NULL,   -- sesuai panggilan di master_user
  hod_panggilan VARCHAR(20) NOT NULL,  -- ROCKY / YOGI
  cabang      VARCHAR(50) NOT NULL,
  kota        VARCHAR(100) NOT NULL,
  created_at  TIMESTAMP DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_territory_am
  ON master_territory(am_panggilan);

CREATE INDEX IF NOT EXISTS idx_territory_kota
  ON master_territory USING gin(to_tsvector('indonesian', kota));

-- Seed territory data
INSERT INTO master_territory (am_panggilan, hod_panggilan, cabang, kota) VALUES

-- ── ROCKY — HOD Sales East Area ─────────────────────────────
-- ARI → Bali
('ARI',   'ROCKY', 'BALI',   'KAB. BADUNG'),
('ARI',   'ROCKY', 'BALI',   'KAB. BANGLI'),
('ARI',   'ROCKY', 'BALI',   'KAB. BULELENG'),
('ARI',   'ROCKY', 'BALI',   'KAB. GIANYAR'),
('ARI',   'ROCKY', 'BALI',   'KAB. KARANGASEM'),
('ARI',   'ROCKY', 'BALI',   'KAB. TABANAN'),
('ARI',   'ROCKY', 'BALI',   'KAB. JEMBRANA'),
('ARI',   'ROCKY', 'BALI',   'KAB. KLUNGKUNG'),
('ARI',   'ROCKY', 'BALI',   'KOTA DENPASAR'),

-- LURI → Jember
('LURI',  'ROCKY', 'JEMBER', 'KAB. BANYUWANGI'),
('LURI',  'ROCKY', 'JEMBER', 'KAB. BONDOWOSO'),
('LURI',  'ROCKY', 'JEMBER', 'KAB. JEMBER'),
('LURI',  'ROCKY', 'JEMBER', 'KAB. LUMAJANG'),
('LURI',  'ROCKY', 'JEMBER', 'KAB. SITUBONDO'),

-- AULIA → Kediri
('AULIA', 'ROCKY', 'KEDIRI', 'KAB. JOMBANG'),
('AULIA', 'ROCKY', 'KEDIRI', 'KAB. KEDIRI'),
('AULIA', 'ROCKY', 'KEDIRI', 'KAB. NGANJUK'),
('AULIA', 'ROCKY', 'KEDIRI', 'KAB. TRENGGALEK'),
('AULIA', 'ROCKY', 'KEDIRI', 'KAB. TULUNGAGUNG'),
('AULIA', 'ROCKY', 'KEDIRI', 'KOTA KEDIRI'),

-- ANGGA → Madura
('ANGGA', 'ROCKY', 'MADURA', 'KAB. BANGKALAN'),
('ANGGA', 'ROCKY', 'MADURA', 'KAB. PAMEKASAN'),
('ANGGA', 'ROCKY', 'MADURA', 'KAB. SAMPANG'),
('ANGGA', 'ROCKY', 'MADURA', 'KAB. SUMENEP'),

-- FIRMAN → Malang
('FIRMAN','ROCKY', 'MALANG', 'KAB. BLITAR'),
('FIRMAN','ROCKY', 'MALANG', 'KAB. MALANG'),
('FIRMAN','ROCKY', 'MALANG', 'KAB. PASURUAN'),
('FIRMAN','ROCKY', 'MALANG', 'KAB. PROBOLINGGO'),
('FIRMAN','ROCKY', 'MALANG', 'KOTA BATU'),
('FIRMAN','ROCKY', 'MALANG', 'KOTA BLITAR'),
('FIRMAN','ROCKY', 'MALANG', 'KOTA MALANG'),
('FIRMAN','ROCKY', 'MALANG', 'KOTA PASURUAN'),
('FIRMAN','ROCKY', 'MALANG', 'KOTA PROBOLINGGO'),

-- VICKY → NTB
('VICKY', 'ROCKY', 'NTB',    'KAB. BIMA'),
('VICKY', 'ROCKY', 'NTB',    'KAB. DOMPU'),
('VICKY', 'ROCKY', 'NTB',    'KAB. LOMBOK BARAT'),
('VICKY', 'ROCKY', 'NTB',    'KAB. LOMBOK TENGAH'),
('VICKY', 'ROCKY', 'NTB',    'KAB. LOMBOK TIMUR'),
('VICKY', 'ROCKY', 'NTB',    'KAB. LOMBOK UTARA'),
('VICKY', 'ROCKY', 'NTB',    'KAB. SUMBAWA'),
('VICKY', 'ROCKY', 'NTB',    'KAB. SUMBAWA BARAT'),
('VICKY', 'ROCKY', 'NTB',    'KOTA BIMA'),
('VICKY', 'ROCKY', 'NTB',    'KOTA MATARAM'),

-- ── YOGI — HOD Sales West Area ──────────────────────────────
-- IQBAL → Jawa Barat + Cirebon
('IQBAL', 'YOGI',  'JAWA BARAT', 'KAB. CIREBON'),
('IQBAL', 'YOGI',  'JAWA BARAT', 'KAB. INDRAMAYU'),
('IQBAL', 'YOGI',  'JAWA BARAT', 'KAB. PURWAKARTA'),
('IQBAL', 'YOGI',  'JAWA BARAT', 'KAB. SUBANG'),
('IQBAL', 'YOGI',  'JAWA BARAT', 'KAB. SUKABUMI'),
('IQBAL', 'YOGI',  'JAWA BARAT', 'KAB. KUNINGAN'),
('IQBAL', 'YOGI',  'JAWA BARAT', 'KAB. MAJALENGKA'),
('IQBAL', 'YOGI',  'JAWA BARAT', 'KAB. BREBES'),
('IQBAL', 'YOGI',  'JAWA BARAT', 'KAB. TEGAL'),
('IQBAL', 'YOGI',  'JAWA BARAT', 'KOTA BANDUNG'),
('IQBAL', 'YOGI',  'JAWA BARAT', 'KOTA CIREBON'),
('IQBAL', 'YOGI',  'JAWA BARAT', 'KOTA TEGAL'),
('IQBAL', 'YOGI',  'JAWA BARAT', 'KOTA TASIKMALAYA'),

-- SIDQI → Jawa Tengah + Solo & Yogyakarta
('SIDQI', 'YOGI',  'JAWA TENGAH', 'KAB. BANYUMAS'),
('SIDQI', 'YOGI',  'JAWA TENGAH', 'KAB. BOYOLALI'),
('SIDQI', 'YOGI',  'JAWA TENGAH', 'KAB. CILACAP'),
('SIDQI', 'YOGI',  'JAWA TENGAH', 'KAB. KLATEN'),
('SIDQI', 'YOGI',  'JAWA TENGAH', 'KAB. SRAGEN'),
('SIDQI', 'YOGI',  'JAWA TENGAH', 'KAB. TEMANGGUNG'),
('SIDQI', 'YOGI',  'JAWA TENGAH', 'KAB. WONOGIRI'),
('SIDQI', 'YOGI',  'JAWA TENGAH', 'KAB. SUKOHARJO'),
('SIDQI', 'YOGI',  'JAWA TENGAH', 'KAB. KARANGANYAR'),
('SIDQI', 'YOGI',  'JAWA TENGAH', 'KAB. MAGELANG'),
('SIDQI', 'YOGI',  'JAWA TENGAH', 'KAB. PURWOREJO'),
('SIDQI', 'YOGI',  'JAWA TENGAH', 'KOTA MAGELANG'),
('SIDQI', 'YOGI',  'JAWA TENGAH', 'KOTA SEMARANG'),
('SIDQI', 'YOGI',  'JAWA TENGAH', 'KOTA SURAKARTA'),
('SIDQI', 'YOGI',  'JAWA TENGAH', 'KOTA YOGYAKARTA'),

-- IRUL → Lamongan
('IRUL',  'YOGI',  'LAMONGAN', 'KAB. BLORA'),
('IRUL',  'YOGI',  'LAMONGAN', 'KAB. BOJONEGORO'),
('IRUL',  'YOGI',  'LAMONGAN', 'KAB. GRESIK'),
('IRUL',  'YOGI',  'LAMONGAN', 'KAB. LAMONGAN'),
('IRUL',  'YOGI',  'LAMONGAN', 'KAB. REMBANG'),
('IRUL',  'YOGI',  'LAMONGAN', 'KAB. TUBAN'),

-- WILDHA → Madiun
('WILDHA','YOGI',  'MADIUN', 'KAB. MADIUN'),
('WILDHA','YOGI',  'MADIUN', 'KAB. MAGETAN'),
('WILDHA','YOGI',  'MADIUN', 'KAB. NGAWI'),
('WILDHA','YOGI',  'MADIUN', 'KAB. PACITAN'),
('WILDHA','YOGI',  'MADIUN', 'KAB. PONOROGO'),
('WILDHA','YOGI',  'MADIUN', 'KOTA MADIUN'),

-- YUGO → Palembang + Sumatera
('YUGO',  'YOGI',  'PALEMBANG', 'KAB. ACEH BARAT'),
('YUGO',  'YOGI',  'PALEMBANG', 'KAB. BANYUASIN'),
('YUGO',  'YOGI',  'PALEMBANG', 'KAB. LAHAT'),
('YUGO',  'YOGI',  'PALEMBANG', 'KAB. OGAN ILIR'),
('YUGO',  'YOGI',  'PALEMBANG', 'KOTA BATAM'),
('YUGO',  'YOGI',  'PALEMBANG', 'KOTA DUMAI'),
('YUGO',  'YOGI',  'PALEMBANG', 'KOTA MEDAN'),
('YUGO',  'YOGI',  'PALEMBANG', 'KOTA PALEMBANG'),
('YUGO',  'YOGI',  'PALEMBANG', 'KOTA PEKANBARU'),
('YUGO',  'YOGI',  'PALEMBANG', 'KOTA PRABUMULIH'),

-- ARIF → Surabaya 2
('ARIF',  'YOGI',  'SURABAYA 2', 'KAB. MOJOKERTO'),
('ARIF',  'YOGI',  'SURABAYA 2', 'KAB. SIDOARJO'),
('ARIF',  'YOGI',  'SURABAYA 2', 'KOTA MOJOKERTO'),
('ARIF',  'YOGI',  'SURABAYA 2', 'KOTA SURABAYA')

ON CONFLICT DO NOTHING;

-- ============================================================
-- 5. SEED master_holiday — libur nasional 2026 (Indonesia)
--    Dipakai is_working_day() untuk skip libur di plan/report check.
--    Update tiap awal tahun untuk kalender baru.
-- ============================================================
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
-- 6. VERIFICATION QUERIES
-- ============================================================

-- Summary per role
SELECT role, wajib_plan_report,
       COUNT(*) AS jumlah
FROM master_user
GROUP BY role, wajib_plan_report
ORDER BY wajib_plan_report DESC, role;

-- AM + jumlah territory
SELECT
  mu.panggilan,
  mu.cabang,
  t.hod_panggilan AS hod,
  COUNT(t.id) AS jumlah_kota
FROM master_user mu
LEFT JOIN master_territory t ON t.am_panggilan = UPPER(mu.panggilan)
WHERE mu.role = 'AM'
GROUP BY mu.panggilan, mu.cabang, t.hod_panggilan
ORDER BY t.hod_panggilan, mu.panggilan;

-- ============================================================
-- ⚠️  FLAG: DODI (NTT) ada di territory map tapi TIDAK ADA
--     di data karyawan. 12 kota NTT (KAB. ALOR, KAB. BELU,
--     KAB. KUPANG, dll) saat ini UNASSIGNED.
--     Konfirmasi ke HR: apakah Dodi belum onboard atau
--     sudah keluar? Tambahkan manual setelah konfirmasi.
-- ============================================================
