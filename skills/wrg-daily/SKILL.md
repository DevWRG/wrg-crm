---
name: wrg-daily
description: Schedule-only design spec (08:00 plan_check / 20:30 report_check / 22:00 daily_summary). Execution di bash wrapper scripts/wrg-daily.sh — bukan via openclaw skill.
---

# wrg-daily
**Trigger:** Schedule (cron) — tidak dipanggil dari WA message  
**Role:** 3 job terjadwal: plan_check, report_check, daily_summary  
**AI Model:** primary `openrouter/anthropic/claude-haiku-4.5`, fallback `openrouter/deepseek/deepseek-r1`

---

## CRON SCHEDULE

| Waktu | Hari | Job |
|---|---|---|
| 08:00 WIB | Daily | `plan_check()` |
| 20:30 WIB | Daily | `report_check()` |
| 22:00 WIB | Senin–Jumat | `daily_summary()` |

---

## JOB 1 — plan_check() [08:00 WIB]

### Step 1 — Cek Hari Kerja
```sql
SELECT is_working_day(CURRENT_DATE) AS is_workday;
```
- `false` → **STOP semua** (weekend/libur, tidak ada warning)
- `true` → lanjut

### Step 2 — Ambil Anggota Belum Plan
```sql
SELECT
  mu.wa_number,
  mu.nama,
  mu.last_active_group,
  mu.area
FROM master_user mu
WHERE mu.aktif = TRUE
  AND NOT EXISTS (
    SELECT 1 FROM sales_plan sp
    WHERE sp.user_id = mu.id
      AND sp.tanggal = CURRENT_DATE
  );
```

### Step 3 — Kirim Warning per Anggota
Untuk setiap anggota yang tidak plan:
```
Target: last_active_group (grup terakhir mereka kirim pesan)
Jika last_active_group NULL → skip (belum pernah aktif)

Pesan:
⚠️ Pengingat #PLAN
{nama} belum submit plan hari ini.
Silakan kirim #PLAN sebelum mulai aktivitas.
```

---

## JOB 2 — report_check() [20:30 WIB]

### Step 1 — Cek Hari Kerja + Weekend Opt-in Logic

**Weekday (Senin–Jumat):**
```sql
-- Semua anggota aktif
SELECT mu.* FROM master_user mu WHERE mu.aktif = TRUE;
```

**Weekend/Libur:**
```sql
-- Hanya yang sudah submit #PLAN hari ini (opt-in)
SELECT DISTINCT mu.*
FROM master_user mu
JOIN sales_plan sp ON sp.user_id = mu.id
WHERE mu.aktif = TRUE
  AND sp.tanggal = CURRENT_DATE;
```

### Step 2 — Ambil Status Report per Anggota
```sql
SELECT *
FROM daily_plan_report_status
WHERE tanggal = CURRENT_DATE
  OR tanggal IS NULL  -- anggota tanpa plan sama sekali
ORDER BY nama;
```

### Step 3 — Kirim Warning

**Punya plan, belum semua report:**
```
Target: grup yang dipakai submit #PLAN hari ini

⚠️ Pengingat #REPORT, {nama}
Masih ada {N} customer belum direport:
  • {customer_1}
  • {customer_2}
Kirim #REPORT sebelum selesai hari ini ya.
```

**Tidak ada plan DAN tidak ada report:**
```
Target: last_active_group

⚠️ {nama} tidak ada plan maupun report hari ini.
```

**Sudah semua report → skip, tidak kirim pesan apapun.**

---

## JOB 3 — daily_summary() [22:00 WIB, Senin–Jumat]

### Step 1 — Cek Hari Kerja
```sql
SELECT is_working_day(CURRENT_DATE);
```
`false` → STOP

