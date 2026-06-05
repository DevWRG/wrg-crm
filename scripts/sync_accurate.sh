#!/usr/bin/env bash
# Accurate Online sync POC — fetch sales-invoice header + items dari
# zeus.accurate.id, upsert ke accurate_invoice / accurate_invoice_item.
#
# Auth chain: aat.* Bearer token + X-Api-Timestamp (dd/MM/yyyy HH:mm:ss WIB)
# + X-Api-Signature (HMAC-SHA256 hex(signature_secret, timestamp)).
#
# Modes:
#   bash sync_accurate.sh                # incremental (last 7 days, default)
#   bash sync_accurate.sh --days 30      # custom window
#   bash sync_accurate.sh --invoice <id> # one-shot single invoice
#
# Credentials di ~/.openclaw/credentials/accurate.json:
#   { "access_token": "aat.*", "signature_secret": "...", "db_id": 1664470 }

set -uo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$BASE_DIR/config/config.sh"
LOG_DIR="$BASE_DIR/logs"
mkdir -p "$LOG_DIR"

CRED=/Users/development/.openclaw/credentials/accurate.json
if [ ! -f "$CRED" ]; then
  log "❌ accurate credentials missing: $CRED"
  exit 1
fi

ACC_TOKEN=$(jq -r '.access_token' "$CRED")
ACC_SECRET=$(jq -r '.signature_secret' "$CRED")
ACC_HOST="zeus.accurate.id"   # DB-specific host. TODO: dynamic via open-db if token tidak include session.

# Working-day gate (cron-only — skip via --force flag): Sunday=0, Sat=6 → libur.
# Plus check master_holiday table.
DOW=$(date '+%w')
TODAY=$(date '+%Y-%m-%d')
# Holiday check (only matters in incremental cron mode; ignore for --invoice/explicit)
if [ "${1:-}" != "--invoice" ] && [ "${1:-}" != "--force" ]; then
  if [ "$DOW" = "0" ] || [ "$DOW" = "6" ]; then
    log "sync_accurate: skipped (weekend dow=$DOW)"
    exit 0
  fi
  IS_HOLIDAY=$($PSQL -c "SELECT EXISTS(SELECT 1 FROM master_holiday WHERE tanggal='$TODAY');" 2>/dev/null | tr -d ' ')
  if [ "$IS_HOLIDAY" = "t" ]; then
    log "sync_accurate: skipped (libur nasional $TODAY)"
    exit 0
  fi
fi

# Args
MODE="incremental"
DAYS=7
INV_ID=""
while [ $# -gt 0 ]; do
  case "$1" in
    --days) DAYS="$2"; shift 2 ;;
    --invoice) MODE="single"; INV_ID="$2"; shift 2 ;;
    *) echo "unknown arg: $1"; exit 1 ;;
  esac
done

