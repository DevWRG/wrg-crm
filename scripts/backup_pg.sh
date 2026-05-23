#!/bin/bash
# ============================================================
# WRG CRM — Daily PostgreSQL Backup
# Output: backups/wrg_crm_YYYY-MM-DD_HHMM.dump (custom format)
# Retention: 30 hari (auto-prune)
# Schedule: 02:00 daily (lihat crontab)
# ============================================================

set -euo pipefail
source "$(dirname "$0")/../config/config.sh"
export WRG_JOB="backup"

DATE=$(date '+%Y-%m-%d_%H%M')
OUT="$BACKUP_DIR/wrg_crm_${DATE}.dump"

pg_dump -U "$PGUSER" -d "$PGDATABASE" \
  --format=custom \
  --file="$OUT" 2>>"$LOG_DIR/daily.log"

if [ ! -s "$OUT" ]; then
  log "Backup FAILED — file empty: $OUT"
  exit 1
fi

SIZE=$(du -h "$OUT" | awk '{print $1}')
log "Backup OK: $(basename "$OUT") ($SIZE)"

# Prune backup > 30 hari
PRUNED=$(find "$BACKUP_DIR" -name 'wrg_crm_*.dump' -type f -mtime +30 -print -delete 2>/dev/null | wc -l | tr -d ' ')
[ "$PRUNED" -gt 0 ] && log "Pruned $PRUNED backup(s) > 30 hari"
