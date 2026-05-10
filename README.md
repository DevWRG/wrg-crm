# WRG CRM Assistant — OpenClaw

WhatsApp-driven CRM untuk tim sales WRG × ACE. Memproses pesan hashtag
(`#PLAN`, `#REPORT`, `#LEADS`, `#UPDATE`) dari WA group "WRG Sales Command
Center", menyimpan ke PostgreSQL lokal, dan mengirim balasan kembali ke
group atau DM pengirim.

## Arsitektur

```
WhatsApp ──▶ OpenClaw Gateway ──▶ POST /webhook ──▶ dispatcher
                                                       │
                              ┌──── handlers/ ─────────┤
                              │  plan / report /       │
                              │  leads / update        │
                              │                        ▼
                              │                  PostgreSQL
                              │                  (wrg_crm)
                              ▼
                          sendReply()  ──▶  WA Gateway (atau mock)
```

- **Stack**: Node.js + TypeScript + Fastify + `pg` + `dayjs`
- **DB**: PostgreSQL 16 dengan ekstensi `pg_trgm` untuk fuzzy matching
- **WA**: pluggable sender (`mock` default, atau `http` ke OpenClaw/Baileys)

## Setup pertama kali

Prereq: Node 20+, PostgreSQL 16, role `wrg_admin`, DB `wrg_crm`.

```bash
# 1. install deps
npm install

# 2. siapkan env (sudah ada .env.example)
cp .env.example .env
# edit kalau perlu (WA_SEND_MODE, dll.)

# 3. init DB schema + seed user demo
npm run db:init
npm run db:seed

# 4. jalankan smoke test
npm run smoke

# 5. nyalakan webhook
npm run dev
```

Server listen di `http://localhost:3000` dengan endpoint:

- `GET /health` — health probe
- `POST /webhook` — terima inbound dari gateway
- `POST /summary/run` — manual trigger daily summary (body `{}` untuk hari ini, atau `{"date":"YYYY-MM-DD"}`)
- `GET /ops/deliveries?status=failed&since=2026-05-10T00:00:00Z&limit=100` — visibility delivery_log untuk Husni/HOD
- `POST /ops/resend-failures` — manual trigger 1 batch resend (cron jalan tiap 5 menit otomatis)
- `GET /ops/resend-stats` — `{pending, resolved24h, exhausted}` ringkasan kesehatan resend
- `GET /dashboard?token=...` — dashboard web untuk Husni / HOD (lihat **Dashboard** di bawah)
- `POST /ops/alerts/check` — manual trigger detector (cron jalan tiap 5 menit otomatis)
- `POST /ops/alerts/escalate` — manual trigger escalation detector
- `POST /ops/alerts/test` — fire test alert ke semua channel (token wajib)
- `GET /api/alerts?limit=N` — list recent alerts
- `GET /export/pipeline.csv` — full pipeline_tracker (token wajib)
- `GET /export/activity.csv?from=YYYY-MM-DD&to=YYYY-MM-DD` — activity_log (range optional)
- `GET /export/plans.csv?from=...&to=...` — sales_plan
- `GET /export/deals.csv?from=...&to=...` — deal_closed
- `GET /export/digest?from=...&to=...` — print-friendly weekly digest HTML (defaults: 7 hari terakhir)
- `POST /ops/email-digest` — kirim digest via email (body `{"from":"...","to":"...","dryRun":true}`, token wajib)
- `GET /login` — halaman login (Google SSO button)
- `GET /auth/google` — start OAuth flow
- `GET /auth/google/callback` — OAuth callback (Google → app)
- `POST /auth/logout` — destroy session + clear cookie
- `GET /api/me` — current user info (untuk dashboard)

Selain itu **scheduler** ikut start otomatis (zona `Asia/Jakarta`):
- `0 18 * * 1-6` → kirim daily summary ke `WA_HOD_GROUP_ID`
- `0 2 * * *`   → bersihkan baris `processed_message` yang sudah lewat TTL (lihat Idempotency)
- `*/5 * * * *` → coba kirim ulang `delivery_log` yang `delivered=false`, lalu evaluasi alert state (lihat Auto-resend & Alerting)
- `0 8 * * 1`   → (kalau `EMAIL_ENABLED=true` + recipients di-set) kirim weekly digest email Senin pagi (lihat Email digest)