# Sign request: gen timestamp + sig, return as TS|SIG (use IFS='|' read)
acc_sign() {
  local ts sig
  ts=$(TZ=Asia/Jakarta python3 -c "from datetime import datetime;print(datetime.now().strftime('%d/%m/%Y %H:%M:%S'))")
  sig=$(python3 -c "
import hmac, hashlib
print(hmac.new(b'$ACC_SECRET', b'$ts', hashlib.sha256).hexdigest())")
  echo "${ts}|${sig}"
}

# Issue API GET. Args: <endpoint-path> [query-string]
acc_get() {
  local path="$1"
  local qs="${2:-}"
  local url="https://${ACC_HOST}${path}"
  [ -n "$qs" ] && url="${url}?${qs}"
  IFS='|' read -r ts sig <<< "$(acc_sign)"
  curl -sS --max-time 30 "$url" \
    -H "Authorization: Bearer ${ACC_TOKEN}" \
    -H "X-Api-Timestamp: ${ts}" \
    -H "X-Api-Signature: ${sig}"
}

# Upsert one invoice from detail JSON file.
# Args: $1 = path ke file dengan response JSON
# (pakai file biar jq bisa baca control chars langsung — variable bash bisa
# mangle binary, lihat catatan POC 2026-06-04.)
process_invoice() {
  local detail_file="$1"
  local inv_id inv_no cust_id cust_name branch_id tgl taxable tax total paid outstanding status
  inv_id=$(jq -r '.d.id' "$detail_file")
  inv_no=$(jq -r '.d.number // .d.transNumber // empty' "$detail_file")
  cust_id=$(jq -r '.d.customerId // .d.customer.id // empty' "$detail_file")
  cust_name=$(jq -r '.d.retailWpName // .d.customer.name // empty' "$detail_file")
  branch_id=$(jq -r '.d.branchId // empty' "$detail_file")
  tgl=$(jq -r '.d.transDate // empty' "$detail_file")
  taxable=$(jq -r '.d.taxableAmount1 // 0' "$detail_file")
  tax=$(jq -r '.d.tax1Amount // 0' "$detail_file")
  total=$(jq -r '.d.totalAmount // 0' "$detail_file")
  paid=$(jq -r '.d.totalPaid // 0' "$detail_file")
  outstanding=$(jq -r '.d.totalDue // 0' "$detail_file")
  status=$(jq -r 'if .d.outstanding then "OPEN" else "PAID" end' "$detail_file")
  local sm_id sm_name
  sm_id=$(jq -r '.d.masterSalesmanId // empty' "$detail_file")
  # Master salesman name not always at header — pull dari detailItem[0].salesmanList[0]
  sm_name=$(jq -r '[.d.detailItem[]?.salesmanList[]? | select(.id == ('"${sm_id:-null}"' | tonumber? // -1)) | .name] | first // empty' "$detail_file" 2>/dev/null)
  [ -z "$sm_name" ] && sm_name=$(jq -r '.d.detailItem[0].salesmanName // empty' "$detail_file")

  # Indo date "04/06/2026" → ISO "2026-06-04"
  local tgl_iso=""
  if [ -n "$tgl" ] && [ "$tgl" != "null" ]; then
    tgl_iso=$(python3 -c "
from datetime import datetime
try: print(datetime.strptime('$tgl','%d/%m/%Y').strftime('%Y-%m-%d'))
except: pass")
  fi
  [ -z "$tgl_iso" ] && return 0

  # Upsert customer (minimal — name + branch)
  if [ -n "$cust_id" ] && [ "$cust_id" != "null" ]; then
    local cust_safe
    cust_safe=$(printf '%s' "$cust_name" | sed "s/'/''/g")
    $PSQL -c "
      INSERT INTO accurate_customer (id, name, branch_id, last_synced_at)
      VALUES ($cust_id, NULLIF('${cust_safe}',''), ${branch_id:-NULL}, NOW())
      ON CONFLICT (id) DO UPDATE SET
        name=EXCLUDED.name, branch_id=EXCLUDED.branch_id, last_synced_at=NOW();
    " >/dev/null 2>>"$LOG_DIR/daily.log"
  fi

  # Upsert branch (minimal)
  if [ -n "$branch_id" ] && [ "$branch_id" != "null" ]; then
    $PSQL -c "
      INSERT INTO accurate_branch (id) VALUES ($branch_id)
      ON CONFLICT (id) DO NOTHING;
    " >/dev/null 2>>"$LOG_DIR/daily.log"
  fi

  # Upsert invoice header (simple INSERT, no raw blob untuk hindari psql escape pain).
  local inv_no_safe sm_name_safe
  inv_no_safe=$(printf '%s' "$inv_no" | sed "s/'/''/g")
  sm_name_safe=$(printf '%s' "$sm_name" | sed "s/'/''/g")
  local status_safe="${status//\'/\'\'}"
  $PSQL -c "
    INSERT INTO accurate_invoice (id, number, customer_id, branch_id, tanggal,
      taxable_amount, tax_amount, total, paid, outstanding, status,
      salesman_id, salesman_name, last_synced_at)
    VALUES ($inv_id, NULLIF('${inv_no_safe}',''),
            ${cust_id:-NULL}, ${branch_id:-NULL}, '$tgl_iso',
            $taxable, $tax, $total, $paid, $outstanding, '$status_safe',
            ${sm_id:-NULL}, NULLIF('${sm_name_safe}',''), NOW())
    ON CONFLICT (id) DO UPDATE SET
      number=EXCLUDED.number, customer_id=EXCLUDED.customer_id,
      branch_id=EXCLUDED.branch_id, tanggal=EXCLUDED.tanggal,
      taxable_amount=EXCLUDED.taxable_amount, tax_amount=EXCLUDED.tax_amount,
      total=EXCLUDED.total, paid=EXCLUDED.paid, outstanding=EXCLUDED.outstanding,
      status=EXCLUDED.status, salesman_id=EXCLUDED.salesman_id,
      salesman_name=EXCLUDED.salesman_name, last_synced_at=NOW();
  " >/dev/null 2>>"$LOG_DIR/daily.log"

  # Upsert salesman master from salesmanList (capture id, name, number, branch)
  jq -c '.d.detailItem[]?.salesmanList[]? | {id, name, number, branchId, suspended, employeeWorkStatus}' "$detail_file" 2>/dev/null \
    | sort -u | while IFS= read -r sm; do
    local s_id s_name s_num s_branch s_susp s_status
    s_id=$(printf '%s' "$sm" | jq -r '.id // empty')
    [ -z "$s_id" ] || [ "$s_id" = "null" ] && continue
    s_name=$(printf '%s' "$sm" | jq -r '.name // empty' | sed "s/'/''/g")
    s_num=$(printf '%s' "$sm" | jq -r '.number // empty' | sed "s/'/''/g")
    s_branch=$(printf '%s' "$sm" | jq -r '.branchId // empty')
    s_susp=$(printf '%s' "$sm" | jq -r '.suspended // false')
    s_status=$(printf '%s' "$sm" | jq -r '.employeeWorkStatus // empty' | sed "s/'/''/g")
    $PSQL -c "
      INSERT INTO accurate_salesman (id, name, number, branch_id, suspended, employee_work_status, last_synced_at)
      VALUES ($s_id, NULLIF('${s_name}',''), NULLIF('${s_num}',''),
              ${s_branch:-NULL}, ${s_susp:-FALSE}, NULLIF('${s_status}',''), NOW())
      ON CONFLICT (id) DO UPDATE SET
        name=EXCLUDED.name, number=EXCLUDED.number, branch_id=EXCLUDED.branch_id,
        suspended=EXCLUDED.suspended, employee_work_status=EXCLUDED.employee_work_status,
        last_synced_at=NOW();
    " >/dev/null 2>>"$LOG_DIR/daily.log"
  done

  # Items — wipe & reinsert. Iterate from file (preserves binary).
  $PSQL -c "DELETE FROM accurate_invoice_item WHERE invoice_id=$inv_id;" >/dev/null 2>>"$LOG_DIR/daily.log"
  jq -c '.d.detailItem[]?' "$detail_file" 2>/dev/null | while IFS= read -r line; do
    local item_id qty unit unit_price disc item_total
    item_id=$(printf '%s' "$line" | jq -r '.item.id // .itemId // empty')
    qty=$(printf '%s' "$line" | jq -r '.quantity // 0')
    unit=$(printf '%s' "$line" | jq -r '.itemUnit.name // .itemUnitName // empty' | sed "s/'/''/g")
    unit_price=$(printf '%s' "$line" | jq -r '.unitPrice // 0')
    disc=$(printf '%s' "$line" | jq -r '.itemCashDiscount // 0')
    item_total=$(printf '%s' "$line" | jq -r '.totalPrice // 0')
    $PSQL -c "
      INSERT INTO accurate_invoice_item (invoice_id, item_id, qty, unit, unit_price, discount_amount, total)
      VALUES ($inv_id, ${item_id:-NULL}, $qty, NULLIF('${unit}',''), $unit_price, $disc, $item_total);
    " >/dev/null 2>>"$LOG_DIR/daily.log"

    # Upsert item master dgn full info (no/name/category/type/unit)
    if [ -n "$item_id" ] && [ "$item_id" != "null" ]; then
      local item_no item_name item_cat_id item_type
      item_no=$(printf '%s' "$line" | jq -r '.item.no // empty' | sed "s/'/''/g")
      item_name=$(printf '%s' "$line" | jq -r '.item.name // empty' | sed "s/'/''/g")
      item_cat_id=$(printf '%s' "$line" | jq -r '.item.itemCategoryId // empty')
      item_type=$(printf '%s' "$line" | jq -r '.item.itemType // empty' | sed "s/'/''/g")
      $PSQL -c "
        INSERT INTO accurate_item (id, no, name, item_category_id, item_type, unit)
        VALUES ($item_id, NULLIF('${item_no}',''), NULLIF('${item_name}',''),
                ${item_cat_id:-NULL}, NULLIF('${item_type}',''), NULLIF('${unit}',''))
        ON CONFLICT (id) DO UPDATE SET
          no=COALESCE(EXCLUDED.no, accurate_item.no),
          name=COALESCE(EXCLUDED.name, accurate_item.name),
          item_category_id=COALESCE(EXCLUDED.item_category_id, accurate_item.item_category_id),
          item_type=COALESCE(EXCLUDED.item_type, accurate_item.item_type),
          unit=COALESCE(EXCLUDED.unit, accurate_item.unit);
      " >/dev/null 2>>"$LOG_DIR/daily.log"
    fi
  done

  log "  accurate: invoice id=$inv_id no='${inv_no:-?}' cust=${cust_name:0:40} tgl=$tgl_iso total=$total"
}

# Single mode
if [ "$MODE" = "single" ]; then
  log "sync_accurate: single invoice id=$INV_ID"
  TMP=$(mktemp -t accurate_inv.XXXXXX.json)
  acc_get "/accurate/api/sales-invoke/detail.do" "id=$INV_ID" >/dev/null 2>&1  # warmup (ignored)
  acc_get "/accurate/api/sales-invoice/detail.do" "id=$INV_ID" > "$TMP"
  if [ "$(jq -r '.s' "$TMP")" != "true" ]; then
    log "  ❌ detail failed: $(jq -c '.d' "$TMP")"
    rm -f "$TMP"
    exit 1
  fi
  process_invoice "$TMP"
  rm -f "$TMP"
  log "sync_accurate done: 1 invoice"
  exit 0
fi

# Incremental: list invoices terbaru (sortBy lastUpdate DESC), iterate detail, stop kalau
# udah ke-sync (cek tanggal < threshold).
log "sync_accurate: incremental last $DAYS days"
THRESHOLD=$(date -v-${DAYS}d +%Y-%m-%d)
PROCESSED=0; PAGE=1

# Default list order is recent-first (id DESC). `sp.sort` field jangan diset
# karena field name yg salah bikin order reversed (old-first), bikin loop
# stop di page 1. Trust default.
# Pakai `fields=id,transDate` di list — hemat: gak perlu detail call hanya
# untuk cek tanggal.
while :; do
  LIST_TMP=$(mktemp -t accurate_list.XXXXXX.json)
  acc_get "/accurate/api/sales-invoice/list.do" \
    "sp.page=${PAGE}&sp.pageSize=50&fields=id,transDate" > "$LIST_TMP"
  if [ "$(jq -r '.s' "$LIST_TMP")" != "true" ]; then
    log "  ❌ list page=$PAGE failed: $(jq -c '.d' "$LIST_TMP")"
    rm -f "$LIST_TMP"
    break
  fi
  COUNT=$(jq '.d | length' "$LIST_TMP")
  [ "$COUNT" = "0" ] && { rm -f "$LIST_TMP"; break; }
  STOP=0
  # Iterate id|transDate pairs
  while IFS='|' read -r ID TGL; do
    [ -z "$ID" ] && continue
    TGL_ISO=$(python3 -c "
from datetime import datetime
try: print(datetime.strptime('$TGL','%d/%m/%Y').strftime('%Y-%m-%d'))
except: pass")
    if [ -n "$TGL_ISO" ] && [[ "$TGL_ISO" < "$THRESHOLD" ]]; then
      log "  stop: id=$ID tgl=$TGL_ISO < threshold $THRESHOLD"
      STOP=1
      break
    fi
    TMP=$(mktemp -t accurate_inv.XXXXXX.json)
    acc_get "/accurate/api/sales-invoice/detail.do" "id=$ID" > "$TMP"
    if [ "$(jq -r '.s' "$TMP")" != "true" ]; then
      rm -f "$TMP"
      continue
    fi
    process_invoice "$TMP"
    rm -f "$TMP"
    PROCESSED=$((PROCESSED + 1))
    sleep 0.15   # rate limit kindness
  done < <(jq -r '.d[] | "\(.id)|\(.transDate)"' "$LIST_TMP")
  rm -f "$LIST_TMP"
  [ "$STOP" = "1" ] && break
  PAGE=$((PAGE + 1))
  [ $PAGE -gt 200 ] && break  # safety: 200 pages × 50 = 10000 invoices
done

# Update sync state
$PSQL -c "
  INSERT INTO accurate_sync_state (entity, last_synced_at, last_run_ok, last_run_summary)
  VALUES ('sales-invoice', NOW(), TRUE, jsonb_build_object('processed', $PROCESSED, 'days', $DAYS))
  ON CONFLICT (entity) DO UPDATE SET
    last_synced_at=NOW(), last_run_ok=TRUE,
    last_run_summary=jsonb_build_object('processed', $PROCESSED, 'days', $DAYS);
" >/dev/null 2>>"$LOG_DIR/daily.log"

log "sync_accurate done: processed=$PROCESSED days=$DAYS"
