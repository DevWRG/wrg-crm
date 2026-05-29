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

  # Anggota wajib plan/report yang belum submit hari ini.
  # Cek BOTH sales_plan (AM mode) DAN sales_todo (non-AM mode).
  # Batch 1 mayoritas pakai sales_todo, jadi tanpa OR ini reminder kirim
  # ke semua orang termasuk yg udah submit todo.
  ROWS=$($PSQL <<SQL
SELECT
  mu.wa_number || '|' ||
  COALESCE(INITCAP(mu.panggilan), mu.nama, '') || '|' ||
  COALESCE(mu.last_active_group, '') || '|' ||
  COALESCE(mu.cabang, '')
FROM master_user mu
WHERE mu.aktif = TRUE
  AND COALESCE(mu.wajib_plan_report, TRUE) = TRUE
  AND NOT is_on_leave(mu.id, CURRENT_DATE)
  AND NOT EXISTS (
    SELECT 1 FROM sales_plan sp
    WHERE sp.user_id = mu.id
      AND sp.tanggal = CURRENT_DATE
  )
  AND NOT EXISTS (
    SELECT 1 FROM sales_todo st
    WHERE st.user_id = mu.id
      AND st.tanggal = CURRENT_DATE
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
    WEEKEND_FILTER="AND (EXISTS (SELECT 1 FROM sales_plan sp WHERE sp.user_id = mu.id AND sp.tanggal = CURRENT_DATE)
                     OR EXISTS (SELECT 1 FROM sales_todo st WHERE st.user_id = mu.id AND st.tanggal = CURRENT_DATE))"
  fi

  # Per anggota: total plan vs total reported. Union AM mode (sales_plan) + TODO mode (sales_todo).
  ROWS=$($PSQL <<SQL
WITH today_status AS (
  SELECT
    mu.id,
    mu.wa_number,
    mu.nama,
    mu.panggilan,
    mu.last_active_group,
    COALESCE(sp.total_plan, 0)                          AS sp_total,
    COALESCE(sp.total_unreported, 0)                    AS sp_unreported,
    COALESCE(st.total_todo, 0)                          AS st_total,
    CASE WHEN COALESCE(st.total_todo, 0) > 0
              AND COALESCE(st.reported_count, 0) = 0
         THEN 1 ELSE 0 END                              AS st_unreported,
    sp.unreported_customers
  FROM master_user mu
  LEFT JOIN LATERAL (
    SELECT
      COUNT(*) AS total_plan,
      COUNT(*) FILTER (WHERE reported = FALSE) AS total_unreported,
      ARRAY_AGG(customer_name ORDER BY seq)
        FILTER (WHERE reported = FALSE) AS unreported_customers
    FROM sales_plan
    WHERE user_id = mu.id AND tanggal = CURRENT_DATE
  ) sp ON TRUE
  LEFT JOIN LATERAL (
    SELECT
      COUNT(*) AS total_todo,
      COUNT(*) FILTER (WHERE reported) AS reported_count
    FROM sales_todo
    WHERE user_id = mu.id AND tanggal = CURRENT_DATE
  ) st ON TRUE
  WHERE mu.aktif = TRUE
    AND COALESCE(mu.wajib_plan_report, TRUE) = TRUE
    AND NOT is_on_leave(mu.id, CURRENT_DATE)
    ${WEEKEND_FILTER}
)
SELECT
  wa_number || '|' ||
  COALESCE(INITCAP(panggilan), nama, '') || '|' ||
  COALESCE(last_active_group,'') || '|' ||
  (sp_total + st_total) || '|' ||
  (sp_unreported + st_unreported) || '|' ||
  COALESCE(array_to_string(unreported_customers, ';'), '')
FROM today_status
WHERE
  -- punya plan/todo tapi belum semua report
  ((sp_total + st_total) > 0 AND (sp_unreported + st_unreported) > 0)
  -- atau gak punya plan/todo sama sekali (no-plan warning)
  OR ((sp_total + st_total) = 0)
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
      # Punya plan, belum semua report.
      # AM mode: sales_plan punya customer_name list di unreported_customers.
      # TODO mode: sales_todo gak punya customer, list kosong → pesan tanpa bullet.
      if [ -n "$UNREP_CUSTS" ]; then
        CUST_LIST=$(echo "$UNREP_CUSTS" | tr ';' '\n' | sed 's/^/  • /')
        BODY="⚠️ *Pengingat #REPORT, ${NAMA}*
Masih ada ${TOT_UNREPORTED} customer belum direport:
${CUST_LIST}
Kirim #REPORT sebelum selesai hari ini ya."
      else
        # TODO mode: tidak ada bullet, pesan generic
        BODY="⚠️ *Pengingat #REPORT, ${NAMA}*
Plan kamu hari ini belum di-report.
Kirim #REPORT sebelum 20:30 ya."
      fi
      wa_send "$GROUP" "$BODY" && WARNED_PARTIAL=$((WARNED_PARTIAL + 1))
    fi
    sleep 0.3
  done <<< "$ROWS"

  log "report_check — partial: $WARNED_PARTIAL — no-plan: $WARNED_NOPLAN — skipped: $SKIPPED"
  exit 0
fi

# ── JOB 3 — daily_summary ───────────────────────────────────
if [ "$JOB" = "daily_summary" ]; then
  # Kumpulkan activity hari ini. UNION dua sumber:
  #   - activity_log (AM mode: customer visits, per-customer row)
  #   - sales_todo + report_data (TODO mode: per-item, hanya yg sudah reported)
  ACTIVITY=$($PSQL <<SQL
-- AM mode
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

UNION ALL

-- TODO mode (per-item unnest dari report_data)
SELECT
  mu.nama || '|' ||
  COALESCE(mu.cabang, '') || '|' ||
  COALESCE(mu.role, '') || '|' ||
  '' || '|' ||                                          -- no customer_name
  COALESCE(item->>'task', '') || '|' ||                 -- task as hasil-equivalent
  COALESCE(item->>'result', '') || '|' ||               -- result if any
  COALESCE(item->>'status', 'matched') || '|' ||        -- matched/ambiguous/unmatched/etc
  '' || '|' ||                                          -- no tujuan for TODO
  ''                                                    -- no separate goal
FROM sales_todo st
JOIN master_user mu ON mu.id = st.user_id
CROSS JOIN LATERAL jsonb_array_elements(COALESCE(st.report_data, '[]'::jsonb)) AS item
WHERE st.tanggal = CURRENT_DATE AND st.reported = TRUE

ORDER BY 1;
SQL
)

  ROW_COUNT=$(echo "$ACTIVITY" | grep -c "|" || echo 0)

  # Stats — union AM mode (activity_log) + TODO mode (sales_todo.report_data items).
  STATS=$($PSQL <<SQL
WITH am AS (
  SELECT user_id, is_unmatched FROM activity_log WHERE tanggal = CURRENT_DATE
),
todo_items AS (
  SELECT st.user_id, COALESCE(item->>'status','matched') AS status
  FROM sales_todo st
  CROSS JOIN LATERAL jsonb_array_elements(COALESCE(st.report_data, '[]'::jsonb)) AS item
  WHERE st.tanggal = CURRENT_DATE AND st.reported = TRUE
)
SELECT
  (SELECT COUNT(DISTINCT user_id) FROM (
     SELECT user_id FROM am UNION SELECT user_id FROM todo_items
   ) u) || '|' ||
  ((SELECT COUNT(*) FROM am) + (SELECT COUNT(*) FROM todo_items)) || '|' ||
  ((SELECT COUNT(*) FROM am WHERE is_unmatched = FALSE)
   + (SELECT COUNT(*) FROM todo_items WHERE status NOT IN ('unmatched'))) || '|' ||
  ((SELECT COUNT(*) FROM am WHERE is_unmatched = TRUE)
   + (SELECT COUNT(*) FROM todo_items WHERE status = 'unmatched')) || '|' ||
  (SELECT COUNT(DISTINCT user_id) FROM (
     SELECT user_id FROM sales_plan WHERE tanggal = CURRENT_DATE
     UNION
     SELECT user_id FROM sales_todo WHERE tanggal = CURRENT_DATE
   ) p);
SQL
)
  IFS='|' read -r N_ANGGOTA N_REPORT N_MATCHED N_UNMATCHED N_PLAN <<< "$STATS"

  if [ "$ROW_COUNT" -eq 0 ] && [ "${N_PLAN:-0}" -eq 0 ]; then
    log "daily_summary — no activity, skip."
    exit 0
  fi

  # Total wajib & non-reporters — biar AI gak hallucinate count + nama.
  # N_WAJIB exclude yang on-leave hari ini supaya denominator akurat.
  N_WAJIB=$($PSQL -c "SELECT COUNT(*) FROM master_user WHERE aktif AND wajib_plan_report AND NOT is_on_leave(id, CURRENT_DATE);" 2>/dev/null | head -1)
  NO_PLAN_LIST=$($PSQL <<SQL
SELECT COALESCE(nama, panggilan, wa_number)
FROM master_user mu
WHERE aktif AND wajib_plan_report
  AND NOT is_on_leave(mu.id, CURRENT_DATE)
  AND NOT EXISTS (SELECT 1 FROM sales_plan WHERE user_id=mu.id AND tanggal=CURRENT_DATE)
  AND NOT EXISTS (SELECT 1 FROM sales_todo WHERE user_id=mu.id AND tanggal=CURRENT_DATE)
ORDER BY nama;
SQL
)
  NO_REPORT_LIST=$($PSQL <<SQL
SELECT COALESCE(nama, panggilan, wa_number)
FROM master_user mu
WHERE aktif AND wajib_plan_report
  AND NOT is_on_leave(mu.id, CURRENT_DATE)
  -- punya plan/todo hari ini
  AND (EXISTS (SELECT 1 FROM sales_plan WHERE user_id=mu.id AND tanggal=CURRENT_DATE)
       OR EXISTS (SELECT 1 FROM sales_todo WHERE user_id=mu.id AND tanggal=CURRENT_DATE))
  -- tapi belum report
  AND NOT EXISTS (SELECT 1 FROM activity_log WHERE user_id=mu.id AND tanggal=CURRENT_DATE)
  AND NOT EXISTS (SELECT 1 FROM sales_todo WHERE user_id=mu.id AND tanggal=CURRENT_DATE AND reported)
ORDER BY nama;
SQL
)
  ON_LEAVE_LIST=$($PSQL <<SQL
SELECT COALESCE(mu.nama, mu.panggilan, mu.wa_number) || ' (' || ul.jenis || ')'
FROM v_leave_today ul
JOIN master_user mu ON mu.id = ul.user_id
WHERE mu.aktif AND mu.wajib_plan_report
ORDER BY mu.nama;
SQL
)

  HARI=$(LC_TIME=id_ID date '+%A')
  TANGGAL=$(date '+%-d %B %Y')

  SYS_PROMPT="Kamu adalah WRG CRM Daily Summary Generator.
Buat ringkasan harian aktivitas tim sales PT Wahana Rizky Gumilang.

CRITICAL RULES:
- JANGAN mengarang nama, angka, atau fakta yg tidak ada di data input.
- Section 'Perhatian' HANYA pakai nama dari list 'NON_REPORTERS' & 'NO_PLAN' yg di-input.
  Kalau list kosong, tulis '(semua wajib user sudah submit)'.
- Section 'Ijin' HANYA pakai nama dari list 'ON_LEAVE'. Skip section ini kalau list kosong.
- Angka 'anggota aktif dari N tim' pakai N=anggota_aktif/wajib_total dari STATS.
  wajib_total sudah exclude yg ijin hari ini.
- Per Area hanya sebut cabang yg muncul di DATA INPUT.

FORMAT OUTPUT WAJIB (plain text, JANGAN pakai markdown header ##):
📊 *Daily Summary — ${HARI}, ${TANGGAL}*

*Overview*
• {anggota_aktif} dari {wajib_total} tim wajib aktif lapor
• {total_report} laporan masuk
• {matched}% sesuai plan, {unmatched} aktivitas di luar plan

*Per Area*
[untuk setiap area yg muncul di data: ringkasan 2-3 kalimat]

*Highlight*
[maks 3 poin penting hari ini — deal hot, prospek baru, warning]

*Perhatian*
[copy nama dari NON_REPORTERS & NO_PLAN list, jangan ngarang]

*Ijin*
[copy nama dari ON_LEAVE list. Skip section kalau kosong]

Gunakan Bahasa Indonesia. Singkat, informatif, eksekutif. Maksimal 30 baris."

  # Encode lists untuk AI input
  NO_PLAN_CSV=$(echo "$NO_PLAN_LIST" | grep -v '^$' | paste -sd ", " - 2>/dev/null || echo "(kosong)")
  NO_REPORT_CSV=$(echo "$NO_REPORT_LIST" | grep -v '^$' | paste -sd ", " - 2>/dev/null || echo "(kosong)")
  ON_LEAVE_CSV=$(echo "$ON_LEAVE_LIST" | grep -v '^$' | paste -sd ", " - 2>/dev/null || echo "(kosong)")
  [ -z "$NO_PLAN_CSV" ] && NO_PLAN_CSV="(kosong)"
  [ -z "$NO_REPORT_CSV" ] && NO_REPORT_CSV="(kosong)"
  [ -z "$ON_LEAVE_CSV" ] && ON_LEAVE_CSV="(kosong)"

  USR_MSG="DATA INPUT (CSV pipe-delimited: nama|cabang|role|customer|hasil|next_action|matched/unmatched|plan_tujuan|plan_goal):

${ACTIVITY}

STATS:
anggota_aktif=${N_ANGGOTA} | wajib_total=${N_WAJIB} | total_report=${N_REPORT} | matched=${N_MATCHED} | unmatched=${N_UNMATCHED} | anggota_punya_plan=${N_PLAN}

NO_PLAN (wajib tapi tidak submit plan hari ini):
${NO_PLAN_CSV}

NON_REPORTERS (sudah submit plan tapi belum report):
${NO_REPORT_CSV}

ON_LEAVE (wajib tapi ijin/sakit/cuti hari ini — sudah di-exclude dari wajib_total):
${ON_LEAVE_CSV}"

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

  # Kirim ke grup HOD Squad (hardcoded). Sebelumnya kirim ke last_active_group
  # tiap HOD individu — bikin summary nyebar ke grup divisi (GA, dll) yg gak
  # relevant. HOD Squad = grup khusus semua HOD, single source.
  HOD_SQUAD_JID="120363042143432430@g.us"
  SENT=0
  if wa_send "$HOD_SQUAD_JID" "$SUMMARY"; then
    SENT=1
  fi

  log "daily_summary — rows=$ROW_COUNT sent=$SENT (HOD Squad) — saved: $OUT_DIR/summary_${TS}.txt"
  exit 0
fi