## Format payload webhook

```json
{
  "from": "6281111111111",
  "groupId": "wrg-sales-command-center",
  "text": "#PLAN\ntgl: 01/05/2026\ncust: RS Husada\ntujuan: visit\ngoal: demo"
}
```

`from` wajib (WA number tanpa `+`). `groupId` opsional — kalau null, dianggap
DM. `text` adalah body pesan apa adanya.

Response:

```json
{
  "ok": true,
  "ignored": false,
  "hashtag": "#PLAN",
  "result": { "status": "SUCCESS", "customerCount": 1, "...": "..." },
  "sent":   [ { "to": "group", "target": "...", "delivered": true } ]
}
```

## Handler matrix

| Hashtag   | Mode                           | Tabel                | Reply default  |
|-----------|--------------------------------|----------------------|----------------|
| `#PLAN`   | single / multi (`N\|`)         | `sales_plan`         | group          |
| `#REPORT` | mode A (single) / mode B (EOD) | `activity_log`       | group          |
| `#LEADS`  | strict 5 field                 | `pipeline_tracker`   | group          |
| `#UPDATE` | auto / confirm / not-found     | `pipeline_tracker`   | group / DM     |

Detail format input lihat `src/handlers/*.ts` atau spec asli di
`wrg-crm-system-prompt.md`.

## Confirm flow #UPDATE

Bila `similarity()` antara nama customer di pesan dengan pipeline AM
berada di rentang **0.40–0.69**, dispatcher menyimpan kandidat ke tabel
`pending_confirm` dan mengirim DM berisi 3 opsi. AM membalas
`UPDATE 1`/`UPDATE 2`/`UPDATE 3` (case-insensitive) — `dispatcher` akan
mendeteksi reply tersebut sebelum parsing hashtag, mengeksekusi update,
dan menghapus baris pending. TTL 10 menit.

## Swap mock sender → OpenClaw / gateway HTTP

Edit `.env`:

```
WA_SEND_MODE=http
WA_SEND_URL=https://your-openclaw-host/send
WA_SEND_TOKEN=your-bearer-token   # optional
WA_HTTP_TIMEOUT_MS=10000
WA_HTTP_RETRIES=2
```

### Kontrak HTTP yang harus dipenuhi gateway-mu

**Outbound (app → gateway):**

```http
POST {WA_SEND_URL}
Authorization: Bearer {WA_SEND_TOKEN}     ← jika token diset
Content-Type: application/json

{
  "to":     "group" | "dm",   // routing intent
  "target": "wrg-sales-command-center",   // group id atau wa number, opaque string
  "text":   "...isi pesan..."
}
```

- **2xx** → dianggap delivered. Kalau body JSON `{messageId}` atau `{message_id}` ada, ditangkap & di-log.
- **4xx** → permanent error, **tidak** di-retry.
- **5xx / network / timeout** → di-retry sampai `WA_HTTP_RETRIES` kali (default 2 = total 3 attempt).

Backoff antar-retry: 500ms → 1500ms → 3000ms.

**Inbound (gateway → app):**

```http
POST http://your-app-host:3000/webhook
Content-Type: application/json

{
  "from":      "6281111111111",                  // WA number tanpa '+'
  "groupId":   "wrg-sales-command-center",       // null untuk DM
  "text":      "#PLAN\ntgl: 01/05/2026\n...",    // body apa adanya
  "messageId": "abc-123"                         // opsional, untuk dedupe nanti
}
```

### Adapter pattern jika gateway-mu format-nya beda

Tulis service kecil (Node/Python) yang menerima format kanonik di atas dan menerjemahkan ke format gateway-mu, lalu arahkan `WA_SEND_URL` ke service tsb. Pattern yang sama juga untuk inbound: gateway → adapter → POST `{from,groupId,text}` ke `/webhook`.

### Test HTTP path tanpa gateway nyata

Repo ini sudah punya **stub gateway** lokal:

