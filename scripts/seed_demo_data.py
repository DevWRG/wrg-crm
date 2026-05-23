#!/usr/bin/env python3
"""Seed wrg_crm_dev with realistic demo plan/report data.

TRUNCATES sales_plan, sales_todo, activity_log first (idempotent re-run).
master_user is NOT touched.

Usage: python3 scripts/seed_demo_data.py
"""
from __future__ import annotations

import datetime
import random
import subprocess
import sys
from pathlib import Path

random.seed(42)  # reproducible runs

PG_USER = "wrg_admin"
PG_DB = "wrg_crm_dev"
PSQL_BASE = ["psql", "-U", PG_USER, "-d", PG_DB]

# Period: 2026-05-04 → 2026-05-22 (3 calendar weeks, ~14 working days)
DATE_START = datetime.date(2026, 5, 4)
DATE_END = datetime.date(2026, 5, 22)


# ── Customer names per AM cabang ─────────────────────────────────────────
CUSTOMERS_BY_CABANG = {
    "Bali": [
        "RS Sanglah Denpasar", "RSUP Sanglah", "RS Wangaya", "RS Bali Mandara",
        "Lab Prodia Denpasar", "Lab Pramita Denpasar", "Klinik Hermina Denpasar",
        "Klinik Kasih Ibu", "RS BIMC Kuta", "RSUD Klungkung", "RSUD Tabanan",
        "Lab Klinik Ubud", "RS Surya Husadha", "Puskesmas Kuta",
    ],
    "Madura": [
        "RSUD Bangkalan", "RSUD Sampang", "RSUD Pamekasan", "RSUD Sumenep",
        "Klinik Pratama Sampang", "Lab Klinik Bangkalan", "RS Surya Husada Madura",
        "Puskesmas Tanah Merah", "RSI Pamekasan", "Lab Pratama Sumenep",
    ],
    "SBY 2": [
        "RS Mitra Keluarga Waru", "RSUD Sidoarjo", "RS PHC Surabaya",
        "Lab Prodia Sidoarjo", "RS Siloam Surabaya", "RSI Jemursari",
        "RS Petrokimia Gresik", "RSUD Mojokerto", "Klinik Hermina Sidoarjo",
        "RS Pusura", "Lab Pramita Surabaya",
    ],
    "Kediri": [
        "RSUD Gambiran Kediri", "RS Baptis Kediri", "RSUD Pare", "RSUD Jombang",
        "Lab Prodia Kediri", "RS Hermina Kediri", "Puskesmas Kandat",
        "RSU Aura Syifa", "RSUD Nganjuk", "RSUD Trenggalek",
    ],
    "Malang": [
        "RSSA Saiful Anwar", "RS Lavalette", "RS Permata Bunda Malang",
        "RSI Aisyiyah Malang", "Lab Prodia Malang", "RS Wava Husada",
        "RSUD Kanjuruhan", "RS Hermina Tangkubanprahu", "Klinik Brawijaya Probolinggo",
        "RSUD Pasuruan", "RS Panti Nirmala",
    ],
    "Cirebon": [
        "RSUD Gunung Jati", "RSUD Indramayu", "RS Mitra Plumbon",
        "Klinik Mitra Keluarga Cirebon", "Lab Prodia Cirebon", "RSUD Waled",
        "RS Permata Cirebon", "Puskesmas Sumber", "RSUD Tasikmalaya",
        "RS Mitra Keluarga Bandung",
    ],
    "Lamongan": [
        "RSUD Soegiri Lamongan", "RSUD Tuban", "RS Muhammadiyah Lamongan",
        "RSUD Bojonegoro", "Lab Klinik Lamongan", "Puskesmas Babat",
        "RS PKU Muhammadiyah Lamongan", "RSUD Blora", "RSUD Rembang",
    ],
    "Jember": [
        "RSD dr. Soebandi Jember", "RSUP Jember Klinik", "RS Bina Sehat Jember",
        "RSUD Banyuwangi", "Lab Prodia Jember", "RSUD Bondowoso",
        "RSUD Situbondo", "Klinik Pratama Jember", "RSUD Lumajang",
    ],
    "Solo & Yogyakarta": [
        "RS dr. Moewardi Solo", "RS Sardjito Yogya", "RS PKU Muhammadiyah Solo",
        "RS Bethesda Yogya", "Lab Prodia Yogya", "RS Panti Rapih",
        "RSUD Klaten", "RS JIH Yogyakarta", "Lab Prodia Solo",
        "RSUD Karanganyar", "RSUD Sukoharjo",
    ],
    "NTB": [
        "RSUD Mataram", "RS Risa Sentra Medika", "RSUD Praya", "RSUD Sumbawa",
        "Lab Klinik Mataram", "RS Harapan Keluarga", "RSUD Bima",
        "Puskesmas Cakranegara", "RSUD Dompu", "RSUD Lombok Timur",
    ],
    "Madiun": [
        "RSUD Sogaten Madiun", "RSUD Caruban", "RSUD Magetan",
        "RS Santa Clara Madiun", "Lab Klinik Madiun", "RSUD Ngawi",
        "RSUD Pacitan", "RS Griya Husada", "RSUD Ponorogo",
    ],
    "Palembang": [
        "RS Moh. Hoesin Palembang", "RS Charitas Palembang", "RSUD Siti Fatimah",
        "Lab Prodia Palembang", "RS Pertamina Plaju", "RSUD Lahat",
        "RSUD Banyuasin", "Klinik Hermina Palembang", "RSUD Prabumulih",
        "RSUD Pekanbaru",
    ],
}


