#!/usr/bin/env bash
# detect_leave.sh — auto-detect pengumuman izin/sakit/cuti individual dari grup
# "HRD WG GROUP 2026" via LLM, lalu minta approval admin sebelum rekam ke
# user_leave. Semua interaksi di dalam grup HRD itu sendiri.
#
# Cron: */10 * * * *
#
# Alur:
#   A. Scan pesan baru HRD group (keyword izin/sakit/cuti) → LLM extract →
#      kalau leave & nama resolve ke user WAJIB & belum ada leave/pending overlap
#      → INSERT pending_confirm + post "Rekam cuti? balas ya L<id>/tidak L<id>".
#   B. Scan balasan admin "ya L<id>"/"tidak L<id>" → resolve pending →
#      ya: INSERT user_leave + konfirmasi ; tidak: batal.
#
# Idempotent: tiap pesan ditandai di processed_message (hashtag leave-detect/
# leave-reply). Dedup leave via overlap check (user_id + tanggal).
set -uo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$BASE_DIR/config/config.sh"
LOG_DIR="$BASE_DIR/logs"
mkdir -p "$LOG_DIR"

GROUP_JID="${LEAVE_HRD_GROUP_JID:-120363048384809457@g.us}"   # HRD WG GROUP 2026
MESSAGES_DIR="${LEAVE_MESSAGES_DIR:-$HOME/.openclaw/tmp/wrg-monitor/messages}"
MODEL="${LEAVE_MODEL:-$DAILY_MODEL_PRIMARY}"
TODAY="$(date '+%Y-%m-%d')"
YDAY="$(date -v-1d '+%Y-%m-%d')"

log "detect_leave: scan grup HRD $GROUP_JID model=$MODEL"

# Helper: sudah diproses?
already_processed() {
  local mid="$1"
  [ -n "$($PSQL -c "SELECT 1 FROM processed_message WHERE message_id='$mid';" 2>/dev/null | head -1)" ]
}
mark_processed() {  # mid wa hashtag status
  $PSQL -c "INSERT INTO processed_message (message_id, wa_number, hashtag, status, finished_at)
            VALUES ('$1','$2','$3','$4',NOW()) ON CONFLICT (message_id) DO NOTHING;" \
            >/dev/null 2>>"$LOG_DIR/daily.log"
}

# Resolve nama → user_id WAJIB (fuzzy). Echo "id<TAB>nama" atau kosong.
resolve_user() {
  local raw="$1" safe
  safe=$(printf '%s' "$raw" | sed "s/'/''/g")
  $PSQL -c "
    WITH p AS (SELECT regexp_replace(LOWER('$safe'),'[^a-z]','','g') AS norm)
    SELECT id || E'\t' || nama
    FROM master_user, p
    WHERE wajib_plan_report AND aktif AND (
         LOWER(panggilan)=LOWER('$safe')
      OR LOWER(nama)=LOWER('$safe')
      OR LOWER(nama) LIKE LOWER('$safe')||' %'
      OR LOWER(panggilan)=LOWER(SPLIT_PART('$safe',' ',1))
      OR (LENGTH(p.norm)>=4 AND regexp_replace(LOWER(nama),'[^a-z]','','g') LIKE p.norm||'%')
      OR (LENGTH(p.norm)>=4 AND p.norm LIKE regexp_replace(LOWER(panggilan),'[^a-z]','','g')||'%')
    )
    ORDER BY CASE WHEN LOWER(panggilan)=LOWER('$safe') THEN 1
                  WHEN LOWER(nama)=LOWER('$safe') THEN 2 ELSE 3 END, LENGTH(nama)
    LIMIT 1;" 2>/dev/null | head -1
}

SYS='You parse a single WhatsApp message from an Indonesian company HR group and decide if it announces that a SPECIFIC employee will be ABSENT from work (izin/sakit/cuti).

