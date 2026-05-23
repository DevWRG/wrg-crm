#!/bin/bash
# ============================================================
# WRG CRM — wrg-daily wrapper
# Mengganti `openclaw skills run wrg-daily <job>` yang belum ada
# di openclaw v2026.5.7.
#
# Usage:
#   bash wrg-daily.sh plan_check       # 08:00 daily
#   bash wrg-daily.sh report_check     # 20:30 daily
#   bash wrg-daily.sh daily_summary    # 22:00 Senin-Jumat
#
# Behavior:
#   - Cek is_working_day() — weekend/libur stop
#   - Query DB → compose WA message → openclaw message send
#   - Log ke logs/daily.log
#
# Untuk weekend opt-in logic di report_check: lihat SKILL.md
# wrg-daily section JOB 2.
# ============================================================

set -uo pipefail
source "$(dirname "$0")/../config/config.sh"

JOB="${1:-}"
export WRG_JOB="$JOB"

case "$JOB" in
  plan_check|report_check|daily_summary) ;;
  *)
    echo "Usage: $0 {plan_check|report_check|daily_summary}" >&2
    exit 1
    ;;
esac

# ── Cek is_working_day untuk semua job ──────────────────────
IS_WORKDAY=$($PSQL -c "SELECT is_working_day(CURRENT_DATE);" 2>/dev/null | tr -d ' ')

# plan_check + daily_summary stop kalau bukan hari kerja.
# report_check punya logic khusus (weekend opt-in).
if [ "$JOB" != "report_check" ] && [ "$IS_WORKDAY" != "t" ]; then
  log "Bukan hari kerja, skip."
  exit 0
fi

# ── JOB 1 — plan_check ──────────────────────────────────────
if [ "$JOB" = "plan_check" ]; then
  WARNED=0
  SKIPPED=0
  SKIPPED_NO_GROUP=0

  # Anggota wajib plan/report yang belum submit hari ini
  ROWS=$($PSQL <<SQL
SELECT
  mu.wa_number || '|' ||
  COALESCE(mu.nama, '') || '|' ||
  COALESCE(mu.last_active_group, '') || '|' ||
  COALESCE(mu.cabang, '')
FROM master_user mu
WHERE mu.aktif = TRUE
  AND COALESCE(mu.wajib_plan_report, TRUE) = TRUE
  AND NOT EXISTS (
    SELECT 1 FROM sales_plan sp
    WHERE sp.user_id = mu.id
      AND sp.tanggal = CURRENT_DATE
  )
ORDER BY mu.nama;
SQL
)

  while IFS='|' read -r WA NAMA GROUP CABANG; do
    [ -z "$WA" ] && continue
    if [ -z "$GROUP" ]; then
      SKIPPED_NO_GROUP=$((SKIPPED_NO_GROUP + 1))
      continue
    fi
    BODY="⚠️ *Pengingat #PLAN*
${NAMA} belum submit plan hari ini.
Silakan kirim #PLAN sebelum mulai aktivitas."
    if wa_send "$GROUP" "$BODY"; then
      WARNED=$((WARNED + 1))
    else
      SKIPPED=$((SKIPPED + 1))
    fi
    # Throttle — hindari rate limit WhatsApp (10 msg/s aman)
    sleep 0.3
  done <<< "$ROWS"

  log "plan_check — warned: $WARNED — skipped (no group): $SKIPPED_NO_GROUP — failed: $SKIPPED"
  exit 0
fi