```bash
# Terminal 1: jalankan stub di :3001
npm run gateway:stub
# atau dengan flaky mode untuk test retry:
STUB_FAIL_RATE=0.5 npm run gateway:stub

# Terminal 2: jalankan app dalam mode http
WA_SEND_MODE=http \
WA_SEND_URL=http://127.0.0.1:3001/send \
WA_SEND_TOKEN=test-token \
npm run dev

# Terminal 3: kirim webhook test
curl -X POST http://localhost:3000/webhook \
  -H 'content-type: application/json' \
  -d '{"from":"6281111111111","groupId":"wrg-sales-command-center","text":"#PLAN\ntgl:01/05/2026\ncust:RS X\ntujuan:visit\ngoal:demo"}'
```

Stub akan log payload masuk lengkap dengan auth status & messageId yang dia balas.

## Layout

```
db/
  001_init.sql                    schema (master_user, sales_plan, pipeline_tracker, ...)
  002_seed.sql                    4 user demo + 1 pipeline seed
  003_processed_message.sql       idempotency dedupe table
  004_delivery_log.sql            per-send-attempt audit
  005_delivery_resend.sql         resend tracking columns
  006_alert_log.sql               alerting log with per-channel results
  007_email_log.sql               email digest audit log
  008_alert_escalation.sql        escalation_for self-FK + escalated_at
  009_user_session.sql            session + auth_log tables
src/
  config.ts            env-driven config
  db.ts                pg pool + query helper
  types.ts             Inbound/Outbound, HandlerResult
  wa.ts                sendReply(), resolveTarget()
  dispatcher.ts        routing + audit + reply orchestration
  server.ts            fastify webhook
  repo/
    users.ts           findUserByWa()
    audit.ts           writeAudit() → audit_id
    dedupe.ts          claimMessage / finishMessage / cleanupExpired
    delivery.ts        writeDelivery / listDeliveries
    resend.ts          claimResendBatch / markResolved / getResendStats
  resend.ts            processResendBatch() service
  dashboard/
    queries.ts         per-AM stats, pipeline snapshot, ops aggregate
    html.ts            single-file HTML (CSS + vanilla JS, no deps)
  alerts/
    channels.ts        log / http-webhook / wa-dm channel impls
    index.ts           fireAlert(), checkExhaustedAndAlert(), listRecentAlerts()
  exports/
    csv.ts             RFC 4180 serializer
    queries.ts         exportPipeline / exportActivity / exportPlans / exportDeals
    digest.ts          renderWeeklyDigest() — print-friendly HTML
  email/
    transport.ts       nodemailer factory (smtp / jsonTransport / disabled)
    digest.ts          sendWeeklyDigestEmail + lastCompleteWeekRange()
  auth/
    google.ts          OAuth2 flow (authorize, exchange, userinfo, verifyAccess)
    session.ts         create/find/destroy session + auth_log
    middleware.ts      requireAuth() cookie OR token
    pages.ts           login page HTML
  handlers/
    plan.ts
    report.ts
    leads.ts
    update.ts
  summary/
    queries.ts         per-AM stats, hot deals, attention list
    format.ts          renderer (mengikuti template spec)
    index.ts           runDailySummary()
  scheduler.ts         node-cron 18:00 WIB Mon-Sat
  limiters.ts          per-WA + global rate limiter instances + exempt set
  util/
    parse.ts           field/section/whitelist helpers
    dateid.ts          DD/MM/YYYY ↔ YYYY-MM-DD ↔ "01 Mei 2026"
    ratelimit.ts       FixedWindowLimiter class
scripts/
  smoke.ts             end-to-end test (~100 checks) against dispatcher
  summary-run.ts       CLI manual trigger daily summary
  wa-stub-server.ts    local fake WA gateway untuk test mode http
  alert-stub.ts        local fake Slack-style webhook untuk test alert wiring
```

## Email digest

Otomatis kirim weekly digest HTML ke email HOD setiap **Senin 08:00 WIB**
yang merekap minggu **Senin–Minggu yang baru lewat** (bukan running 7-day).

