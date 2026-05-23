---
name: wrg-leads
description: Parse #LEADS hashtag → insert ke pipeline_tracker (prospek baru)
---

# wrg-leads
**Trigger:** `/^#leads/i`  
**Role:** Tambah prospek/customer baru ke master_data + pipeline_tracker  
**Depends on:** wrg-router (context sudah di-inject)

---

## INPUT FORMAT
```
#LEADS
cust: [nama institusi baru]
pic: [nama PIC] ([kontak opsional])
tipe: [RS|Klinik|Lab|Apotek|dll]
produk: [produk diminati]
info: [konteks tambahan]
```

Field wajib: `cust`  
Field opsional: `pic`, `tipe`, `produk`, `info`

---

## TIPE WHITELIST

| Input | Tersimpan Sebagai |
|---|---|
| rs, rumah sakit, hospital | RS |
| klinik, clinic | Klinik |
| lab, laboratorium, laboratory | Lab |
| apotek, apotik, pharmacy | Apotek |
| puskesmas, pkm | Puskesmas |
| klinik kecantikan, estetik | Klinik Kecantikan |
| lainnya, other, dll | Lainnya |

Jika tidak cocok → simpan as-is.

---

## LANGKAH WAJIB

### Step 1 — Cek Duplikat di master_data
```sql
SELECT id, customer_name, area, tipe
FROM master_data
WHERE similarity(customer_name, $input_cust) > 0.70
  AND (area = $user_area OR area IS NULL)
ORDER BY similarity(customer_name, $input_cust) DESC
LIMIT 3;
```

**Jika ada duplikat potensial (score ≥ 0.70):**
```
⚠️ Customer serupa sudah ada di database:
  1️⃣ {existing_1} ({tipe}, {area})
  2️⃣ {existing_2} ({tipe}, {area})

Ini customer yang sama?
  • Balas SAMA 1 / SAMA 2 → update existing
  • Balas BARU → lanjut tambah sebagai customer baru
```

**Jika tidak ada duplikat → lanjut Step 2.**

### Step 2 — Insert ke master_data
```sql
INSERT INTO master_data
  (customer_name, area, tipe, pic_name, pic_contact, alamat)
VALUES
  ($cust, $user_area, $tipe_normalized, $pic_name, $pic_contact, NULL)
ON CONFLICT DO NOTHING
RETURNING id;
```

### Step 3 — Buat Entry Pipeline
```sql
INSERT INTO pipeline_tracker
  (user_id, customer_name, stage, status, note)
VALUES
  ($user_id, $cust, 1, 'Cold', $info)
RETURNING id;
```

Stage 1 = Cold Lead (entry point semua leads baru).

### Step 4 — Reply ke Grup

**Sukses (baru):**
```
✅ Leads baru tercatat, {nama}
🏢 {customer_name}
   Tipe    : {tipe}
   PIC     : {pic_name} {pic_contact}
   Produk  : {produk}
   Info    : {info}
   Pipeline: Stage 1 — Cold Lead

Gunakan #UPDATE untuk update progress pipeline.
```

**Sukses (update existing setelah konfirmasi):**
```
✅ Pipeline diupdate, {nama}
🏢 {customer_name} (existing)
   Note baru: {info}
   Status   : tetap {stage}/{status}
```

---

## ERROR HANDLING

**Nama customer kosong:**
```
❌ Nama customer wajib diisi.

Format:
#LEADS
cust: [nama institusi]
```

**Database error:**
```
⚠️ Gagal menyimpan leads. Coba lagi atau hubungi admin.
```
