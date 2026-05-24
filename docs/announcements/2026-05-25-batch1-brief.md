# Brief Batch 1 — `#PLAN` & `#REPORT` via WhatsApp

**Tanggal mulai**: Senin, 26 Mei 2026
**Berlaku untuk**: 37 orang non-AM/non-Teknisi —
Operasional · Admin · Finance · Accounting · Purchasing · Logistik · Supply Chain · GA

> AM (12) & Teknisi (5) menyusul di batch 2 — boleh ikutan sekarang kalau mau, tapi tidak wajib & tidak dapat reminder.

---

## Versi singkat (paste ke WA group)

```
📢 BRIEFING WRG CRM — Mulai Senin 26 Mei 2026

Tim Operasional, Admin, Finance, Accounting, Purchasing, Logistik,
Supply Chain, GA — kita mulai pakai bot WA untuk catat plan kerja
harian. AM & Teknisi menyusul nanti.

🎯 RULES SIMPEL:
1. Tiap pagi (atau malam sebelumnya): kirim #PLAN di grup divisi
2. Tiap sore sebelum 20:30: kirim #REPORT update progress
3. Bot bakal balas otomatis konfirmasi
4. Sabtu/Minggu/libur nasional: SKIP (gak perlu submit)

📝 FORMAT #PLAN (pagi/malam sebelumnya):

   #PLAN
   1. Task pertama
   2. Task kedua
   3. Task ketiga

📝 FORMAT #REPORT (sore):

   #REPORT
   1. Task pertama — done/in progress/blocked + catatan
   2. Task kedua — selesai
   3. Task ketiga — postponed ke besok

👥 KALAU 1 HP DIPAKAI BERSAMA (mis. admin counter):
   Tulis nama panggilan setelah #PLAN / #REPORT supaya
   bot bisa pisahin per orang:

   #PLAN Andi
   1. Task A
   2. Task B

   #REPORT Andi
   1. done
   2. done, ada catatan

   (Cukup 1 kata nama panggilan — Andi/Budi/Cici, dst.)

⏰ DEADLINE #PLAN: sebelum *08:30* (semua role batch 1)
⏰ DEADLINE #REPORT: sebelum *20:30*
- Lewat batas: bot tetap terima, tapi di-flag "late"

🔔 REMINDER:
- 08:30 — kalau belum #PLAN, bot kirim DM
- 20:30 — kalau ada #PLAN tapi belum #REPORT, bot kirim DM

❓ TANYA:
- Bot gak reply? Cek format harus mulai #PLAN atau #REPORT
- Plan/report berubah? Kirim ulang aja, bot pakai versi terakhir
- Ada error? Chat Pak Husni langsung

Semangat! 💪
```

---

## Format khusus: 1 HP dipakai bersama beberapa orang

Kalau di unit lo 1 nomor WA dipakai bergantian (mis. admin counter, gudang
shared, tim shift), tulis **nama orang yg submit** setelah `#PLAN` /
`#REPORT`. Bot bakal mencatat nama tsb di histori, walaupun secara teknis
tetap kekirim atas WA pemilik nomor.

### Format inline (1 baris dgn separator `|`)

```
#PLAN Andi 26/05/2026 | 1. Input invoice A | 2. Update DB customer | 3. Follow PO

#REPORT Andi 26/05/2026 | 1. done | 2. done, 12 record baru | 3. blocked, vendor blm balas
```

### Format multiline (lebih readable di WA)

```
#PLAN Andi 26/05/2026
1. Input invoice A
2. Update DB customer
3. Follow PO
```

```
#REPORT Andi 26/05/2026
1. done
2. done, 12 record baru
3. blocked, vendor blm balas
```

### Rules nama

- **Nama HARUS ditulis kalau HP shared.** Kalau gak ditulis, bot anggap submit dari
  owner HP (default).
- Cukup nama panggilan (1 kata) — `Andi`, `Budi`, `Cici`. Gak perlu nama lengkap.
- Tanggal opsional. Kalau gak ditulis, default = hari ini.
- Case-insensitive — `#plan andi`, `#Plan Andi`, `#PLAN ANDI` sama aja.

### Yang HARUS dihindari

```
❌ #PLAN
   1. ...        ← bot anggap kamu pemilik HP

❌ #PLAN Tim Admin Cabang Madiun lengkap
   1. ...        ← nama terlalu panjang, parser bingung

❌ #PLAN 26/05/2026  Andi
   1. ...        ← urutan salah, tanggal jangan duluan
```

### Contoh real

**Admin Counter Gudang dipakai 3 orang (Adi, Budi, Cici) — masing-masing submit pakai 1 HP yg sama:**

```
#PLAN Adi
1. Receiving 3 shipment baru
2. Update kartu stok

#REPORT Adi
1. Receiving done, 3 PO closed
2. Stok update done

──── (Budi lanjut pake HP yg sama) ────

#PLAN Budi
1. Picking 5 SO outbound
2. Packing & labeling

#REPORT Budi
1. Done semua 5
2. Done, ready ship

──── (Cici lanjut) ────

#PLAN Cici
1. Cek expired reagen
2. Update FIFO board
```

