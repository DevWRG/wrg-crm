#!/usr/bin/env bash
# extract_competitor.sh — LLM-based extraction of competitor mentions dari
# activity_log.hasil → competitor_intel rows.
#
# Modes:
#   bash extract_competitor.sh                  # incremental (process unextracted)
#   bash extract_competitor.sh --backfill 30    # backfill last N days
#   bash extract_competitor.sh --activity <id>  # one-shot specific activity
#
# Uses call_openrouter from config.sh. Skips activity_log rows already di
# competitor_extraction_state (idempotent).

set -uo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$BASE_DIR/config/config.sh"
LOG_DIR="$BASE_DIR/logs"
mkdir -p "$LOG_DIR"

LIMIT_DEFAULT=20  # max rows per run untuk avoid API cost spike
MODEL="${COMPETITOR_MODEL:-$DAILY_MODEL_PRIMARY}"

# Args
MODE="incremental"
BACKFILL_DAYS=30
ACTIVITY_ID=""
while [ $# -gt 0 ]; do
  case "$1" in
    --backfill) MODE="backfill"; BACKFILL_DAYS="${2:-30}"; shift 2 ;;
    --activity) MODE="single"; ACTIVITY_ID="$2"; shift 2 ;;
    --limit)    LIMIT_DEFAULT="$2"; shift 2 ;;
    *) echo "unknown arg: $1"; exit 1 ;;
  esac
done

log "extract_competitor: mode=$MODE limit=$LIMIT_DEFAULT model=$MODEL"

# Build target query
if [ "$MODE" = "single" ]; then
  WHERE="al.id = $ACTIVITY_ID"
elif [ "$MODE" = "backfill" ]; then
  WHERE="al.tanggal >= CURRENT_DATE - INTERVAL '$BACKFILL_DAYS days' AND al.hasil IS NOT NULL AND length(al.hasil) > 30 AND ces.activity_id IS NULL"
else
  WHERE="al.hasil IS NOT NULL AND length(al.hasil) > 30 AND ces.activity_id IS NULL"
fi

