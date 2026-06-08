#!/bin/bash
# ============================================================
# WRG CRM — Inbound Handler
# Process incoming WhatsApp group messages matching hashtag triggers.
# Reads JSONL captured by WRG Monitor patch
# (~/.openclaw/tmp/wrg-monitor/messages/<date>/<jid>.jsonl), filters
# group messages with #PLAN/#REPORT/#LEADS/#UPDATE, auths sender via
# master_user, writes to PG, replies via openclaw message send.
#
# Idempotent via processed_message table (7-day TTL).
#
# Usage:
#   bash wrg-inbound.sh              # process new messages then exit
#   bash wrg-inbound.sh --watch      # long-running (fswatch — requires brew)
#
# Cron: every minute (lihat crontab WRG_CRM section)
# ============================================================

set -uo pipefail
source "$(dirname "$0")/../config/config.sh"
export WRG_JOB="inbound"

MESSAGES_DIR="$HOME/.openclaw/tmp/wrg-monitor/messages"
STATE_DIR="$BASE_DIR/data/state"
mkdir -p "$STATE_DIR"
CURSOR_FILE="$STATE_DIR/inbound-cursor"

# Lock dir — prevent overlap with concurrent run (macOS-friendly atomic mkdir).
# PID-based stale recovery: store our PID inside the lockdir; on contention,
# check if the owning PID is still alive via `kill -0`. If dead → reclaim
# immediately (no 10-minute wait). Trap is registered BEFORE any lock activity
# and guarded by LOCK_OWNED so we never accidentally clean another instance's lock.
LOCK_DIR="$STATE_DIR/inbound.lock.d"
LOCK_OWNED=0
trap '[ "$LOCK_OWNED" = "1" ] && rm -rf "$LOCK_DIR" 2>/dev/null' EXIT

acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo $$ > "$LOCK_DIR/pid"
    LOCK_OWNED=1
    return 0
  fi
  # Lock exists — verify owner.
  local OWNER_PID
  OWNER_PID=$(cat "$LOCK_DIR/pid" 2>/dev/null)
  if [ -n "$OWNER_PID" ] && kill -0 "$OWNER_PID" 2>/dev/null; then
    return 1   # owner alive, another instance running — exit silently
  fi
  # Owner dead (or no PID file) — reclaim.
  rm -rf "$LOCK_DIR" 2>/dev/null
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo $$ > "$LOCK_DIR/pid"
    LOCK_OWNED=1
    log "  inbound: reclaimed stale lock (prev PID=${OWNER_PID:-unknown})"
    return 0
  fi
  return 1
}

if ! acquire_lock; then
  exit 0
fi

# ── Hashtag dispatch ────────────────────────────────────────

# Late threshold per role (HHMM format).
# Decision per HOD Squad 2026-05-24:
# - Batch 1 (all 37 wajib users): 08:30 — Bu Ika usul, Husni ack & extend ke
#   Operasional Kirim Tagih supaya semua batch 1 unified.
# - Batch 2 (AM, Teknisi) default 08:00 sampai keputusan HOD-area mereka.
late_threshold_for_role() {
  case "$1" in
    Admin|Finance|Accounting|Purchasing|"Supply Chain"|Logistik|GA|Operasional)
      echo "0830" ;;
    *)
      echo "0800" ;;
  esac
}

# Late plan flag: TRUE kalau submit hari ini AND jam > role-specific threshold.
# Args: $1=tanggal ISO, $2=role (optional, default '' → 08:00).
compute_is_late() {
  local TGL_ISO="$1"
  local ROLE="${2:-}"
  local MSG_TS_S="${3:-}"     # epoch detik dari JSONL ts_ms (optional)
  local THRESHOLD
  THRESHOLD=$(late_threshold_for_role "$ROLE")
  # Pakai MSG_TS_S kalau ada (kapan user kirim), bukan waktu cron processing.
  # Tanpa ini, message yg di-process telat (mis. setelah cursor rollback) jadi
  # salah flagged late walaupun user submit ontime.
  local SUBMIT_DATE SUBMIT_HHMM
  if [ -n "$MSG_TS_S" ]; then
    SUBMIT_DATE=$(date -r "$MSG_TS_S" '+%Y-%m-%d')
    SUBMIT_HHMM=$(date -r "$MSG_TS_S" '+%H%M')
  else
    SUBMIT_DATE=$(date '+%Y-%m-%d')
    SUBMIT_HHMM=$(date '+%H%M')
  fi
  if [ "$TGL_ISO" = "$SUBMIT_DATE" ] && [ "$SUBMIT_HHMM" -gt "$THRESHOLD" ]; then
    echo "TRUE"
  else
    echo "FALSE"
  fi
}

# Cek apakah tanggal di body sudah lewat (< today). Plan adalah perencanaan
# untuk hari ini atau ke depan — bukan untuk hari yang sudah berlalu.
# Args: $1=TGL_ISO. Returns 0 = past (reject), 1 = not past (OK).
is_past_date() {
  local TGL_ISO="$1"
  local TODAY
  TODAY=$(date '+%Y-%m-%d')
  if [[ "$TGL_ISO" < "$TODAY" ]]; then
    return 0   # past = reject
  fi
  return 1     # not past
}

# Cek apakah tanggal terlalu jauh ke depan (> today + WRG_PLAN_MAX_AHEAD_DAYS).
# Default window: 4 hari (today + 4). Bisa di-override via env var.
# Args: $1=TGL_ISO. Returns 0 = too far (reject), 1 = within window (OK).
WRG_PLAN_MAX_AHEAD_DAYS="${WRG_PLAN_MAX_AHEAD_DAYS:-4}"
is_too_future_date() {
  local TGL_ISO="$1"
  local MAX_DATE
  MAX_DATE=$(date -v+${WRG_PLAN_MAX_AHEAD_DAYS}d '+%Y-%m-%d' 2>/dev/null \
              || date -d "+${WRG_PLAN_MAX_AHEAD_DAYS} days" '+%Y-%m-%d')
  if [[ "$TGL_ISO" > "$MAX_DATE" ]]; then
    return 0   # too far = reject
  fi
  return 1     # within window
}