**Setup Gmail (App Password):**
```bash
EMAIL_ENABLED=true
SMTP_HOST=smtp.gmail.com
SMTP_PORT=587
SMTP_USER=your-account@gmail.com
SMTP_PASS=<16-char-app-password>   # bukan password Google biasa
SMTP_SECURE=false                  # 587 pakai STARTTLS, bukan TLS murni
EMAIL_FROM=WRG CRM <your-account@gmail.com>
EMAIL_HOD_RECIPIENTS=hod@company.com,direktur@company.com
```

**Setup Mailgun / SendGrid / SES** (any SMTP provider):
```bash
EMAIL_ENABLED=true
SMTP_HOST=smtp.mailgun.org
SMTP_PORT=587
SMTP_USER=postmaster@your-domain.mailgun.org
SMTP_PASS=<api-key>
EMAIL_FROM=WRG CRM <crm@your-domain.com>
EMAIL_HOD_RECIPIENTS=hod@company.com
```

**Manual trigger / test:**
```bash
# Dry-run (no SMTP traffic, return rendered message dalam response):
curl -X POST 'http://localhost:3000/ops/email-digest?token=TOKEN' \
  -H 'content-type: application/json' \
  -d '{"dryRun":true}'

# Send sungguhan dengan range custom:
curl -X POST 'http://localhost:3000/ops/email-digest?token=TOKEN' \
  -H 'content-type: application/json' \
  -d '{"from":"2026-04-27","to":"2026-05-03"}'
```

**Format email:**
- **HTML body**: Sama persis dengan `/export/digest` (4 KPI cards, daily
  breakdown, per-AM, deals closed, hot pipeline).
- **Plain-text fallback**: ringkasan singkat (KPI numbers) untuk client
  yang tidak render HTML / mobile preview.
- **Subject**: `WRG Weekly Digest — 04 Mei 2026 → 10 Mei 2026`

**Date math — "minggu yang baru lewat":**
- Cron fires Senin 08:00 → range = Senin..Minggu minggu sebelumnya
- Untuk panggil ad-hoc dari Selasa-Sabtu → range tetap Senin..Minggu minggu
  lalu (week-aligned)
- Khusus Minggu malam → range = Senin..Minggu **2 minggu lalu** (karena
  minggu ini belum complete)

**Audit:** Semua pengiriman (sukses/gagal) ditulis ke `email_log`:
```sql
SELECT created_at, kind, recipients, subject, delivered, error
FROM email_log
ORDER BY created_at DESC LIMIT 10;
```

**Skip kalau:**
- `EMAIL_ENABLED=false` → cron tidak di-register sama sekali
- `EMAIL_HOD_RECIPIENTS` kosong → cron tidak di-register
- `SMTP_HOST` kosong tapi `EMAIL_ENABLED=true` → fallback ke disabled (log warning)

## Export & laporan (CSV + Weekly Digest)

Untuk laporan offline / monthly review / arsip:

**CSV** (RFC 4180-compliant, UTF-8 dengan BOM untuk Excel-friendly):

```bash
# Pipeline state lengkap (tanpa filter tanggal — pipeline_tracker bersifat ongoing)
curl -OJ 'http://localhost:3000/export/pipeline.csv?token=TOKEN'

# Activity log dengan range
curl -OJ 'http://localhost:3000/export/activity.csv?token=TOKEN&from=2026-05-01&to=2026-05-31'

# Sales plans + closed deals
curl -OJ 'http://localhost:3000/export/plans.csv?token=TOKEN&from=2026-05-01&to=2026-05-31'
curl -OJ 'http://localhost:3000/export/deals.csv?token=TOKEN&from=2026-05-01&to=2026-05-31'
```

`Content-Disposition` set ke `attachment; filename="wrg-<type>-<date>.csv"` —
`-OJ` di curl atau klik dari dashboard akan download dengan nama yang benar.

**Weekly Digest** — print-friendly HTML report:

```bash
open 'http://localhost:3000/export/digest?token=TOKEN&from=2026-05-04&to=2026-05-10'
```

