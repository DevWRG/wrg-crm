# Setup & Deployment Guide

Untuk tim baru yang nge-onboard, atau deploy ke Mac Mini baru.
Estimated time: ~45 menit kalau prereq udah ready, ~2 jam kalau install dari nol.

> **Audience**: developer/sysadmin yang familiar dgn macOS terminal, Homebrew, PostgreSQL, dan crontab.

---

## 1 · Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| macOS | 14+ (Sonoma/Sequoia) | — |
| Homebrew | latest | `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"` |
| PostgreSQL | 16.x | `brew install postgresql@16` |
| Python | 3.9+ (built-in di macOS) | tidak perlu install |
| Google Chrome | latest | `brew install --cask google-chrome` (untuk PDF export) |
| openclaw | v2026.5.7+ | Lihat repo internal openclaw setup |
| gh CLI | optional | `brew install gh` (untuk GitHub ops) |
| jq | latest | `brew install jq` |

**Catatan macOS Sequoia**: TCC (Transparency Consent & Control) lebih ketat. Lihat §6 untuk workaround LaunchAgent + Documents folder access.

---

## 2 · Clone & directory layout

```bash
cd ~/Documents
git clone https://github.com/DevWRG/wrg-crm.git
cd wrg-crm
```

Struktur yang muncul setelah deploy lengkap:

```
~/Documents/wrg-crm/         (tracked di git)
├── config/, schema/, scripts/, skills/, .gitignore, README.md
├── backups/                 (created at first cron run, gitignored)
├── data/state/              (auto-init by env-switch, gitignored)
├── exports/                 (created by export_pdf.sh, gitignored)
└── logs/                    (auto-created, gitignored)

~/wrg-crm-runtime/           (created by reload-dashboard.sh)
└── dashboard.py             (TCC workaround copy — see §6)

~/Library/LaunchAgents/
└── ai.wrg-crm.dashboard.plist  (deployed in §6)
```

---

## 3 · PostgreSQL setup

### 3.1 Start service

```bash
brew services start postgresql@16
psql --version  # verify: psql (PostgreSQL) 16.x
```

### 3.2 Create user + databases

```bash
# Pakai username macOS lo (yg jadi default superuser oleh homebrew)
psql -d postgres <<'SQL'
CREATE USER wrg_admin WITH SUPERUSER;
CREATE DATABASE wrg_crm_dev   OWNER wrg_admin;
CREATE DATABASE wrg_crm_prod  OWNER wrg_admin;
SQL
```

### 3.3 Apply schema (dev DB)

```bash
psql -U wrg_admin -d wrg_crm_dev -v ON_ERROR_STOP=1 -f schema/00_initial.sql
psql -U wrg_admin -d wrg_crm_dev -v ON_ERROR_STOP=1 -f schema/master_data_seed.sql
```

**Verify** — harus lihat 62 user, 97 territory rows, 16 holiday:

```bash
psql -U wrg_admin -d wrg_crm_dev -tA -c "
  SELECT 'users=' || COUNT(*) FROM master_user;
  SELECT 'territory=' || COUNT(*) FROM master_territory;
  SELECT 'holidays=' || COUNT(*) FROM master_holiday;
  SELECT 'is_working(today)=' || is_working_day(CURRENT_DATE);
"
```

### 3.4 Apply schema (prod DB) — saat siap go-live

```bash
psql -U wrg_admin -d wrg_crm_prod -v ON_ERROR_STOP=1 -f schema/00_initial.sql
psql -U wrg_admin -d wrg_crm_prod -v ON_ERROR_STOP=1 -f schema/master_data_seed.sql
```

> ⚠️ `schema/schema_update_v2.sql` & `schema/sales_todo_v1.sql` adalah migrasi **historis** yg sudah ter-incorporate di `00_initial.sql`. Skip; jangan dijalankan di fresh DB.

### 3.5 Update kalender libur tiap awal tahun

Edit `schema/master_data_seed.sql` section 5 → tambah tanggal libur tahun baru. Lalu:

```bash
psql -U wrg_admin -d wrg_crm_dev  -c "INSERT INTO master_holiday ... ON CONFLICT DO NOTHING;"
psql -U wrg_admin -d wrg_crm_prod -c "INSERT INTO master_holiday ... ON CONFLICT DO NOTHING;"
```

---

## 4 · openclaw gateway (WhatsApp bot)

openclaw adalah gateway WA proprietary internal. Anggap udah punya account agent. Yang perlu setup:

### 4.1 Agent name + WA pairing