Dashboard direksi bakal show 3 entry terpisah dgn label nama "Adi", "Budi", "Cici" — meskipun WA owner-nya 1.

---

## Contoh real per role

Format **wajib mulai dgn `#PLAN` atau `#REPORT`** (case-insensitive — `#plan`, `#Plan`, `#PLAN` semua OK), diikuti list bernomor.

### Admin Sales & Penawaran (Abib / Jasyim / Puput)
```
#PLAN
1. Input 5 invoice penjualan baru ke ERP
2. Siapkan quotation utk RS Mitra Keluarga
3. Follow status PO ke supplier Roche
4. Update database customer baru cabang Bali
5. Konfirmasi spec alat ke purchasing
```

### Admin Cabang (Elok / Nungky)
```
#PLAN
1. Closing kas kecil cabang minggu lalu
2. Rekap penjualan cabang per AM
3. Update stok consignment ke Pusat
4. Approve PR dari tim AM
```

### Operasional - Kirim Tagih (Adi / Anas / Munir / Surya / dll)
```
#PLAN
1. Kirim alat Cobas Pro ke RS Mitra Keluarga Cirebon
2. Tagih invoice INV-2026-0234 ke Lab Prodia Surabaya
3. Antar dokumen kontrak ke notaris Mojokerto
4. Pickup return reagen dari Klinik Kasih Ibu
```

### Operasional - Kirim Tagih & Admin Cabang (Agus / Baginda / Ekba / Hanif / Ibnu / Karib / Rizal)
```
#PLAN
1. Tagih invoice 3 customer Kediri area
2. Update kas cabang H-1
3. Kirim sample reagen ke RS Baptis
4. Rekap KK harian
```

### Finance (Ayu / Kolis / Navisa)
```
#PLAN
1. Rekonsiliasi bank Mandiri & BCA
2. Input AR aging customer tertunggak
3. Verifikasi pembayaran customer minggu ini
4. Siapkan laporan kas mingguan
```

### Accounting (Fanessa / Putri)
```
#PLAN
1. Closing jurnal pengeluaran H-1
2. Input invoice supplier
3. Reconcile inventory shipment
```

### Purchasing (Claudya / Rahma)
```
#PLAN
1. Proses 5 PO supplier (Roche, Sysmex, Mindray)
2. Negosiasi harga reagen Q3
3. Follow ETA delivery shipment minggu ini
```

### Supply Chain (Pita)
```
#PLAN
1. Update stok gudang pusat
2. Monitor lead time 3 supplier prioritas
3. Atur shipment ke cabang Madiun + Jember
```

### Logistik (Boni)
```
#PLAN
1. Koordinasi pengiriman alat ke Bali
2. Atur ekspedisi Surabaya-Mataram
3. Follow tracking shipment pending
```

### GA (Dito)
```
#PLAN
1. Follow vendor maintenance AC kantor
2. Inventarisasi aset baru bulan ini
3. Approve permintaan perjalanan dinas tim
```

---

## Contoh #REPORT (sore)

```
#REPORT
1. Input 5 invoice — done, semua masuk ERP
2. Quotation RS Mitra — selesai, draft dikirim ke Pak Mufid
3. Follow PO Roche — ETA confirmed 28 Mei
4. Update DB customer — done, 12 record baru
5. Konfirmasi spec — pending, vendor blm balas
```

Boleh juga lebih singkat:
```
#REPORT
1. done
2. done
3. blocked - menunggu vendor
```

---

## FAQ

**Q: Lupa submit pagi, masih bisa siang?**
Bisa. Plan tetap tersimpan, tapi di-flag `late submit`. Konsisten on-time bagus untuk evaluasi.

**Q: Plan saya berubah pas tengah hari, gimana?**
Kirim ulang `#PLAN` dgn isi baru. Bot pakai versi terakhir hari itu.

**Q: Mau report tapi belum sempat plan, bisa langsung?**
Bisa. Tapi konsekuensinya plan ke-skip → tercatat "unmatched activity" di dashboard direksi.

**Q: Cuti / sakit gimana?**
Kasih tau atasan langsung lewat WA biasa. Bot bakal tetap kirim reminder (sistem belum tau cuti). Atasan tinggal mark exception manual.

**Q: HP unit kami dipakai bareng — submission orang lain dianggap saya?**
Cantumkan nama panggilan setelah hashtag, contoh `#PLAN Andi`. Liat section
"Format khusus: 1 HP dipakai bersama" di atas.

**Q: Bot kirim notif aneh / error?**
Screenshot + forward ke Pak Husni. Sertakan jam kirim & isi pesan.

---

## Untuk direksi & HOD

Dashboard real-time monitoring per orang/divisi/cabang ada di:
**http://wrg-mac-mini.local:8091** (atau IP server)

Tab "Per Orang" — drilldown ke detail plan/report per karyawan
Tab "Per Divisi" — agregat per role
Tab "Per Cabang" — agregat per cabang

PDF report mingguan ke Pak Husni tiap Senin 07:00 WIB otomatis.

---

*Brief ini di-versioning di repo `DevWRG/wrg-crm` → `docs/announcements/`. Update via PR.*