# Parse tanggal dari body. Format yang di-support:
#   - "tgl: DD/MM/YYYY" (spec SKILL.md)
#   - "DD/MM/YYYY" inline (e.g., "#Plan Pita 21/05/2026")
#   - "DD <Bulan> YYYY" Indonesian month name (e.g., "21 Mei 2026", "22 januari 2027")
#   - "DD <Month> YYYY" English month name (e.g., "21 May 2026")
# Return ISO YYYY-MM-DD. Default: hari ini.
parse_tanggal_from_body() {
  local BODY="$1"
  # Only scan HEADER (everything before first numbered item like "1.").
  # Prevents matching dates inside task descriptions (mis. "Bank Jatim 22/05/2026").
  local HEADER
  HEADER=$(echo "$BODY" | awk '/^[[:space:]]*[0-9]+[\.\)]/{exit}{print}')
  # Fallback to first 5 lines if no numbered item detected (AM mode, etc).
  [ -z "$HEADER" ] && HEADER=$(echo "$BODY" | head -5)

  # Try slash/dash format DD/MM/YYYY or DD-MM-YYYY (tolerate optional space).
  local TGL_RAW
  TGL_RAW=$(echo "$HEADER" | grep -oE '[0-9]{1,2}[/-] ?[0-9]{1,2}[/-] ?[0-9]{4}' | head -1)
  if [ -n "$TGL_RAW" ]; then
    # Normalize: strip spaces, convert dash to slash for uniform parsing
    local CLEAN="${TGL_RAW// /}"
    CLEAN="${CLEAN//-//}"
    if [[ "$CLEAN" =~ ^([0-9]{1,2})/([0-9]{1,2})/([0-9]{4})$ ]]; then
      printf "%04d-%02d-%02d" "${BASH_REMATCH[3]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[1]}"
      return
    fi
  fi

  # Try month-name format "DD <Bulan> YYYY" via Python (handles Indonesian + English)
  local TGL_ISO
  TGL_ISO=$(echo "$HEADER" | python3 -c '
import sys, re
text = sys.stdin.read().lower()
months = {
  # Indonesian (full + 3-letter)
  "januari": 1, "jan": 1,
  "februari": 2, "feb": 2,
  "maret": 3, "mar": 3, "mrt": 3,
  "april": 4, "apr": 4,
  "mei": 5,
  "juni": 6, "jun": 6,
  "juli": 7, "jul": 7,
  "agustus": 8, "agu": 8, "agt": 8, "ags": 8,
  "september": 9, "sep": 9, "sept": 9,
  "oktober": 10, "okt": 10, "oct": 10, "october": 10,
  "november": 11, "nov": 11,
  "desember": 12, "des": 12, "december": 12, "dec": 12,
  # English remaining
  "january": 1, "february": 2, "march": 3, "may": 5,
  "june": 6, "july": 7, "august": 8, "aug": 8,
}
# Find "DD <month-name> YYYY" pattern
pat = re.compile(r"\b(\d{1,2})\s+(" + "|".join(sorted(months.keys(), key=len, reverse=True)) + r")\s+(\d{4})\b", re.I)
m = pat.search(text)
if m:
    d, mon, y = int(m.group(1)), months[m.group(2).lower()], int(m.group(3))
    print(f"{y:04d}-{mon:02d}-{d:02d}")
' 2>/dev/null)

  if [ -n "$TGL_ISO" ]; then
    echo "$TGL_ISO"
    return
  fi

  # Fallback: today
  date '+%Y-%m-%d'
}

# Format tanggal display Indonesian: "Kamis, 21 Mei 2026"
format_tanggal_display() {
  local TGL_ISO="$1"
  LC_TIME=id_ID date -j -f "%Y-%m-%d" "$TGL_ISO" "+%A, %-d %B %Y" 2>/dev/null || echo "$TGL_ISO"
}

# Format tanggal display English: "Thursday, 21 May 2026"
format_tanggal_display_en() {
  local TGL_ISO="$1"
  LC_TIME=en_US date -j -f "%Y-%m-%d" "$TGL_ISO" "+%A, %-d %B %Y" 2>/dev/null || echo "$TGL_ISO"
}

# Format tanggal display mixed: ID day + EN month — "Jumat, 22 May 2026"
format_tanggal_display_mix() {
  local TGL_ISO="$1"
  local DAY_ID DAY_REST
  DAY_ID=$(LC_TIME=id_ID date -j -f "%Y-%m-%d" "$TGL_ISO" "+%A" 2>/dev/null)
  DAY_REST=$(LC_TIME=en_US date -j -f "%Y-%m-%d" "$TGL_ISO" "+%-d %B %Y" 2>/dev/null)
  if [ -n "$DAY_ID" ] && [ -n "$DAY_REST" ]; then
    echo "${DAY_ID}, ${DAY_REST}"
  else
    echo "$TGL_ISO"
  fi
}

# Extract display name dari first line body. Pattern: "#Plan <NAME> <date>" atau "#Plan <date>".
# Kalau ada nama di body, return itu. Kalau gak ada (langsung date), return empty.
# Caller fallback ke master_user.panggilan via USER_ID.
parse_name_from_body() {
  local BODY="$1"
  local FIRST_LINE
  FIRST_LINE=$(echo "$BODY" | head -1 | tr -d '\r')
  # Strip leading #plan/#report/etc + whitespace
  local REM
  REM=$(echo "$FIRST_LINE" | sed -E 's/^[[:space:]]*#(plan|report|leads|update)[[:space:]]*//I')
  REM=$(echo "$REM" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
  # Kalau remainder kosong → no name
  [ -z "$REM" ] && { echo ""; return; }
  # Kalau remainder starts with digit OR matches DD/MM/YYYY → no name (langsung date)
  if [[ "$REM" =~ ^[0-9] ]]; then
    echo ""
    return
  fi
  # Else: ambil token pertama (single word) sebagai name.
  # Stop di first digit atau month name (kasar tapi cukup).
  echo "$REM" | awk '{
    for (i=1; i<=NF; i++) {
      if ($i ~ /^[0-9]/) break
      if (out) out = out " " $i
      else out = $i
      if (i >= 1) break   # ambil 1 word only untuk safety
    }
    print out
  }'
}

# === AM mode: customer-visit format ===
# Parse "cust: X, tujuan: Y, goal: Z" (single) atau "C | T | G" (multi)
# Insert ke sales_plan dengan ON CONFLICT UPDATE.
handle_plan_am() {
  local USER_ID="$1" SENDER_NAME="$2" GROUP_JID="$3" BODY="$4" MSG_TS_S="${5:-}"
  local TGL_ISO IS_LATE
  TGL_ISO=$(parse_tanggal_from_body "$BODY")
  if is_past_date "$TGL_ISO"; then
    wa_send "$GROUP_JID" "❌ Tanggal plan sudah lewat ($(format_tanggal_display_en "$TGL_ISO")).
Plan harus untuk hari ini atau yang akan datang.

Contoh:
#PLAN
tgl: $(date '+%d/%m/%Y')
cust: ..."
    log "  #PLAN AM rejected: past date $TGL_ISO from user=$USER_ID"
    return 1
  fi
  if is_too_future_date "$TGL_ISO"; then
    wa_send "$GROUP_JID" "❌ Tanggal plan terlalu jauh ($(format_tanggal_display_en "$TGL_ISO")).
Plan maksimal ${WRG_PLAN_MAX_AHEAD_DAYS} hari kedepan dari hari ini.

Contoh:
#PLAN
tgl: $(date '+%d/%m/%Y')
cust: ..."
    log "  #PLAN AM rejected: too far ahead $TGL_ISO from user=$USER_ID"
    return 1
  fi
  # AM role is hard-coded here (this is the AM-mode handler) → lapangan = 08:00.
  IS_LATE=$(compute_is_late "$TGL_ISO" "AM" "$MSG_TS_S")

  local CUSTS=() TUJUANS=() GOALS=()
  if echo "$BODY" | grep -qE '^[^#]*\|[^|]+\|'; then
    # Multi mode
    while IFS= read -r LINE; do
      [[ -z "$LINE" ]] && continue
      [[ "$LINE" =~ ^[[:space:]]*\#?[Pp][Ll][Aa][Nn] ]] && continue
      [[ "$LINE" =~ ^[[:space:]]*[Tt][Gg][Ll][[:space:]]*: ]] && continue
      [[ "$LINE" =~ ^[[:space:]]*[0-9]+\|[[:space:]]*$ ]] && continue
      if [[ "$LINE" == *"|"*"|"* ]]; then
        IFS='|' read -r C T G <<<"$LINE"
        # Strip leading numbering "1. " / "2)" / "3.⁠ ⁠" (handles unicode invisible chars
        # like U+2060 word-joiner that WhatsApp sometimes injects via auto-format).
        C=$(echo "$C" | sed -E 's/^[[:space:]]*[0-9]+[.)][^A-Za-z]*//' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
        T=$(echo "$T" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
        G=$(echo "$G" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
        [ -z "$C" ] && continue
        CUSTS+=("$C"); TUJUANS+=("$T"); GOALS+=("$G")
      fi
    done <<<"$BODY"
  else
    # Single mode
    local C T G
    C=$(echo "$BODY" | grep -iE "^[[:space:]]*cust[[:space:]]*:" | head -1 | sed -E 's/^[^:]*:[[:space:]]*//')
    T=$(echo "$BODY" | grep -iE "^[[:space:]]*tujuan[[:space:]]*:" | head -1 | sed -E 's/^[^:]*:[[:space:]]*//')
    G=$(echo "$BODY" | grep -iE "^[[:space:]]*goal[[:space:]]*:" | head -1 | sed -E 's/^[^:]*:[[:space:]]*//')
    if [ -z "$C" ]; then
      wa_send "$GROUP_JID" "❌ Format #PLAN untuk AM:
#PLAN
tgl: DD/MM/YYYY
cust: [nama customer]
tujuan: [kunjungan/telp/wa/demo/dll]
goal: [deskripsi]

Atau multi customer:
#PLAN
tgl: DD/MM/YYYY
[Cust 1] | [tujuan] | [goal]
[Cust 2] | [tujuan] | [goal]"
      return 1
    fi
    CUSTS+=("$C"); TUJUANS+=("$T"); GOALS+=("$G")
  fi

  normalize_tujuan() {
    local T_LC
    T_LC="$(echo "$1" | tr '[:upper:]' '[:lower:]')"
    case "$T_LC" in
      kunjungan*fisik|visit|kunjungan|ktm|kf) echo "Kunjungan Fisik" ;;
      telepon|telp|call|tlp|telfon)            echo "Telepon" ;;
      wa|whatsapp|chat|msg|pesan)              echo "WA" ;;
      demo|demonstrasi|demo*produk)            echo "Demo" ;;
      presentasi|present|pitch|pres)           echo "Presentasi" ;;
      follow-up|follow*up|fu|tl|fl|followup)   echo "Follow-up" ;;
      instalasi|install|pasang)                echo "Instalasi" ;;
      pengiriman|kirim|delivery)               echo "Pengiriman" ;;
      servis|service|perbaikan)                echo "Servis" ;;
      training|pelatihan|train)                echo "Training" ;;
      lainnya|other|dll)                       echo "Lainnya" ;;
      *)                                       echo "$1" ;;
    esac
  }

  local N=${#CUSTS[@]} SUCCESS=0 LINES_DISPLAY=""
  for ((i=0; i<N; i++)); do
    local C="${CUSTS[$i]}" T_NORM G="${GOALS[$i]}" SEQ=$((i+1))
    T_NORM=$(normalize_tujuan "${TUJUANS[$i]}")
    if psql -U "$PGUSER" -d "$PGDATABASE" -v ON_ERROR_STOP=1 -q <<SQL >/dev/null 2>>"$LOG_DIR/daily.log"
INSERT INTO sales_plan (user_id, tanggal, customer_name, tujuan, goal, seq, submitted_at, is_late_plan)
VALUES ($USER_ID, '$TGL_ISO', \$\$$C\$\$, \$\$$T_NORM\$\$, \$\$$G\$\$, $SEQ,
        COALESCE(to_timestamp(NULLIF('$MSG_TS_S','')::bigint), NOW()), $IS_LATE)
ON CONFLICT (user_id, tanggal, customer_name) DO UPDATE SET
  tujuan       = EXCLUDED.tujuan,
  goal         = EXCLUDED.goal,
  submitted_at = LEAST(sales_plan.submitted_at, EXCLUDED.submitted_at),
  is_late_plan = sales_plan.is_late_plan;
SQL
    then
      SUCCESS=$((SUCCESS + 1))
      LINES_DISPLAY="${LINES_DISPLAY}
  ${SEQ}. ${C} → ${T_NORM}"
    fi
  done

  # Resolve display name: dari body (e.g. "#Plan Iqbal ...") kalau ada, else master_user.panggilan
  local NAME_FROM_BODY DISPLAY_NAME
  NAME_FROM_BODY=$(parse_name_from_body "$BODY")
  if [ -n "$NAME_FROM_BODY" ]; then
    DISPLAY_NAME="$NAME_FROM_BODY"
  else
    DISPLAY_NAME=$($PSQL -c "SELECT COALESCE(panggilan, nama) FROM master_user WHERE id = $USER_ID;" 2>/dev/null | head -1)
    [ -z "$DISPLAY_NAME" ] && DISPLAY_NAME="$SENDER_NAME"
  fi

  # Compact reply (consistent dengan handle_plan_todo): English date + count summary,
  # no per-customer enumeration. Customer detail tetap tersimpan di sales_plan untuk
  # report_check + dashboard.
  # AM hardcoded threshold 08:00 (lapangan).
  local REPLY="✅ Plan tercatat, ${DISPLAY_NAME}"
  [ "$IS_LATE" = "TRUE" ] && REPLY="${REPLY}
⏰ Plan masuk $(date '+%H:%M') — melewati batas jam 08:00"
  REPLY="${REPLY}

📅 $(format_tanggal_display_en "$TGL_ISO")
 🗒️ ${SUCCESS} customer visit"

  wa_send "$GROUP_JID" "$REPLY"
  log "  #PLAN AM ok: user=$USER_ID name='$DISPLAY_NAME' tgl=$TGL_ISO customers=$SUCCESS/$N late=$IS_LATE"
  return 0
}

