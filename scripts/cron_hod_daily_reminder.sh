#!/bin/bash
# Daily reminder ke grup Koord HoD: HOD yg giliran hari ini wajib share
# "daily update" maksimal jam 20:30. Giliran dibagi per parity tanggal:
#   tanggal GENAP  -> Rocky Gunawan (RG WG)
#   tanggal GANJIL -> Yogi Nugroho
# Fire via cron 20:00 weekday (lihat crontab). Skip weekend + master_holiday,
# dan skip kalau yg giliran sudah posting "berikut update <hari ini>".
set -uo pipefail
source /Users/development/Documents/wrg-crm/config/config.sh

GROUP_JID="120363404092121926@g.us"   # grup Koord HoD
TODAY_ISO="$(date +%F)"
DOM="$(date +%-d)"                      # day-of-month tanpa leading zero
DOW="$(date +%u)"                       # 1=Sen .. 7=Min
DD_MM="$(date +%-d/%-m)"                # mis. 9/6
DDMMYYYY="$(date +%d/%m/%Y)"           # mis. 09/06/2026
HARI_ID=(Senin Selasa Rabu Kamis Jumat Sabtu Minggu)
HARI="${HARI_ID[$((DOW-1))]}"

# --- Skip weekend (guard; cron sudah batasi 1-5) ---
if [ "$DOW" -ge 6 ]; then
  log "  hod-reminder: weekend ($HARI) — skip"
  exit 0
fi

# --- Skip hari libur ---
IS_HOLIDAY="$(psql -U "$PGUSER" -d "$PGDATABASE" -tA \
  -c "SELECT keterangan FROM master_holiday WHERE tanggal = '$TODAY_ISO' LIMIT 1;" 2>/dev/null)"
if [ -n "$IS_HOLIDAY" ]; then
  log "  hod-reminder: libur ($IS_HOLIDAY) — skip"
  exit 0
fi

# --- Tentukan giliran berdasarkan parity tanggal ---
if [ $((DOM % 2)) -eq 0 ]; then
  WHO="Rocky";  WHO_NUM="6281213255253"; WHO_SENDER="RG WG";        PARITY="genap"
else
  WHO="Yogi";   WHO_NUM="6281330088773"; WHO_SENDER="Yogi Nugroho"; PARITY="ganjil"
fi

# --- Guard: skip kalau yg giliran sudah posting update hari ini ---
CAP="$HOME/.openclaw/tmp/wrg-monitor/messages/$TODAY_ISO/${GROUP_JID}.jsonl"
if [ -f "$CAP" ]; then
  ALREADY="$(python3 - "$CAP" "$WHO_SENDER" "$DD_MM" "$DDMMYYYY" <<'PY'
import sys, json, re
cap, sender, dd_mm, ddmmyyyy = sys.argv[1:5]
# normalisasi tanggal target -> set string yg dianggap "update hari ini"
targets = {dd_mm, ddmmyyyy, ddmmyyyy.lstrip("0")}
hit = False
try:
    with open(cap) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            r = json.loads(line)
            if r.get("sender_name") != sender:
                continue
            body = (r.get("body") or "").lower()
            if "update" not in body:
                continue
            # cocokkan tanggal hari ini di body (dd/mm atau dd/mm/yyyy)
            for t in targets:
                if t and t.lower() in body:
                    hit = True
                    break
            if hit:
                break
except FileNotFoundError:
    pass
print("1" if hit else "0")
PY
)"
  if [ "$ALREADY" = "1" ]; then
    log "  hod-reminder: $WHO sudah posting update $DDMMYYYY — skip"
    exit 0
  fi
fi

# --- Susun & kirim reminder ---
MSG="⏰ *Reminder Daily Update HoD*

@${WHO_NUM} (${WHO}) — hari ini *${HARI}, ${DDMMYYYY}* (tanggal ${PARITY}) giliran lu share *daily update* di grup ini.

⚠️ Maksimal kirim *jam 20:30*. Jangan lupa lampirin foto/dokumen update-nya 🙏"

wa_send "$GROUP_JID" "$MSG"
log "  hod-reminder: sent to $WHO ($WHO_NUM) for $DDMMYYYY ($PARITY)"