CRITICAL: the word "izin"/"ijin" is usually just a POLITENESS particle in Indonesian business chat ("izin bertanya", "izin mengingatkan", "izin update", "mohon izin untuk...") — those are NOT leave. Only treat as leave when the message clearly says a named person will NOT come to work / tidak masuk kerja / tidak bisa masuk / sedang sakit / mengajukan cuti.

Also: ignore COMPANY-WIDE holiday announcements (libur nasional, Idul Adha, cuti bersama) — those are not individual leave. Ignore third-party mentions that are not a real absence.

The input gives "Pengirim" (sender display name) and "Pesan" (body). If the message is first-person ("saya tidak masuk"...) and no other name appears, the absent person IS the sender — use the sender name. If the body forwards/quotes someone (e.g. "[..] Sari Wg: saya izin...") or names a person ("pengajuan cuti mba Kolis"), use THAT person.

Message date (for resolving "hari ini"/"besok"): %MSGDATE%

Return STRICT JSON (no markdown):
{
  "is_leave": true|false,
  "nama": "name of the ABSENT employee (the person not coming to work), or null",
  "jenis": "ijin" | "sakit" | "cuti" | null,
  "start_date": "YYYY-MM-DD" or null,
  "end_date": "YYYY-MM-DD" or null,
  "confidence": 0.0-1.0
}
Rules: end_date = start_date if single day. If date unclear, use message date. confidence < 0.6 if unsure. Output JSON only.'

