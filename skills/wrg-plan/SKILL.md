---
name: wrg-plan
description: Parse #PLAN hashtag dari WhatsApp grup → insert ke sales_plan PostgreSQL (tgl/cust/tujuan/goal)
---

# wrg-plan
**Trigger:** `/^#plan/i`  
**Role:** Parse & simpan rencana kunjungan harian (single & multi mode)  
**Depends on:** wrg-router (context sudah di-inject)

---

## INPUT FORMAT

### Single Mode
```
#PLAN
tgl: DD/MM/YYYY
cust: [nama customer]
tujuan: [lihat whitelist]
goal: [deskripsi tujuan]
```

### Multi Mode
```
#PLAN
tgl: DD/MM/YYYY
N|
[Customer 1] | [tujuan] | [goal]
[Customer 2] | [tujuan] | [goal]
```
`N` = jumlah baris yang akan diinput (opsional, untuk validasi)

---

## TUJUAN WHITELIST

Normalisasi input bebas ke nilai standar:

| Input AM (contoh) | Tersimpan Sebagai |
|---|---|
| kunjungan fisik, visit, kunjungan, ktm, kf | Kunjungan Fisik |
| telepon, telp, call, tlp, telfon | Telepon |
| wa, whatsapp, chat, msg, pesan | WA |
| demo, demonstrasi, demo produk | Demo |
| presentasi, present, pitch, pres | Presentasi |
| follow-up, follow up, fu, tl, fl, followup | Follow-up |
| instalasi, install, pasang | Instalasi |
| pengiriman, kirim, delivery | Pengiriman |
| servis, service, perbaikan | Servis |
| training, pelatihan, train | Training |
| lainnya, other, dll | Lainnya |

Jika tidak cocok dengan whitelist → simpan as-is, jangan reject.

---

## LANGKAH WAJIB

### Step 1 — Parse Tanggal
```
tgl dari input → parse DD/MM/YYYY
Jika tidak ada → gunakan CURRENT_DATE
Jika format salah → reply error format
```

### Step 2 — Deteksi Mode
```
Ada baris dengan format "[X] | [Y] | [Z]" → Multi Mode
Tidak ada → Single Mode
```

### Step 3 — Normalisasi Tujuan
Untuk setiap customer, normalisasi tujuan ke whitelist.

### Step 4 — Cek Late Plan
```
submitted_at = NOW()
is_late_plan = (tanggal == CURRENT_DATE AND TIME(NOW()) > '08:00:00')
```

### Step 5 — Insert ke Database
```sql
-- Untuk setiap customer (loop):
INSERT INTO sales_plan
  (user_id, tanggal, customer_name, tujuan, goal, seq,
   submitted_at, is_late_plan)
VALUES
  ($user_id, $tanggal, $customer_name, $tujuan, $goal, $seq,
   NOW(), $is_late_plan)
ON CONFLICT (user_id, tanggal, customer_name)
DO UPDATE SET
  tujuan       = EXCLUDED.tujuan,
  goal         = EXCLUDED.goal,
  submitted_at = EXCLUDED.submitted_at,
  is_late_plan = EXCLUDED.is_late_plan;
```

### Step 6 — Reply ke Grup

**Sukses — On Time:**
```
✅ Plan tercatat, {nama}
📅 {hari}, {tanggal_formatted} — {N} customer:
  1. {Customer 1} → {Tujuan}
  2. {Customer 2} → {Tujuan}
  ...
```

**Sukses — Late Plan (> 08:00):**
```
✅ Plan tercatat, {nama}
⏰ Plan masuk {HH:MM} — melewati batas jam 08:00

📅 {hari}, {tanggal_formatted} — {N} customer:
  1. {Customer 1} → {Tujuan}
  2. {Customer 2} → {Tujuan}
```

**Multi mode, sebagian gagal parse:**
```
✅ {N_sukses} customer berhasil dicatat.
⚠️ {N_gagal} baris tidak bisa diparse:
  - Baris 3: format tidak valid

Format multi: [Customer] | [tujuan] | [goal]
```

---

## ERROR HANDLING

**Tanggal tidak valid:**
```
❌ Format tanggal salah.
Gunakan: tgl: DD/MM/YYYY
Contoh: tgl: 21/05/2026
```

**Customer kosong:**
```
❌ Nama customer tidak boleh kosong.
```

**Database error:**
```
⚠️ Gagal menyimpan plan. Coba lagi atau hubungi admin.
```

---

## FORMAT TANGGAL DISPLAY
- Gunakan nama hari Indonesia: Senin, Selasa, Rabu, Kamis, Jumat, Sabtu, Minggu
- Format: `Kamis, 21 Mei 2026`