Berisi: 4 KPI cards (Total Visits / Plans / Avg Active AM / Revenue),
Daily Breakdown per hari, Per-AM agregat minggu, Deals Closed minggu
ini, Hot Pipeline (Stage ≥3 atau Status=Hot).

Untuk PDF: buka di browser, **Cmd+P / Ctrl+P → Save as PDF**. CSS sudah
print-optimized (`@page` margin, `page-break-inside: avoid` untuk
tabel). Tidak butuh server-side PDF renderer (puppeteer / chromium).

**Dashboard punya tab "Export"** dengan date picker + tombol download
untuk semua 4 CSV + digest. URL otomatis include token + range.

## Alerting on exhausted resends

Setelah resend cron (tiap 5 menit) selesai, detector mengecek apakah
ada baris `delivery_log` yang **exhausted** (`delivered=false`,
`resolved=false`, `resend_count >= MAX`). Kalau ada yang baru sejak
alert terakhir DAN debounce window sudah lewat, fire alert ke semua
channel yang enabled.

**3 channel** (`src/alerts/channels.ts`):

| Channel        | Aktif kalau                  | Catatan                                          |
|----------------|------------------------------|--------------------------------------------------|
| `log`          | Selalu                       | console.log; jaring pengaman (tidak pernah gagal) |
| `http-webhook` | `ALERT_WEBHOOK_URL` di-set   | Slack-compatible `{text, attachments[]}` payload  |
| `wa-dm`        | `ALERT_WA_NUMBER` di-set     | Best-effort — bisa gagal kalau gateway WA mati   |

Channel disatukan via `Promise.allSettled` — satu channel gagal **tidak**
block channel lain. Hasil per-channel ditulis ke `alert_log.channels_delivered`.

**State machine:**

1. `snap.count == 0` + ada `exhausted_resend` sebelumnya yang belum di-clear → fire `kind=cleared` (info)
2. `snap.count > 0` + `snap.maxId > last alert.maxId` + sudah lewat debounce → fire `kind=exhausted_resend` (warn jika <5, critical jika ≥5)
3. Selain itu → silent (sudah pernah alert, atau masih dalam debounce)

Watermark `payload.maxId` mencegah re-alert untuk row yang sama —
hanya delivery baru yang melewati cap yang trigger alert berikutnya.

**Escalation chain:**

Selain detector di atas, ada **escalation detector** yang jalan
piggyback ke cron resend. Logic:

1. Cari `exhausted_resend` yang `created_at` sudah lewat
   `ALERT_ESCALATE_AFTER_MIN` (default 15 menit) **AND**
   `escalated_at IS NULL` **AND** belum ada `cleared` yang fired
   setelahnya.
2. Untuk setiap kandidat → fire alert baru `kind=escalation`,
   `level=critical` dengan reference `escalation_for = parent.id` dan
   payload memuat `parentAlertId`, `ageMin`, `thresholdMin`.
3. Update parent `escalated_at = NOW()` supaya idempotent — tidak
   re-escalate alert yang sama.

Use case: gateway WA down 15+ menit → warn awal jalan, 15 menit
kemudian belum ada cleared → critical follow-up "🚨 ESCALATION: …
(unresolved 15m)" memaksa attention Husni.

Manual trigger: `POST /ops/alerts/escalate` (tanpa token; sama dengan check).

**Setup Slack:** buat Incoming Webhook, copy URL, set:
```
ALERT_WEBHOOK_URL=https://hooks.slack.com/services/T.../B.../...
```

**Test wiring tanpa Slack beneran:**
```bash
# Terminal 1: stub webhook
npm run alert:stub          # listen :3001

# Terminal 2: app dengan alert wiring
ALERT_WEBHOOK_URL=http://127.0.0.1:3001/alert \
DASHBOARD_TOKEN=token npm run dev

# Terminal 3: fire test
curl -X POST 'http://localhost:3000/ops/alerts/test?token=token'
# → kedua channel akan menerima
```

Dashboard **Ops Health** tab punya panel "Recent Alerts" yang
menampilkan history alert + delivery status per-channel (hijau =
delivered, merah = gagal).

