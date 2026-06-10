# Auto-detect Izin/Sakit/Cuti dari Grup HRD

Versi: 2026-06-10
Audience: Admin / sysadmin (ops)

---

## 📌 Apa itu

Otomatis deteksi pengumuman **izin/sakit/cuti individual** di grup **"HRD WG GROUP 2026"**, lalu (setelah approval admin) rekam ke `user_leave` supaya user yang absen tidak kena reminder & tidak salah dihitung di summary/dashboard.

Menggantikan input manual yang sering kelupaan → user absen "selalu diingetin" padahal sudah izin.

---

## ⚙️ Komponen

- Script: `scripts/detect_leave.sh`
- Cron: `*/10 * * * *` (tiap 10 menit, prod-only)
- Sumber: **hanya** grup HRD `120363048384809457@g.us` (env `LEAVE_HRD_GROUP_JID`)
- Engine: LLM `call_ai_with_fallback` (`DAILY_MODEL_PRIMARY`, override `LEAVE_MODEL`)
- Idempotent: `processed_message` (hashtag `leave-detect`/`leave-reply`)
- Draft approval: tabel `pending_confirm` (hashtag `leave-approval`, expire 24 jam)

---

## 🔁 Alur (semua di dalam grup HRD)

```
1. Scan pesan baru grup HRD (today + yesterday)
2. Gate keyword (izin|sakit|cuti|tidak masuk|pengajuan) → hemat LLM
3. LLM klasifikasi → JSON {is_leave, nama, jenis, start_date, end_date, confidence}
   • TOLAK "izin" sbg partikel sopan ("izin bertanya", "izin mengingatkan")
   • TOLAK libur company-wide (Idul Adha, cuti bersama)
   • first-person "saya tidak masuk" → pakai nama pengirim
4. confidence ≥ 0.6 & nama resolve ke user WAJIB & belum ada leave/pending overlap
   → INSERT pending_confirm + post di grup:
     "📋 Konfirmasi cuti — Nama X, jenis Y, tgl Z. Balas ya L<id> / tidak L<id>"
5. Balasan admin di grup:
   • "ya L<id>"    → INSERT user_leave + "✅ Tercatat"
   • "tidak L<id>" → batal, pending dihapus
```

Pending auto-expire 24 jam (housekeeping tiap run).

---

## 🛡️ Safety

- Hanya user `wajib_plan_report` (yang relevan ke reminder/summary).
- Wajib lewat **approval admin** sebelum nulis `user_leave` (anti false-positive).
- Nama harus resolve; kalau ambigu/tidak ketemu → skip + log (tidak buat pending).
- Libur company-wide **di luar scope** — itu tetap manual ke `master_holiday`.
- Tidak menyentuh `wrg-inbound.sh` (path kritikal aman).

---

## 🧪 Test

- LLM only (tanpa DB/WA): `source config/config.sh` lalu `call_ai_with_fallback "<SYS>" "<pesan>" 400`.
- DB path: validasi `pending_confirm` + `user_leave` di `wrg_crm_dev`.
- Override sumber utk dev: `LEAVE_MESSAGES_DIR=<dir> LEAVE_HRD_GROUP_JID=<jid> bash scripts/detect_leave.sh`.

Lihat juga `docs/HOD-DAILY-REMINDER.md`, dan `is_on_leave()` (leave tracking).
