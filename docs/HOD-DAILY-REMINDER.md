# HOD Daily Sales Update Reminder

Versi: 2026-06-09
Audience: Admin / sysadmin (ops)

---

## 📌 Apa itu

Reminder otomatis ke grup **Koord HoD** untuk HOD yang giliran share *daily sales update* hari itu. Mengingatkan supaya update dikirim **maksimal jam 20:30**.

Daily update = pesan `Berikut update DD/MM/YYYY` + foto/dokumen rekap.

---

## 🔁 Pembagian giliran

Berdasarkan **parity tanggal** (sesuai kesepakatan HOD: "tgl genap di-share orang lain, ganjil/Selasa Yogi"):

| Tanggal | Giliran | Nomor | Pushname |
|---------|---------|-------|----------|
| **Genap** | Rocky Gunawan | `6281213255253` | RG WG |
| **Ganjil** | Yogi Nugroho | `6281330088773` | Yogi Nugroho |

---

## ⏰ Jadwal & target

- **Cron**: `0 20 * * 1-5` (tiap weekday jam 20:00, prod-only)
- **Deadline di pesan**: maksimal **20:30**
- **Grup target**: Koord HoD — `120363404092121926@g.us`

---

## 🚫 Auto-skip

Reminder **tidak dikirim** kalau:

1. **Weekend** (Sabtu/Minggu) — cron sudah dibatasi `1-5`, plus guard di script.
2. **Hari libur** — tanggal ada di tabel `master_holiday`.
3. **Sudah posting** — yang giliran sudah kirim pesan mengandung `update` + tanggal hari ini (`dd/mm` atau `dd/mm/yyyy`) di capture jsonl hari itu.

Guard #3 baca capture: `~/.openclaw/tmp/wrg-monitor/messages/<tanggal>/120363404092121926@g.us.jsonl`.

---

## ⚙️ Implementasi

- Script: `scripts/cron_hod_daily_reminder.sh`
- Kirim via `wa_send` (openclaw `message send`).
- **Catatan mention**: `openclaw message send` tidak punya parameter mention; `@<nomor>` di body kemungkinan render plain text, bukan tag tappable. Nama panggilan (`(Rocky)` / `(Yogi)`) disertakan supaya tetap jelas.

### Contoh isi pesan

```
⏰ *Reminder Daily Sales Update HoD*

@6281330088773 (Yogi) — hari ini *Selasa, 09/06/2026* (tanggal ganjil) giliran lu share *daily update* di grup ini.

⚠️ Maksimal kirim *jam 20:30*. Jangan lupa lampirin foto/dokumen update-nya 🙏
```

---

## 🧪 Test

Grup dev/test = RESEARCH_GROUP_JID `120363409252019573@g.us`. Untuk dry-run logika tanpa kirim WA, stub binary `openclaw` di PATH lalu jalankan script.

Deployed: 2026-06-09.