# Tujuan & weighted distribution
TUJUAN_WEIGHTS = [
    ("Kunjungan Fisik", 50),
    ("Follow-up", 20),
    ("Demo", 15),
    ("Presentasi", 10),
    ("Telepon", 5),
]


def pick_tujuan() -> str:
    r = random.randint(1, 100)
    cum = 0
    for tujuan, w in TUJUAN_WEIGHTS:
        cum += w
        if r <= cum:
            return tujuan
    return TUJUAN_WEIGHTS[0][0]


GOALS = {
    "Kunjungan Fisik": [
        "visit rutin", "intro produk baru", "cek progress quotation",
        "ketemu PIC lab", "negosiasi harga", "tindak lanjut RFQ",
        "presentasi alat IVD baru", "evaluasi kebutuhan reagen",
    ],
    "Follow-up": [
        "FU quotation alat IVD", "FU sample produk", "FU demo minggu lalu",
        "FU PO pending", "FU instalasi", "FU training operator",
    ],
    "Demo": [
        "demo Cobas Pro", "demo hematology analyzer Mindray BC-6000",
        "demo POCT", "demo coagulometer Stago", "demo immunoassay",
        "demo line otomatisasi lab", "demo reagen baru",
    ],
    "Presentasi": [
        "pres produk hematology", "pres line IVD baru", "pres harga & TOP",
        "pres after-sales support", "pres training plan operator",
        "pres mapping kebutuhan customer",
    ],
    "Telepon": [
        "confirm jadwal demo", "follow info quotation", "confirm PO",
        "info ETA pengiriman", "tanya status approval",
    ],
}

DR_NAMES = ["Andi", "Bagus", "Cahya", "Dewi", "Eka", "Fitri", "Gita", "Heru",
            "Indra", "Joko", "Kartika", "Lukman", "Maya", "Nita", "Oscar",
            "Putri", "Rini", "Surya", "Tono", "Umar", "Wahyu", "Yuli"]
PROD_NAMES = ["Cobas Pro", "BC-6000", "Mindray IVD", "POCT analyzer",
              "hematology line", "coagulometer", "biokimia line", "immunoassay system"]