```bash
openclaw agent create wrg-crm
openclaw channel auth whatsapp --agent wrg-crm
# Scan QR di iPhone WhatsApp → Linked Devices → Link a Device
```

Verify pairing:
```bash
openclaw channel status whatsapp --agent wrg-crm
# expect: Connected (+62...)
```

### 4.2 OpenRouter API key (untuk AI daily summary)

```bash
# Edit auth profile file
$EDITOR ~/.openclaw/agents/wrg-crm/agent/auth-profiles.json
```

Set struktur:
```json
{
  "profiles": {
    "openrouter:default": {
      "key": "sk-or-v1-XXXXXXXX..."
    }
  }
}
```

Sumber API key: https://openrouter.ai/keys (akun internal WRG).

### 4.3 Catat WA group JID untuk dev filter

Bot harus join grup test "WRG Research". Setelah join, get JID:

```bash
openclaw chat list --agent wrg-crm | grep -i research
# expect: 120363409252019573@g.us  WRG Research
```

Update `config/config.sh` kalau JID berbeda (default sudah ada).

---

## 5 · Config file

`config/config.sh` sudah aman sebagaimana adanya untuk Mac Mini WRG. Yang perlu di-review/customize kalau deploy ke instance lain:

| Variable | Default | Action |
|----------|---------|--------|
| `BOT_NUMBER` | `+6285168121906` | Update kalau pakai nomor bot lain |
| `ADMIN_NUMBER` | `+6285733048855` (Husni) | Update ke owner instance |
| `RESEARCH_GROUP_JID` | `120363409252019573@g.us` | Update ke grup test lo |
| `DAILY_MODEL_PRIMARY` | `openrouter/anthropic/claude-haiku-4.5` | Bisa ganti |
| `DAILY_MODEL_FALLBACK` | `openrouter/deepseek/deepseek-r1` | Bisa ganti |

Sanity test config:
```bash
source config/config.sh
echo "Env: $WRG_ENV, DB: $PGDATABASE, Bot: $BOT_NUMBER, Admin: $ADMIN_NUMBER"
$PSQL -c "SELECT 'db connected'" 2>&1 | head -2
```

---

## 6 · Dashboard via launchd (Mac Mini)

Dashboard `scripts/dashboard.py` di-supervise launchd (auto-start saat boot, restart kalau crash).

### 6.1 macOS Sequoia TCC workaround

**Problem**: macOS Sequoia blokir LaunchAgent baru baca folder Documents, walaupun Full Disk Access udah granted ke Python.app. Per-LaunchAgent label butuh TCC consent terpisah yang tidak mudah di-grant.

**Workaround**: simpan script di luar `~/Documents/`. Repo tetap di Documents, script runtime copy ke `~/wrg-crm-runtime/`.

### 6.2 Setup TCC grant

1. **System Settings → Privacy & Security → Full Disk Access**
2. Klik **+**, Cmd+Shift+G di Finder dialog, paste path:
   ```
   /Library/Developer/CommandLineTools/Library/Frameworks/Python3.framework/Versions/3.9/Resources/Python.app
   ```
3. Pilih `Python.app`, Open. Pastikan toggle hijau.

### 6.3 Bikin LaunchAgent plist

Karena plist nge-reference path absolute, harus dibikin per-machine. Simpan di `~/Library/LaunchAgents/ai.wrg-crm.dashboard.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key>             <string>ai.wrg-crm.dashboard</string>
  <key>RunAtLoad</key>         <true/>
  <key>KeepAlive</key>         <true/>
  <key>ThrottleInterval</key>  <integer>10</integer>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/python3</string>
    <string>/Users/development/wrg-crm-runtime/dashboard.py</string>
    <string>--port</string>     <string>8091</string>
    <string>--bind</string>     <string>127.0.0.1</string>
  </array>
  <key>WorkingDirectory</key>     <string>/Users/development/wrg-crm-runtime</string>
  <key>StandardOutPath</key>      <string>/Users/development/wrg-crm-runtime/dashboard.log</string>
  <key>StandardErrorPath</key>    <string>/Users/development/wrg-crm-runtime/dashboard.err.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>                  <string>/opt/homebrew/opt/postgresql@16/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>WRG_CRM_PROJECT_DIR</key>   <string>/Users/development/Documents/wrg-crm</string>
  </dict>
</dict></plist>
```

Ganti `/Users/development/` ke home dir lo kalau berbeda.

### 6.4 Deploy

```bash
# Copy script ke runtime location + restart launchd
bash scripts/reload-dashboard.sh

# Load LaunchAgent
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/ai.wrg-crm.dashboard.plist

# Verify
launchctl list | grep wrg-crm    # expect PID nyala (kolom pertama)
curl -fsS http://127.0.0.1:8091/api/env
# {"env":"dev","db":"wrg_crm_dev",...}
```

