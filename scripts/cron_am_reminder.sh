#!/bin/bash
# ============================================================
# WRG CRM — AM Reminder Cron
# AM submit #REPORT dgn line "note: TGL keterangan" → reminder saved.
# This script fires reminders ke The ALLIANCE group:
#   H-1 sore (17:00): heads-up untuk reminder besok
#   H pagi (07:00):    reminder final hari ini
#
# Cron schedule:
#   0 17 * * * → fire H-1 (tanggal_reminder = besok)
#   0 7 * * *  → fire H   (tanggal_reminder = hari ini)
# ============================================================
set -uo pipefail

source "$(dirname "$0")/../config/config.sh"
export WRG_JOB="am_reminder"

# Arg: "h-minus-1" atau "h"
MODE="${1:-h}"
if [ "$MODE" = "h-minus-1" ]; then
  TARGET_DATE=$(date -j -v+1d '+%Y-%m-%d')
  FIRED_COL="fired_h_minus_1"
  LABEL_PREFIX="📅 *Heads-up reminder besok ($TARGET_DATE)*"
else
  TARGET_DATE=$(date '+%Y-%m-%d')
  FIRED_COL="fired_h"
  LABEL_PREFIX="🔔 *Reminder hari ini ($TARGET_DATE)*"
fi

THE_ALLIANCE_GROUP="120363405485256544@g.us"

log "  am_reminder: mode=$MODE target_date=$TARGET_DATE"

# Get reminders due, group by user
ROWS=$($PSQL <<SQL
SELECT
  ar.id || E'\t' || COALESCE(INITCAP(mu.panggilan), mu.nama, '') || E'\t' || ar.keterangan
FROM am_reminder ar
JOIN master_user mu ON mu.id = ar.user_id
WHERE ar.tanggal_reminder = '$TARGET_DATE'
  AND ar.$FIRED_COL = FALSE
ORDER BY mu.panggilan, ar.id;
SQL
)

if [ -z "$ROWS" ]; then
  log "  am_reminder: no reminders due for $TARGET_DATE"
  exit 0
fi

# Build consolidated WA message — grouped by AM
MSG="$LABEL_PREFIX
"
CURR_AM=""
FIRED_IDS=""
COUNT=0
while IFS=$'\t' read -r ID NAME KET; do
  [ -z "$ID" ] && continue
  if [ "$NAME" != "$CURR_AM" ]; then
    MSG="${MSG}
*${NAME}:*"
    CURR_AM="$NAME"
  fi
  MSG="${MSG}
• ${KET}"
  FIRED_IDS="${FIRED_IDS}${FIRED_IDS:+,}$ID"
  COUNT=$((COUNT + 1))
done <<< "$ROWS"

log "  am_reminder: sending $COUNT reminders to The ALLIANCE"

if wa_send "$THE_ALLIANCE_GROUP" "$MSG"; then
  # Mark fired
  $PSQL -c "UPDATE am_reminder SET $FIRED_COL = TRUE, fired_at = NOW() WHERE id IN ($FIRED_IDS);" >/dev/null 2>>"$LOG_DIR/daily.log"
  log "  am_reminder: done (fired=$COUNT)"
else
  log "  am_reminder: WA send failed — keep fired flag FALSE for retry"
  exit 1
fi
