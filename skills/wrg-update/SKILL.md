---
name: wrg-update
description: Parse #UPDATE hashtag → update status pipeline / deal_closed
---

# wrg-update
**Trigger:** `/^#update/i`  
**Role:** Update stage/status/note pipeline tracker dengan fuzzy customer name  
**Depends on:** wrg-router (context sudah di-inject)

---

## INPUT FORMAT
```
#UPDATE
cust: [nama customer — boleh typo/partial]
stage: [1-5]
status: [Cold|Warm|Hot|Won|Lost]
note: [update progress]
```

Field wajib: `cust` + minimal satu dari `stage`, `status`, atau `note`

---

## STAGE & STATUS REFERENCE

| Stage | Label |
|---|---|
| 1 | Cold Lead |
| 2 | Prospecting |
| 3 | Proposal |
| 4 | Negotiation |
| 5 | Closing |

| Status | Keterangan |
|---|---|
| Cold | Belum ada engagement aktif |
| Warm | Ada interest, sedang diproses |
| Hot | Close to deal |
| Won | Deal closed |
| Lost | Deal gagal |

---

## LANGKAH WAJIB

### Step 1 — Fuzzy Search Pipeline
```sql
SELECT
  pt.id,
  pt.customer_name,
  pt.stage,
  pt.status,
  pt.note,
  similarity(pt.customer_name, $input_cust) AS score
FROM pipeline_tracker pt
WHERE pt.user_id = $user_id
  AND similarity(pt.customer_name, $input_cust) > 0.25
ORDER BY score DESC
LIMIT 3;
```

### Step 2 — Decision Tree

| Score | Aksi |
|---|---|
| ≥ 0.70 | **AUTO UPDATE** — langsung proses, tidak perlu konfirmasi |
| 0.40–0.69 | **CONFIRM** — tampilkan 3 opsi, minta AM pilih |
| < 0.40 | **NOT FOUND** — error + saran |

### Step 3A — AUTO UPDATE (score ≥ 0.70)
```sql
UPDATE pipeline_tracker
SET
  stage  = COALESCE($stage, stage),
  status = COALESCE($status, status),
  note   = COALESCE($note, note)
WHERE id = $matched_id;
```

Jika status = 'Won' → tambah ke deal_closed:
```sql
INSERT INTO deal_closed
  (pipeline_id, user_id, customer_name, nilai_deal, tanggal_closed)
VALUES
  ($pipeline_id, $user_id, $customer_name, NULL, CURRENT_DATE);
```
(nilai_deal diisi NULL, bisa diupdate manual via pgAdmin)

### Step 3B — CONFIRM (score 0.40–0.69)
```
Reply ke grup:
❓ Konfirmasi customer untuk {nama}:

"UPDATE {input_cust}" cocok dengan:
  1️⃣ {candidate_1} — Stage {stage}/{status}
  2️⃣ {candidate_2} — Stage {stage}/{status}
  3️⃣ Bukan keduanya

Balas: UPDATE 1 / UPDATE 2 / UPDATE 3
```

Setelah AM reply `UPDATE N`:
- UPDATE 1/2 → lanjut ke Step 3A dengan candidate terpilih
- UPDATE 3 → arahkan ke #LEADS

### Step 3C — NOT FOUND (< 0.40)
```
Reply ke grup:
❌ Customer "{input_cust}" tidak ditemukan di pipeline kamu.

Kemungkinan:
• Nama berbeda jauh — coba nama lain
• Belum pernah dicatat — gunakan #LEADS untuk tambah baru
```

---

## REPLY FORMAT

### Sukses AUTO UPDATE
```
✅ Pipeline diupdate, {nama}
🏢 {customer_name}
   Stage  : {stage_label}
   Status : {status}
   Note   : {note}
{jika Won:}
🎉 Deal Closed! Selamat {nama}!
   Catat nilai deal ke admin untuk laporan revenue.
```

### Sukses setelah CONFIRM
```
✅ Pipeline diupdate, {nama}
🏢 {customer_name} (dikonfirmasi)
   Stage  : {stage_label}
   Status : {status}
   Note   : {note}
```

---

## ERROR HANDLING

**Nama customer kosong:**
```
❌ Nama customer wajib diisi.
```

**Stage di luar range 1-5:**
```
❌ Stage harus antara 1-5.
  1=Cold Lead, 2=Prospecting, 3=Proposal, 4=Negotiation, 5=Closing
```

**Status tidak valid:**
```
❌ Status tidak valid. Pilih: Cold, Warm, Hot, Won, Lost
```

**Tidak ada field yang diupdate:**
```
❌ Minimal isi satu dari: stage, status, atau note.
```