# ── JOB 2 — report_check ────────────────────────────────────
if [ "$JOB" = "report_check" ]; then
  WARNED_PARTIAL=0
  WARNED_NOPLAN=0
  SKIPPED=0

  # Weekend/libur logic — kalau bukan hari kerja, hanya cek anggota yang sudah submit plan (opt-in)
  if [ "$IS_WORKDAY" = "t" ]; then
    WEEKEND_FILTER=""
  else
    WEEKEND_FILTER="AND EXISTS (SELECT 1 FROM sales_plan sp WHERE sp.user_id = mu.id AND sp.tanggal = CURRENT_DATE)"
  fi

  # Per anggota: total plan vs total reported
  ROWS=$($PSQL <<SQL
WITH today_status AS (
  SELECT
    mu.id,
    mu.wa_number,
    mu.nama,
    mu.last_active_group,
    COUNT(sp.id)                                    AS total_plan,
    COUNT(sp.id) FILTER (WHERE sp.reported = FALSE) AS total_unreported,
    -- grup terakhir tempat user kirim #PLAN
    (SELECT sp2.activity_id FROM sales_plan sp2
       WHERE sp2.user_id = mu.id AND sp2.tanggal = CURRENT_DATE
       ORDER BY sp2.submitted_at DESC LIMIT 1)      AS last_plan_aid,
    ARRAY_AGG(sp.customer_name ORDER BY sp.seq)
      FILTER (WHERE sp.reported = FALSE)            AS unreported_customers
  FROM master_user mu
  LEFT JOIN sales_plan sp
    ON sp.user_id = mu.id AND sp.tanggal = CURRENT_DATE
  WHERE mu.aktif = TRUE
    AND COALESCE(mu.wajib_plan_report, TRUE) = TRUE
    ${WEEKEND_FILTER}
  GROUP BY mu.id, mu.wa_number, mu.nama, mu.last_active_group
)
SELECT
  wa_number || '|' ||
  COALESCE(nama,'') || '|' ||
  COALESCE(last_active_group,'') || '|' ||
  total_plan || '|' ||
  total_unreported || '|' ||
  COALESCE(array_to_string(unreported_customers, ';'), '')
FROM today_status
WHERE
  (total_plan > 0 AND total_unreported > 0)  -- punya plan tapi belum semua report
  OR (total_plan = 0)                         -- tidak punya plan sama sekali
ORDER BY nama;
SQL
)

  while IFS='|' read -r WA NAMA GROUP TOT_PLAN TOT_UNREPORTED UNREP_CUSTS; do
    [ -z "$WA" ] && continue
    if [ -z "$GROUP" ]; then
      SKIPPED=$((SKIPPED + 1))
      continue
    fi

    if [ "$TOT_PLAN" = "0" ]; then
      # Tidak ada plan sama sekali
      BODY="⚠️ ${NAMA} tidak ada plan maupun report hari ini."
      wa_send "$GROUP" "$BODY" && WARNED_NOPLAN=$((WARNED_NOPLAN + 1))
    else
      # Punya plan, belum semua report
      CUST_LIST=$(echo "$UNREP_CUSTS" | tr ';' '\n' | sed 's/^/  • /')
      BODY="⚠️ *Pengingat #REPORT, ${NAMA}*
Masih ada ${TOT_UNREPORTED} customer belum direport:
${CUST_LIST}
Kirim #REPORT sebelum selesai hari ini ya."
      wa_send "$GROUP" "$BODY" && WARNED_PARTIAL=$((WARNED_PARTIAL + 1))
    fi
    sleep 0.3
  done <<< "$ROWS"

  log "report_check — partial: $WARNED_PARTIAL — no-plan: $WARNED_NOPLAN — skipped: $SKIPPED"
  exit 0
fi