# === Non-AM mode: todo-list format ===
# Parse numbered list "1. ..., 2. ..., 3. ..." dari body, insert sebagai 1 row
# di sales_todo dengan items JSONB array.
handle_plan_todo() {
  local USER_ID="$1" SENDER_NAME="$2" GROUP_JID="$3" BODY="$4" MSG_ID="$5" MSG_TS_S="${6:-}"
  local TGL_ISO IS_LATE
  TGL_ISO=$(parse_tanggal_from_body "$BODY")
  if is_past_date "$TGL_ISO"; then
    wa_send "$GROUP_JID" "❌ Tanggal plan sudah lewat ($(format_tanggal_display_en "$TGL_ISO")).
Plan harus untuk hari ini atau yang akan datang.

Contoh:
#Plan $(date '+%-d %B %Y')
1. ..."
    log "  #PLAN TODO rejected: past date $TGL_ISO from user=$USER_ID"
    return 1
  fi
  if is_too_future_date "$TGL_ISO"; then
    wa_send "$GROUP_JID" "❌ Tanggal plan terlalu jauh ($(format_tanggal_display_en "$TGL_ISO")).
Plan maksimal ${WRG_PLAN_MAX_AHEAD_DAYS} hari kedepan dari hari ini.

Contoh:
#Plan $(date '+%-d %B %Y')
1. ..."
    log "  #PLAN TODO rejected: too far ahead $TGL_ISO from user=$USER_ID"
    return 1
  fi
  # TODO mode = non-AM. Lookup role for threshold (non-lapangan → 08:30).
  local USER_ROLE
  USER_ROLE=$($PSQL -c "SELECT role FROM master_user WHERE id = $USER_ID;" 2>/dev/null | head -1)
  IS_LATE=$(compute_is_late "$TGL_ISO" "$USER_ROLE" "$MSG_TS_S")

  # Extract items. Support two formats:
  #   1. Numbered list (canonical): "1. X" / "2. Y" per line
  #   2. Pipe-separated inline: "#Plan X | item1 | item2 | ..." (Hanif-style)
  # Pipe format auto-detected: kalau body single-line dgn ≥2 pipes & gak ada numbered item.
  local ITEMS_JSON
  ITEMS_JSON=$(echo "$BODY" | python3 -c '
import sys, json, re
text = sys.stdin.read()
# Strip Unicode LRM (U+200E) yg sering muncul di body iOS WA
text = text.replace("‎", "")
items = []
def is_skippable(s):
    s = s.strip()
    if not s:
        return True
    if re.match(r"^#?\s*(plan|report|leads|update)\b", s, re.IGNORECASE):
        return True
    if re.match(r"^\d{1,2}[/-]\s*\d{1,2}[/-]\s*\d{4}$", s):
        return True
    return False
# 1. Numbered format
for line in text.splitlines():
    m = re.match(r"^\s*(\d+)[.)]\s*(.+?)\s*$", line.rstrip())
    if m:
        items.append(m.group(2).strip())
# 2. Pipe-separated inline (single-line dgn ≥2 pipes)
if not items and text.count("|") >= 2:
    for p in text.split("|"):
        p = p.strip()
        if not is_skippable(p):
            items.append(p)
# 3. Line-based fallback: each non-empty non-header line = item
if not items:
    for line in text.splitlines():
        line = line.strip()
        if not is_skippable(line):
            items.append(line)
print(json.dumps(items, ensure_ascii=False))
' 2>/dev/null)

  local N
  N=$(echo "$ITEMS_JSON" | jq 'length' 2>/dev/null)
  if [ -z "$N" ] || [ "$N" -lt 1 ]; then
    wa_send "$GROUP_JID" "❌ Format #PLAN tidak terbaca, ${SENDER_NAME}.

Pakai numbered list:
#Plan ${SENDER_NAME} $(date '+%-d/%m/%Y')
1. [tugas pertama]
2. [tugas kedua]
3. [tugas ketiga]"
    return 1
  fi

  # Insert/upsert ke sales_todo by message_id (unique)
  local SAFE_BODY
  SAFE_BODY=$(echo "$BODY" | sed "s/\$\$//g")
  if ! psql -U "$PGUSER" -d "$PGDATABASE" -v ON_ERROR_STOP=1 -q <<SQL >/dev/null 2>>"$LOG_DIR/daily.log"
INSERT INTO sales_todo (user_id, tanggal, items, raw_body, message_id, submitted_at, is_late_plan)
VALUES ($USER_ID, '$TGL_ISO', \$ITEMS\$$ITEMS_JSON\$ITEMS\$::jsonb, \$BODY\$$SAFE_BODY\$BODY\$, \$MID\$$MSG_ID\$MID\$,
        COALESCE(to_timestamp(NULLIF('$MSG_TS_S','')::bigint), NOW()), $IS_LATE)
ON CONFLICT (user_id, tanggal) DO UPDATE SET
  items        = EXCLUDED.items,
  raw_body     = EXCLUDED.raw_body,
  message_id   = EXCLUDED.message_id,
  submitted_at = LEAST(sales_todo.submitted_at, EXCLUDED.submitted_at),
  is_late_plan = sales_todo.is_late_plan;
SQL
  then
    log "  #PLAN TODO insert failed: user=$USER_ID msg=$MSG_ID"
    return 1
  fi

  # Resolve display name: dari body (e.g. "#Plan Cindy ...") kalau ada, else master_user.panggilan
  local NAME_FROM_BODY DISPLAY_NAME
  NAME_FROM_BODY=$(parse_name_from_body "$BODY")
  if [ -n "$NAME_FROM_BODY" ]; then
    DISPLAY_NAME="$NAME_FROM_BODY"
  else
    DISPLAY_NAME=$($PSQL -c "SELECT COALESCE(panggilan, nama) FROM master_user WHERE id = $USER_ID;" 2>/dev/null | head -1)
    [ -z "$DISPLAY_NAME" ] && DISPLAY_NAME="$SENDER_NAME"
  fi

  # Build compact reply. Deadline string driven by role threshold (08:30 batch 1
  # non-lapangan/Operasional, 08:00 lapangan AM/Teknisi).
  local THRESHOLD_HHMM DEADLINE_DISPLAY
  THRESHOLD_HHMM=$(late_threshold_for_role "$USER_ROLE")
  DEADLINE_DISPLAY="${THRESHOLD_HHMM:0:2}:${THRESHOLD_HHMM:2:2}"

  local REPLY="✅ Plan tercatat, ${DISPLAY_NAME}"
  [ "$IS_LATE" = "TRUE" ] && REPLY="${REPLY}
⏰ Plan masuk $(date '+%H:%M') — melewati batas jam ${DEADLINE_DISPLAY}"
  REPLY="${REPLY}

📅 $(format_tanggal_display_en "$TGL_ISO")
 🗒️ ${N} tasklist to-do"

  wa_send "$GROUP_JID" "$REPLY"
  log "  #PLAN TODO ok: user=$USER_ID name='$DISPLAY_NAME' tgl=$TGL_ISO items=$N late=$IS_LATE"
  return 0
}

# Top-level dispatcher: route by master_user.role.
handle_plan() {
  local USER_ID="$1" SENDER_NAME="$2" GROUP_JID="$3" BODY="$4" MSG_ID="$5" MSG_TS_S="${6:-}"
  local ROLE
  ROLE=$($PSQL -c "SELECT role FROM master_user WHERE id = $USER_ID;" 2>/dev/null | head -1)
  if [ "$ROLE" = "AM" ]; then
    handle_plan_am "$USER_ID" "$SENDER_NAME" "$GROUP_JID" "$BODY" "$MSG_TS_S"
  else
    handle_plan_todo "$USER_ID" "$SENDER_NAME" "$GROUP_JID" "$BODY" "$MSG_ID" "$MSG_TS_S"
  fi
}

# === REPORT handlers ===
# AM mode: fuzzy match cust→sales_plan, insert activity_log + update sales_plan.reported
# Todo mode: fuzzy match each numbered line → sales_todo.items, store report_data JSONB

# Thresholds (per SKILL.md)
REPORT_AUTO_MATCH=0.70
REPORT_AMBIGUOUS=0.40

handle_report_am() {
  local USER_ID="$1" SENDER_NAME="$2" GROUP_JID="$3" BODY="$4" MSG_ID="$5"
  local MEDIA_TYPE="${6:-}" MEDIA_PATH="${7:-}" SENDER_WA="${8:-}"
  local TGL_ISO IS_MULTI
  TGL_ISO=$(parse_tanggal_from_body "$BODY")

  # ── Photo + geotag check ────────────────────────────────────
  # AM #REPORT now supports TWO modes:
  #   (a) Photo-with-caption: 1 message = hashtag text + photo (single-customer
  #       atau multi-customer dgn 1 foto kolektif).
  #   (b) Cumulative: text-only hashtag msg dgn N customers, followed by
  #       N image messages dgn caption "1.", "2.", "3." per customer.
  # Mode (b) handled by handle_am_followup_photo when image arrives later;
  # mode (a) processes photo here. Text-only with NO follow-up photos =
  # accepted but flagged (visit_lat/lon remain NULL).
  local PHOTO_PATH="" PHOTO_GEOTAG=""
  if [ -n "$MEDIA_TYPE" ] && [ "${MEDIA_TYPE#image/}" != "$MEDIA_TYPE" ] && [ -f "$MEDIA_PATH" ]; then
    PHOTO_GEOTAG=$(python3 "$BASE_DIR/scripts/check_photo_geotag.py" "$MEDIA_PATH" 2>/dev/null)
    if [ -n "$PHOTO_GEOTAG" ]; then
      PHOTO_PATH="$MEDIA_PATH"
      local HAS_GT
      HAS_GT=$(echo "$PHOTO_GEOTAG" | jq -r '.has_geotag' 2>/dev/null)
      if [ "$HAS_GT" != "true" ]; then
        wa_send "$GROUP_JID" "⚠️ Foto terdeteksi tapi *tidak ada geotag*. Pakai app Geo-Tagging Camera / GPS Map Camera supaya coord ke-burn di foto."
        log "  #REPORT AM warn: photo without geotag from user=$USER_ID"
      else
        local LAT LON
        LAT=$(echo "$PHOTO_GEOTAG" | jq -r '.lat')
        LON=$(echo "$PHOTO_GEOTAG" | jq -r '.lon')
        log "  #REPORT AM photo geotag: user=$USER_ID lat=$LAT lon=$LON"
      fi
    fi
  else
    # Text-only #REPORT — cumulative mode. User akan kirim foto per customer
    # dgn caption "1.", "2.", "3." sebagai follow-up.
    log "  #REPORT AM text-only: user=$USER_ID — awaiting follow-up photos per customer"
  fi

  # Detect Mode B (multi via "---" separator)
  IS_MULTI=0
  if echo "$BODY" | grep -qE '^\s*---\s*$'; then
    IS_MULTI=1
  fi

  # Parse entries — each entry: cust + hasil + next
  # Mode A: single entry (cust/hasil/next at top level)
  # Mode B: multiple entries separated by ---
  local ENTRIES_JSON
  ENTRIES_JSON=$(echo "$BODY" | python3 -c '
import sys, re, json
body = sys.stdin.read()
# Drop hashtag line + tgl: line
lines = [l for l in body.splitlines()
         if not re.match(r"^\s*#report", l, re.I)
         and not re.match(r"^\s*tgl\s*:", l, re.I)]

# Accept two formats:
#   A) Explicit:  cust: NAME / hasil: ... / next: ...
#                 Multiple entries separated by ---
#   B) Numbered:  1. NAME / hasil: ... / next: ...
#                 2. NAME / hasil: ... / next: ...
# Strip unicode invisible chars + numbering when present.

def strip_num(s):
    # Strip leading numbering + "*update " marker, in order:
    # 1) leading numbering "N." / "N)" + non-letter filler chars EXCEPT `*`
    #    (handles U+2060 invisible padding, but preserves `*update` marker).
    # 2) "*update " / "*UPDATE " prefix — AM pakai untuk tandai customer di
    #    luar plan. Badge *update dirender via is_unmatched, jangan stored
    #    di customer_name.
    # Loop sampai stable (handle "1. *update Foo" + edge cases).
    prev = None
    while prev != s:
        prev = s
        s = re.sub(r"^\s*[0-9]+[.)][^A-Za-z*]*", "", s).strip()
        s = re.sub(r"^\*\s*update\s+", "", s, flags=re.I).strip()
    return s

out = []
current = None

def flush():
    global current
    if current and current.get("cust") and current.get("hasil"):
        out.append(current)
    current = None

for raw in lines:
    line = raw.rstrip()
    if not line.strip():
        continue
    # Entry boundary
    if re.match(r"^\s*---\s*$", line):
        flush()
        continue
    # Numbered customer line: "1. NAME" / "2) NAME"
    mnum = re.match(r"^\s*[0-9]+[.)]\s*(.+?)\s*$", line)
    # Keyed lines
    mkey = re.match(r"^\s*(cust|hasil|next)\s*:\s*(.+?)\s*$", line, re.I)

    if mkey:
        key = mkey.group(1).lower()
        val = mkey.group(2).strip()
        if key == "cust":
            flush()
            current = {"cust": strip_num(val), "hasil": "", "next": ""}
        else:
            if current is None:
                current = {"cust": "", "hasil": "", "next": ""}
            current[key] = val
    elif mnum:
        # Numbered customer header — start new entry
        flush()
        current = {"cust": strip_num(line), "hasil": "", "next": ""}
    else:
        # Plain text line (no prefix). If current entry exists tapi hasil
        # masih kosong, treat baris ini sebagai hasil (user lupa typing
        # 'hasil:' prefix). Else ignore.
        if current and not current.get("hasil"):
            current["hasil"] = line.strip()

flush()
print(json.dumps(out, ensure_ascii=False))
' 2>/dev/null)

  local N
  N=$(echo "$ENTRIES_JSON" | jq 'length' 2>/dev/null)
  if [ -z "$N" ] || [ "$N" -lt 1 ]; then
    wa_send "$GROUP_JID" "❌ Format #REPORT tidak terbaca, ${SENDER_NAME}.

Mode A (single):
#REPORT
cust: [nama customer]
hasil: [hasil kunjungan]
next: [tindak lanjut]

Mode B (EOD multi):
#REPORT
tgl: DD/MM/YYYY
---
cust: [Customer 1]
hasil: [hasil]
next: [next]
---
cust: [Customer 2]
hasil: ...
next: ..."
    return 1
  fi

  local MATCHED=0 UNMATCHED=0 AMBIGUOUS=0 LINES_DISPLAY="" MISMATCH_WARNINGS=""
  local AM_CUST_NAMES=""  # untuk warning "foto belum ada" list
  for ((i=0; i<N; i++)); do
    local CUST HASIL NXT
    CUST=$(echo "$ENTRIES_JSON" | jq -r ".[$i].cust")
    AM_CUST_NAMES="${AM_CUST_NAMES}${AM_CUST_NAMES:+, }${CUST}"
    HASIL=$(echo "$ENTRIES_JSON" | jq -r ".[$i].hasil")
    NXT=$(echo "$ENTRIES_JSON" | jq -r ".[$i].next")
    local SAFE_CUST
    SAFE_CUST=$(echo "$CUST" | sed "s/'/''/g")

    # Fuzzy match against today's sales_plan for this user
    local MATCH_ROW
    MATCH_ROW=$($PSQL -c "
      SELECT id || E'\t' || customer_name || E'\t' || tujuan || E'\t' || similarity(customer_name, '$SAFE_CUST')::text
      FROM sales_plan
      WHERE user_id = $USER_ID
        AND tanggal = '$TGL_ISO'
        AND similarity(customer_name, '$SAFE_CUST') > 0.25
      ORDER BY similarity(customer_name, '$SAFE_CUST') DESC
      LIMIT 1;
    " 2>/dev/null | head -1)

    local PLAN_ID="NULL" MATCH_SCORE="NULL" IS_UNMATCHED="TRUE" SHORT_MARK="⚠️"
    if [ -n "$MATCH_ROW" ]; then
      local TOP_ID TOP_CUST TOP_TUJUAN TOP_SCORE
      IFS=$'\t' read -r TOP_ID TOP_CUST TOP_TUJUAN TOP_SCORE <<<"$MATCH_ROW"
      local SCORE_NUM
      SCORE_NUM=$(echo "$TOP_SCORE" | awk '{print int($1 * 100)}')
      if awk -v s="$TOP_SCORE" -v t="$REPORT_AUTO_MATCH" 'BEGIN{exit !(s >= t)}'; then
        # AUTO MATCH (≥0.70)
        PLAN_ID="$TOP_ID"
        MATCH_SCORE="$TOP_SCORE"
        IS_UNMATCHED="FALSE"
        SHORT_MARK="✅"
        MATCHED=$((MATCHED + 1))
      elif awk -v s="$TOP_SCORE" -v t="$REPORT_AMBIGUOUS" 'BEGIN{exit !(s >= t)}'; then
        # AMBIGUOUS (0.40-0.69) — for Phase 0 simplicity, treat as unmatched + flag
        IS_UNMATCHED="TRUE"
        MATCH_SCORE="$TOP_SCORE"
        SHORT_MARK="❓"
        AMBIGUOUS=$((AMBIGUOUS + 1))
      else
        UNMATCHED=$((UNMATCHED + 1))
      fi
    else
      UNMATCHED=$((UNMATCHED + 1))
    fi

    # Insert activity_log row + update sales_plan kalau matched
    local SAFE_HASIL SAFE_NEXT
    SAFE_HASIL=$(echo "$HASIL" | sed "s/'/''/g")
    SAFE_NEXT=$(echo "$NXT" | sed "s/'/''/g")
    local INSERTED_ID
    # photo_path + photo_geotag JSONB (only when AM provided foto with watermark)
    local PHOTO_SQL="NULL, NULL"
    if [ -n "$PHOTO_PATH" ]; then
      local SAFE_PHOTO_PATH SAFE_GEOTAG
      SAFE_PHOTO_PATH=$(echo "$PHOTO_PATH" | sed "s/'/''/g")
      SAFE_GEOTAG=$(echo "$PHOTO_GEOTAG" | sed "s/'/''/g")
      PHOTO_SQL="'$SAFE_PHOTO_PATH', '$SAFE_GEOTAG'::jsonb"
    fi
    local SAFE_WA
    SAFE_WA=$(echo "$SENDER_WA" | sed "s/'/''/g")
    INSERTED_ID=$($PSQL -c "
      INSERT INTO activity_log
        (user_id, customer_name, tanggal, hasil, next_action, source,
         plan_id, is_unmatched, match_score, message_id,
         photo_path, photo_geotag, sender_wa_number)
      VALUES
        ($USER_ID, '$SAFE_CUST', '$TGL_ISO', '$SAFE_HASIL', '$SAFE_NEXT', 'WHATSAPP',
         $PLAN_ID, $IS_UNMATCHED, $MATCH_SCORE,
         '${MSG_ID}__${i}',
         $PHOTO_SQL, '$SAFE_WA')
      ON CONFLICT (message_id) DO NOTHING
      RETURNING id;
    " 2>/dev/null | head -1)

    if [ -n "$INSERTED_ID" ] && [ "$PLAN_ID" != "NULL" ]; then
      # Build visit geo SET clause kalau ada photo geotag valid
      local VISIT_SQL=""
      if [ -n "$PHOTO_GEOTAG" ]; then
        local V_LAT V_LON V_TS_ISO V_MISMATCH
        V_LAT=$(echo "$PHOTO_GEOTAG" | jq -r '.lat // empty')
        V_LON=$(echo "$PHOTO_GEOTAG" | jq -r '.lon // empty')
        V_TS_ISO=$(echo "$PHOTO_GEOTAG" | jq -r '.timestamp_iso // empty')
        if [ -n "$V_LAT" ] && [ -n "$V_LON" ]; then
          # Check date match between photo timestamp + plan tanggal
          V_MISMATCH="FALSE"
          if [ -n "$V_TS_ISO" ]; then
            local TS_DATE
            TS_DATE=$(echo "$V_TS_ISO" | cut -d' ' -f1)
            [ "$TS_DATE" != "$TGL_ISO" ] && V_MISMATCH="TRUE"
            VISIT_SQL=", visit_lat = $V_LAT, visit_lon = $V_LON, visit_timestamp = '$V_TS_ISO', visit_date_mismatch = $V_MISMATCH"
            if [ "$V_MISMATCH" = "TRUE" ]; then
              log "  #REPORT AM warn: photo date $TS_DATE mismatch plan tanggal $TGL_ISO (user=$USER_ID plan=$PLAN_ID)"
              MISMATCH_WARNINGS="${MISMATCH_WARNINGS}
  ⚠️ ${CUST}: foto $TS_DATE ≠ plan $TGL_ISO"
            fi
          else
            VISIT_SQL=", visit_lat = $V_LAT, visit_lon = $V_LON"
          fi
        fi
      fi
      $PSQL -c "
        UPDATE sales_plan SET reported = TRUE, reported_at = NOW(), activity_id = $INSERTED_ID$VISIT_SQL
        WHERE id = $PLAN_ID;
      " >/dev/null 2>>"$LOG_DIR/daily.log"
    fi

    if [ "$IS_UNMATCHED" = "FALSE" ]; then
      LINES_DISPLAY="${LINES_DISPLAY}
${SHORT_MARK} ${CUST} → ${TOP_TUJUAN} ✓
   Hasil: ${HASIL}${NXT:+ | Next: $NXT}"
    elif [ "$SHORT_MARK" = "❓" ]; then
      LINES_DISPLAY="${LINES_DISPLAY}
${SHORT_MARK} ${CUST} → mirip '${TOP_CUST}' (${SCORE_NUM}%), simpan unmatched
   Hasil: ${HASIL}${NXT:+ | Next: $NXT}"
    else
      LINES_DISPLAY="${LINES_DISPLAY}
${SHORT_MARK} ${CUST} → tidak ada di plan
   Hasil: ${HASIL}${NXT:+ | Next: $NXT}"
    fi
  done

  # Progress recap
  local PROG_ROW
  PROG_ROW=$($PSQL -c "
    SELECT
      COALESCE(SUM(CASE WHEN reported THEN 1 ELSE 0 END), 0) || E'\t' ||
      COUNT(*) || E'\t' ||
      COALESCE(string_agg(customer_name, ', ' ORDER BY seq) FILTER (WHERE NOT reported), '')
    FROM sales_plan
    WHERE user_id = $USER_ID AND tanggal = '$TGL_ISO';
  " 2>/dev/null | head -1)
  local DONE_N TOTAL_N UNREPORTED_LIST
  IFS=$'\t' read -r DONE_N TOTAL_N UNREPORTED_LIST <<<"$PROG_ROW"

  local PROGRESS_BAR=""
  if [ "${TOTAL_N:-0}" -gt 0 ]; then
    local FILLED EMPTY
    FILLED=$((DONE_N * 7 / TOTAL_N))
    EMPTY=$((7 - FILLED))
    PROGRESS_BAR=$(printf '%.0s▓' $(seq 1 $FILLED 2>/dev/null))$(printf '%.0s░' $(seq 1 $EMPTY 2>/dev/null))
  fi

  # Resolve display name (parse from body OR fallback to panggilan)
  local NAME_FROM_BODY DISPLAY_NAME
  NAME_FROM_BODY=$(parse_name_from_body "$BODY")
  if [ -n "$NAME_FROM_BODY" ]; then
    DISPLAY_NAME="$NAME_FROM_BODY"
  else
    DISPLAY_NAME=$($PSQL -c "SELECT COALESCE(panggilan, nama) FROM master_user WHERE id = $USER_ID;" 2>/dev/null | head -1)
    [ -z "$DISPLAY_NAME" ] && DISPLAY_NAME="$SENDER_NAME"
  fi

  # Compact reply consistent dengan #PLAN AM format
  local LABEL
  if [ "$N" -eq 1 ] && [ "$IS_MULTI" -eq 0 ]; then
    LABEL="Report tercatat"
  else
    LABEL="Report EOD tercatat"
  fi

  # Compact AM reply: progress + bar inline, Belum direport inline-space-separated
  local REPLY="✅ ${LABEL}, ${DISPLAY_NAME}

📅 $(format_tanggal_display_en "$TGL_ISO")
🗒️ ${N} customer reported"

  # Progress + bar (inline 2-space)
  if [ "${TOTAL_N:-0}" -gt 0 ]; then
    REPLY="${REPLY}
📊 ${DONE_N}/${TOTAL_N} customer selesai  ${PROGRESS_BAR}"
  fi

  # Match plan line — only non-zero counts, no space before ✓
  local SUMMARY_PARTS=""
  [ "$MATCHED" -gt 0 ]   && SUMMARY_PARTS="${SUMMARY_PARTS} ${MATCHED}✓"
  [ "$AMBIGUOUS" -gt 0 ] && SUMMARY_PARTS="${SUMMARY_PARTS} ${AMBIGUOUS}❓"
  [ "$UNMATCHED" -gt 0 ] && SUMMARY_PARTS="${SUMMARY_PARTS} ${UNMATCHED}⚠️"
  [ -n "$SUMMARY_PARTS" ] && REPLY="${REPLY}
🎯 Match plan:${SUMMARY_PARTS}"

  # Belum direport — inline, space-separated, ⚠️ per item
  if [ -n "$UNREPORTED_LIST" ]; then
    local INLINE_BELUM
    INLINE_BELUM=$(echo "$UNREPORTED_LIST" | sed 's/, /⚠️ /g')
    REPLY="${REPLY}
 Belum direport:  ⚠️ ${INLINE_BELUM}"
  fi

  # Append date-mismatch warnings (visit photo tanggal ≠ plan tanggal — sus
  # backdate report). Tetap accept tapi flag visible di reply ke user + HOD.
  if [ -n "$MISMATCH_WARNINGS" ]; then
    REPLY="${REPLY}

⚠️ *Tanggal foto mismatch — verifikasi visit:*${MISMATCH_WARNINGS}"
  fi

  # Photo coverage warning:
  #   (a) Text-only hashtag → semua customer awaiting follow-up foto.
  #   (b) Photo on hashtag msg + multi customer → cuma customer #1 ter-cover,
  #       sisa awaiting follow-up.
  if [ -z "$PHOTO_PATH" ] && [ "$N" -gt 0 ]; then
    REPLY="${REPLY}

⚠️ *Foto visit belum ada (${N} customer):*
${AM_CUST_NAMES}

Kirim foto Geo-Tagging Camera per customer dgn caption \`Nama Customer\` — fuzzy match auto-pair ke pending."
    log "  #REPORT AM warn: text-only, $N customer awaiting photos (user=$USER_ID)"
  elif [ -n "$PHOTO_PATH" ] && [ "$N" -gt 1 ]; then
    # First customer covered, list the rest
    local REST_LIST
    REST_LIST=$(printf "%s" "$AM_CUST_NAMES" | python3 -c "import sys; print(', '.join(sys.stdin.read().split(', ')[1:]))" 2>/dev/null)
    REPLY="${REPLY}

⚠️ *Foto cuma 1, tapi report ${N} customer.* Foto di-apply ke customer #1. Sisa $((N - 1)) belum ada foto:
${REST_LIST}

Kirim foto Geo-Tagging Camera dgn caption nama customer untuk yg belum."
    log "  #REPORT AM warn: single photo for $N customers (user=$USER_ID)"
  fi

  # ── Note: TGL keterangan — reminder masa depan ──────────────
  # Single-line format: "note: 7/6/2026 cek deal closing RS Mitra"
  # Parser: extract semua line `note: ...` dari body. Bisa multi-note (1 per
  # line). Tanggal flexible: dd/mm/yyyy, dd-mm-yyyy, dd Mon yyyy.
  # Reminder fires H-1 17:00 + H 07:00 ke The ALLIANCE (cron_reminder.sh).
  local NOTES_REPLY=""
  while IFS= read -r NOTE_LINE; do
    [ -z "$NOTE_LINE" ] && continue
    local NOTE_PARSED
    NOTE_PARSED=$(printf '%s' "$NOTE_LINE" | python3 -c '
import sys, re, json
line = sys.stdin.read().strip()
m = re.match(r"^\s*note\s*:\s*(.+)$", line, re.I)
if not m: sys.exit(0)
rest = m.group(1).strip()
# Try dd/mm/yyyy or dd-mm-yyyy
md = re.match(r"^(\d{1,2})[/\-](\d{1,2})[/\-](\d{2,4})\s+(.+)$", rest)
if md:
    d, mo, y, txt = md.group(1), md.group(2), md.group(3), md.group(4)
    if len(y) == 2: y = "20" + y
    iso = f"{int(y):04d}-{int(mo):02d}-{int(d):02d}"
    print(json.dumps({"tgl": iso, "ket": txt.strip()}))
    sys.exit(0)
# Try dd Mon yyyy (Indonesian + English month)
months = {"jan":1,"feb":2,"mar":3,"apr":4,"mei":5,"may":5,"jun":6,"jul":7,"agu":8,"agt":8,"aug":8,
         "sep":9,"okt":10,"oct":10,"nov":11,"des":12,"dec":12,"januari":1,"februari":2,"maret":3,
         "april":4,"juni":6,"juli":7,"agustus":8,"september":9,"oktober":10,"november":11,"desember":12}
mm = re.match(r"^(\d{1,2})\s+([A-Za-z]+)\s+(\d{2,4})\s+(.+)$", rest)
if mm:
    d, mon_str, y, txt = mm.group(1), mm.group(2).lower()[:3], mm.group(3), mm.group(4)
    if mon_str in months:
        if len(y) == 2: y = "20" + y
        iso = f"{int(y):04d}-{months[mon_str]:02d}-{int(d):02d}"
        print(json.dumps({"tgl": iso, "ket": txt.strip()}))
' 2>/dev/null)
    if [ -n "$NOTE_PARSED" ]; then
      local N_TGL N_KET
      N_TGL=$(echo "$NOTE_PARSED" | jq -r '.tgl')
      N_KET=$(echo "$NOTE_PARSED" | jq -r '.ket')
      # Check tanggal masa depan (today atau later)
      if [[ "$N_TGL" < "$(date '+%Y-%m-%d')" ]]; then
        NOTES_REPLY="${NOTES_REPLY}
⚠️ Note diabaikan: tanggal $N_TGL sudah lewat."
        continue
      fi
      # Auto-detect customer: scan body line-by-line, track LAST numbered
      # customer header seen. Saat ketemu line `note:`, associate dgn last
      # customer header (positional context — note ditulis di bawah customer
      # entry-nya). Fallback fuzzy match kalau positional gagal.
      local SAFE_KET N_CUST
      SAFE_KET=$(echo "$N_KET" | sed "s/'/''/g")
      N_CUST=$(printf '%s\n###KET###\n%s' "$BODY" "$N_KET" | python3 -c '
import sys, re
parts = sys.stdin.read().split("###KET###")
body, ket = parts[0], parts[1].strip() if len(parts) > 1 else ""
if not ket: sys.exit(0)

# Pass 1: walk body, track last customer for each note position
note_to_cust = {}  # ket_text → customer_name
last_cust = None
all_customers = []
for line in body.splitlines():
    # Numbered customer header — capture customer name
    mc = re.match(r"^\s*[0-9]+[.):]\s*([^|/\n]{2,80}?)(\s*[|/]|$)", line)
    if mc:
        cust = mc.group(1).strip()
        cust = re.sub(r"^\*\s*update\s+", "", cust, flags=re.I).strip()
        if cust:
            last_cust = cust
            all_customers.append(cust)
        continue
    # Note line — bind to last_cust
    mn = re.match(r"^\s*note\s*:\s*(.+)$", line, re.I)
    if mn:
        # Compare ket_text (everything after "note:") with our target ket
        ket_full = mn.group(1).strip()
        if ket in ket_full or ket_full.endswith(ket):
            if last_cust:
                note_to_cust[ket] = last_cust

if ket in note_to_cust:
    print(note_to_cust[ket])
    sys.exit(0)

# Fallback: fuzzy match kalau positional ga deteksi
if not all_customers: sys.exit(0)
STOP = {"visit", "kunjungan", "fisik", "follow", "fwup", "next", "hasil",
        "untuk", "dari", "deal", "closing", "yang", "dan", "atau", "kepada",
        "akan", "selesai", "tunggu", "report", "the", "with", "ulang",
        "ketemu", "kepala", "direktur"}
def tokens(s):
    return set(t for t in re.findall(r"[a-zA-Z]{3,}", s.lower()) if t not in STOP)
ket_toks = tokens(ket)
best = ("", 0.0)
for c in all_customers:
    c_toks = tokens(c)
    if not c_toks or not ket_toks: continue
    overlap = len(ket_toks & c_toks)
    if not overlap: continue
    score = max(overlap / len(c_toks), overlap / len(ket_toks))
    if score > best[1]:
        best = (c, score)
if best[1] >= 0.4:
    print(best[0])
' 2>/dev/null)
      local CUST_SQL
      if [ -n "$N_CUST" ]; then
        local SAFE_CUST
        SAFE_CUST=$(echo "$N_CUST" | sed "s/'/''/g")
        CUST_SQL="'$SAFE_CUST'"
      else
        CUST_SQL="NULL"
      fi
      $PSQL -c "INSERT INTO am_reminder (user_id, tanggal_reminder, keterangan, customer_name, created_msg_id, source_report_date) VALUES ($USER_ID, '$N_TGL', '$SAFE_KET', $CUST_SQL, '$MSG_ID', '$TGL_ISO');" >/dev/null 2>>"$LOG_DIR/daily.log"
      log "  #REPORT AM note: user=$USER_ID tgl=$N_TGL cust='${N_CUST}' ket='${N_KET:0:60}'"
      local CUST_LABEL=""
      [ -n "$N_CUST" ] && CUST_LABEL=" (${N_CUST})"
      NOTES_REPLY="${NOTES_REPLY}
📌 Note tercatat: $N_TGL${CUST_LABEL} — ${N_KET}"
    fi
  done <<< "$(printf '%s' "$BODY" | grep -iE '^[[:space:]]*note[[:space:]]*:')"

  if [ -n "$NOTES_REPLY" ]; then
    REPLY="${REPLY}${NOTES_REPLY}"
  fi

  wa_send "$GROUP_JID" "$REPLY"
  log "  #REPORT AM ok: user=$USER_ID name='$DISPLAY_NAME' entries=$N matched=$MATCHED ambiguous=$AMBIGUOUS unmatched=$UNMATCHED"
  return 0
}

handle_report_todo() {
  local USER_ID="$1" SENDER_NAME="$2" GROUP_JID="$3" BODY="$4" MSG_ID="$5"
  local TGL_ISO
  TGL_ISO=$(parse_tanggal_from_body "$BODY")

  # Parse numbered items from report body (format: "1. <task> : <result>")
  local REPORT_ITEMS_JSON
  REPORT_ITEMS_JSON=$(echo "$BODY" | python3 -c '
import sys, re, json
items = []
for line in sys.stdin:
    line = line.rstrip()
    m = re.match(r"^\s*(\d+)[.)]\s*(.+?)\s*$", line)
    if m:
        text = m.group(2).strip()
        # Split task vs result at LAST ":" (handles "Membuat X : 36 SJ (selesai)")
        if ":" in text:
            parts = text.rsplit(":", 1)
            task   = parts[0].strip()
            result = parts[1].strip()
        else:
            task, result = text, ""
        items.append({"idx": int(m.group(1)), "task": task, "result": result})
print(json.dumps(items, ensure_ascii=False))
' 2>/dev/null)

  local N
  N=$(echo "$REPORT_ITEMS_JSON" | jq 'length' 2>/dev/null)
  if [ -z "$N" ] || [ "$N" -lt 1 ]; then
    wa_send "$GROUP_JID" "❌ Format #REPORT tidak terbaca, ${SENDER_NAME}.

Pakai numbered list:
#Report ${SENDER_NAME} $(date '+%-d/%m/%Y')
1. [tugas dari plan] : [hasil/status]
2. [tugas dari plan] : [hasil/status]
3. [tugas dari plan] : [hasil/status]"
    return 1
  fi

  # Find latest sales_todo for this user today
  local TODO_ROW
  TODO_ROW=$($PSQL -c "
    SELECT id || E'\t' || items::text
    FROM sales_todo
    WHERE user_id = $USER_ID AND tanggal = '$TGL_ISO'
    ORDER BY submitted_at DESC LIMIT 1;
  " 2>/dev/null | head -1)

  local TODO_ID="" TODO_ITEMS_JSON="[]"
  if [ -n "$TODO_ROW" ]; then
    IFS=$'\t' read -r TODO_ID TODO_ITEMS_JSON <<<"$TODO_ROW"
  fi

  # Fuzzy match each report item against plan items + build report_data
  # Pass JSON via env vars (avoids heredoc-substitution syntax errors)
  local MATCHED_DATA
  MATCHED_DATA=$(
    REPORT_ITEMS="$REPORT_ITEMS_JSON" \
    PLAN_ITEMS="${TODO_ITEMS_JSON:-[]}" \
    AUTO="$REPORT_AUTO_MATCH" \
    AMBIG="$REPORT_AMBIGUOUS" \
    PGUSER="$PGUSER" PGDATABASE="$PGDATABASE" \
    python3 <<'PYEOF'
import json, os, subprocess

report_items = json.loads(os.environ.get("REPORT_ITEMS","[]") or "[]")
plan_items   = json.loads(os.environ.get("PLAN_ITEMS","[]") or "[]")
auto         = float(os.environ.get("AUTO","0.70"))
ambig        = float(os.environ.get("AMBIG","0.40"))
pguser       = os.environ.get("PGUSER","wrg_admin")
pgdb         = os.environ.get("PGDATABASE","wrg_crm")

def sim(report_text, plan_text):
    # GREATEST(similarity, word_similarity):
    # - similarity = symmetric, baik kalau dua string mirip overall
    # - word_similarity(plan, report) = high kalau plan substantially di-contain di report
    #   (e.g., report = plan + ", selesai" → word_sim=1.0)
    a_esc = report_text.replace("'", "''")
    b_esc = plan_text.replace("'", "''")
    r = subprocess.run(
        ["psql","-U",pguser,"-d",pgdb,"-tA","-c",
         f"SELECT GREATEST(similarity('{a_esc}', '{b_esc}'), word_similarity('{b_esc}', '{a_esc}'));"],
        capture_output=True, text=True, timeout=5)
    try: return float(r.stdout.strip())
    except: return 0.0

result = []
for r in report_items:
    best_idx, best_score, best_task = -1, 0.0, ""
    for i, pt in enumerate(plan_items):
        s = sim(r["task"], pt)
        if s > best_score:
            best_score, best_idx, best_task = s, i, pt
    matched = best_score >= auto
    is_amb  = (not matched) and (best_score >= ambig)
    result.append({
        "idx": r["idx"],
        "task": r["task"],
        "result": r["result"],
        "matched_plan_idx": best_idx if matched else None,
        "matched_plan_task": best_task if matched else None,
        "match_score": round(best_score, 3),
        "status": "matched" if matched else ("ambiguous" if is_amb else "unmatched")
    })
print(json.dumps(result, ensure_ascii=False))
PYEOF
  )

  # Store report_data into sales_todo (kalau ada plan match)
  if [ -n "$TODO_ID" ]; then
    local SAFE_DATA
    SAFE_DATA=$(echo "$MATCHED_DATA" | sed "s/'/''/g")
    $PSQL -c "
      UPDATE sales_todo
      SET report_data   = '$SAFE_DATA'::jsonb,
          report_msg_id = '$MSG_ID',
          reported      = TRUE,
          reported_at   = NOW()
      WHERE id = $TODO_ID;
    " >/dev/null 2>>"$LOG_DIR/daily.log"
  else
    # Ad-hoc report — user skip #PLAN tapi langsung #REPORT. Insert sales_todo
    # row baru dgn items dari report (jadi items=baru semua), is_late_plan=TRUE,
    # reported=TRUE. Supaya report_check ga warn "no plan" + dashboard reflect
    # bahwa user submitted.
    local ITEMS_JSON SAFE_ITEMS SAFE_DATA
    ITEMS_JSON=$(echo "$REPORT_ITEMS_JSON" | jq -c '[.[] | .task]')
    SAFE_ITEMS=$(echo "$ITEMS_JSON" | sed "s/'/''/g")
    SAFE_DATA=$(echo "$MATCHED_DATA" | sed "s/'/''/g")
    TODO_ID=$($PSQL -c "
      INSERT INTO sales_todo (user_id, tanggal, items, is_late_plan, reported, reported_at, report_data, report_msg_id, submitted_at)
      VALUES ($USER_ID, '$TGL_ISO', '$SAFE_ITEMS'::jsonb, TRUE, TRUE, NOW(), '$SAFE_DATA'::jsonb, '$MSG_ID', NOW())
      ON CONFLICT (user_id, tanggal) DO UPDATE
        SET items = EXCLUDED.items,
            reported = TRUE,
            reported_at = NOW(),
            report_data = EXCLUDED.report_data,
            report_msg_id = EXCLUDED.report_msg_id
      RETURNING id;
    " 2>/dev/null | head -1)
    log "  #REPORT TODO ad-hoc: user=$USER_ID inserted todo_id=$TODO_ID dgn $N items (no prior #PLAN)"
  fi

  # Build reply
  local MATCHED UNMATCHED AMBIG
  MATCHED=$(echo "$MATCHED_DATA" | jq '[.[] | select(.status=="matched")] | length')
  UNMATCHED=$(echo "$MATCHED_DATA" | jq '[.[] | select(.status=="unmatched")] | length')
  AMBIG=$(echo "$MATCHED_DATA" | jq '[.[] | select(.status=="ambiguous")] | length')

  # Resolve display name (parse from body OR fallback to panggilan)
  local NAME_FROM_BODY DISPLAY_NAME
  NAME_FROM_BODY=$(parse_name_from_body "$BODY")
  if [ -n "$NAME_FROM_BODY" ]; then
    DISPLAY_NAME="$NAME_FROM_BODY"
  else
    DISPLAY_NAME=$($PSQL -c "SELECT COALESCE(panggilan, nama) FROM master_user WHERE id = $USER_ID;" 2>/dev/null | head -1)
    [ -z "$DISPLAY_NAME" ] && DISPLAY_NAME="$SENDER_NAME"
  fi

  # Build reply — TODO REPORT format (ID day + EN month, list unmatched below divider)
  # Treat ambiguous as "Baru" (unmatched) since pg_trgm ambig zone narrow.
  local TOTAL_BARU=$((AMBIG + UNMATCHED))
  local REPLY="✅ Report tercatat, ${DISPLAY_NAME}

📅 $(format_tanggal_display_mix "$TGL_ISO")
🗒️ ${N} tasklist reported"

  # Match plan line — show counts even if 0 for clarity
  REPLY="${REPLY}
🎯 Match plan: ${MATCHED} ✓"
  [ "$TOTAL_BARU" -gt 0 ] && REPLY="${REPLY}  ⚠️ Baru : ${TOTAL_BARU}"

  # Divider + list unmatched items (incl ambiguous)
  if [ "$TOTAL_BARU" -gt 0 ]; then
    REPLY="${REPLY}
━━━━━━━━━━━━━━━━━━━━"
    local I=0
    while [ "$I" -lt "$N" ]; do
      local STATUS TASK RESULT
      STATUS=$(echo "$MATCHED_DATA" | jq -r ".[$I].status")
      if [ "$STATUS" = "matched" ]; then
        I=$((I + 1))
        continue
      fi
      TASK=$(echo "$MATCHED_DATA" | jq -r ".[$I].task")
      RESULT=$(echo "$MATCHED_DATA" | jq -r ".[$I].result")
      REPLY="${REPLY}
  ⚠️ ${TASK}${RESULT:+ → $RESULT}"
      I=$((I + 1))
    done
  fi

  [ -z "$TODO_ID" ] && REPLY="${REPLY}
⚠️ Tidak ada #PLAN hari ini untuk match."

  wa_send "$GROUP_JID" "$REPLY"
  log "  #REPORT TODO ok: user=$USER_ID name='$DISPLAY_NAME' items=$N matched=$MATCHED baru=$TOTAL_BARU todo_id=$TODO_ID"
  return 0
}

handle_report() {
  local USER_ID="$1" SENDER_NAME="$2" GROUP_JID="$3" BODY="$4" MSG_ID="$5"
  local MEDIA_TYPE="${6:-}" MEDIA_PATH="${7:-}" SENDER_WA="${8:-}"
  local ROLE
  ROLE=$($PSQL -c "SELECT role FROM master_user WHERE id = $USER_ID;" 2>/dev/null | head -1)
  if [ "$ROLE" = "AM" ]; then
    handle_report_am "$USER_ID" "$SENDER_NAME" "$GROUP_JID" "$BODY" "$MSG_ID" "$MEDIA_TYPE" "$MEDIA_PATH" "$SENDER_WA"
  else
    handle_report_todo "$USER_ID" "$SENDER_NAME" "$GROUP_JID" "$BODY" "$MSG_ID"
  fi
}

handle_am_followup_photo() {
  # Image message tanpa hashtag dengan caption seperti "1. RS Foo", "Kalianget",
  # atau "3.". Pairing strategy (priority):
  #   1. Caption text → fuzzy match (pg_trgm similarity) ke customer_name dari
  #      activity_log rows sender hari ini. Min score 0.30. Pick highest.
  #   2. Fallback: number di caption → ROW_NUMBER posisi di activity_log
  #      (urutan insert = urutan di body report).
  # Ini handle case user pakai number sebagai sequence counter dgn name sebagai
  # identifier, OR pakai number-only caption tanpa nama.
  local GROUP_JID="$1" BODY="$2" MEDIA_PATH="$3" SENDER_WA="$4"
  local TGL_ISO TGL_FROM CAPTION_TEXT IDX
  TGL_ISO=$(date '+%Y-%m-%d')
  TGL_FROM=$(date -v-7d '+%Y-%m-%d')

  # Extract caption components: number (optional) + text-after-number
  CAPTION_TEXT=$(echo "$BODY" | head -1)
  IDX=$(echo "$CAPTION_TEXT" | python3 -c "
import sys, re
line = sys.stdin.readline()
m = re.match(r'^\s*(\d+)[.):\s\-]', line)
print(m.group(1) if m else '')
" 2>/dev/null)
  # Strip leading number+punct to get name part for fuzzy match
  local NAME_PART
  NAME_PART=$(echo "$CAPTION_TEXT" | python3 -c "
import sys, re
line = sys.stdin.readline().strip()
# Remove leading 'N.', 'N)', 'N -', 'N:' etc
line = re.sub(r'^\s*\d+[.):\s\-]+', '', line)
print(line.strip())
" 2>/dev/null)

  # Reject jika tidak ada number AND tidak ada name part (bukan follow-up valid)
  if [ -z "$IDX" ] && [ -z "$NAME_PART" ]; then
    return 1
  fi

  local TOTAL_ROWS
  TOTAL_ROWS=$($PSQL -c "SELECT COUNT(*) FROM activity_log WHERE sender_wa_number = '$SENDER_WA' AND tanggal BETWEEN '$TGL_FROM' AND '$TGL_ISO';" 2>/dev/null | head -1)
  if [ -z "$TOTAL_ROWS" ] || [ "$TOTAL_ROWS" = "0" ]; then
    return 1  # No pending #REPORT from this sender today
  fi

  # Try fuzzy match by name first (priority over index)
  local TARGET_ROW=""
  if [ -n "$NAME_PART" ]; then
    local SAFE_NAME
    SAFE_NAME=$(echo "$NAME_PART" | sed "s/'/''/g")
    TARGET_ROW=$($PSQL -c "
      SELECT id || E'\t' || customer_name || E'\t' || COALESCE(plan_id::text, 'NULL') || E'\t' || user_id || E'\t' || (CASE WHEN photo_path IS NOT NULL THEN 't' ELSE 'f' END) || E'\t' || ROUND(similarity(customer_name, '$SAFE_NAME')::numeric, 2)
      FROM activity_log
      WHERE sender_wa_number = '$SENDER_WA' AND tanggal BETWEEN '$TGL_FROM' AND '$TGL_ISO'
        AND photo_path IS NULL
        AND similarity(customer_name, '$SAFE_NAME') >= 0.30
      ORDER BY similarity(customer_name, '$SAFE_NAME') DESC
      LIMIT 1;
    " 2>/dev/null | head -1)
  fi

  # Fallback: ROW_NUMBER by index if name match failed.
  # Only consider rows yang masih pending (photo_path IS NULL) supaya ga
  # ke-pair ke row yang udah ada foto (prevent overwrite + cross-AM collision
  # ketika sender_wa_number shared across AM via grup yang sama).
  if [ -z "$TARGET_ROW" ] && [ -n "$IDX" ]; then
    TARGET_ROW=$($PSQL -c "
      SELECT id || E'\t' || customer_name || E'\t' || COALESCE(plan_id::text, 'NULL') || E'\t' || user_id || E'\t' || 'f' || E'\t' || '0.00'
      FROM (
        SELECT *, ROW_NUMBER() OVER (ORDER BY id ASC) AS rn
        FROM activity_log
        WHERE sender_wa_number = '$SENDER_WA' AND tanggal BETWEEN '$TGL_FROM' AND '$TGL_ISO'
          AND photo_path IS NULL
      ) t WHERE rn = $IDX;
    " 2>/dev/null | head -1)
  fi

  if [ -z "$TARGET_ROW" ]; then
    # Pre-check: kalau caption match ke row yang udah punya photo, kasih
    # message spesifik instead of misleading "no match". User probably resend
    # photo yang sudah tersimpan sebelumnya.
    local ALREADY_NAME=""
    if [ -n "$NAME_PART" ]; then
      ALREADY_NAME=$($PSQL -c "
        SELECT customer_name
        FROM activity_log
        WHERE sender_wa_number = '$SENDER_WA' AND tanggal BETWEEN '$TGL_FROM' AND '$TGL_ISO'
          AND photo_path IS NOT NULL
          AND similarity(customer_name, '$SAFE_NAME') >= 0.50
        ORDER BY similarity(customer_name, '$SAFE_NAME') DESC
        LIMIT 1;
      " 2>/dev/null | head -1)
    fi
    if [ -n "$ALREADY_NAME" ]; then
      wa_send "$GROUP_JID" "ℹ️ Foto ${ALREADY_NAME} sudah tersimpan sebelumnya. Tidak perlu kirim ulang."
      log "  #REPORT AM photo-followup: skip-dup caption='$CAPTION_TEXT' already-saved='$ALREADY_NAME'"
      return 0
    fi
    wa_send "$GROUP_JID" "⚠️ Caption '${CAPTION_TEXT}' gak match ke customer manapun di report (${TOTAL_ROWS} customers). Pakai caption \`N. Nama Customer\` (mis. \`3. Rsud Sumenep\`)."
    log "  #REPORT AM photo-followup: no match for caption='$CAPTION_TEXT' (total=$TOTAL_ROWS wa=$SENDER_WA)"
    return 1
  fi

  local ACT_ID CUST_NAME PLAN_ID USER_ID ALREADY_HAS_PHOTO MATCH_SIM
  IFS=$'\t' read -r ACT_ID CUST_NAME PLAN_ID USER_ID ALREADY_HAS_PHOTO MATCH_SIM <<<"$TARGET_ROW"
  if [ "$ALREADY_HAS_PHOTO" = "t" ]; then
    log "  #REPORT AM photo-followup: overwriting existing photo for cust='$CUST_NAME'"
  fi
  log "  #REPORT AM photo-followup: matched '$NAME_PART' → cust='$CUST_NAME' (sim=$MATCH_SIM)"

  local PHOTO_GEOTAG HAS_GT
  PHOTO_GEOTAG=$(python3 "$BASE_DIR/scripts/check_photo_geotag.py" "$MEDIA_PATH" 2>/dev/null)
  if [ -z "$PHOTO_GEOTAG" ]; then
    wa_send "$GROUP_JID" "⚠️ Foto customer #$IDX ($CUST_NAME): gagal OCR. Pastikan watermark Geo-Tagging Camera kebaca."
    log "  #REPORT AM photo-followup: OCR failed idx=$IDX cust='$CUST_NAME'"
    return 1
  fi
  HAS_GT=$(echo "$PHOTO_GEOTAG" | jq -r '.has_geotag' 2>/dev/null)

  local SAFE_PATH SAFE_GEOTAG
  SAFE_PATH=$(echo "$MEDIA_PATH" | sed "s/'/''/g")
  # Re-serialize via jq -c (compact, ensures newlines + control chars escaped)
  SAFE_GEOTAG=$(echo "$PHOTO_GEOTAG" | jq -c . 2>/dev/null | sed "s/'/''/g")
  [ -z "$SAFE_GEOTAG" ] && SAFE_GEOTAG="$(echo "$PHOTO_GEOTAG" | tr -d '\n' | sed "s/'/''/g")"
  $PSQL -c "UPDATE activity_log SET photo_path = '$SAFE_PATH', photo_geotag = '$SAFE_GEOTAG'::jsonb WHERE id = $ACT_ID;" >/dev/null 2>>"$LOG_DIR/daily.log"

  if [ "$HAS_GT" != "true" ]; then
    wa_send "$GROUP_JID" "⚠️ Foto customer #$IDX ($CUST_NAME) tersimpan, tapi *tidak ada geotag*. Pakai Geo-Tagging Camera supaya coord ke-burn di pixel."
    log "  #REPORT AM photo-followup: no geotag idx=$IDX cust='$CUST_NAME'"
    return 0
  fi

  local V_LAT V_LON V_TS_ISO V_MISMATCH TS_DATE
  V_LAT=$(echo "$PHOTO_GEOTAG" | jq -r '.lat // empty')
  V_LON=$(echo "$PHOTO_GEOTAG" | jq -r '.lon // empty')
  V_TS_ISO=$(echo "$PHOTO_GEOTAG" | jq -r '.timestamp_iso // empty')
  V_MISMATCH="FALSE"
  TS_DATE=""
  if [ -n "$V_TS_ISO" ]; then
    TS_DATE=$(echo "$V_TS_ISO" | cut -d' ' -f1)
    [ "$TS_DATE" != "$TGL_ISO" ] && V_MISMATCH="TRUE"
  fi

  if [ "$PLAN_ID" != "NULL" ] && [ -n "$V_LAT" ] && [ -n "$V_LON" ]; then
    local VISIT_SQL="visit_lat = $V_LAT, visit_lon = $V_LON, visit_date_mismatch = $V_MISMATCH"
    [ -n "$V_TS_ISO" ] && VISIT_SQL="$VISIT_SQL, visit_timestamp = '$V_TS_ISO'"
    $PSQL -c "UPDATE sales_plan SET $VISIT_SQL WHERE id = $PLAN_ID;" >/dev/null 2>>"$LOG_DIR/daily.log"
  fi

  log "  #REPORT AM photo-followup ok: user=$USER_ID cust='$CUST_NAME' lat=$V_LAT lon=$V_LON mismatch=$V_MISMATCH"

  # Count + list remaining pending photos for this sender (after current update)
  local REMAINING REMAINING_LIST
  # Only nag for customers yang ada di #PLAN (plan_id IS NOT NULL).
  # Ad-hoc unmatched customers di #REPORT tidak masuk reminder — AM gak
  # diharapkan kirim foto untuk visit yang gak di-rencanakan sebelumnya.
  REMAINING=$($PSQL -c "SELECT COUNT(*) FROM activity_log WHERE sender_wa_number = '$SENDER_WA' AND tanggal BETWEEN '$TGL_FROM' AND '$TGL_ISO' AND photo_path IS NULL AND plan_id IS NOT NULL;" 2>/dev/null | head -1)
  REMAINING_LIST=$($PSQL -c "SELECT string_agg(customer_name, ', ' ORDER BY id) FROM activity_log WHERE sender_wa_number = '$SENDER_WA' AND tanggal BETWEEN '$TGL_FROM' AND '$TGL_ISO' AND photo_path IS NULL AND plan_id IS NOT NULL;" 2>/dev/null | head -1)

  local FOLLOWUP_REPLY="✅ Foto ${CUST_NAME} tersimpan"
  if [ "$REMAINING" -gt 0 ] 2>/dev/null; then
    FOLLOWUP_REPLY="${FOLLOWUP_REPLY}. Sisa ${REMAINING} customer belum ada foto:
⚠️ ${REMAINING_LIST}"
  else
    FOLLOWUP_REPLY="${FOLLOWUP_REPLY}. ✅ Semua foto visit lengkap."
  fi
  if [ "$V_MISMATCH" = "TRUE" ]; then
    FOLLOWUP_REPLY="${FOLLOWUP_REPLY}
⚠️ Tanggal foto $TS_DATE ≠ plan $TGL_ISO — pastikan foto diambil hari ini."
  fi
  wa_send "$GROUP_JID" "$FOLLOWUP_REPLY"
  return 0
}

handle_leads() {
  local GROUP_JID="$1"
  wa_send "$GROUP_JID" "🚧 #LEADS handler belum di-deploy (Phase 0 — coming soon)."
  return 0
}

handle_update() {
  local GROUP_JID="$1"
  wa_send "$GROUP_JID" "🚧 #UPDATE handler belum di-deploy (Phase 0 — coming soon)."
  return 0
}

# ── Main loop ───────────────────────────────────────────────

# Read cursor (default to current time minus 5 min for first run).
# LOOKBACK_SEC: openclaw kadang lazy-write msgs ke JSONL beberapa menit
# setelah ts asli — kalau cursor advance dulu, msg jadi permanently skipped.
# Re-scan window + processed_message dedup = no double-process. 2 silent
# skips terobservasi 2026-06-03 (Nungky #Report, Udin #Report).
LOOKBACK_SEC=600
SINCE_TS=0
if [ -f "$CURSOR_FILE" ]; then
  RAW_CURSOR=$(cat "$CURSOR_FILE" | tr -d '\n' | tr -d ' ')
  SINCE_TS=$((RAW_CURSOR - LOOKBACK_SEC))
else
  SINCE_TS=$(($(date +%s) - 300))
fi
NEW_CURSOR=$(date +%s)

# Today + yesterday's dir cover messages newly arriving across midnight
DATES=("$(date '+%Y-%m-%d')" "$(date -v-1d '+%Y-%m-%d')")
PROCESSED=0
SKIPPED=0
HASHTAG_HITS=0

for D in "${DATES[@]}"; do
  DIR="$MESSAGES_DIR/$D"
  [ -d "$DIR" ] || continue
  for JSONL in "$DIR"/*.jsonl; do
    [ -f "$JSONL" ] || continue
    # Only process files mtime >= SINCE_TS
    FILE_MTIME=$(stat -f %m "$JSONL")
    [ "$FILE_MTIME" -lt "$SINCE_TS" ] && continue

    # Iterate each line
    while IFS= read -r LINE; do
      [ -z "$LINE" ] && continue
      # Parse JSON fields
      TS_MS=$(echo "$LINE" | jq -r '.ts_ms // empty' 2>/dev/null)
      [ -z "$TS_MS" ] && continue
      # Convert to seconds, skip if before cursor
      TS_S=$((TS_MS / 1000))
      [ "$TS_S" -lt "$SINCE_TS" ] && continue

      CHAT_TYPE=$(echo "$LINE" | jq -r '.chat_type // empty' 2>/dev/null)
      [ "$CHAT_TYPE" != "group" ] && continue

      MSG_ID=$(echo "$LINE" | jq -r '.message_id // empty' 2>/dev/null)
      SENDER=$(echo "$LINE" | jq -r '.sender // empty' 2>/dev/null)
      SENDER_NAME=$(echo "$LINE" | jq -r '.sender_name // .sender' 2>/dev/null)
      GROUP_JID=$(echo "$LINE" | jq -r '.group_jid // empty' 2>/dev/null)
      BODY=$(echo "$LINE" | jq -r '.body // empty' 2>/dev/null)
      # Strip invisible Unicode bidi/format chars (iOS WA suka inject LRM
      # U+200E/RLM U+200F sebelum hashtag → bikin `^\s*#` regex miss).
      # Juga strip ZWNJ/ZWJ U+200C-D, BOM U+FEFF, isolate marks U+2066-9,
      # bidi formatting U+202A-E.
      BODY=$(printf '%s' "$BODY" | python3 -c '
import sys, re
# LRM U+200E, RLM U+200F, ZWNJ U+200C, ZWJ U+200D, ZWSP U+200B,
# bidi formatting U+202A-E, isolates U+2066-9, BOM U+FEFF
PATTERN = re.compile("[​‌‍‎‏‪‫‬‭‮⁦⁧⁨⁩﻿]")
sys.stdout.write(PATTERN.sub("", sys.stdin.read()))
' 2>/dev/null)
      MEDIA_TYPE=$(echo "$LINE" | jq -r '.media_type // empty' 2>/dev/null)
      MEDIA_PATH=$(echo "$LINE" | jq -r '.media_path // empty' 2>/dev/null)

      [ -z "$MSG_ID" ] || [ -z "$SENDER" ] || [ -z "$GROUP_JID" ] && continue

      # Group filter (config WRG_INBOUND_ALLOWED_GROUPS, comma-separated).
      # Kalau empty → process semua grup. Kalau set → hanya grup yang match.
      if [ -n "$WRG_INBOUND_ALLOWED_GROUPS" ]; then
        if ! echo ",$WRG_INBOUND_ALLOWED_GROUPS," | grep -q ",$GROUP_JID,"; then
          continue
        fi
      fi

      # Group deny-list (WRG_INBOUND_DENY_GROUPS, comma-separated). Skip messages
      # from these JIDs even when allowlist is empty. Used on prod to keep the
      # Research test group dev-only — prevents test #PLAN/#REPORT from
      # contaminating wrg_crm_prod.
      if [ -n "$WRG_INBOUND_DENY_GROUPS" ]; then
        if echo ",$WRG_INBOUND_DENY_GROUPS," | grep -q ",$GROUP_JID,"; then
          continue
        fi
      fi

      # Normalize sender: strip @s.whatsapp.net / @g.us / @lid etc
      WA_NUM=$(echo "$SENDER" | sed -E 's/@.*$//' | sed -E 's/[^0-9]//g')
      [ -z "$WA_NUM" ] && continue

      # Detect if sender is group JID (18+ digit) — openclaw kadang gak resolve participant
      # Fallback: cari master_user via sender_name (display name) match.
      SENDER_IS_GROUP=0
      if [ "${#WA_NUM}" -gt 14 ] && [[ "$SENDER" == *"@g.us" || "$SENDER" == *"@lid" ]]; then
        SENDER_IS_GROUP=1
      fi
      WA_NUM_PLUS="+$WA_NUM"

      # Idempotency check via processed_message
      ALREADY=$($PSQL -c "SELECT 1 FROM processed_message WHERE message_id = '$MSG_ID';" 2>/dev/null | head -1)
      if [ -n "$ALREADY" ]; then
        SKIPPED=$((SKIPPED + 1))
        continue
      fi

      # Check if body has hashtag trigger (sebelum spawn DB write — performance)
      HASHTAG=""
      # Hashtag detection: cari #PLAN/REPORT/LEADS/UPDATE di body manapun (bukan
      # cuma awal). Beberapa user kirim format inline dgn date prefix sebelum #,
      # mis. "25/5/2026 | #Plan Hanif | 1. ..." — anchor ^ bikin miss.
      if [[ "$BODY" =~ \#[[:space:]]*([Pp][Ll][Aa][Nn]|[Rr][Ee][Pp][Oo][Rr][Tt]|[Ll][Ee][Aa][Dd][Ss]|[Uu][Pp][Dd][Aa][Tt][Ee]) ]]; then
        HASHTAG=$(echo "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')
      else
        # Non-hashtag check: image dari sender yang punya pending AM activity
        # hari ini → photo-followup pairing. Caption variants yang ditrigger:
        #   "1.", "1)", "1:", "1." dst (numbered)
        #   "#1", "#1 Customer Name" (hash prefix — iOS sometimes)
        #   "Customer Name" plain text (no number) — fallback ke fuzzy name match
        # Untuk plain text, cuma trigger kalo ada pending photo_path IS NULL
        # row di activity_log hari ini (avoid noise on unrelated images).
        FOLLOWUP_HIT=0
        # When sender is group JID (openclaw gak resolve participant), resolve
        # via sender_name pushname so PENDING_CNT query + handler pakai actual
        # AM wa_number — otherwise sender_wa_number lookup tidak match (data
        # fix 2026-06-07 sudah re-set semua activity_log.sender_wa_number
        # ke individual phone).
        EFFECTIVE_WA="$WA_NUM"
        if [ "$SENDER_IS_GROUP" = "1" ] && [ -n "$SENDER_NAME" ]; then
          SAFE_PUSH=$(echo "$SENDER_NAME" | sed "s/'/''/g")
          RESOLVED_WA=$($PSQL -c "
            SELECT wa_number FROM master_user
            WHERE LOWER(nama) = LOWER('$SAFE_PUSH')
               OR LOWER(panggilan) = LOWER('$SAFE_PUSH')
               OR LOWER(nama) LIKE LOWER('$SAFE_PUSH') || ' %'
               OR LOWER(panggilan) = LOWER(SPLIT_PART('$SAFE_PUSH', ' ', 1))
               OR LOWER(panggilan) = LOWER(regexp_replace('$SAFE_PUSH', '[_|/\\\\\\-\\s].*\$', ''))
            ORDER BY LENGTH(nama) LIMIT 1;
          " 2>/dev/null | head -1)
          [ -n "$RESOLVED_WA" ] && EFFECTIVE_WA="$RESOLVED_WA"
        fi
        if [ -n "$MEDIA_PATH" ] && [ -f "$MEDIA_PATH" ] && \
           [ -n "$MEDIA_TYPE" ] && [ "${MEDIA_TYPE#image/}" != "$MEDIA_TYPE" ]; then
          FIRST_LINE=$(echo "$BODY" | head -1)
          if echo "$FIRST_LINE" | grep -qE '^[[:space:]]*#?[[:space:]]*[0-9]+[.):]?'; then
            FOLLOWUP_HIT=1
          elif [ -n "$FIRST_LINE" ] && [ "${#FIRST_LINE}" -lt 100 ]; then
            # Plain text — check ada pending row buat sender ini hari ini
            PENDING_CNT=$($PSQL -c "SELECT COUNT(*) FROM activity_log WHERE sender_wa_number = '$EFFECTIVE_WA' AND tanggal >= CURRENT_DATE - INTERVAL '7 days' AND photo_path IS NULL;" 2>/dev/null | head -1)
            [ "${PENDING_CNT:-0}" -gt 0 ] 2>/dev/null && FOLLOWUP_HIT=1
          fi
        fi
        if [ "$FOLLOWUP_HIT" = "1" ]; then
          if handle_am_followup_photo "$GROUP_JID" "$BODY" "$MEDIA_PATH" "$EFFECTIVE_WA"; then
            $PSQL -c "INSERT INTO processed_message (message_id, wa_number, hashtag, status) VALUES ('$MSG_ID', '$EFFECTIVE_WA', 'photo-followup', 'PHOTO_FOLLOWUP') ON CONFLICT DO NOTHING;" >/dev/null 2>>"$LOG_DIR/daily.log"
            PROCESSED=$((PROCESSED + 1))
            HASHTAG_HITS=$((HASHTAG_HITS + 1))
            continue
          fi
        fi
        # Non-hashtag message: still update last_active_group (if sender resolvable)
        if [ "$SENDER_IS_GROUP" = "0" ]; then
          $PSQL -c "UPDATE master_user SET last_active_group = '$GROUP_JID', last_active_at = NOW() WHERE wa_number = '$WA_NUM';" >/dev/null 2>>"$LOG_DIR/daily.log"
        fi
        continue
      fi
      HASHTAG_HITS=$((HASHTAG_HITS + 1))

      # Auth — explicit body-name attribution wins over sender. Tier order:
      #   A. body-name override (score >= 70: panggilan/nama exact or multi-token)
      #   B. sender phone (wa_number registered)
      #   C. sender pushname (nama/panggilan match)
      #   D. body-name fuzzy fallback (score >= 40, shared-HP heuristic)
      # Rationale: "#PLAN Elok" sent from Husni's HP → row attributed to Elok.
      # Garbage tokens like "Mei" (from "29 Mei 2026") score 0 → no match.

      # Build body candidate row ONCE (reused for tier A high & tier D low).
      BODY_BEST_ROW=""
      BODY_QUERY=$(echo "$BODY" | python3 -c "
import sys, re
b = sys.stdin.read()
# Match same-line after #hashtag (don't cross newline — prevents form labels
# like 'Cust : RS Surya Melati' bocor jadi name candidate yg false-positive
# match panggilan AM lain).
m = re.match(r'^\s*#\s*\w+[ \t]+(.{0,80})', b)
if not m: sys.exit(0)
# Stop-words: form labels yang BUKAN nama orang.
STOP = {'cust','hasil','next','tujuan','goal','tgl','tanggal','cabang',
        'rs','rsu','rsd','rsud','rsia','rspau','rsau','rsab','rsi','rsgm',
        'klinik','lab','labkesda','pkm','puskesmas','pmi','dinkes','dinas',
        'note','visit','jv','join','silaturahmi'}
toks_raw = re.findall(r'[A-Za-z]+', m.group(1))
toks = [t for t in toks_raw if t.lower() not in STOP][:3]
if not toks: sys.exit(0)
parts = []
# Multi-token name substring (longer phrase = higher score)
if len(toks) >= 2:
    score = 100
    for n in range(len(toks), 1, -1):
        for i in range(len(toks) - n + 1):
            phrase = ' '.join(toks[i:i+n])
            parts.append(f\"SELECT id, nama, aktif, {score} AS s, '{phrase}' AS matched FROM master_user WHERE POSITION(LOWER('{phrase}') IN LOWER(nama)) > 0\")
            score -= 5
# Panggilan exact
score = 80
for t in toks:
    parts.append(f\"SELECT id, nama, aktif, {score} AS s, '{t}' AS matched FROM master_user WHERE LOWER(panggilan) = LOWER('{t}')\")
    score -= 2
# Nama exact match (single token equals full nama, e.g., 'Maskhanudin' → nama 'Maskhanudin')
score = 70
for t in toks:
    parts.append(f\"SELECT id, nama, aktif, {score} AS s, '{t}' AS matched FROM master_user WHERE LOWER(nama) = LOWER('{t}')\")
    score -= 2
# Nama starts with token (single-token prefix)
score = 60
for t in toks:
    parts.append(f\"SELECT id, nama, aktif, {score} AS s, '{t}' AS matched FROM master_user WHERE LOWER(nama) LIKE LOWER('{t}') || ' %'\")
    score -= 2
# Fuzzy panggilan
score = 40
for t in toks:
    parts.append(f\"SELECT id, nama, aktif, {score} AS s, '{t}' AS matched FROM master_user WHERE panggilan IS NOT NULL AND ABS(LENGTH(panggilan) - LENGTH('{t}')) <= 2 AND similarity(LOWER(panggilan), LOWER('{t}')) >= 0.4\")
    score -= 2
print(' UNION ALL '.join(parts))
" 2>/dev/null)
      if [ -n "$BODY_QUERY" ]; then
        BODY_BEST_ROW=$($PSQL -c "
          SELECT id || E'\t' || COALESCE(nama,'') || E'\t' ||
                 CASE WHEN aktif THEN 't' ELSE 'f' END || E'\t' || matched || E'\t' || s
          FROM ($BODY_QUERY) candidates
          ORDER BY s DESC, LENGTH(nama) ASC
          LIMIT 1;
        " 2>/dev/null | head -1)
      fi

      USER_ROW=""

      # Tier A: body-name override (score >= 70) — explicit attribution wins.
      if [ -n "$BODY_BEST_ROW" ]; then
        BODY_SCORE=$(echo "$BODY_BEST_ROW" | cut -f5)
        if [ -n "$BODY_SCORE" ] && [ "$BODY_SCORE" -ge 70 ]; then
          RESOLVED_ID=$(echo "$BODY_BEST_ROW" | cut -f1)
          MATCHED=$(echo "$BODY_BEST_ROW" | cut -f4)
          USER_ROW=$(echo "$BODY_BEST_ROW" | cut -f1-3)
          $PSQL -c "UPDATE master_user SET last_active_group = '$GROUP_JID', last_active_at = NOW() WHERE id = $RESOLVED_ID;" >/dev/null 2>>"$LOG_DIR/daily.log"
          log "  matched via body-name override: '$MATCHED' (score $BODY_SCORE) → id=$RESOLVED_ID (sender '$SENDER_NAME')"
          BODY_NAME="$MATCHED"
        fi
      fi

      # Tier B: sender phone (wa_number registered).
      if [ -z "$USER_ROW" ] && [ "$SENDER_IS_GROUP" = "0" ]; then
        USER_ROW=$($PSQL -c "
          SELECT id || E'\t' || COALESCE(nama,'') || E'\t' ||
                 CASE WHEN aktif THEN 't' ELSE 'f' END
          FROM master_user WHERE wa_number = '$WA_NUM';
        " 2>/dev/null | head -1)
        if [ -n "$USER_ROW" ]; then
          $PSQL -c "UPDATE master_user SET last_active_group = '$GROUP_JID', last_active_at = NOW() WHERE wa_number = '$WA_NUM';" >/dev/null 2>>"$LOG_DIR/daily.log"
        fi
      fi

      # Tier C: sender pushname (nama/panggilan match, 5 sub-tiers).
      # Pushname often has suffix like "Arif_Official", "IRUL|PT WAHANA GUMILANG",
      # "John-Smith" — strip after first separator (_|/-\s) to extract first
      # token, lalu match panggilan.
      if [ -z "$USER_ROW" ] && [ -n "$SENDER_NAME" ]; then
        SAFE_NAME=$(echo "$SENDER_NAME" | sed "s/'/''/g")
        USER_ROW=$($PSQL -c "
          SELECT id || E'\t' || COALESCE(nama,'') || E'\t' ||
                 CASE WHEN aktif THEN 't' ELSE 'f' END
          FROM master_user
          WHERE LOWER(nama) = LOWER('$SAFE_NAME')
             OR LOWER(panggilan) = LOWER('$SAFE_NAME')
             OR LOWER(nama) LIKE LOWER('$SAFE_NAME') || ' %'
             OR LOWER(panggilan) = LOWER(SPLIT_PART('$SAFE_NAME', ' ', 1))
             OR LOWER(panggilan) = LOWER(regexp_replace('$SAFE_NAME', '[_|/\\\\\\-\\s].*\$', ''))
          ORDER BY
            CASE
              WHEN LOWER(nama)      = LOWER('$SAFE_NAME')                          THEN 1
              WHEN LOWER(panggilan) = LOWER('$SAFE_NAME')                          THEN 2
              WHEN LOWER(nama) LIKE LOWER('$SAFE_NAME') || ' %'                    THEN 3
              WHEN LOWER(panggilan) = LOWER(SPLIT_PART('$SAFE_NAME', ' ', 1))      THEN 4
              WHEN LOWER(panggilan) = LOWER(regexp_replace('$SAFE_NAME', '[_|/\\\\\\-\\s].*\$', '')) THEN 5
              ELSE 6
            END,
            LENGTH(nama)
          LIMIT 1;
        " 2>/dev/null | head -1)
        if [ -n "$USER_ROW" ]; then
          RESOLVED_ID=$(echo "$USER_ROW" | cut -f1)
          $PSQL -c "UPDATE master_user SET last_active_group = '$GROUP_JID', last_active_at = NOW() WHERE id = $RESOLVED_ID;" >/dev/null 2>>"$LOG_DIR/daily.log"
          log "  matched via sender_name: '$SENDER_NAME' → id=$RESOLVED_ID"
        fi
      fi

      # Tier D: body fuzzy fallback (score >= 40) — shared-HP heuristic when
      # sender lookups all failed (e.g., generic group pushname like 'Admin Counter').
      if [ -z "$USER_ROW" ] && [ -n "$BODY_BEST_ROW" ]; then
        BODY_SCORE=$(echo "$BODY_BEST_ROW" | cut -f5)
        if [ -n "$BODY_SCORE" ] && [ "$BODY_SCORE" -ge 40 ]; then
          RESOLVED_ID=$(echo "$BODY_BEST_ROW" | cut -f1)
          MATCHED=$(echo "$BODY_BEST_ROW" | cut -f4)
          USER_ROW=$(echo "$BODY_BEST_ROW" | cut -f1-3)
          $PSQL -c "UPDATE master_user SET last_active_group = '$GROUP_JID', last_active_at = NOW() WHERE id = $RESOLVED_ID;" >/dev/null 2>>"$LOG_DIR/daily.log"
          log "  matched via body shared-HP: '$MATCHED' → id=$RESOLVED_ID (sender pushname '$SENDER_NAME')"
          BODY_NAME="$MATCHED"
        fi
      fi

      if [ -z "$USER_ROW" ]; then
        wa_send "$GROUP_JID" "❌ Nomor kamu belum terdaftar di sistem WRG CRM.
Hubungi admin untuk registrasi."
        log "  #$HASHTAG unauth: $WA_NUM_PLUS (not in master_user)"
        $PSQL -c "INSERT INTO processed_message (message_id, wa_number, hashtag, status, finished_at)
                   VALUES ('$MSG_ID', '$WA_NUM', '$HASHTAG', 'UNAUTHORIZED', NOW()) ON CONFLICT DO NOTHING;" >/dev/null 2>>"$LOG_DIR/daily.log"
        PROCESSED=$((PROCESSED + 1))
        continue
      fi
      IFS=$'\t' read -r USER_ID NAMA AKTIF <<<"$USER_ROW"
      if [ "$AKTIF" != "t" ]; then
        wa_send "$GROUP_JID" "❌ Akun kamu sedang nonaktif.
Hubungi admin untuk mengaktifkan kembali."
        log "  #$HASHTAG inactive: $WA_NUM_PLUS"
        $PSQL -c "INSERT INTO processed_message (message_id, wa_number, hashtag, status, finished_at)
                   VALUES ('$MSG_ID', '$WA_NUM', '$HASHTAG', 'INACTIVE', NOW()) ON CONFLICT DO NOTHING;" >/dev/null 2>>"$LOG_DIR/daily.log"
        PROCESSED=$((PROCESSED + 1))
        continue
      fi

      # Group-JID sender fallback: openclaw kadang gak resolve participant
      # → WA_NUM jadi group ID (18+ digit). Subst dgn wa_number user yang
      # ke-resolve via tier A/C/D, supaya activity_log.sender_wa_number tidak
      # cross-pollute photo-followup query antar-AM di group yang sama.
      if [ "$SENDER_IS_GROUP" = "1" ]; then
        REAL_WA=$($PSQL -c "SELECT wa_number FROM master_user WHERE id = $USER_ID;" 2>/dev/null | head -1)
        if [ -n "$REAL_WA" ]; then
          WA_NUM="$REAL_WA"
          WA_NUM_PLUS="+$REAL_WA"
        fi
      fi

      # Insert PROCESSING row
      $PSQL -c "INSERT INTO processed_message (message_id, wa_number, hashtag, status)
                 VALUES ('$MSG_ID', '$WA_NUM', '$HASHTAG', 'PROCESSING') ON CONFLICT DO NOTHING;" >/dev/null 2>>"$LOG_DIR/daily.log"

      # Dispatch
      DISPLAY_NAME="${NAMA:-$WA_NUM_PLUS}"
      case "$HASHTAG" in
        plan)
          if handle_plan "$USER_ID" "$DISPLAY_NAME" "$GROUP_JID" "$BODY" "$MSG_ID" "$TS_S"; then
            FINAL_STATUS="DONE"
          else
            FINAL_STATUS="ERROR"
          fi
          ;;
        report)
          if handle_report "$USER_ID" "$DISPLAY_NAME" "$GROUP_JID" "$BODY" "$MSG_ID" "$MEDIA_TYPE" "$MEDIA_PATH" "$WA_NUM"; then
            FINAL_STATUS="DONE"
          else
            FINAL_STATUS="ERROR"
          fi
          ;;
        leads)  handle_leads  "$GROUP_JID"; FINAL_STATUS="DEFERRED" ;;
        update) handle_update "$GROUP_JID"; FINAL_STATUS="DEFERRED" ;;
      esac

      $PSQL -c "UPDATE processed_message SET status = '$FINAL_STATUS', finished_at = NOW() WHERE message_id = '$MSG_ID';" >/dev/null 2>>"$LOG_DIR/daily.log"

      PROCESSED=$((PROCESSED + 1))
      # Throttle reply rate
      sleep 0.3
    done < "$JSONL"
  done
done

# Save cursor
echo "$NEW_CURSOR" > "$CURSOR_FILE"

if [ "$PROCESSED" -gt 0 ] || [ "$HASHTAG_HITS" -gt 0 ] || [ "$SKIPPED" -gt 0 ]; then
  log "processed=$PROCESSED hashtag_hits=$HASHTAG_HITS skipped(dup)=$SKIPPED cursor=$NEW_CURSOR"
fi

exit 0