### Step 2 — Kumpulkan Data Hari Ini
```sql
-- Activity log hari ini
SELECT
  mu.nama,
  mu.area,
  mu.role,
  al.customer_name,
  al.tanggal,
  al.hasil,
  al.next_action,
  al.is_unmatched,
  sp.tujuan AS plan_tujuan,
  sp.goal   AS plan_goal
FROM activity_log al
JOIN master_user mu ON mu.id = al.user_id
LEFT JOIN sales_plan sp ON sp.id = al.plan_id
WHERE al.tanggal = CURRENT_DATE
ORDER BY mu.area, mu.nama, al.id;

-- Summary stats
SELECT
  COUNT(DISTINCT user_id)                                     AS anggota_aktif,
  COUNT(*)                                                    AS total_report,
  COUNT(*) FILTER (WHERE is_unmatched = FALSE)                AS matched_plan,
  COUNT(*) FILTER (WHERE is_unmatched = TRUE)                 AS unmatched,
  (SELECT COUNT(DISTINCT user_id) FROM sales_plan
   WHERE tanggal = CURRENT_DATE)                             AS anggota_plan
FROM activity_log
WHERE tanggal = CURRENT_DATE;
```

### Step 3 — Kompres Data (Layer B Compression)
```
wrg_compress(rows):
1. Field shortening  : customer_name→cust, next_action→nx, hasil→h
2. Enum compression  : "Kunjungan Fisik"→KF, "Cold"→C, "Warm"→W, "Hot"→H
3. Pipe packing      : JSON → key:val|key:val per baris
4. Header dedup      : [HDR:Budi:v5c3,Andi:v3c2,...]
Target: 8.000 token → ~640 token (92% compression)
```

### Step 4 — Kirim ke AI (OpenRouter)

**System prompt (stable prefix — cache-friendly):**
```
Kamu adalah WRG CRM Daily Summary Generator.
Buat ringkasan harian aktivitas tim sales PT Wahana Rizky Gumilang.

FORMAT OUTPUT WAJIB:
📊 *Daily Summary — {hari}, {tanggal}*

*Overview*
• {N} anggota aktif dari {total} tim
• {total_report} laporan masuk
• {matched}% sesuai plan, {unmatched} aktivitas di luar plan

*Per Area*
[untuk setiap area: ringkasan 2-3 kalimat tentang aktivitas hari ini]

*Highlight*
[maks 3 poin penting hari ini — deal hot, prospek baru, warning]

*Perhatian*
[anggota yang tidak plan/report hari ini, jika ada]

Gunakan Bahasa Indonesia. Singkat, informatif, eksekutif. Maksimal 30 baris.
```

**User message (variable — DATA INPUT):**
```
============================================
DATA INPUT (compressed):
{wrg_compress_output}

STATS:
anggota_aktif={N} | total_report={N} | matched={N} | unmatched={N}
============================================
```

### Step 5 — Kirim ke Grup HOD/Direktur
```
Target grup: ambil dari master_user WHERE role IN ('HOD', 'Direktur')
             → kirim ke last_active_group masing-masing

Atau: hardcode grup khusus direktur jika sudah diset di config
```

---

## ERROR HANDLING

**OpenRouter quota habis (403):**
```
Log ke: ~/wrg-crm/logs/daily.log
Kirim notif ke admin via DM: "⚠️ OpenRouter quota habis, daily summary tidak terkirim."
Fallback ke model berikutnya (deepseek-r1)
```

**Tidak ada data hari ini (libur de facto):**
```
Skip summary, tidak kirim pesan apapun.
```

**Grup target tidak ditemukan:**
```
Log warning: "Target grup tidak ada, skip kirim."
```

---

## LOG FORMAT
```
[2026-05-21 08:00:01] plan_check   — warned: 3 anggota — skipped: 26
[2026-05-21 20:30:02] report_check — warned: 5 anggota — skipped: 24
[2026-05-21 22:00:05] daily_summary — rows: 47 — tokens_in: 620 — tokens_out: 380 — model: claude-haiku-4.5
```
