#!/bin/bash
# ============================================================
# WRG CRM — Environment Switch
# Toggle dev (Research grup saja) ↔ prod (semua grup).
# State disimpan di data/state/environment (single source of truth).
#
# Usage:
#   bash env-switch.sh status        # show current env
#   bash env-switch.sh dev           # switch to dev (Research only)
#   bash env-switch.sh prod          # switch to prod (REQUIRES YES confirm)
#   bash env-switch.sh prod --force  # skip confirmation (for scripted use)
# ============================================================

set -euo pipefail
source "$(dirname "$0")/../config/config.sh"

ENV_FILE="$BASE_DIR/data/state/environment"
mkdir -p "$(dirname "$ENV_FILE")"

# Secondary mirror — written for the launchd dashboard which can't read Documents/
# due to macOS Sequoia TCC restrictions. Path matches dashboard.py ENV_FILE_MIRROR.
ENV_MIRROR="/Users/development/wrg-crm-runtime/environment"

# Helper: write to both canonical & mirror so dashboard picks up flip immediately.
write_env() {
  echo "$1" > "$ENV_FILE"
  if [ -d "$(dirname "$ENV_MIRROR")" ]; then
    echo "$1" > "$ENV_MIRROR"
  fi
}

case "${1:-status}" in
  status)
    CURRENT=$(cat "$ENV_FILE" 2>/dev/null || echo "dev")
    echo "Current environment: $CURRENT"
    if [ "$CURRENT" = "prod" ]; then
      echo "  → DB:     wrg_crm_prod"
      echo "  → Filter: ALL groups (production)"
      echo "  → Bot WILL reply to any registered user in any group bot is in"
    else
      echo "  → DB:     wrg_crm_dev"
      echo "  → Filter: Research group only (120363409252019573@g.us)"
      echo "  → Bot only processes messages from Research group"
    fi
    # Row counts per env
    ROWS=$(psql -U wrg_admin -d "wrg_crm_${CURRENT}" -tA -c "
      SELECT
        'master_user='   || (SELECT COUNT(*) FROM master_user)   || ' ' ||
        'sales_plan='    || (SELECT COUNT(*) FROM sales_plan)    || ' ' ||
        'sales_todo='    || (SELECT COUNT(*) FROM sales_todo)    || ' ' ||
        'activity_log='  || (SELECT COUNT(*) FROM activity_log);
    " 2>/dev/null)
    [ -n "$ROWS" ] && echo "  → Data:   $ROWS"
    exit 0
    ;;

  dev)
    write_env "dev"
    echo "✓ Switched to DEV."
    echo "  → DB:     wrg_crm_dev"
    echo "  → Filter: Research group only"
    echo "  Effective in next cron tick (max 60s)."
    ;;

  prod)
    if [ "${2:-}" != "--force" ]; then
      echo "⚠️  ⚠️  ⚠️  SWITCH TO PRODUCTION  ⚠️  ⚠️  ⚠️"
      echo ""
      echo "Bot akan reply ke SEMUA grup yang bot di-invite."
      echo "Anggota terdaftar di master_user (62 users) bisa trigger #PLAN/#REPORT/dll."
      echo "Data akan tersimpan di DB wrg_crm_prod (separated from wrg_crm_dev)."
      echo ""
      echo "Pastikan:"
      echo "  □ Format edukasi tim sudah selesai (cust:/tujuan:/goal: utk AM, numbered list utk non-AM)"
      echo "  □ Test data sudah di-clean (truncate sales_plan / sales_todo / activity_log)"
      echo "  □ Backup PG terbaru tersedia (bash scripts/backup_pg.sh)"
      echo "  □ AI quota OpenRouter cukup untuk daily_summary"
      echo ""
      printf "Ketik 'YES' untuk konfirmasi: "
      read -r CONFIRM
      if [ "$CONFIRM" != "YES" ]; then
        echo "Aborted. Environment unchanged."
        exit 1
      fi
    fi
    write_env "prod"
    echo "✓ Switched to PROD."
    echo "  → DB:     wrg_crm_prod"
    echo "  → Filter: ALL groups"
    echo "  Effective in next cron tick (max 60s)."
    echo "  Monitor: tail -f logs/daily.log"
    echo "  Emergency revert: bash scripts/env-switch.sh dev"
    ;;

  *)
    echo "Usage: $0 {status|dev|prod [--force]}" >&2
    exit 1
    ;;
esac