HASIL_TEMPLATES = [
    "ketemu dr. {dr}, tertarik {prod}, minta quotation",
    "presentasi sukses, masuk shortlist, follow up minggu depan",
    "demo lancar, user feedback positif",
    "negosiasi harga ongoing, target close akhir bulan",
    "tidak ketemu PIC, reschedule minggu depan",
    "follow up berlanjut, PO targeted next month",
    "quotation diterima, menunggu approval direksi",
    "intro produk, customer minta sample dulu",
    "training operator scheduled minggu depan",
    "submit RFQ via email, await response",
    "dr. {dr} setuju demo dgn {prod}, schedule pekan ini",
    "customer compare dgn kompetitor, kirim TCO analysis",
    "approval level pertama lolos, naik ke direktur",
    "PO sudah diterima, lanjut ke shipment",
]


NEXT_TEMPLATES = [
    "kirim quotation Senin",
    "schedule demo minggu depan",
    "follow-up Selasa pagi",
    "kirim sample produk",
    "visit ulang minggu depan",
    "submit PO ke admin",
    "training operator dijadwalkan",
    "konfirmasi spec via email",
    "menunggu approval user",
    "pres ulang dgn direksi",
    "kirim TCO analysis",
    "minta surat pesanan dari klinik",
    "siapkan demo unit",
]


def fill_hasil() -> str:
    tpl = random.choice(HASIL_TEMPLATES)
    return tpl.format(dr=random.choice(DR_NAMES), prod=random.choice(PROD_NAMES))


def fill_next() -> str:
    return random.choice(NEXT_TEMPLATES)


# ── Non-AM todo templates ────────────────────────────────────────────────
TODO_TEMPLATES = {
    "Admin": [
        "input invoice ke ERP", "follow PO supplier", "rekap penjualan minggu ini",
        "verifikasi data shipping", "balas email customer", "siapkan laporan bulanan",
        "input quotation ke ERP", "konfirmasi stok ke gudang", "update database customer",
        "follow status PO ke supplier", "input faktur penjualan",
    ],
    "Operasional": [
        "kirim alat ke RS", "tagih invoice customer", "antar dokumen ke notaris",
        "pickup return barang", "deliver demo unit", "ambil pembayaran customer",
        "kirim sample reagen", "koordinasi shipping ke cabang",
    ],
    "Teknisi": [
        "maintenance Cobas Pro di lab customer", "kalibrasi alat hematology",
        "trouble shooting di RS", "install reagen baru", "training operator on-site",
        "PM kuartal di lab", "validasi performa alat", "ganti sparepart sensor",
    ],
    "Finance": [
        "rekonsiliasi bank", "input AR aging", "verifikasi pembayaran customer",
        "siapkan laporan kas", "ikut meeting dgn direksi", "review payment terms customer",
    ],
    "Accounting": [
        "closing bulanan", "input jurnal pengeluaran", "rekonsiliasi inventory",
        "siapkan SPT PPN", "audit internal bulanan",
    ],
    "Purchasing": [
        "proses PO supplier", "negosiasi harga supplier baru",
        "follow ETA delivery", "approve PR dari sales", "evaluasi supplier",
    ],
    "Supply Chain": [
        "update stok gudang pusat", "monitor lead time supplier",
        "atur shipment ke cabang", "rekap stok minimum", "audit fisik gudang",
    ],
    "Logistik": [
        "koordinasi pengiriman luar kota", "atur ekspedisi",
        "follow tracking pengiriman", "pickup dari supplier",
    ],
    "GA": [
        "follow vendor maintenance gedung", "inventarisasi aset kantor",
        "atur perjalanan dinas tim",
    ],
}


# ── Helpers ──────────────────────────────────────────────────────────────

def sql_escape(s: str) -> str:
    """Escape single-quote for SQL string literal."""
    return s.replace("'", "''")


def working_days(start: datetime.date, end: datetime.date, holidays: set) -> list:
    days = []
    d = start
    while d <= end:
        # Mon=0..Sun=6
        if d.weekday() < 5 and d not in holidays:
            days.append(d)
        d += datetime.timedelta(days=1)
    return days


def fetch_users() -> list:
    proc = subprocess.run(
        PSQL_BASE + ["-tA", "-F", "|", "-c",
                     "SELECT id,panggilan,role,cabang FROM master_user "
                     "WHERE aktif AND wajib_plan_report ORDER BY id;"],
        capture_output=True, text=True, check=True,
    )
    users = []
    for line in proc.stdout.strip().splitlines():
        parts = line.split("|")
        if len(parts) == 4:
            users.append({
                "id": int(parts[0]),
                "panggilan": parts[1],
                "role": parts[2],
                "cabang": parts[3],
            })
    return users


