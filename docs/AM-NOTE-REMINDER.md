# Brief AM — Note Reminder di #REPORT

Versi: 2026-06-03
Audience: Account Manager (AM Sales)

---

## 📌 Apa itu Note Reminder

AM bisa attach catatan `note:` di #REPORT untuk **reminder otomatis di tanggal masa depan**. Bot akan kirim reminder ke grup The ALLIANCE:

- **H-1 sore (17:03)** — heads-up reminder besok
- **H pagi (07:03)** — reminder hari itu (sebelum 08:00 #PLAN threshold)

Useful untuk: follow-up customer, deal closing tanggal tertentu, visit ulang, jadwal meeting, dll.

---

## 📋 Format

Single line, ditulis **di bawah customer entry** yang relevan:

```
note: TGL keterangan
```

atau (huruf capital juga OK):
```
Note : TGL keterangan
```

**Date format** flexible:
- `7/6/2026` atau `7-6-2026` (DD/MM/YYYY)
- `7/6/26` (year short auto-prefix 20xx)
- `7 Jun 2026` atau `7 Juni 2026` (month name Indonesia + English)

Bisa **multi-note** dalam 1 #REPORT — satu per baris.

---

## ✅ Contoh

```
#REPORT Iqbal 3/6/2026

1. RS Mitra Keluarga
Hasil: meeting purchasing
Next: tunggu PO
Note: 5/6/2026 follow up deal closing

2. Lab Prodia Surabaya
Hasil: visit selesai
Next: tunggu sample
Note: 10/6/2026 visit ulang ke kalab

3. RS Al-irsyad
Hasil: presentasi produk
Next: tunggu approval

Note: 15/6/2026 ketemu direktur RS Mitra untuk lobby PO
```

Bot bakal balas:

```
✅ Report EOD tercatat, Iqbal
...
📌 Note tercatat: 2026-06-05 (RS Mitra Keluarga) — follow up deal closing
📌 Note tercatat: 2026-06-10 (Lab Prodia Surabaya) — visit ulang ke kalab
📌 Note tercatat: 2026-06-15 (RS Mitra Keluarga) — ketemu direktur RS Mitra untuk lobby PO
```

---

## 🎯 Auto-detect Customer

Bot otomatis link note ke customer **berdasarkan posisi** di body — note di bawah customer #X → reminder pakai customer #X.

Kalo lu tulis note di paling bawah (luar urutan customer), bot fallback ke fuzzy match nama customer dari keterangan. Disarankan tulis **di bawah customer-nya** biar pasti.

---

## 🔔 Cara Reminder Sampai

Tanggal mendekati, AM + HOD bakal lihat di grup The ALLIANCE:

**H-1 17:03 (sore sebelumnya)**:
```
📅 Heads-up reminder besok (2026-06-05)

*Iqbal:*
• follow up deal closing
```

**H 07:03 (pagi hari itu)**:
```
🔔 Reminder hari ini (2026-06-05)

*Iqbal:*
• follow up deal closing
```

Plus visible di **Sales Calendar dashboard** sebagai pink pill (`📌`) di tanggal yang relevan.

---

## ⚠️ Rules

| Aturan | Note |
|---|---|
| Tanggal harus masa depan | Lewat = diabaikan |
| Format tanggal salah | Note skip (ga error fatal) |
| Note tanpa customer terdekat | Customer column kosong di dashboard |
| Multiple notes same date | Semua tersimpan terpisah |
| Hari libur | Reminder tetap fire (note buat reminder personal, not work-day check) |

---

## 🆘 Help

Tanya / report bug langsung WA Husni.

Brief lengkap: dokumen sebelumnya di grup ini (AM-BRIEF.md + AM-GEOTAG-COACHING.md).