# ── JOB 3 — daily_summary ───────────────────────────────────
if [ "$JOB" = "daily_summary" ]; then
  # Kumpulkan activity hari ini (compact CSV-ish format untuk AI)
  ACTIVITY=$($PSQL <<SQL
SELECT
  mu.nama || '|' ||
  COALESCE(mu.cabang, '') || '|' ||
  COALESCE(mu.role, '') || '|' ||
  COALESCE(al.customer_name, '') || '|' ||
  COALESCE(al.hasil, '') || '|' ||
  COALESCE(al.next_action, '') || '|' ||
  CASE WHEN al.is_unmatched THEN 'unmatched' ELSE 'matched' END || '|' ||
  COALESCE(sp.tujuan, '') || '|' ||
  COALESCE(sp.goal, '')
FROM activity_log al
JOIN master_user mu ON mu.id = al.user_id
LEFT JOIN sales_plan sp ON sp.id = al.plan_id
WHERE al.tanggal = CURRENT_DATE
ORDER BY mu.cabang, mu.nama, al.id;
SQL
)

  ROW_COUNT=$(echo "$ACTIVITY" | grep -c "|" || echo 0)

  # Stats
  STATS=$($PSQL <<SQL
SELECT
  (SELECT COUNT(DISTINCT user_id) FROM activity_log WHERE tanggal = CURRENT_DATE) || '|' ||
  (SELECT COUNT(*) FROM activity_log WHERE tanggal = CURRENT_DATE) || '|' ||
  (SELECT COUNT(*) FROM activity_log WHERE tanggal = CURRENT_DATE AND is_unmatched = FALSE) || '|' ||
  (SELECT COUNT(*) FROM activity_log WHERE tanggal = CURRENT_DATE AND is_unmatched = TRUE) || '|' ||
  (SELECT COUNT(DISTINCT user_id) FROM sales_plan WHERE tanggal = CURRENT_DATE);
SQL
)
  IFS='|' read -r N_ANGGOTA N_REPORT N_MATCHED N_UNMATCHED N_PLAN <<< "$STATS"

  if [ "$ROW_COUNT" -eq 0 ] && [ "${N_PLAN:-0}" -eq 0 ]; then
    log "daily_summary — no activity, skip."
    exit 0
  fi

  HARI=$(LC_TIME=id_ID date '+%A')
  TANGGAL=$(date '+%-d %B %Y')

  SYS_PROMPT="Kamu adalah WRG CRM Daily Summary Generator.
Buat ringkasan harian aktivitas tim sales PT Wahana Rizky Gumilang.

FORMAT OUTPUT WAJIB (plain text, JANGAN pakai markdown header ##):
📊 *Daily Summary — ${HARI}, ${TANGGAL}*

*Overview*
• {N} anggota aktif dari {total} tim
• {total_report} laporan masuk
• {matched}% sesuai plan, {unmatched} aktivitas di luar plan

*Per Area*
[untuk setiap area: ringkasan 2-3 kalimat tentang aktivitas hari ini]

*Highlight*
[maks 3 poin penting hari ini — deal hot, prospek baru, warning]

*Perhatian*
[anggota yang tidak plan/report hari ini, jika ada]

Gunakan Bahasa Indonesia. Singkat, informatif, eksekutif. Maksimal 30 baris."

  USR_MSG="DATA INPUT (CSV pipe-delimited: nama|cabang|role|customer|hasil|next_action|matched/unmatched|plan_tujuan|plan_goal):

${ACTIVITY}

STATS:
anggota_aktif=${N_ANGGOTA} | total_report=${N_REPORT} | matched=${N_MATCHED} | unmatched=${N_UNMATCHED} | anggota_punya_plan=${N_PLAN}"

  log "daily_summary — calling AI: rows=$ROW_COUNT anggota=$N_ANGGOTA"
  SUMMARY=$(call_ai_with_fallback "$SYS_PROMPT" "$USR_MSG" 4000)

  if [ -z "$SUMMARY" ] || [ "${#SUMMARY}" -lt 50 ]; then
    log "daily_summary — AI returned empty/short, abort"
    wa_send "$ADMIN_NUMBER" "⚠️ WRG CRM daily_summary gagal — AI returned empty. Cek logs/daily.log"
    exit 1
  fi

  # Simpan output untuk inspect
  OUT_DIR="$BASE_DIR/data/daily-summary"
  mkdir -p "$OUT_DIR"
  TS=$(date '+%Y-%m-%d_%H%M')
  echo "$SUMMARY" > "$OUT_DIR/summary_${TS}.txt"

  # Kirim ke last_active_group setiap HOD + Direktur
  TARGETS=$($PSQL -c "
SELECT DISTINCT last_active_group
FROM master_user
WHERE role IN ('HOD', 'Direktur')
  AND aktif = TRUE
  AND last_active_group IS NOT NULL
  AND last_active_group <> '';
" 2>/dev/null)

  SENT=0
  while IFS= read -r GROUP; do
    GROUP=$(echo "$GROUP" | tr -d ' ')
    [ -z "$GROUP" ] && continue
    wa_send "$GROUP" "$SUMMARY" && SENT=$((SENT + 1))
    sleep 0.5
  done <<< "$TARGETS"

  log "daily_summary — rows=$ROW_COUNT sent=$SENT — saved: $OUT_DIR/summary_${TS}.txt"
  exit 0
fi