Knobs `.env`:
```
ALERT_WEBHOOK_URL=             # kosong → http-webhook channel disabled
ALERT_WA_NUMBER=               # kosong → wa-dm channel disabled
ALERT_WEBHOOK_TIMEOUT_MS=5000
ALERT_DEBOUNCE_MIN=30          # jangan re-fire alert yang sama dalam 30 menit
ALERT_ESCALATE_AFTER_MIN=15    # warn yang unresolved >15 menit → critical follow-up
```

## Authentication

Dashboard mendukung **2 mode auth** (bisa jalan bareng):

1. **Google OAuth (SSO)** — rekomendasi untuk user. Login lewat akun
   Google internal, session cookie disimpan di DB, TTL 7 hari.
2. **Bearer token** — backward-compat untuk API/script. Pakai header
   `Authorization: Bearer <DASHBOARD_TOKEN>` atau query `?token=...`.

Browser navigation (`GET /dashboard`) tanpa auth → **302 redirect ke /login**.
API call (`GET /api/...`) tanpa auth → **401 JSON**.

### Setup Google OAuth

1. **Google Cloud Console** → APIs & Services → Credentials → Create OAuth 2.0 Client ID:
   - Application type: Web application
   - Authorized redirect URIs: `https://your-host/auth/google/callback` (atau `http://localhost:3000/...` untuk dev)
2. **Set di `.env`:**
   ```
   OAUTH_GOOGLE_CLIENT_ID=...apps.googleusercontent.com
   OAUTH_GOOGLE_CLIENT_SECRET=GOCSPX-...
   OAUTH_GOOGLE_HD=wahanalifeline.co.id    # restrict to Workspace domain
   OAUTH_BASE_URL=https://your-host        # exact match Google Console
   SESSION_TTL_DAYS=7
   ```
3. **Optional** — selain HD, bisa pakai email allowlist (override HD):
   ```
   OAUTH_EMAIL_ALLOWLIST=husni@wahanalifeline.co.id,hod@company.com,partner@external.com
   ```
   Berguna kalau ingin invite konsultan luar tanpa membuka HD lebar.

### Auth audit

Setiap login attempt (sukses/gagal) di-record ke `auth_log`:
```sql
SELECT created_at, email, event, reason, ip
FROM auth_log
ORDER BY created_at DESC LIMIT 20;

-- Login failure dalam 24 jam terakhir
SELECT email, COUNT(*), array_agg(DISTINCT reason)
FROM auth_log
WHERE event = 'login_failed' AND created_at > NOW() - INTERVAL '24 hours'
GROUP BY email;
```

`user_session` table tracks active sessions:
```sql
SELECT email, ip, created_at, last_seen_at, expires_at
FROM user_session
ORDER BY last_seen_at DESC;
```

Session expired di-cleanup tiap 02:00 WIB (sama dengan dedupe cleanup cron).

### Security notes

- Cookie: `HttpOnly`, `SameSite=Lax`, `Secure` (auto kalau `OAUTH_BASE_URL`
  pakai `https://`). Path=/.
- OAuth state CSRF: random nonce per attempt, validated di callback, expired 10 menit.
- `DASHBOARD_TOKEN` tetap berlaku untuk backward compat. Untuk audit ketat,
  unset token dan force SSO-only (cookie session yang dipakai).

## Dashboard (Husni / HOD)

Web UI berbasis single-file HTML (vanilla JS, no build, no deps), 4 tab
dengan auto-refresh tiap 30 detik.

**Setup:**
```bash
# 1. Set token (apapun string panjang; treat sebagai shared secret)
echo 'DASHBOARD_TOKEN=ganti-saya-jadi-string-rahasia-32-char' >> .env

# 2. Restart server
npm run dev

# 3. Buka di browser
open 'http://localhost:3000/dashboard?token=ganti-saya-jadi-string-rahasia-32-char'
```

**4 tab:**

| Tab          | Isi                                                                          |
|--------------|------------------------------------------------------------------------------|
| Overview     | 4 KPI (Tim Aktif, Visits, Plans, Coverage), Hot Deals, Perlu Perhatian, Top Performer, Per-AM table |
| Activity     | Recent activity_log (50 baris terbaru, ada waktu/AM/customer/hasil/next)    |
| Pipeline     | Status breakdown + bar chart, Stage × Status matrix, Top deals (Hot/Won/stage≥3) |
| Ops Health   | Resend pending/resolved/exhausted, Rate-limit hits 1 jam, Failed deliveries, Audit status 24h |