Buka **http://127.0.0.1:8091** di browser. Default view "Per Orang", periode "Minggu ini".

### 6.5 Workflow edit dashboard

```bash
# Edit di Documents
$EDITOR ~/Documents/wrg-crm/scripts/dashboard.py

# Sync + restart
bash ~/Documents/wrg-crm/scripts/reload-dashboard.sh
# Output: "OK: http://127.0.0.1:8091/ responding"
```

---

## 7 · Crontab

Cron tidak di-track repo — tambah manual.

```bash
crontab -e
```

Append:
```cron
# PATH biar bisa nemu psql, jq, openclaw, dll
PATH=/opt/homebrew/bin:/opt/homebrew/opt/postgresql@16/bin:/usr/local/bin:/usr/bin:/bin

# Inbound poller — fetch WA & dispatch ke skill
*/1  *  *  *  *  bash /Users/development/Documents/wrg-crm/scripts/wrg-inbound.sh >> /Users/development/Documents/wrg-crm/logs/cron.log 2>&1

# Daily reminders (dev & prod aware via env-switch)
15   8  *  *  *  bash /Users/development/Documents/wrg-crm/scripts/wrg-daily.sh plan_check     >> /Users/development/Documents/wrg-crm/logs/cron.log 2>&1
30  20  *  *  *  bash /Users/development/Documents/wrg-crm/scripts/wrg-daily.sh report_check   >> /Users/development/Documents/wrg-crm/logs/cron.log 2>&1
0   22  *  *  1-5 bash /Users/development/Documents/wrg-crm/scripts/wrg-daily.sh daily_summary >> /Users/development/Documents/wrg-crm/logs/cron.log 2>&1

# HOD daily sales update reminder ke grup Koord HoD (giliran genap=Rocky/ganjil=Yogi, deadline 20:30)
0   20  *  *  1-5 bash /Users/development/Documents/wrg-crm/scripts/cron_hod_daily_reminder.sh  >> /Users/development/Documents/wrg-crm/logs/cron.log 2>&1

# Auto-detect izin/sakit/cuti dari grup HRD via LLM + approval (docs/AUTO-DETECT-LEAVE.md)
*/10 *  *  *  *  bash /Users/development/Documents/wrg-crm/scripts/detect_leave.sh             >> /Users/development/Documents/wrg-crm/logs/cron.log 2>&1

# Backup PG nightly
0    2  *  *  *  bash /Users/development/Documents/wrg-crm/scripts/backup_pg.sh                >> /Users/development/Documents/wrg-crm/logs/cron.log 2>&1

# Weekly PDF report ke admin tiap Senin 07:00 WIB
0    7  *  *  1  bash /Users/development/Documents/wrg-crm/scripts/cron_weekly_report.sh       >> /Users/development/Documents/wrg-crm/logs/cron.log 2>&1
```

Verify cron daemon jalan + entries ke-load:
```bash
crontab -l | grep wrg-crm | wc -l   # expect 7
tail -f logs/cron.log               # tunggu 1 menit, lihat inbound polling
```

---

## 8 · Smoke test end-to-end (dev env)

```bash
# 1. Env confirm
bash scripts/env-switch.sh status
# Current: dev, DB: wrg_crm_dev

# 2. Dashboard responsive
curl -fsS http://127.0.0.1:8091/api/env

# 3. Seed demo data (TRUNCATE + insert ~600 rows di dev DB)
python3 scripts/seed_demo_data.py
# Generated: sales_plan=435, sales_todo=175, activity=365

# 4. Browser open
open http://127.0.0.1:8091/

# 5. PDF export dry run
bash scripts/export_pdf.sh 2026-05-04 2026-05-22
# expect: PDF di exports/, ~660KB

# 6. Cron weekly report dry-run (gak kirim WA)
bash scripts/cron_weekly_report.sh --dry-run 2026-05-18 2026-05-22
# expect: print formatted WA message (DRY RUN block)
```

Kalau semua 6 step lulus → setup selesai.

---

## 9 · Go-live (switch dev → prod)

Setelah tim WA sudah di-edukasi format `#PLAN` / `#REPORT`:

