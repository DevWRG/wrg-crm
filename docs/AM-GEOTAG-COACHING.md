# Coaching AM — Geo-Tagging Camera

Versi: 2026-06-02
Audience: Account Manager (AM Sales)
Why: Day 1 AM rollout — 66/84 plans reported (79%), tapi cuma **2 plans yang foto-nya ter-verifikasi geotag**. App yg dipakai mayoritas ga punya lat/lon di watermark.

---

## 🎯 Kenapa Geotag Penting

Foto visit AM diverifikasi sistem dgn 3 cek:

1. **Photo presence** — ada foto = visit ter-dokumentasi
2. **Geotag (lat/lon)** — buktikan lokasi sebenernya match dgn customer
3. **Tanggal foto** — match dgn tanggal report (anti-backdate)

Tanpa geotag di pixel foto: report **diterima tapi visit tidak ter-verifikasi**. HOD lihat status: `⚠️ no geotag` di dashboard drilldown.

WhatsApp **strip metadata EXIF GPS** otomatis saat kirim foto. Jadi metadata GPS dari kamera HP biasa pasti hilang. Solusi: app yang **burn lat/lon langsung di pixel foto** (jadi watermark visible).

---

## 📱 App Recommendation

### Pilihan #1: *Geo-Tagging Camera* (Android/iOS, GRATIS)

- Play Store: cari "Geo-Tagging Camera"
- App Store: cari "Geo-Tagging Camera"
- Watermark format: `Lat -7.282302 Long 112.754749` + alamat lengkap + tanggal/jam

### Pilihan #2: *GPS Map Camera* (alternative, juga gratis)

- Cari di Play Store / App Store dgn nama exact "GPS Map Camera"
- Format watermark sedikit beda (`-7,2823° 112,7547°`) tapi bot handle dua-duanya

### Yang TIDAK Work

- ❌ Kamera bawaan HP (default Camera app)
- ❌ Apps lain yang cuma tampilkan tanggal + altitude tanpa lat/lon (mis. Solocator versi free, Timestamp Camera)
- ❌ Screenshot dari Google Maps
- ❌ Foto dari Gallery / WA Web

**Cara cek**: foto lu harus ada teks `Lat <angka> Long <angka>` di sudut bawah. Kalau cuma date + altitude/compass, **bukan yang benar**.

---

## 📋 Workflow Visit + Photo

### Saat Visit di Customer

1. Buka *Geo-Tagging Camera* (jangan kamera biasa)
2. Pastikan GPS HP aktif (Setting → Location → ON)
3. Foto **subjek visit** (gedung customer, user lab, alat, dll)
4. Pastikan watermark di sudut foto terbaca jelas
5. Save (otomatis ke gallery)

### Kirim ke Grup WRG

1. Selesai semua visit, kirim **text #REPORT dulu** di grup WRG:
   ```
   #REPORT [PanggilanLu] 2/6/2026
   1. RS Mitra Keluarga
   Hasil: meeting purchasing dgn bu Yuli
   Next: tunggu PO end of week
   
   2. Lab Prodia Surabaya
   ...
   ```

2. Bot reply confirm + list customer yang belum ada foto
3. **Kirim foto satu per satu** dgn caption nama customer:
   - Foto 1, caption: `1. RS Mitra Keluarga` (atau cukup nama customer)
   - Foto 2, caption: `2. Lab Prodia Surabaya`
   - dst
4. Bot reply per foto: confirm matched + check geotag

Catatan: caption boleh tanpa nomor (mis. `RS Mitra Keluarga` aja). Fuzzy match akan resolve. Yang penting **nama customer benar minimum 1 keyword**.

---

## ⚠️ Common Mistakes Day 1

| Salah | Bener |
|---|---|
| Foto pakai Solocator (cuma date+altitude) | Geo-Tagging Camera (lat+long burn di pixel) |
| Foto langsung kirim dari gallery (WA strip EXIF) | Pakai app yg burn coords di pixel saat foto diambil |
| Caption foto `1. RS Bargraf l visit l...` (huruf l) | Pipe `|` (shift+\\): `1. RS Bargraf \| visit \| ...` (cuma untuk #PLAN, bukan caption foto) |
| #PLAN setelah 08:00 | Sebelum 08:00 — kena late flag kalau lewat |
| Foto tanggal kemarin di-pakai untuk report hari ini | Foto harus diambil hari yg sama dgn tanggal report |
| Skip #PLAN, langsung #REPORT | Selalu #PLAN dulu pagi, #REPORT sore |

---

## 🆘 Help

Tanya / report bug langsung WA Husni.

Brief #PLAN & #REPORT lengkap: dokumen yg di-share kemarin di grup ini.

Dashboard cek progress: link akan dishare admin.