**Auth:**
- Token wajib di-set via `DASHBOARD_TOKEN` env. Tanpa itu, endpoint return 503.
- Bisa di-pass via query string `?token=...` (untuk URL share) atau header `Authorization: Bearer ...`.
- Bad/missing token → 401.

**API endpoints (dipakai internal oleh HTML, juga bisa dipakai langsung):**
- `GET /api/overview` — KPI today + per-AM stats
- `GET /api/activity?limit=N` — recent activity log
- `GET /api/pipeline` — stage breakdown + top deals
- `GET /api/ops` — resend stats + rate-limit + failed deliveries + audit summary

**Security note:**
- Token-based auth → cukup untuk internal use, **bukan** untuk public exposure.
- Untuk production: taruh di balik reverse proxy dengan TLS + IP allowlist, atau ganti
  dengan OAuth/SSO. Token saja tidak protect dari token leak via shoulder-surfing /
  log files.

## Auto-resend reply gagal

Reply yang gagal kirim (gateway down, 5xx, timeout) **tidak hilang** —
mereka jadi kandidat resend. Setiap 5 menit cron menjalankan
`processResendBatch()` yang:

1. **Claim batch** failed deliveries pakai `SELECT FOR UPDATE SKIP LOCKED` (race-safe).
2. Bump `resend_count` + set `last_resend_at = NOW()`.
3. Untuk setiap baris: panggil `sendReply()` (yang sudah punya retry internal).
4. Tulis **child row** baru di `delivery_log` (`source='resend'`, `parent_delivery_id`).
5. Kalau child `delivered=true` → tandai parent `resolved=true` (tidak diambil lagi).

**Eligibility filter:**
- `delivered=false AND resolved=false`
- `resend_count < RESEND_MAX_ATTEMPTS` (default 3)
- `last_resend_at IS NULL` atau lewat backoff (default 5 menit)
- `created_at > NOW() - RESEND_TTL_HOURS` (default 24 jam — failure lama tidak resurrected)
- `source <> 'resend'` (hanya retry baris original, tidak nested loops)

**Manual trigger** (Husni):
```bash
curl -X POST http://localhost:3000/ops/resend-failures
# → {"ok":true,"picked":N,"delivered":N,"failed":0}

curl http://localhost:3000/ops/resend-stats
# → {"ok":true,"pending":3,"resolved24h":47,"exhausted":1}
```

Knobs `.env`:
```
RESEND_MAX_ATTEMPTS=3       # cap per row
RESEND_BACKOFF_MIN=5        # backoff antar attempt
RESEND_TTL_HOURS=24         # jangan resurrect failure lebih tua dari ini
RESEND_BATCH_SIZE=20        # per-tick batch
```

Skema (kolom tambahan di `delivery_log` via migration 005):
- `text_full`           — full body, untuk dipakai saat resend
- `resend_count`        — berapa kali baris ini sudah di-pick
- `last_resend_at`      — utk backoff
- `resolved`            — true setelah ada child yang sukses
- `parent_delivery_id`  — link child→parent untuk audit chain

## Delivery audit

`audit_log` mencatat **hasil pemrosesan handler** (PARSE OK / FAILED /
SUCCESS), tetapi tidak tahu apakah balasan WA sampai. Itu tugas
`delivery_log` — **satu baris per upaya kirim**, dengan FK opsional ke
audit_log.

```sql
delivery_log (
  id, audit_id (FK → audit_log, NULL untuk scheduler/manual),
  source         'inbound' | 'scheduler' | 'manual',
  message_id_in  -- gateway inbound id (untuk join)
  wa_number      -- pengirim, jika ada
  to_kind        'group' | 'dm',
  target,
  text_preview,  -- 200 char pertama
  delivered      bool,
  attempts       int,
  message_id_out -- id gateway dari response
  error,
  created_at
)
```