def fetch_holidays(start: datetime.date, end: datetime.date) -> set:
    proc = subprocess.run(
        PSQL_BASE + ["-tA", "-c",
                     f"SELECT tanggal FROM master_holiday "
                     f"WHERE tanggal BETWEEN '{start}' AND '{end}';"],
        capture_output=True, text=True, check=True,
    )
    out = set()
    for line in proc.stdout.strip().splitlines():
        if line:
            out.add(datetime.date.fromisoformat(line.strip()))
    return out


def submitted_at_for(tanggal: datetime.date) -> tuple[datetime.datetime, bool]:
    """Return (timestamp, is_late). Distribution:
       50% previous evening 19:00–22:00 (not late)
       35% same day early morning 06:00–07:55 (not late)
       15% same day after 08:00 (LATE)."""
    r = random.random()
    if r < 0.50:
        prev = tanggal - datetime.timedelta(days=1)
        ts = datetime.datetime.combine(prev, datetime.time(
            random.randint(19, 21), random.randint(0, 59), random.randint(0, 59)
        ))
        return ts, False
    if r < 0.85:
        ts = datetime.datetime.combine(tanggal, datetime.time(
            random.choice([6, 7]), random.randint(0, 55), random.randint(0, 59)
        ))
        return ts, False
    # 15% late
    ts = datetime.datetime.combine(tanggal, datetime.time(
        random.randint(8, 14), random.randint(0, 59), random.randint(0, 59)
    ))
    return ts, True


# ── Generators ───────────────────────────────────────────────────────────

def generate_sales_plan(am_users, work_days):
    """Yields tuples: (user_id, tanggal, cust, tujuan, goal, seq, submitted_at, is_late,
                      reported_target, hasil_text, next_text)"""
    for am in am_users:
        customers = CUSTOMERS_BY_CABANG.get(am["cabang"], ["RS Generic"])
        # Some AMs more diligent (90% days) than others (60%)
        diligence = random.uniform(0.55, 0.92)
        for d in work_days:
            if random.random() > diligence:
                continue  # skipped this day
            ts, late = submitted_at_for(d)
            # 2–5 customers per day
            n_plan = random.randint(2, 5)
            chosen = random.sample(customers, min(n_plan, len(customers)))
            for seq, cust in enumerate(chosen, 1):
                tujuan = pick_tujuan()
                goal = random.choice(GOALS[tujuan])
                # 80% reported overall
                will_report = random.random() < 0.80
                hasil = fill_hasil() if will_report else None
                next_a = fill_next() if will_report else None
                yield (am["id"], d, cust, tujuan, goal, seq, ts, late,
                       will_report, hasil, next_a)


