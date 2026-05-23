---
name: wrg-report
description: Parse #REPORT hashtag → match ke sales_plan via pg_trgm → insert ke activity_log
---

# wrg-report
**Trigger:** `/^#report/i`  
**Role:** Parse hasil kunjungan, match ke sales_plan, tracking progress  
**Depends on:** wrg-router (context sudah di-inject)

---

## INPUT FORMAT

### Mode A — Per Kunjungan (Realtime)
```
#REPORT
cust: [nama customer]
hasil: [hasil kunjungan]
next: [rencana tindak lanjut]
```

### Mode B — EOD Multi (Akhir Hari)
```
#REPORT
tgl: DD/MM/YYYY
---
cust: [Customer 1]
hasil: [hasil]
next: [next action]
---
cust: [Customer 2]
hasil: [hasil]
next: [next action]
```

---

## LANGKAH WAJIB

### Step 1 — Deteksi Mode
```
Ada separator "---" → Mode B (EOD Multi)
Tidak ada → Mode A (Single Realtime)
```

### Step 2 — Parse Tanggal
```
Mode A: tanggal = CURRENT_DATE
Mode B: ambil dari field tgl (jika ada), fallback CURRENT_DATE
```

### Step 3 — Untuk Setiap Customer: Fuzzy Match ke Plan

```sql
SELECT
  sp.id,
  sp.customer_name,
  sp.tujuan,
  sp.goal,
  sp.reported,
  similarity(sp.customer_name, $input_cust) AS score
FROM sales_plan sp
WHERE sp.user_id  = $user_id
  AND sp.tanggal  = $tanggal
  AND similarity(sp.customer_name, $input_cust) > 0.25
ORDER BY score DESC
LIMIT 3;
```

**Decision tree per customer:**

| Score | Aksi |
|---|---|
| ≥ 0.70 | AUTO MATCH → link ke plan_id |
| 0.40–0.69 | AMBIGUOUS → minta konfirmasi (lihat format di bawah) |
| < 0.40 | UNMATCHED → simpan tanpa plan_id, flag is_unmatched = true |

**Untuk Mode B:** proses semua customer dulu, kumpulkan yang AMBIGUOUS, tanyakan sekaligus di akhir.

### Step 4 — Insert ke activity_log
```sql
INSERT INTO activity_log
  (user_id, pipeline_id, customer_name, tanggal,
   hasil, next_action, source,
   plan_id, is_unmatched, match_score)
VALUES
  ($user_id, NULL, $customer_name, $tanggal,
   $hasil, $next_action, 'WHATSAPP',
   $plan_id, $is_unmatched, $match_score);
```

### Step 5 — Update sales_plan jika matched
```sql
UPDATE sales_plan
SET reported    = TRUE,
    reported_at = NOW(),
    activity_id = $activity_id
WHERE id = $plan_id;
```

### Step 6 — Hitung Progress Hari Ini
```sql
SELECT
  total_plan,
  total_reported,
  total_unreported,
  unreported_customers
FROM daily_plan_report_status
WHERE user_id = $user_id
  AND tanggal = $tanggal;
```

### Step 7 — Reply ke Grup

---

## REPLY FORMAT

### Mode A — Single, Matched (≥ 0.70)
```
✅ Report tercatat, {nama}
🏢 {customer_name}
   Plan  : {tujuan} ✓
   Hasil : {hasil}
   Next  : {next_action}

📊 Progress {tanggal}: {reported}/{total} selesai
{progress_bar}
{sisa_list}
```

**Progress bar format:**
```
▓▓▓▓░░░  4/7 selesai
⬜ RS Bunda, Lab Medika, Apotek Maju
```

### Mode A — Single, Unmatched (< 0.40)
```
✅ Report tercatat, {nama}
🏢 {customer_name}
   Hasil : {hasil}
   Next  : {next_action}

⚠️ {customer_name} tidak ada di plan hari ini.
   Tambahkan ke pipeline?
   • #LEADS — jika customer baru
   • #UPDATE — jika sudah ada di pipeline

📊 Progress {tanggal}: {reported}/{total} selesai
```

### Mode B — EOD Multi, Semua Matched
```
✅ Report EOD tercatat, {nama}
📅 {hari}, {tanggal_formatted} — Rekap Harian:

{untuk setiap customer matched:}
✅ {customer_name} → {tujuan} ✓
   Hasil: {hasil} | Next: {next_action}

{untuk setiap customer unmatched:}
⚠️ {customer_name} → tidak ada di plan
   Hasil: {hasil} | Next: {next_action}

━━━━━━━━━━━━━━━━━━━━
📊 {reported}/{total} customer selesai
{jika ada unreported:}
⬜ Belum direport: {list_customer}
   Ketik #REPORT untuk melengkapi.
```

### Konfirmasi AMBIGUOUS (score 0.40–0.69)
```
❓ Konfirmasi matching untuk {nama}:

Report "{input_cust}" cocok dengan:
  1️⃣ {candidate_1} (similarity: {score}%)
  2️⃣ {candidate_2} (similarity: {score}%)
  3️⃣ Bukan keduanya (simpan sebagai baru)

Balas: PILIH 1 / PILIH 2 / PILIH 3
```

Setelah AM reply `PILIH N`:
- Pilih 1/2 → link ke plan tersebut, lanjut proses normal
- Pilih 3 → simpan sebagai unmatched

---

## ERROR HANDLING

**Hasil kosong:**
```
❌ Field "hasil" tidak boleh kosong.
```

**Customer kosong:**
```
❌ Nama customer tidak boleh kosong.
```

**Mode B — format separator salah:**
```
❌ Format EOD tidak valid.
Pastikan setiap customer dipisahkan dengan "---"

Contoh:
#REPORT
tgl: 21/05/2026
---
cust: RS Harapan
hasil: ...
next: ...
```

---

## FORMAT TANGGAL DISPLAY
- Hari dalam Bahasa Indonesia
- Format: `Kamis, 21 Mei 2026`
