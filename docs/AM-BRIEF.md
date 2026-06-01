# Brief AM — #PLAN & #REPORT WRG CRM

Versi: 2026-06-01
Audience: Account Manager (AM Sales)

---

## 📅 #PLAN (Pagi, sebelum jam 08:30)

Kirim ke grup WRG di WhatsApp:

```
#PLAN Iqbal 2/6/2026
1. RS Mitra Keluarga | demo | sign MoU Cobas
2. Lab Prodia Surabaya | kunjungan fisik | follow up PO
3. RS Al-irsyad | visit | tawarkan reagen
```

**Format per baris**: `Nomor. Nama Customer | Tujuan | Goal`

- **Tujuan**: demo / kunjungan fisik / negosiasi / visit / closing
- **Goal**: ringkas tujuan visit
- Pisah pakai `|`

**Late penalty**: kirim setelah 08:30 → late flag visible di dashboard HOD.

---

## 📋 #REPORT (Sore / EOD)

### Step 1 — Kirim teks report dulu (1 pesan untuk semua customer)

```
#REPORT Iqbal 2/6/2026
1. RS Mitra Keluarga
Hasil: meeting purchasing
Next: tunggu PO

2. Lab Prodia Surabaya
Hasil: visit selesai
Next: follow up PO end of week

3. RS Al-irsyad
Hasil: presentasi produk
Next: tunggu approval direksi
```

Bot bakal balas:

```
✅ Report EOD tercatat, Iqbal
🗒️ 3 customer reported
📊 3/3 selesai
⚠️ Foto visit belum ada (3 customer):
RS Mitra Keluarga, Lab Prodia Surabaya, RS Al-irsyad
```

### Step 2 — Kirim foto per customer (1 foto per pesan)

**Foto WAJIB pakai app Geo-Tagging Camera** (atau GPS Map Camera) — yang **burn lat/lon + tanggal langsung di pixel foto**. App biasa ga jalan (WA strip EXIF metadata).

Caption foto: **nama customer + nomor** (mis. `1. RS Mitra Keluarga`).

- Nomor sebagai counter aja — yang penting **nama customer benar** (fuzzy match toleran typo).
- 1 foto = 1 pesan = 1 customer.

Bot bakal balas tiap foto:

```
✅ Foto RS Mitra Keluarga tersimpan. Sisa 2 customer belum ada foto:
⚠️ Lab Prodia Surabaya, RS Al-irsyad
```

Setelah foto terakhir:

```
✅ Foto RS Al-irsyad tersimpan. ✅ Semua foto visit lengkap.
```

---

## ⚠️ Rules

| Aturan | Konsekuensi |
|---|---|
| Foto bukan dari Geo-Tagging Camera | Geotag ga ke-detect → warning, visit ga ke-verifikasi |
| Foto tanggal ≠ tanggal report (backdated) | Date mismatch flag → visible di dashboard HOD |
| Customer di foto ga match plan | Activity log unmatched → HOD aware |
| Kelupaan foto 1 customer | Plan status "reported tapi tanpa visit verification" |

---

## 🎯 App Recommendation

**Geo-Tagging Camera** (Android/iOS, free):

- Auto-burn lat/lon + alamat + tanggal/jam di sudut foto
- Tetap kebaca walau WA compress
- Format watermark contoh: `Lat -7.282302 Long 112.754749 / 2026-06-02 14:30`

Alternatif: **GPS Map Camera** (juga work, format watermark sedikit beda — bot handle dua-duanya).

---

## 📊 Dashboard

Cek progress sendiri di dashboard (URL akan disebar admin).
Login: pakai panggilan + password awal `<panggilan_lowercase>123`. Ganti password setelah login pertama.

- **Detail Plan & Report** → drilldown per-day per-AM
- **Visit geotag kolom**: klik link Google Maps untuk verify lokasi
- **Date mismatch flag**: customer yang foto ga sesuai tanggal report ditandai ⚠️

---

## ❓ FAQ

**Q: Kalau ga ada visit hari ini, gimana?**
A: Kirim #PLAN dgn 0 customer atau skip. HOD aware via dashboard.

**Q: Foto dari kamera HP biasa boleh?**
A: Ga boleh untuk verifikasi visit. WA strip metadata EXIF. Wajib pakai Geo-Tagging Camera atau GPS Map Camera yang burn coords di pixel.

**Q: Kalau foto 1 customer ada 2 (mis. depan toko + dalam)?**
A: Pilih 1 yang paling jelas watermark-nya. Bot pair 1 foto per customer.

**Q: Caption typo nama customer, gimana?**
A: Fuzzy match akan handle (similarity ≥ 30%). Tapi pastikan nama customer benar minimal 1 kata kunci.

**Q: Kirim semua foto sekaligus (multiple attach 1 message)?**
A: WA Web kirim sebagai pesan terpisah masing-masing dgn caption sendiri. Bot proses individually — OK.