# ── PHASE A+B: scan pesan grup HRD ───────────────────────────
process_file() {
  local f="$1"
  [ -f "$f" ] || return 0
  jq -c '.' "$f" 2>/dev/null | while IFS= read -r J; do
    local MID BODY SENDER_NAME WA MSGDATE
    MID=$(printf '%s' "$J" | jq -r '.message_id // empty')
    [ -z "$MID" ] && continue
    BODY=$(printf '%s' "$J" | jq -r '.body // empty')
    [ -z "$BODY" ] && continue
    SENDER_NAME=$(printf '%s' "$J" | jq -r '.sender_name // empty')
    WA=$(printf '%s' "$J" | jq -r '.sender // empty' | sed -E 's/@.*//; s/[^0-9]//g')
    MSGDATE=$(printf '%s' "$J" | jq -r '.ts // empty' | cut -dT -f1)
    [ -z "$MSGDATE" ] && MSGDATE="$TODAY"

    already_processed "$MID" && continue

    # ── PHASE B: balasan approval "ya L<id>" / "tidak L<id>" ──
    if printf '%s' "$BODY" | grep -qiE '^[[:space:]]*(ya|iya|ok|setuju|tidak|tdk|gak|batal|no)[[:space:]]*#?L?[0-9]+'; then
      local DECISION PID
      DECISION=$(printf '%s' "$BODY" | grep -oiE '^[[:space:]]*[a-z]+' | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
      PID=$(printf '%s' "$BODY" | grep -oiE '[0-9]+' | head -1)
      handle_approval "$DECISION" "$PID" "$MID" "$WA"
      mark_processed "$MID" "$WA" "leave-reply" "DONE"
      continue
    fi

    # ── PHASE A: kandidat leave (keyword gate sebelum LLM) ──
    if ! printf '%s' "$BODY" | grep -qiE 'izin|ijin|sakit|cuti|tidak masuk|tdk masuk|ndak masuk|tidak bisa masuk|tidak dapat masuk|pengajuan'; then
      mark_processed "$MID" "$WA" "leave-detect" "NO_KEYWORD"
      continue
    fi

    local PROMPT_SYS RESULT USR_MSG
    PROMPT_SYS="${SYS/\%MSGDATE\%/$MSGDATE}"
    USR_MSG="Pengirim: ${SENDER_NAME:-?}
Pesan:
${BODY}"
    RESULT=$(call_ai_with_fallback "$PROMPT_SYS" "$USR_MSG" 500)
    RESULT=$(printf '%s' "$RESULT" | sed -E '/^```/d; s/^json//')
    if ! printf '%s' "$RESULT" | jq -e '.is_leave' >/dev/null 2>&1; then
      log "  detect_leave: $MID LLM non-JSON/empty: ${RESULT:0:80}"
      mark_processed "$MID" "$WA" "leave-detect" "LLM_FAIL"
      continue
    fi

    local IS CONF NAMA JENIS SD ED
    IS=$(printf '%s' "$RESULT" | jq -r '.is_leave')
    CONF=$(printf '%s' "$RESULT" | jq -r '.confidence // 0')
    NAMA=$(printf '%s' "$RESULT" | jq -r '.nama // empty')
    JENIS=$(printf '%s' "$RESULT" | jq -r '.jenis // empty')
    SD=$(printf '%s' "$RESULT" | jq -r '.start_date // empty')
    ED=$(printf '%s' "$RESULT" | jq -r '.end_date // empty')

    if [ "$IS" != "true" ] || awk "BEGIN{exit !($CONF < 0.6)}"; then
      log "  detect_leave: $MID not-leave/low-conf (is=$IS conf=$CONF)"
      mark_processed "$MID" "$WA" "leave-detect" "NOT_LEAVE"
      continue
    fi

    # Resolve nama → user wajib
    local UROW UID UNAMA
    UROW=$(resolve_user "$NAMA")
    if [ -z "$UROW" ]; then
      log "  detect_leave: $MID leave terdeteksi tapi nama '$NAMA' tdk resolve ke user wajib — skip"
      mark_processed "$MID" "$WA" "leave-detect" "NAME_UNRESOLVED"
      continue
    fi
    IFS=$'\t' read -r UID UNAMA <<<"$UROW"
    [ -z "$SD" ] && SD="$MSGDATE"; [ -z "$ED" ] && ED="$SD"
    # Normalisasi jenis: LLM kadang balikin "izin"/kapital → set ke ijin/sakit/cuti
    JENIS=$(printf '%s' "$JENIS" | tr '[:upper:]' '[:lower:]')
    case "$JENIS" in izin) JENIS="ijin" ;; sakit|cuti|ijin) ;; *) JENIS="ijin" ;; esac

    # Dedup: sudah ada leave atau pending overlap?
    local OVL
    OVL=$($PSQL -c "SELECT 1 FROM user_leave WHERE user_id=$UID AND daterange(start_date,end_date,'[]') && daterange('$SD','$ED','[]') LIMIT 1;" 2>/dev/null | head -1)
    if [ -n "$OVL" ]; then
      log "  detect_leave: $MID $UNAMA sudah ada user_leave overlap — skip"
      mark_processed "$MID" "$WA" "leave-detect" "ALREADY_LEAVE"
      continue
    fi
    local PEND
    PEND=$($PSQL -c "SELECT id FROM pending_confirm WHERE hashtag='leave-approval' AND expires_at>NOW() AND (payload->>'user_id')::int=$UID AND payload->>'start_date'='$SD' LIMIT 1;" 2>/dev/null | head -1)
    if [ -n "$PEND" ]; then
      log "  detect_leave: $MID pending L$PEND sudah ada utk $UNAMA $SD — skip"
      mark_processed "$MID" "$WA" "leave-detect" "ALREADY_PENDING"
      continue
    fi

    # Buat pending_confirm + minta approval di grup
    local NAMA_SAFE PAYLOAD PID
    NAMA_SAFE=$(echo "$UNAMA" | sed "s/'/''/g")
    PAYLOAD=$(jq -nc --argjson uid "$UID" --arg nm "$UNAMA" --arg jn "$JENIS" \
      --arg sd "$SD" --arg ed "$ED" --arg src "$MID" \
      '{user_id:$uid, nama:$nm, jenis:$jn, start_date:$sd, end_date:$ed, source_message_id:$src}')
    PID=$($PSQL -c "INSERT INTO pending_confirm (wa_number, hashtag, candidates, payload, expires_at)
                    VALUES ('$WA','leave-approval','[]'::jsonb,'$(printf '%s' "$PAYLOAD" | sed "s/'/''/g")'::jsonb, NOW()+INTERVAL '24 hours')
                    RETURNING id;" 2>>"$LOG_DIR/daily.log" | head -1)
    if [ -z "$PID" ]; then
      log "  detect_leave: $MID gagal insert pending"
      continue
    fi
    local RANGE_TXT="$SD"
    [ "$ED" != "$SD" ] && RANGE_TXT="$SD s/d $ED"
    wa_send "$GROUP_JID" "📋 *Konfirmasi cuti* — rekam ke sistem?

• Nama: *${UNAMA}*
• Jenis: *${JENIS}*
• Tanggal: *${RANGE_TXT}*

Balas *ya L${PID}* untuk rekam, atau *tidak L${PID}* untuk batal. (auto-expire 24 jam)"
    log "  detect_leave: pending L$PID dibuat utk $UNAMA ($JENIS $RANGE_TXT) dari msg $MID"
    mark_processed "$MID" "$WA" "leave-detect" "PENDING_L$PID"
  done
}

# ── Handler approval ─────────────────────────────────────────
handle_approval() {
  local decision="$1" pid="$2" mid="$3" wa="$4"
  [ -z "$pid" ] && return 0
  local ROW
  ROW=$($PSQL -c "SELECT payload::text FROM pending_confirm WHERE id=$pid AND hashtag='leave-approval' AND expires_at>NOW();" 2>/dev/null | head -1)
  if [ -z "$ROW" ]; then
    log "  detect_leave: approval L$pid tdk ditemukan/expired (decision=$decision)"
    return 0
  fi
  local UID NM JN SD ED
  UID=$(printf '%s' "$ROW" | jq -r '.user_id'); NM=$(printf '%s' "$ROW" | jq -r '.nama')
  JN=$(printf '%s' "$ROW" | jq -r '.jenis'); SD=$(printf '%s' "$ROW" | jq -r '.start_date')
  ED=$(printf '%s' "$ROW" | jq -r '.end_date')

  case "$decision" in
    ya|iya|ok|setuju)
      local NM_SAFE; NM_SAFE=$(echo "$NM" | sed "s/'/''/g")
      $PSQL -c "INSERT INTO user_leave (user_id,start_date,end_date,jenis,keterangan)
                SELECT $UID,'$SD','$ED','$JN','Auto-detect HRD group, approved via WA'
                WHERE NOT EXISTS (SELECT 1 FROM user_leave WHERE user_id=$UID AND daterange(start_date,end_date,'[]') && daterange('$SD','$ED','[]'));" \
                >/dev/null 2>>"$LOG_DIR/daily.log"
      $PSQL -c "DELETE FROM pending_confirm WHERE id=$pid;" >/dev/null 2>>"$LOG_DIR/daily.log"
      local RT="$SD"; [ "$ED" != "$SD" ] && RT="$SD s/d $ED"
      wa_send "$GROUP_JID" "✅ Tercatat: *${NM}* ${JN} ${RT}. Tidak akan kena reminder/summary."
      log "  detect_leave: L$pid APPROVED → user_leave $NM $JN $SD..$ED"
      ;;
    tidak|tdk|gak|batal|no)
      $PSQL -c "DELETE FROM pending_confirm WHERE id=$pid;" >/dev/null 2>>"$LOG_DIR/daily.log"
      wa_send "$GROUP_JID" "❌ Dibatalkan — *${NM}* tidak direkam (L${pid})."
      log "  detect_leave: L$pid REJECTED"
      ;;
  esac
}

process_file "$MESSAGES_DIR/$YDAY/${GROUP_JID}.jsonl"
process_file "$MESSAGES_DIR/$TODAY/${GROUP_JID}.jsonl"

# Expire pending lama (housekeeping)
$PSQL -c "DELETE FROM pending_confirm WHERE hashtag='leave-approval' AND expires_at<NOW();" >/dev/null 2>>"$LOG_DIR/daily.log"

log "detect_leave: selesai"
