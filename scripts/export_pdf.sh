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

# Quick sanity: dashboard responding?
if ! curl -fsS -o /dev/null --max-time 3 "$DASHBOARD_URL/api/env"; then
  echo "ERROR: dashboard tidak respond di $DASHBOARD_URL" >&2
  echo "       launchctl list | grep wrg-crm  → cek status" >&2
  exit 1
fi

# Build full URL with export=pdf + env override + date range
URL="${DASHBOARD_URL}/?export=pdf"
[[ -n "$ENV_FLAG" ]] && URL="${URL}&env=${ENV_FLAG}"
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
