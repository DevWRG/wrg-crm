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

mkdir -p "$DST_DIR"
cp "$SRC" "$DST"
echo "Synced: $SRC -> $DST"

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

# Quick health probe.
sleep 0.5
if curl -fsS -o /dev/null http://127.0.0.1:8091/api/env; then
  echo "OK: http://127.0.0.1:8091/ responding"
else
  echo "WARN: http://127.0.0.1:8091/ not responding — check $DST_DIR/dashboard.err.log"
  exit 1
fi
