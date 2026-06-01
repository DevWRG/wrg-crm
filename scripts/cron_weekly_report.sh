#!/bin/bash
# ============================================================
# WRG CRM — Weekly Report Cron
# Tiap Senin 07:00 WIB: generate PDF report minggu lalu (Sen→Jum),
# kirim notif WA ke admin dgn ringkasan KPI.
#
# Schedule: 0 7 * * 1
# Log:      logs/cron.log (sama dgn job wrg-crm lain)
# ============================================================
set -uo pipefail

source "$(dirname "$0")/../config/config.sh"
export WRG_JOB="weekly_report"

DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then
  DRY_RUN=1
  shift
fi

# ── Hitung periode: Senin–Jumat minggu lalu ──────────────────
# Optional manual override via args (untuk dry-run/testing).
if [ $# -ge 2 ] && [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && [[ "$2" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  LAST_MON="$1"
  LAST_FRI="$2"
  log "  weekly_report: manual range $LAST_MON → $LAST_FRI"
else
  # Default: most recent completed work-week.
  # Cron runs Monday 07:00 → today-7 = last Mon, today-3 = last Fri.
  DOW=$(date +%u)
  if [ "$DOW" -ne 1 ]; then
    log "  WARN: bukan hari Senin (DOW=$DOW), tetap lanjut dgn 'minggu lalu' logic"
  fi
  LAST_MON=$(date -j -v-7d +%Y-%m-%d)
  LAST_FRI=$(date -j -v-3d +%Y-%m-%d)
fi

log "  weekly_report: periode $LAST_MON → $LAST_FRI"

# ── Generate PDF ─────────────────────────────────────────────
OUT_DIR="$BASE_DIR/exports"
mkdir -p "$OUT_DIR"
OUT_FILE="$OUT_DIR/wrg-report-weekly-${LAST_MON}_${LAST_FRI}.pdf"

if ! bash "$BASE_DIR/scripts/export_pdf.sh" "$LAST_MON" "$LAST_FRI" "$OUT_FILE" >> "$LOG_DIR/daily.log" 2>&1; then
  log "  weekly_report: ERROR export_pdf.sh gagal"
  wa_send "$ADMIN_NUMBER" "⚠️ WRG Weekly Report GAGAL generate ($LAST_MON → $LAST_FRI). Cek logs/daily.log."
  exit 1
fi

if [ ! -s "$OUT_FILE" ]; then
  log "  weekly_report: ERROR file kosong: $OUT_FILE"
  wa_send "$ADMIN_NUMBER" "⚠️ WRG Weekly Report file kosong ($LAST_MON → $LAST_FRI). Cek logs/daily.log."
  exit 2
fi

SIZE_KB=$(( $(stat -f%z "$OUT_FILE") / 1024 ))
log "  weekly_report: PDF created $OUT_FILE (${SIZE_KB}KB)"

# ── Auth: service-token login (dashboard /api/* require session sejak Phase 5) ──
# Token disimpan di env var WRG_SERVICE_TOKEN (juga di-set di dashboard plist).
# Generate via `openssl rand -hex 32`, simpan di .service_token (chmod 600) +
# inject via launchd plist EnvironmentVariables.
if [[ -z "${WRG_SERVICE_TOKEN:-}" ]] && [[ -f "$BASE_DIR/.service_token" ]]; then
  WRG_SERVICE_TOKEN=$(cat "$BASE_DIR/.service_token")
fi
if [[ -z "${WRG_SERVICE_TOKEN:-}" ]]; then
  log "  weekly_report: ERROR WRG_SERVICE_TOKEN unset (cek plist + .service_token)"
  wa_send "$ADMIN_NUMBER" "⚠️ WRG Weekly Report: WRG_SERVICE_TOKEN tidak ter-set di cron env."
  exit 1
fi
COOKIE_JAR=$(mktemp -t wrg-cron-cookie)
trap 'rm -f "$COOKIE_JAR"' EXIT
if ! curl -fsS --max-time 10 -L -c "$COOKIE_JAR" \
  "http://127.0.0.1:8091/api/auth/service-login?token=${WRG_SERVICE_TOKEN}&next=/api/auth/me" \
  -o /dev/null 2>/dev/null; then
  log "  weekly_report: ERROR service-login failed — dashboard auth issue"
  wa_send "$ADMIN_NUMBER" "⚠️ WRG Weekly Report: service-login dashboard gagal."
  exit 1
fi

# ── Ambil ringkasan KPI dari dashboard API ───────────────────
SUMMARY_JSON=$(curl -fsS --max-time 10 -b "$COOKIE_JAR" \
  "http://127.0.0.1:8091/api/summary?from=${LAST_MON}&to=${LAST_FRI}" 2>/dev/null || echo '{}')

# Parse fields safely via python (stdlib JSON)
read -r WD TPV TTI PR TR PL TL TA UN MA UA <<< $(python3 -c "
import sys, json
d = json.loads(sys.stdin.read() or '{}').get('summary') or {}
fields = ['working_days','total_plan_visits','total_todo_items','plan_reported','todo_reported','plan_late','todo_late','total_activity','unmatched_activity','matched_activity','users_with_report']
print(' '.join(str(d.get(f, 0)) for f in fields))
" <<< "$SUMMARY_JSON")

TOTAL_PLAN=$(( TPV + TTI ))
TOTAL_REP=$(( PR + TR ))
TOTAL_LATE=$(( PL + TL ))
if [ "$TOTAL_PLAN" -gt 0 ]; then
  PCT=$(( TOTAL_REP * 100 / TOTAL_PLAN ))
else
  PCT=0
fi
if [ "$TA" -gt 0 ]; then
  MATCH_PCT=$(( MA * 100 / TA ))
else
  MATCH_PCT=0
fi

# ── Top 3 cabang by % selesai (min 5 plan biar bukan outlier) ─
TOP_CABANG=$(curl -fsS --max-time 10 -b "$COOKIE_JAR" \
  "http://127.0.0.1:8091/api/per-cabang?from=${LAST_MON}&to=${LAST_FRI}" 2>/dev/null | \
  python3 -c "
import sys, json
rows = (json.loads(sys.stdin.read() or '{}').get('rows') or [])
ranked = []
for r in rows:
    tp = (r.get('total_plan') or 0)
    if tp < 5:
        continue
    rep = (r.get('plan_reported') or 0) + (r.get('todo_reported') or 0)
    pct = (rep * 100 // tp) if tp else 0
    ranked.append((pct, r.get('cabang','-'), rep, tp))
ranked.sort(reverse=True)
out = []
for pct, cab, rep, tp in ranked[:3]:
    out.append(f'  • {cab}: {pct}% ({rep}/{tp})')
print('\n'.join(out) if out else '  (tidak ada cabang dgn data cukup)')
" 2>/dev/null || echo "  (tidak ada cabang dgn data cukup)")

# ── Compose WA message ───────────────────────────────────────
MSG="📊 WRG CRM Weekly Report
Periode: $LAST_MON → $LAST_FRI ($WD hari kerja)

🎯 *Ringkasan KPI*
• Total Plan: $TOTAL_PLAN ($TPV kunjungan + $TTI todo)
• Reported: $TOTAL_REP (${PCT}% selesai)
• Late submission: $TOTAL_LATE
• Aktivitas: $TA (${MATCH_PCT}% matched ke plan)
• Unmatched: $UN

🏆 *Top 3 Cabang*
$TOP_CABANG

📁 File: $OUT_FILE (${SIZE_KB}KB)
Buka via Finder atau \`open\` di terminal."

if [ "$DRY_RUN" = "1" ]; then
  echo "─── DRY RUN ─── would send to $ADMIN_NUMBER:"
  echo "$MSG"
  echo "─── END DRY RUN ───"
  log "  weekly_report: DRY RUN — skip wa_send"
else
  log "  weekly_report: sending WA notif to admin $ADMIN_NUMBER"
  if ! wa_send "$ADMIN_NUMBER" "$MSG"; then
    log "  weekly_report: WARN wa_send returned non-zero (PDF still saved)"
  fi
fi

# ── Cleanup: keep 8 most recent weekly PDFs (~2 months) ──────
ls -t "$OUT_DIR"/wrg-report-weekly-*.pdf 2>/dev/null | tail -n +9 | while read -r old; do
  log "  weekly_report: cleanup old PDF $old"
  rm -f "$old"
done

log "  weekly_report: done"
exit 0