def generate_sales_todo(non_am_users, work_days):
    """Yields todo rows for non-AM users."""
    # ~50% of non-AMs participate
    participants = random.sample(non_am_users, k=max(1, len(non_am_users) // 2))
    for user in participants:
        tpls = TODO_TEMPLATES.get(user["role"], TODO_TEMPLATES["Admin"])
        # Each user submits on 50–80% of working days (less frequent than AM)
        freq = random.uniform(0.45, 0.80)
        for d in work_days:
            if random.random() > freq:
                continue
            ts, late = submitted_at_for(d)
            n_items = random.randint(2, 6)
            items = random.sample(tpls, min(n_items, len(tpls)))
            # 85% reported
            reported = random.random() < 0.85
            yield (user["id"], d, items, ts, late, reported)


def generate_unmatched(am_users, work_days, ratio=0.06):
    """Sprinkle extra activity_log entries with no plan_id (unmatched reports)."""
    for am in am_users:
        customers = CUSTOMERS_BY_CABANG.get(am["cabang"], ["RS Generic"])
        for d in work_days:
            if random.random() < ratio:
                cust = random.choice(customers)
                ts = datetime.datetime.combine(d, datetime.time(
                    random.randint(14, 17), random.randint(0, 59), random.randint(0, 59)
                ))
                yield (am["id"], d, cust, fill_hasil(), fill_next(), ts)


# ── Main ─────────────────────────────────────────────────────────────────

def main():
    print(f"Connecting to {PG_DB} as {PG_USER}…")
    users = fetch_users()
    if not users:
        print("ERROR: no users found", file=sys.stderr)
        sys.exit(1)
    am_users = [u for u in users if u["role"] == "AM"]
    non_am_users = [u for u in users if u["role"] != "AM"]
    print(f"  AM users:     {len(am_users)}")
    print(f"  Non-AM users: {len(non_am_users)}")

    holidays = fetch_holidays(DATE_START, DATE_END)
    print(f"  Holidays in range: {sorted(holidays)}")

    work_days = working_days(DATE_START, DATE_END, holidays)
    print(f"  Working days: {len(work_days)} ({work_days[0]} … {work_days[-1]})")

    # Generate all rows in memory first.
    plan_rows = list(generate_sales_plan(am_users, work_days))
    todo_rows = list(generate_sales_todo(non_am_users, work_days))
    unmatched_rows = list(generate_unmatched(am_users, work_days))

    print(f"\nGenerated:")
    print(f"  sales_plan rows:    {len(plan_rows)}")
    print(f"  sales_todo rows:    {len(todo_rows)}")
    print(f"  unmatched extras:   {len(unmatched_rows)}")

    # Build SQL.
    sql_parts = []
    sql_parts.append("BEGIN;")
    sql_parts.append("TRUNCATE activity_log RESTART IDENTITY CASCADE;")
    sql_parts.append("TRUNCATE sales_plan   RESTART IDENTITY CASCADE;")
    sql_parts.append("TRUNCATE sales_todo   RESTART IDENTITY CASCADE;")

    # Insert sales_plan; capture id via INSERT…RETURNING through DO block —
    # but we need plan_id for activity_log linkage. Use staging temp table approach.
    sql_parts.append("CREATE TEMP TABLE _plan_stage ("
                     "stage_seq INT, user_id INT, tanggal DATE, customer_name TEXT, "
                     "tujuan TEXT, goal TEXT, seq INT, submitted_at TIMESTAMP, "
                     "is_late_plan BOOLEAN, will_report BOOLEAN, hasil TEXT, next_action TEXT);")

    chunks = []
    for i, p in enumerate(plan_rows):
        uid, d, cust, tujuan, goal, seq, ts, late, will_report, hasil, next_a = p
        hasil_sql = f"'{sql_escape(hasil)}'" if hasil else "NULL"
        next_sql  = f"'{sql_escape(next_a)}'" if next_a else "NULL"
        chunks.append(
            f"({i}, {uid}, '{d}', '{sql_escape(cust)}', '{sql_escape(tujuan)}', "
            f"'{sql_escape(goal)}', {seq}, '{ts.isoformat()}', "
            f"{'TRUE' if late else 'FALSE'}, "
            f"{'TRUE' if will_report else 'FALSE'}, {hasil_sql}, {next_sql})"
        )
    if chunks:
        sql_parts.append("INSERT INTO _plan_stage VALUES\n" + ",\n".join(chunks) + ";")

    sql_parts.append("""
INSERT INTO sales_plan
  (user_id, tanggal, customer_name, tujuan, goal, seq, submitted_at, is_late_plan)
SELECT user_id, tanggal, customer_name, tujuan, goal, seq, submitted_at, is_late_plan
FROM _plan_stage
ORDER BY stage_seq;
""")
    # For reported plans, insert into activity_log AND link back.
    sql_parts.append("""
WITH inserted_plans AS (
  SELECT sp.id AS plan_id, ps.user_id, ps.tanggal, ps.customer_name,
         ps.tujuan, ps.hasil, ps.next_action, ps.submitted_at, ps.will_report
  FROM _plan_stage ps
  JOIN sales_plan sp ON sp.user_id = ps.user_id
                    AND sp.tanggal = ps.tanggal
                    AND sp.customer_name = ps.customer_name
                    AND sp.seq = ps.seq
),
new_acts AS (
  INSERT INTO activity_log
    (user_id, customer_name, tanggal, tujuan, hasil, next_action,
     source, plan_id, is_unmatched, match_score, created_at)
  SELECT user_id, customer_name, tanggal, tujuan, hasil, next_action,
         'WHATSAPP', plan_id, FALSE,
         ROUND((0.85 + random() * 0.15)::numeric, 3),
         (tanggal + (random() * INTERVAL '8 hours' + INTERVAL '9 hours'))
  FROM inserted_plans WHERE will_report
  RETURNING id, plan_id
)
UPDATE sales_plan sp
SET reported = TRUE,
    reported_at = (sp.tanggal + (random() * INTERVAL '8 hours' + INTERVAL '9 hours')),
    activity_id = na.id
FROM new_acts na
WHERE sp.id = na.plan_id;
""")

    # sales_todo
    if todo_rows:
        import json
        td_chunks = []
        for tr in todo_rows:
            uid, d, items, ts, late, reported = tr
            items_json = json.dumps(items, ensure_ascii=False)
            reported_at = "NULL"
            if reported:
                # Reported same day evening
                rt = datetime.datetime.combine(d, datetime.time(
                    random.randint(17, 19), random.randint(0, 59), random.randint(0, 59)
                ))
                reported_at = f"'{rt.isoformat()}'"
            td_chunks.append(
                f"({uid}, '{d}', '{sql_escape(items_json)}'::jsonb, "
                f"'{ts.isoformat()}', "
                f"{'TRUE' if late else 'FALSE'}, "
                f"{'TRUE' if reported else 'FALSE'}, "
                f"{reported_at})"
            )
        sql_parts.append(
            "INSERT INTO sales_todo "
            "(user_id, tanggal, items, submitted_at, is_late_plan, reported, reported_at) "
            "VALUES\n" + ",\n".join(td_chunks) + ";"
        )

    # Unmatched activity_log rows
    if unmatched_rows:
        un_chunks = []
        for ur in unmatched_rows:
            uid, d, cust, hasil, next_a, ts = ur
            un_chunks.append(
                f"({uid}, '{sql_escape(cust)}', '{d}', NULL, "
                f"'{sql_escape(hasil)}', '{sql_escape(next_a)}', "
                f"'WHATSAPP', NULL, TRUE, NULL, '{ts.isoformat()}')"
            )
        sql_parts.append(
            "INSERT INTO activity_log "
            "(user_id, customer_name, tanggal, tujuan, hasil, next_action, "
            "source, plan_id, is_unmatched, match_score, created_at) "
            "VALUES\n" + ",\n".join(un_chunks) + ";"
        )

    sql_parts.append("DROP TABLE _plan_stage;")
    sql_parts.append("COMMIT;")
    sql_parts.append("""
SELECT '== verify ==' AS msg;
SELECT
  (SELECT COUNT(*) FROM sales_plan)   AS plan_rows,
  (SELECT COUNT(*) FROM sales_todo)   AS todo_rows,
  (SELECT COUNT(*) FROM activity_log) AS act_rows,
  (SELECT COUNT(*) FROM sales_plan WHERE reported)   AS plan_reported,
  (SELECT COUNT(*) FROM sales_plan WHERE is_late_plan) AS plan_late,
  (SELECT COUNT(*) FROM activity_log WHERE is_unmatched) AS unmatched;
""")

    full_sql = "\n".join(sql_parts)
    tmp = Path("/tmp/wrg-crm-seed.sql")
    tmp.write_text(full_sql, encoding="utf-8")
    print(f"\nWrote SQL: {tmp} ({len(full_sql)} bytes)")

    print("Executing on Postgres…")
    proc = subprocess.run(
        PSQL_BASE + ["-v", "ON_ERROR_STOP=1", "-f", str(tmp)],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        print("ERROR:", proc.stderr, file=sys.stderr)
        sys.exit(2)
    print(proc.stdout[-1200:])


if __name__ == "__main__":
    main()
