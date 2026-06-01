#!/bin/bash
# Export dashboard ke PDF via Chrome headless --print-to-pdf.
# Buat kirim ke direksi / HOD.
#
# Usage:
#   bash scripts/export_pdf.sh                    # default: minggu ini, simpan ke exports/
#   bash scripts/export_pdf.sh 2026-05-04 2026-05-22
#   bash scripts/export_pdf.sh 2026-05-01 2026-05-31 /path/to/output.pdf
#   bash scripts/export_pdf.sh --env prod         # preview prod (read-only)
#   bash scripts/export_pdf.sh --env prod 2026-05-01 2026-05-31
#
# Output: PDF di /Users/development/Documents/wrg-crm/exports/wrg-report-<from>_<to>.pdf
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EXPORT_DIR="$BASE_DIR/exports"
DASHBOARD_URL="http://127.0.0.1:8091"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

# Parse args
ENV_FLAG=""
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)
      shift
      if [[ "${1:-}" == "prod" || "${1:-}" == "dev" ]]; then
        ENV_FLAG="$1"
        shift
      else
        echo "ERROR: --env must be prod|dev" >&2
        exit 1
      fi
      ;;
    -h|--help)
      sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done

FROM="${ARGS[0]:-}"
TO="${ARGS[1]:-}"
OUTPUT="${ARGS[2]:-}"

# Default range: this week Mon→Fri (or Mon→today if before Friday)
if [[ -z "$FROM" || -z "$TO" ]]; then
  # Compute Monday of this week
  TODAY=$(date +%Y-%m-%d)
  DOW=$(date +%u)  # 1..7 Mon..Sun
  DAYS_BACK=$((DOW - 1))
  FROM=$(date -j -v-${DAYS_BACK}d +%Y-%m-%d)
  DAYS_TO_FRI=$((5 - DOW))
  if (( DAYS_TO_FRI < 0 )); then DAYS_TO_FRI=0; fi
  FRI=$(date -j -v+${DAYS_TO_FRI}d +%Y-%m-%d)
  TO=$([[ "$FRI" > "$TODAY" ]] && echo "$TODAY" || echo "$FRI")
fi

# Validate date format
if [[ ! "$FROM" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ || ! "$TO" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  echo "ERROR: tanggal harus YYYY-MM-DD (got from=$FROM to=$TO)" >&2
  exit 1
fi

mkdir -p "$EXPORT_DIR"
if [[ -z "$OUTPUT" ]]; then
  STAMP=$(date +%Y%m%d-%H%M)
  ENV_SUFFIX=""
  [[ -n "$ENV_FLAG" ]] && ENV_SUFFIX="-${ENV_FLAG}"
  OUTPUT="$EXPORT_DIR/wrg-report-${FROM}_${TO}${ENV_SUFFIX}-${STAMP}.pdf"
fi

# Quick sanity: dashboard responding? (login.html is public, no auth needed)
if ! curl -fsS -o /dev/null --max-time 3 "$DASHBOARD_URL/login.html"; then
  echo "ERROR: dashboard tidak respond di $DASHBOARD_URL" >&2
  echo "       launchctl list | grep wrg-crm  → cek status" >&2
  exit 1
fi

# Service token: required sejak Phase 5 (dashboard auth-gated).
# Set via env var WRG_SERVICE_TOKEN (di launchd plist dashboard supaya
# proses dashboard tahu nilainya), atau fallback ke .service_token file.
# Generate: `openssl rand -hex 32`.
if [[ -z "${WRG_SERVICE_TOKEN:-}" ]] && [[ -f "$BASE_DIR/.service_token" ]]; then
  WRG_SERVICE_TOKEN=$(cat "$BASE_DIR/.service_token")
fi
if [[ -z "${WRG_SERVICE_TOKEN:-}" ]]; then
  echo "ERROR: WRG_SERVICE_TOKEN env var unset — required for PDF export auth" >&2
  echo "       Set di plist + cron env (sama dgn yg ada di dashboard plist)" >&2
  exit 1
fi

# Build full URL via /api/auth/service-login (302 → next dgn session cookie).
# Chrome stores Set-Cookie + follows redirect → semua fetch() di page auth-ed.
INNER="/?export=pdf"
[[ -n "$ENV_FLAG" ]] && INNER="${INNER}&env=${ENV_FLAG}"
INNER_ENC=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$INNER")
URL="${DASHBOARD_URL}/api/auth/service-login?token=${WRG_SERVICE_TOKEN}&next=${INNER_ENC}"
# Fragment preserved across 302 by Chrome:
URL="${URL}#from=${FROM}&to=${TO}"

echo "Exporting:"
echo "  range:  $FROM → $TO"
[[ -n "$ENV_FLAG" ]] && echo "  env:    $ENV_FLAG (preview)"
echo "  url:    $URL"
echo "  output: $OUTPUT"
echo ""

# Run Chrome headless
"$CHROME" --headless=new --disable-gpu \
  --hide-scrollbars \
  --no-pdf-header-footer \
  --print-to-pdf-no-header \
  --print-to-pdf="$OUTPUT" \
  --virtual-time-budget=8000 \
  --window-size=1400,1100 \
  "$URL" 2>&1 | grep -v -E '(externally_managed|os_integration_manager|InitializeSandbox|chrome_default)' | grep -v '^$' || true

if [[ -f "$OUTPUT" && -s "$OUTPUT" ]]; then
  SIZE=$(stat -f%z "$OUTPUT")
  PAGES=$(/usr/bin/mdls -name kMDItemNumberOfPages -raw "$OUTPUT" 2>/dev/null || echo "?")
  echo ""
  echo "✓ PDF created: $OUTPUT"
  echo "  size:  $SIZE bytes"
  echo "  pages: $PAGES"
  echo ""
  echo "Buka: open \"$OUTPUT\""
else
  echo "ERROR: PDF tidak terbuat atau kosong" >&2
  exit 2
fi
