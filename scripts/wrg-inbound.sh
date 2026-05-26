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
  local THRESHOLD
  THRESHOLD=$(late_threshold_for_role "$ROLE")
  if [ "$TGL_ISO" = "$(date '+%Y-%m-%d')" ] && [ "$(date '+%H%M')" -gt "$THRESHOLD" ]; then
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
  local USER_ID="$1" SENDER_NAME="$2" GROUP_JID="$3" BODY="$4"
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
  IS_LATE=$(compute_is_late "$TGL_ISO" "AM")

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
        C=$(echo "$C" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
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
VALUES ($USER_ID, '$TGL_ISO', \$\$$C\$\$, \$\$$T_NORM\$\$, \$\$$G\$\$, $SEQ, NOW(), $IS_LATE)
ON CONFLICT (user_id, tanggal, customer_name) DO UPDATE SET
  tujuan       = EXCLUDED.tujuan,
  goal         = EXCLUDED.goal,
  submitted_at = EXCLUDED.submitted_at,
  is_late_plan = EXCLUDED.is_late_plan;
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
  local USER_ID="$1" SENDER_NAME="$2" GROUP_JID="$3" BODY="$4" MSG_ID="$5"
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
  USER_ROLE=$($PSQL -c "SELECT role FROM master_user WHERE id = $USER_ID;" 2>/dev/null | head -1 | tr -d ' ')
  IS_LATE=$(compute_is_late "$TGL_ISO" "$USER_ROLE")

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
VALUES ($USER_ID, '$TGL_ISO', \$ITEMS\$$ITEMS_JSON\$ITEMS\$::jsonb, \$BODY\$$SAFE_BODY\$BODY\$, \$MID\$$MSG_ID\$MID\$, NOW(), $IS_LATE)
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
  local USER_ID="$1" SENDER_NAME="$2" GROUP_JID="$3" BODY="$4" MSG_ID="$5"
  local ROLE
  ROLE=$($PSQL -c "SELECT role FROM master_user WHERE id = $USER_ID;" 2>/dev/null | head -1 | tr -d ' ')
  if [ "$ROLE" = "AM" ]; then
    handle_plan_am "$USER_ID" "$SENDER_NAME" "$GROUP_JID" "$BODY"
  else
    handle_plan_todo "$USER_ID" "$SENDER_NAME" "$GROUP_JID" "$BODY" "$MSG_ID"
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
  local TGL_ISO IS_MULTI
  TGL_ISO=$(parse_tanggal_from_body "$BODY")

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
# Drop the first line (the hashtag line) and tgl: line
lines = [l for l in body.splitlines()
         if not re.match(r"^\s*#report", l, re.I)
         and not re.match(r"^\s*tgl\s*:", l, re.I)]
text = "\n".join(lines)
chunks = re.split(r"\n\s*---\s*\n", text) if "---" in text else [text]
out = []
for chunk in chunks:
    chunk = chunk.strip()
    if not chunk: continue
    e = {"cust": "", "hasil": "", "next": ""}
    for line in chunk.splitlines():
        m = re.match(r"^\s*(cust|hasil|next)\s*:\s*(.+?)\s*$", line, re.I)
        if m:
            e[m.group(1).lower()] = m.group(2).strip()
    if e["cust"] and e["hasil"]:
        out.append(e)
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

  local MATCHED=0 UNMATCHED=0 AMBIGUOUS=0 LINES_DISPLAY=""
  for ((i=0; i<N; i++)); do
    local CUST HASIL NXT
    CUST=$(echo "$ENTRIES_JSON" | jq -r ".[$i].cust")
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
    INSERTED_ID=$($PSQL -c "
      INSERT INTO activity_log
        (user_id, customer_name, tanggal, hasil, next_action, source,
         plan_id, is_unmatched, match_score, message_id)
      VALUES
        ($USER_ID, '$SAFE_CUST', '$TGL_ISO', '$SAFE_HASIL', '$SAFE_NEXT', 'WHATSAPP',
         $PLAN_ID, $IS_UNMATCHED, $MATCH_SCORE,
         '${MSG_ID}__${i}')
      ON CONFLICT (message_id) DO NOTHING
      RETURNING id;
    " 2>/dev/null | head -1)

    if [ -n "$INSERTED_ID" ] && [ "$PLAN_ID" != "NULL" ]; then
      $PSQL -c "
        UPDATE sales_plan SET reported = TRUE, reported_at = NOW(), activity_id = $INSERTED_ID
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

def sim(a, b):
    a_esc = a.replace("'", "''")
    b_esc = b.replace("'", "''")
    r = subprocess.run(
        ["psql","-U",pguser,"-d",pgdb,"-tA","-c",
         f"SELECT similarity('{a_esc}', '{b_esc}');"],
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
  local ROLE
  ROLE=$($PSQL -c "SELECT role FROM master_user WHERE id = $USER_ID;" 2>/dev/null | head -1 | tr -d ' ')
  if [ "$ROLE" = "AM" ]; then
    handle_report_am "$USER_ID" "$SENDER_NAME" "$GROUP_JID" "$BODY" "$MSG_ID"
  else
    handle_report_todo "$USER_ID" "$SENDER_NAME" "$GROUP_JID" "$BODY" "$MSG_ID"
  fi
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

# Read cursor (default to current time minus 5 min for first run)
SINCE_TS=0
if [ -f "$CURSOR_FILE" ]; then
  SINCE_TS=$(cat "$CURSOR_FILE" | tr -d '\n' | tr -d ' ')
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

      [ -z "$MSG_ID" ] || [ -z "$SENDER" ] || [ -z "$GROUP_JID" ] && continue

      # Group filter (config WRG_INBOUND_ALLOWED_GROUPS, comma-separated).
      # Kalau empty → process semua grup. Kalau set → hanya grup yang match.
      if [ -n "$WRG_INBOUND_ALLOWED_GROUPS" ]; then
        if ! echo ",$WRG_INBOUND_ALLOWED_GROUPS," | grep -q ",$GROUP_JID,"; then
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
        # Non-hashtag message: still update last_active_group (if sender resolvable)
        if [ "$SENDER_IS_GROUP" = "0" ]; then
          $PSQL -c "UPDATE master_user SET last_active_group = '$GROUP_JID', last_active_at = NOW() WHERE wa_number = '$WA_NUM';" >/dev/null 2>>"$LOG_DIR/daily.log"
        fi
        continue
      fi
      HASHTAG_HITS=$((HASHTAG_HITS + 1))

      # Auth — lookup master_user (via wa_number primarily, fallback sender_name).
      # Use CASE for boolean → 't'/'f' karena PG concat "true"/"false" yang awkward.
      USER_ROW=""
      if [ "$SENDER_IS_GROUP" = "0" ]; then
        USER_ROW=$($PSQL -c "
          SELECT id || E'\t' || COALESCE(nama,'') || E'\t' ||
                 CASE WHEN aktif THEN 't' ELSE 'f' END
          FROM master_user WHERE wa_number = '$WA_NUM';
        " 2>/dev/null | head -1)
      fi
      if [ -z "$USER_ROW" ] && [ -n "$SENDER_NAME" ]; then
        # Fallback: match nama/panggilan dgn 4 tier priority. WA pushname seringkali
        # parsial (mis. "Denys Chandra" sementara DB "Denys Chandra Irawan").
        SAFE_NAME=$(echo "$SENDER_NAME" | sed "s/'/''/g")
        USER_ROW=$($PSQL -c "
          SELECT id || E'\t' || COALESCE(nama,'') || E'\t' ||
                 CASE WHEN aktif THEN 't' ELSE 'f' END
          FROM master_user
          WHERE LOWER(nama) = LOWER('$SAFE_NAME')
             OR LOWER(panggilan) = LOWER('$SAFE_NAME')
             OR LOWER(nama) LIKE LOWER('$SAFE_NAME') || ' %'
             OR LOWER(panggilan) = LOWER(SPLIT_PART('$SAFE_NAME', ' ', 1))
          ORDER BY
            CASE
              WHEN LOWER(nama)      = LOWER('$SAFE_NAME')                          THEN 1
              WHEN LOWER(panggilan) = LOWER('$SAFE_NAME')                          THEN 2
              WHEN LOWER(nama) LIKE LOWER('$SAFE_NAME') || ' %'                    THEN 3
              WHEN LOWER(panggilan) = LOWER(SPLIT_PART('$SAFE_NAME', ' ', 1))      THEN 4
              ELSE 5
            END,
            LENGTH(nama)
          LIMIT 1;
        " 2>/dev/null | head -1)
        if [ -n "$USER_ROW" ]; then
          RESOLVED_ID=$(echo "$USER_ROW" | cut -f1)
          $PSQL -c "UPDATE master_user SET last_active_group = '$GROUP_JID', last_active_at = NOW() WHERE id = $RESOLVED_ID;" >/dev/null 2>>"$LOG_DIR/daily.log"
          log "  matched via sender_name: '$SENDER_NAME' → id=$RESOLVED_ID"
        fi
      elif [ -n "$USER_ROW" ]; then
        $PSQL -c "UPDATE master_user SET last_active_group = '$GROUP_JID', last_active_at = NOW() WHERE wa_number = '$WA_NUM';" >/dev/null 2>>"$LOG_DIR/daily.log"
      fi
      # Tier 5: shared-HP fallback. Per brief, format "#PLAN <nama panggilan>" ke
      # grup dengan HP yang dipakai bersama. Scoring-based match — prefer
      # multi-token full-name substring of nama (most specific) over single-token
      # panggilan match. Avoid mis-resolve "Najmi Putri Harini" → Putri Diana.
      if [ -z "$USER_ROW" ]; then
        BODY_QUERY=$(echo "$BODY" | python3 -c "
import sys, re
b = sys.stdin.read()
m = re.match(r'^\s*#\s*\w+\s+(.{0,80})', b)
if not m: sys.exit(0)
toks = re.findall(r'[A-Za-z]+', m.group(1))[:3]
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
          BEST_ROW=$($PSQL -c "
            SELECT id || E'\t' || COALESCE(nama,'') || E'\t' ||
                   CASE WHEN aktif THEN 't' ELSE 'f' END || E'\t' || matched
            FROM ($BODY_QUERY) candidates
            ORDER BY s DESC, LENGTH(nama) ASC
            LIMIT 1;
          " 2>/dev/null | head -1)
          if [ -n "$BEST_ROW" ]; then
            RESOLVED_ID=$(echo "$BEST_ROW" | cut -f1)
            MATCHED=$(echo "$BEST_ROW" | cut -f4)
            USER_ROW=$(echo "$BEST_ROW" | cut -f1-3)
            $PSQL -c "UPDATE master_user SET last_active_group = '$GROUP_JID', last_active_at = NOW() WHERE id = $RESOLVED_ID;" >/dev/null 2>>"$LOG_DIR/daily.log"
            log "  matched via body shared-HP: '$MATCHED' → id=$RESOLVED_ID (sender pushname '$SENDER_NAME')"
            BODY_NAME="$MATCHED"
          fi
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

      # Insert PROCESSING row
      $PSQL -c "INSERT INTO processed_message (message_id, wa_number, hashtag, status)
                 VALUES ('$MSG_ID', '$WA_NUM', '$HASHTAG', 'PROCESSING') ON CONFLICT DO NOTHING;" >/dev/null 2>>"$LOG_DIR/daily.log"

      # Dispatch
      DISPLAY_NAME="${NAMA:-$WA_NUM_PLUS}"
      case "$HASHTAG" in
        plan)
          if handle_plan "$USER_ID" "$DISPLAY_NAME" "$GROUP_JID" "$BODY" "$MSG_ID"; then
            FINAL_STATUS="DONE"
          else
            FINAL_STATUS="ERROR"
          fi
          ;;
        report)
          if handle_report "$USER_ID" "$DISPLAY_NAME" "$GROUP_JID" "$BODY" "$MSG_ID"; then
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
