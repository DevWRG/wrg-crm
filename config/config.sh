#!/bin/bash
# ============================================================
# WRG CRM — Konfigurasi Utama
# Sourced oleh wrg-daily.sh dan script lain di scripts/
# ============================================================

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="$BASE_DIR/logs"
BACKUP_DIR="$BASE_DIR/backups"
mkdir -p "$LOG_DIR" "$BACKUP_DIR"

# ── PostgreSQL (env-aware) ───────────────────────────────────
# Pisah DB per env: dev/prod data tidak nyebrang.
# Legacy db `wrg_crm` masih ada sebagai fallback — jangan dipakai langsung.
export PGUSER="wrg_admin"
# (PGHOST/PGPORT default localhost:5432 — OK untuk local Mac Mini)
# Note: WRG_ENV diset di section di bawah; PGDATABASE depend on it.

# ── WhatsApp via openclaw ────────────────────────────────────
BOT_NUMBER="+6285168121906"   # nomor bot (sama dengan WRG Monitor)
ADMIN_NUMBER="+6285733048855" # owner WA — untuk error notif

# ── Environment switch (dev | prod) ──────────────────────────
# State di data/state/environment. Toggle via scripts/env-switch.sh.
# Pisah BOTH: filter group + database.
# dev  → DB=wrg_crm_dev,  filter=Research group JID only
# prod → DB=wrg_crm_prod, filter=all groups
WRG_ENV=$(cat "$BASE_DIR/data/state/environment" 2>/dev/null || echo "dev")

# Database selection
if [ "$WRG_ENV" = "prod" ]; then
  export PGDATABASE="wrg_crm_prod"
else
  export PGDATABASE="wrg_crm_dev"
fi
PSQL="psql -U $PGUSER -d $PGDATABASE -tA"
PSQL_FMT="psql -U $PGUSER -d $PGDATABASE"

# ── Inbound handler filter (driven by WRG_ENV) ───────────────
RESEARCH_GROUP_JID="120363409252019573@g.us"
if [ "$WRG_ENV" = "prod" ]; then
  WRG_INBOUND_ALLOWED_GROUPS="${WRG_INBOUND_ALLOWED_GROUPS:-}"   # empty = all groups
  # Research = dev-only zone. Prevents test #PLAN/#REPORT messages from
  # leaking into wrg_crm_prod when dev inbound (worktree ~/wrg-crm-dev/) is
  # also running on cron. Both prod & dev see the same JSONL; this carves
  # responsibility cleanly.
  WRG_INBOUND_DENY_GROUPS="${WRG_INBOUND_DENY_GROUPS:-$RESEARCH_GROUP_JID}"
else
  WRG_INBOUND_ALLOWED_GROUPS="${WRG_INBOUND_ALLOWED_GROUPS:-$RESEARCH_GROUP_JID}"
  WRG_INBOUND_DENY_GROUPS="${WRG_INBOUND_DENY_GROUPS:-}"
fi
export WRG_INBOUND_ALLOWED_GROUPS WRG_INBOUND_DENY_GROUPS

# ── AI: direct OpenRouter API ────────────────────────────────
# Sama pattern dengan WRG Monitor karena openclaw agent --model
# overrides di-block oleh gateway auth (lihat memory project_ai_model_setup).
# API key dari agent wrg-crm punya (sama key dengan main agent).
AUTH_PROFILES="$HOME/.openclaw/agents/wrg-crm/agent/auth-profiles.json"
OPENROUTER_KEY="${OPENROUTER_KEY:-$(jq -r '.profiles."openrouter:default".key // empty' "$AUTH_PROFILES" 2>/dev/null)}"

DAILY_MODEL_PRIMARY="openrouter/anthropic/claude-haiku-4.5"
DAILY_MODEL_FALLBACK="openrouter/deepseek/deepseek-r1"

# ── Logging ──────────────────────────────────────────────────
# File-only output. Cron's >> cron.log 2>&1 captures stderr separately (errors).
# Manual debug: `tail -f logs/daily.log` di terminal lain.
# Tidak pakai `tee` karena dup entry kalau cron pipe stdout balik ke daily.log.
# Format: [YYYY-MM-DD HH:MM:SS] [<env>:<job>] message
log() {
  local JOB="${WRG_JOB:-daily}"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${WRG_ENV}:${JOB}] $*" >> "$LOG_DIR/daily.log"
}

# ── Helpers ──────────────────────────────────────────────────

# Send WhatsApp message via openclaw.
# Args: $1=target (group JID atau +E.164), $2=message body.
wa_send() {
  local TARGET="$1"; shift
  local BODY="$*"
  if [ -z "$TARGET" ]; then
    log "  wa_send: empty target — skip"
    return 1
  fi
  openclaw message send \
    --channel whatsapp \
    --target "$TARGET" \
    --message "$BODY" \
    >/dev/null 2>>"$LOG_DIR/daily.log"
}

# Call OpenRouter directly (bypass openclaw agent --model auth block).
# Args: $1=model_id (provider/model), $2=system_prompt, $3=user_message, $4=max_tokens(default 4000).
call_openrouter() {
  local MODEL="${1#openrouter/}"
  local SYS="$2"
  local USR="$3"
  local MAX="${4:-4000}"

  [ -z "$OPENROUTER_KEY" ] && { log "  ai: OPENROUTER_KEY missing"; return 1; }

  local PAYLOAD
  PAYLOAD=$(jq -nc \
    --arg model "$MODEL" \
    --arg sys   "$SYS" \
    --arg usr   "$USR" \
    --argjson m "$MAX" \
    '{
      model: $model,
      messages: [
        {role: "system", content: $sys},
        {role: "user",   content: $usr}
      ],
      max_tokens: $m
    }')

  local RESP
  RESP=$(curl -sS --max-time 120 -X POST "https://openrouter.ai/api/v1/chat/completions" \
    -H "Authorization: Bearer $OPENROUTER_KEY" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" 2>>"$LOG_DIR/daily.log")

  local ERR
  ERR=$(printf '%s' "$RESP" | jq -r '.error.message // empty' 2>/dev/null)
  if [ -n "$ERR" ]; then
    log "  ai [$MODEL] error: $ERR"
    return 1
  fi
  printf '%s' "$RESP" | jq -r '.choices[0].message.content // empty' 2>/dev/null
}

# Try primary → fallback if empty/short.
call_ai_with_fallback() {
  local SYS="$1"
  local USR="$2"
  local MAX="${3:-4000}"

  local OUT
  OUT=$(call_openrouter "$DAILY_MODEL_PRIMARY" "$SYS" "$USR" "$MAX")
  if [ -n "$OUT" ] && [ "${#OUT}" -gt 50 ]; then
    printf '%s' "$OUT"
    return 0
  fi
  log "  ai-fallback: primary '$DAILY_MODEL_PRIMARY' short/empty, retry '$DAILY_MODEL_FALLBACK'"
  call_openrouter "$DAILY_MODEL_FALLBACK" "$SYS" "$USR" "$MAX"
}