Indexes: created_at desc, partial index untuk `delivered=false` (cepat
lookup kegagalan), `audit_id` untuk join.

**Skenario yang sekarang bisa di-debug:**

```bash
# Reply yang gagal terkirim 24 jam terakhir
curl 'http://localhost:3000/ops/deliveries?status=failed&since=2026-05-10T00:00:00Z'

# Semua reply ke AM tertentu
psql -d wrg_crm -c "SELECT created_at, hashtag, delivered, error
                    FROM delivery_log dl
                    LEFT JOIN audit_log al ON al.id = dl.audit_id
                    WHERE dl.wa_number = '6281111111111'
                    ORDER BY dl.created_at DESC LIMIT 20"
```

## Rate limit

Dua layer pengaman di `/webhook`, in-memory fixed window 1 menit:

| Layer    | Default     | Key             | Tujuan                                       |
|----------|-------------|------------------|----------------------------------------------|
| Per-WA   | 20/min      | `body.from`     | Cegah satu AM (atau akun bermasalah) flood   |
| Global   | 600/min     | `req.ip`        | Cegah gateway runaway / replay storm         |

Saat melebihi quota:

- HTTP **429** dengan header `Retry-After: <seconds>`
- Body: `{"ok":false, "error":"rate_limited_per_wa", "retryAfterSec": 60}`
- Tidak ada balasan WA ke pengirim (mencegah spam balik)
- Audit row dengan `status='RATE_LIMITED'` ditulis untuk visibility

Knobs di `.env`:
```
RATE_LIMIT_PER_WA_PER_MIN=20
RATE_LIMIT_GLOBAL_PER_MIN=600
RATE_LIMIT_EXEMPT_WA=6281234567890,6281999999999  # comma-separated
```

Memory dijaga via sweep tiap 5 menit (hapus bucket yang sudah expired).
Untuk multi-instance deployment, swap `FixedWindowLimiter` dengan
implementasi Redis-backed (INCR + EXPIRE) — interface-nya sama.

## Idempotency (anti double-process)

Inbound webhook dapat menyertakan `messageId`. Bila ada, dispatcher akan:

1. **Klaim** `message_id` di tabel `processed_message` (PRIMARY KEY → race-safe).
2. Bila klaim gagal (sudah pernah masuk) → return `{ignored:true, duplicate:true, originalStatus:...}` **tanpa** menulis ulang DB dan **tanpa** mengirim balasan kedua.
3. Bila klaim berhasil → proses normal, lalu update row dengan hashtag + status final + ringkasan hasil.

TTL default 7 hari (cleanup cron `0 2 * * *`). Untuk gateway lama yang
tidak mengirim `messageId`, dedupe **tidak** dipakai (legacy compat) —
resend akan double-process. Pastikan gateway baru selalu kirim
`messageId`.

```http
POST /webhook
{
  "from":      "6281111111111",
  "groupId":   "wrg-sales-command-center",
  "text":      "#PLAN ...",
  "messageId": "abc-123"
}
```

Tabel:
```sql
processed_message (
  message_id PRIMARY KEY,
  wa_number, hashtag, status,
  result_summary jsonb,
  processed_at, finished_at, expires_at
)
```

## Daily summary

```bash
npm run summary:run                  # kirim untuk hari ini (WIB)
npm run summary:run -- 2026-05-15    # tanggal tertentu (back-fill / debug)
```

Atau via HTTP:
```bash
curl -X POST http://localhost:3000/summary/run \
  -H 'content-type: application/json' -d '{"date":"2026-05-10"}'
```

Format render mengikuti spec: Tim Aktif, Total Kunjungan vs Plan,
Coverage %, Hot Deals (status='Hot' atau stage ≥ 3 yang updated hari
itu), Perlu Perhatian (AM dengan plan tapi 0 kunjungan, fallback ke AM
0-kunjungan), Top Performer, dan paragraf narrative templated.

## Belum dibangun (next steps)

- **Multi-instance deployment** — swap in-memory rate limiter ke
  Redis-backed jika app discale horizontal. (Premature untuk 29-AM team
  saat ini — single-instance fits well.)