# Fetch candidates as JSON array
CANDIDATES=$($PSQL -tA -c "
SELECT json_agg(t) FROM (
  SELECT al.id, al.user_id, al.customer_name, al.tanggal::text AS tanggal, al.hasil
  FROM activity_log al
  LEFT JOIN competitor_extraction_state ces ON ces.activity_id = al.id
  WHERE $WHERE
  ORDER BY al.id DESC
  LIMIT $LIMIT_DEFAULT
) t;" 2>>"$LOG_DIR/daily.log")

if [ -z "$CANDIDATES" ] || [ "$CANDIDATES" = "null" ]; then
  log "  extract_competitor: no candidates"
  exit 0
fi

N=$(echo "$CANDIDATES" | jq -r 'length')
log "  extract_competitor: processing $N rows"

SYS='You extract competitor intelligence from Indonesian sales-visit reports for a medical/lab equipment distributor (Wahana Lifeline).

Given a `hasil` (visit narrative), extract mentions of COMPETITOR vendors, products, and prices. A competitor is any OTHER vendor/PT/distributor or product brand the customer mentioned using, comparing, or buying from — NOT Wahana itself.

Return STRICT JSON array. Each item:
{
  "vendor": "PT name OR brand name (e.g., PT Dexa, PT Itama, Mindray, Nubion)",
  "produk": "specific product mentioned (e.g., HBA1C, Hematologi analyzer, BGA, blood bag)",
  "produk_kategori": "category: Hematologi | Kimia Klinik | POCT | BMHP | BGA | Imunologi | Mikrobiologi | Alkes | Reagen | Other",
  "harga_text": "raw price text if mentioned (e.g., \"50 ribu per tes\", \"Rp 64.000\"), or null",
  "harga_numeric": numeric IDR value or null,
  "konteks": "short 1-sentence snippet (≤120 chars) showing context"
}

Rules:
- Output JSON array only — no preamble, no markdown fence.
- Empty array `[]` if no competitor mention.
- Skip generic mentions of "vendor lain" tanpa nama spesifik.
- Skip Wahana own brand (Family Dr, Lysun, Snibe Maglumi, Clover, Wahana, WGI).
- One row per distinct (vendor, produk) pair. Same vendor 2 produk = 2 rows.
- harga_numeric: parse "50 ribu" → 50000, "1.5 jt" → 1500000. null if unclear.'

# Process each candidate
PROCESSED=0
TOTAL_MENTIONS=0
echo "$CANDIDATES" | jq -c '.[]' | while IFS= read -r ITEM; do
  ID=$(echo "$ITEM" | jq -r '.id')
  HASIL=$(echo "$ITEM" | jq -r '.hasil')
  CUST=$(echo "$ITEM" | jq -r '.customer_name')
  TGL=$(echo "$ITEM" | jq -r '.tanggal')
  USRID=$(echo "$ITEM" | jq -r '.user_id // empty')

  USR="Customer: ${CUST:-?}\nTanggal: ${TGL}\n\nHasil:\n${HASIL}"

  RESULT=$(call_openrouter "$MODEL" "$SYS" "$USR" 2000)
  if [ -z "$RESULT" ]; then
    log "  extract_competitor: id=$ID skip (LLM empty)"
    continue
  fi

  # Strip markdown fences kalau model lupa
  RESULT=$(printf '%s' "$RESULT" | sed -E '/^```/d' | sed -E 's/^json//' )

  # Validate JSON
  if ! echo "$RESULT" | jq -e 'type == "array"' >/dev/null 2>&1; then
    log "  extract_competitor: id=$ID LLM returned non-array: ${RESULT:0:100}"
    continue
  fi

  N_MENTIONS=$(echo "$RESULT" | jq 'length')

  # Insert each mention
  if [ "$N_MENTIONS" -gt 0 ]; then
    echo "$RESULT" | jq -c '.[]' | while IFS= read -r M; do
      VENDOR=$(echo "$M"   | jq -r '.vendor // empty'           | sed "s/'/''/g")
      PRODUK=$(echo "$M"   | jq -r '.produk // empty'           | sed "s/'/''/g")
      KAT=$(echo "$M"      | jq -r '.produk_kategori // empty'  | sed "s/'/''/g")
      HRGT=$(echo "$M"     | jq -r '.harga_text // empty'       | sed "s/'/''/g")
      HRGN=$(echo "$M"     | jq -r '.harga_numeric // empty')
      KTX=$(echo "$M"      | jq -r '.konteks // empty'          | sed "s/'/''/g")

      [ -z "$VENDOR" ] && [ -z "$PRODUK" ] && continue

      HRGN_SQL="NULL"
      if [ -n "$HRGN" ] && [ "$HRGN" != "null" ]; then
        HRGN_SQL="$HRGN"
      fi
      CUST_SAFE=$(echo "$CUST" | sed "s/'/''/g")
      USRID_SQL="NULL"
      [ -n "$USRID" ] && USRID_SQL="$USRID"

      $PSQL -c "
        INSERT INTO competitor_intel
          (activity_id, user_id, customer_name, tanggal,
           vendor, produk, produk_kategori, harga_text, harga_numeric,
           konteks, extraction_model)
        VALUES ($ID, $USRID_SQL, '${CUST_SAFE}', '$TGL',
                NULLIF('${VENDOR}',''), NULLIF('${PRODUK}',''),
                NULLIF('${KAT}',''), NULLIF('${HRGT}',''), $HRGN_SQL,
                NULLIF('${KTX}',''), '${MODEL}');
      " >/dev/null 2>>"$LOG_DIR/daily.log"
    done
  fi

  # Mark extracted
  $PSQL -c "
    INSERT INTO competitor_extraction_state (activity_id, n_mentions, extraction_model)
    VALUES ($ID, $N_MENTIONS, '${MODEL}')
    ON CONFLICT (activity_id) DO UPDATE SET
      extracted_at = NOW(), n_mentions = EXCLUDED.n_mentions,
      extraction_model = EXCLUDED.extraction_model;
  " >/dev/null 2>>"$LOG_DIR/daily.log"

  PROCESSED=$((PROCESSED + 1))
  TOTAL_MENTIONS=$((TOTAL_MENTIONS + N_MENTIONS))
  log "  extract_competitor: id=$ID cust='${CUST:0:30}' mentions=$N_MENTIONS"
done

log "extract_competitor done: processed=$N total_mentions=$TOTAL_MENTIONS"
