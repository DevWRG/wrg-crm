#!/bin/bash
# Sync wrg-crm/scripts/dashboard.py → ~/wrg-crm-runtime/, restart launchd job.
# Workaround: macOS Sequoia TCC blocks launchd from reading the Documents folder
# for new LaunchAgent labels even with FDA. So we host the script outside Documents
# and pass WRG_CRM_PROJECT_DIR=... so it still reads data/ from the project.
#
# Usage: bash scripts/reload-dashboard.sh
set -euo pipefail

SRC="/Users/development/Documents/wrg-crm/scripts/dashboard.py"
DST_DIR="/Users/development/wrg-crm-runtime"
DST="$DST_DIR/dashboard.py"
LABEL="ai.wrg-crm.dashboard"
UID_NUM="$(id -u)"

# Adminator frontend dist (built separately in ~/wrg-crm-dev/frontend/dist).
# If the build is present, sync to runtime so dashboard.py serves it.
FRONTEND_SRC="/Users/development/wrg-crm-dev/frontend/dist"
FRONTEND_DST="$DST_DIR/frontend-dist"

mkdir -p "$DST_DIR"
cp "$SRC" "$DST"
echo "Synced: $SRC -> $DST"

# Sync sibling Python modules (split from dashboard.py — 2026-05-30 refactor).
# All modules must live in same dir as dashboard.py untuk import resolution.
for mod in wrg_db.py wrg_auth.py wrg_queries.py; do
  if [ -f "/Users/development/Documents/wrg-crm/scripts/$mod" ]; then
    cp "/Users/development/Documents/wrg-crm/scripts/$mod" "$DST_DIR/$mod"
    echo "Synced module: $mod"
  fi
done

if [ -d "$FRONTEND_SRC" ]; then
  rsync -a --delete "$FRONTEND_SRC/" "$FRONTEND_DST/"
  echo "Synced frontend: $FRONTEND_SRC -> $FRONTEND_DST"
else
  echo "INFO: $FRONTEND_SRC not present — dashboard.py akan fallback ke legacy inline INDEX_HTML"
fi

# Kick the launchd job so changes take effect immediately.
if launchctl list | grep -q "$LABEL"; then
  launchctl kickstart -k "gui/$UID_NUM/$LABEL"
  sleep 1
  if launchctl list | grep -q "$LABEL"; then
    echo "Restarted launchd job: $LABEL"
  else
    echo "WARN: $LABEL not in launchctl list after restart"
    exit 1
  fi
else
  echo "WARN: $LABEL not loaded. To install: launchctl bootstrap gui/$UID_NUM ~/Library/LaunchAgents/$LABEL.plist"
  exit 1
fi

# Quick health probe. Post-auth-deploy, /api/env requires session — so
# probe / (login page or dashboard, both return 200 unauthenticated) instead.
sleep 0.5
if curl -fsS -o /dev/null http://127.0.0.1:8091/; then
  echo "OK: http://127.0.0.1:8091/ responding"
else
  echo "WARN: http://127.0.0.1:8091/ not responding — check $DST_DIR/dashboard.err.log"
  exit 1
fi