```bash
# 1. Backup dev sebagai safety
bash scripts/backup_pg.sh

# 2. Reset prod DB (TRUNCATE test data kalau ada)
psql -U wrg_admin -d wrg_crm_prod -c "
  TRUNCATE activity_log, sales_plan, sales_todo RESTART IDENTITY CASCADE;
"

# 3. Flip env
bash scripts/env-switch.sh prod
# → minta YES confirm → flip data/state/environment ke 'prod'

# 4. Effective di cron tick berikutnya (max 60s)
tail -f logs/cron.log    # liat inbound mulai process all groups

# 5. Dashboard otomatis switch ke wrg_crm_prod
curl -s http://127.0.0.1:8091/api/env
# {"env":"prod","db":"wrg_crm_prod",...}
```

Emergency revert ke dev:
```bash
bash scripts/env-switch.sh dev
```

---

## 10 · Troubleshooting

### Dashboard `HTTP 502` / `Connection refused`
```bash
launchctl list | grep wrg-crm
# Jika kosong → re-bootstrap (lihat §6.4)
# Jika PID = "-" + exit code 2 → TCC blokir, cek §6.1-§6.2
cat ~/wrg-crm-runtime/dashboard.err.log | tail -20
```

### `wrg-inbound` gak fetch pesan
```bash
tail -50 logs/cron.log | grep inbound
# - "openclaw timeout"   → cek openclaw daemon: `openclaw daemon status`
# - "channel disconnected" → WA logged out, re-pair (§4.1)
```

### Plan/report submit gagal di-parse
```bash
# Cek processed_message buat liat trace
psql -U wrg_admin -d wrg_crm_dev -c "
  SELECT id, hashtag, status, error_detail, created_at
  FROM audit_log ORDER BY id DESC LIMIT 10;
"
```

### Cron entries gak fire
```bash
# macOS bisa block cron via SIP. Verify cron daemon ada:
sudo launchctl list | grep com.vix.cron
# Kosong = cron daemon stopped. Restart:
sudo launchctl bootstrap system /System/Library/LaunchDaemons/com.vix.cron.plist
```

### TCC grant Python.app gak nyangkut
1. Verifikasi grant pas: System Settings → Privacy & Security → Full Disk Access → `Python.app` toggle ON
2. Restart launchd job: `launchctl kickstart -k gui/$(id -u)/ai.wrg-crm.dashboard`
3. Tail error log: `tail -f ~/wrg-crm-runtime/dashboard.err.log`
4. Kalau masih blocked: `tccutil reset SystemPolicyAllFiles` (system-wide reset — drastis!)

### PDF export gagal (`HTTP 000`)
Dashboard mungkin lagi down. Cek §10.1 dulu, baru retry export.

---

## 11 · Daily operations cheat sheet

| Task | Command |
|------|---------|
| Cek env aktif | `bash scripts/env-switch.sh status` |
| Switch env | `bash scripts/env-switch.sh dev/prod` |
| Reload dashboard | `bash scripts/reload-dashboard.sh` |
| Generate PDF (minggu ini) | `bash scripts/export_pdf.sh` |
| Generate PDF custom range | `bash scripts/export_pdf.sh 2026-05-04 2026-05-22` |
| Preview prod tanpa flip | `open "http://127.0.0.1:8091/?env=prod"` |
| Manual run cron weekly | `bash scripts/cron_weekly_report.sh` |
| Test HOD reminder (tanpa kirim) | stub `openclaw` di PATH lalu `bash scripts/cron_hod_daily_reminder.sh` (lihat `docs/HOD-DAILY-REMINDER.md`) |
| Regenerate README screenshots | seed demo data → `cd frontend && WRG_SERVICE_TOKEN=<token-:8092> node scripts/wrg-readme-shots.mjs` |
| Seed demo data (dev only) | `python3 scripts/seed_demo_data.py` |
| Reset test data (dev) | `psql -U wrg_admin -d wrg_crm_dev -c "TRUNCATE activity_log, sales_plan, sales_todo RESTART IDENTITY CASCADE;"` |
| Backup manual | `bash scripts/backup_pg.sh` |
| Restore dari backup | `psql -U wrg_admin -d wrg_crm_dev -f backups/wrg_crm_YYYY-MM-DD.dump` |
| Tail logs | `tail -f logs/cron.log logs/daily.log` |

---

## 12 · Next steps setelah onboarding

- Baca `README.md` untuk arsitektur high-level
- Baca `skills/wrg-router/SKILL.md` untuk paham flow routing
- Cek `skills/wrg-plan/SKILL.md` & `skills/wrg-report/SKILL.md` untuk parser logic
- Eksperimen via grup test (Research) — submit `#PLAN`, `#REPORT`, lihat trace di `audit_log`

Kalau ada hal yg gak jelas, atau script yg behaviornya beda dari dokumentasi: update file ini, commit, push.
