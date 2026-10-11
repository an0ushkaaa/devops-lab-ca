#!/usr/bin/env bash
# =============================================================================
# setup-kibana.sh — Provision Kibana objects for devops-lab-ca
#
# Creates:
#   1. Data view  : app-logs-* (timeField: @timestamp)
#   2. Viz 1      : Bar chart  — Request count by HTTP status code over time
#   3. Viz 2      : Line chart — P95 response time over time
#   4. Viz 3      : Data table — Top 10 error messages
#   5. Dashboard  : "App Monitoring" containing all three visualizations
#
# Usage:
#   ./setup-kibana.sh [--help]
#
# Environment overrides (all optional):
#   KIBANA_URL        default: http://localhost:5601
#   MAX_WAIT          seconds to wait for Kibana to be ready  (default: 300)
#   RETRY_INTERVAL    seconds between readiness polls          (default: 5)
#   API_RETRY_COUNT   attempts per API call before giving up   (default: 3)
#   API_RETRY_DELAY   seconds between API retries              (default: 5)
#
# Required tools: curl, python3
# =============================================================================

set -euo pipefail

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
  grep '^#' "$0" | grep -v '#!/' | sed 's/^# \{0,1\}//'
  exit 0
}
[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && usage

# ── Configuration ─────────────────────────────────────────────────────────────
KIBANA_URL="${KIBANA_URL:-http://localhost:5601}"
MAX_WAIT="${MAX_WAIT:-300}"
RETRY_INTERVAL="${RETRY_INTERVAL:-5}"
API_RETRY_COUNT="${API_RETRY_COUNT:-3}"
API_RETRY_DELAY="${API_RETRY_DELAY:-5}"

# ── Fixed object IDs ──────────────────────────────────────────────────────────
# Deterministic IDs mean the script is fully idempotent: re-running it will
# overwrite the objects in-place rather than creating duplicates.
DATA_VIEW_ID="app-logs-dv-001"
VIZ_STATUS_ID="app-logs-viz-status-bar"
VIZ_RESPTIME_ID="app-logs-viz-response-time"
VIZ_ERRORS_ID="app-logs-viz-error-table"
DASHBOARD_ID="app-monitoring-dashboard"

# ── Colours ───────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; NC=''
fi

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()  { echo -e "\n${BOLD}${CYAN}▶ $*${NC}"; }
die()       { log_err "$*"; exit 1; }

# ── Dependency check ──────────────────────────────────────────────────────────
check_deps() {
  local missing=()
  for cmd in curl python3; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  (( ${#missing[@]} == 0 )) || die "Missing required tools: ${missing[*]}"
  log_ok "Dependencies satisfied (curl $(curl --version | head -1 | awk '{print $2}'), python3 $(python3 --version 2>&1 | awk '{print $2}'))"
}

# ── JSON string escaper ───────────────────────────────────────────────────────
# Reads a raw JSON document from stdin; outputs the content escaped as a JSON
# string value (no surrounding quotes).  Used to embed one JSON doc as a
# string field inside another (e.g. visState, panelsJSON, searchSourceJSON).
json_str() {
  python3 -c 'import json,sys; s=sys.stdin.read(); print(json.dumps(s)[1:-1])'
}

# Emit a valid JSON string for the Kibana searchSourceJSON attribute.
# Args: $1 = KQL query string (may be empty), $2 = filter JSON array or ""
make_search_source() {
  local kql_query="$1"
  local filter_json="${2:-[]}"
  python3 - "$kql_query" "$filter_json" << 'PYEOF'
import json, sys
kql_query  = sys.argv[1]
filter_raw = sys.argv[2]
try:
    filters = json.loads(filter_raw)
except Exception:
    filters = []
ss = {
    "query":  {"language": "kuery", "query": kql_query},
    "filter": filters,
    "indexRefName": "kibanaSavedObjectMeta.searchSourceJSON.index"
}
# Output the JSON *string* value (escaped, no outer quotes) for embedding.
print(json.dumps(json.dumps(ss))[1:-1])
PYEOF
}

# ── Temp-file-based HTTP helper ───────────────────────────────────────────────
# Usage: kbn METHOD /path [json_body]
# Writes response body to stdout.
# Returns "CONFLICT" on 409; exits with error on other 4xx/5xx.
kbn() {
  local method="$1"
  local path="$2"
  local body="${3:-}"

  local resp_file
  resp_file=$(mktemp)
  # shellcheck disable=SC2064
  trap "rm -f '$resp_file'" RETURN

  local curl_args=(
    -sS
    -X "$method"
    -H "kbn-xsrf: true"
    -H "Content-Type: application/json"
    -o "$resp_file"
    -w "%{http_code}"
    --max-time 30
    --retry 0            # we handle retries ourselves
  )
  [[ -n "$body" ]] && curl_args+=(-d "$body")

  local http_code
  http_code=$(curl "${curl_args[@]}" "${KIBANA_URL}${path}" 2>&1) || {
    log_err "curl failed for $method $path"
    return 1
  }

  local resp_body
  resp_body=$(cat "$resp_file")

  case "$http_code" in
    2*)
      echo "$resp_body"
      return 0
      ;;
    409)
      echo "CONFLICT"
      return 0
      ;;
    *)
      log_err "HTTP $http_code — $method $KIBANA_URL$path"
      # Pretty-print the error if it is JSON
      local err_msg
      err_msg=$(echo "$resp_body" | python3 -c \
        'import json,sys; d=json.load(sys.stdin); print(d.get("message",d))' 2>/dev/null \
        || echo "$resp_body")
      log_err "Kibana said: $err_msg"
      return 1
      ;;
  esac
}

# ── Retry wrapper ─────────────────────────────────────────────────────────────
# Usage: with_retry DESCRIPTION command [args...]
with_retry() {
  local desc="$1"; shift
  local attempt=1
  until "$@"; do
    if (( attempt >= API_RETRY_COUNT )); then
      die "$desc failed after $API_RETRY_COUNT attempts"
    fi
    log_warn "$desc — attempt $attempt/$API_RETRY_COUNT failed, retrying in ${API_RETRY_DELAY}s..."
    sleep "$API_RETRY_DELAY"
    (( attempt++ ))
  done
}

# ── Upsert helper ─────────────────────────────────────────────────────────────
# Uses ?overwrite=true so the call is always idempotent.
kbn_upsert() {
  local method="$1"
  local path="$2"
  local body="$3"
  local label="$4"

  local resp
  resp=$(with_retry "$label" kbn "$method" "$path" "$body")
  if [[ "$resp" == "CONFLICT" ]]; then
    log_warn "$label already existed — overwritten"
  else
    log_ok "$label"
  fi
}

# ── Wait for Kibana ───────────────────────────────────────────────────────────
wait_for_kibana() {
  log_step "Waiting for Kibana to become available"
  log_info "URL: $KIBANA_URL  |  timeout: ${MAX_WAIT}s  |  poll: ${RETRY_INTERVAL}s"

  local elapsed=0
  local last_level="unknown"

  while true; do
    local raw_status
    raw_status=$(curl -fsSL --max-time 5 \
      -H "kbn-xsrf: true" \
      "${KIBANA_URL}/api/status" 2>/dev/null || true)

    # Kibana is ready when its overall status level is "available"
    if echo "$raw_status" | python3 -c \
        'import json,sys; d=json.load(sys.stdin); exit(0 if d["status"]["overall"]["level"]=="available" else 1)' \
        2>/dev/null; then
      log_ok "Kibana is available (${elapsed}s elapsed)"
      return 0
    fi

    # Extract current status level for informative messages
    last_level=$(echo "$raw_status" | python3 -c \
      'import json,sys; d=json.load(sys.stdin); print(d["status"]["overall"]["level"])' \
      2>/dev/null || echo "unreachable")

    if (( elapsed >= MAX_WAIT )); then
      die "Kibana did not become available within ${MAX_WAIT}s (last status: $last_level)"
    fi

    printf '\r%s' "${YELLOW}[WAIT]${NC}  Kibana status: ${last_level} — ${elapsed}/${MAX_WAIT}s elapsed..."
    sleep "$RETRY_INTERVAL"
    (( elapsed += RETRY_INTERVAL ))
  done
}

# =============================================================================
# STEP 1 — Data View
# =============================================================================
create_data_view() {
  log_step "Step 1/5 — Data view: app-logs-*"

  # Use the saved objects API so we get deterministic ID control and
  # ?overwrite=true idempotency.  The newer /api/data_views endpoint exists
  # in Kibana 8.x but lacks a simple overwrite parameter.
  local payload
  payload=$(cat << JSON
{
  "attributes": {
    "title": "app-logs-*",
    "timeFieldName": "@timestamp",
    "name": "App Logs (devops-lab-ca)"
  }
}
JSON
)

  kbn_upsert POST \
    "/api/saved_objects/index-pattern/${DATA_VIEW_ID}?overwrite=true" \
    "$payload" \
    "Data view 'app-logs-*' (id: ${DATA_VIEW_ID})"
}

# =============================================================================
# STEP 2 — Visualisation helpers
# =============================================================================

# Common structure for the saved-object wrapper around a visualization.
# Args: $1=id  $2=title  $3=visState_escaped  $4=searchSourceJSON_escaped
#       $5=description  $6... extra references (name:type:id triplets)
build_viz_payload() {
  local title="$1"
  local description="$2"
  local vis_state_escaped="$3"
  local search_source_escaped="$4"
  shift 4

  # Build references array (always includes the index-pattern reference)
  local refs='[{"name":"kibanaSavedObjectMeta.searchSourceJSON.index","type":"index-pattern","id":"'"${DATA_VIEW_ID}"'"}'
  while (( $# >= 3 )); do
    refs+=',{"name":"'"$1"'","type":"'"$2"'","id":"'"$3"'"}'
    shift 3
  done
  refs+=']'

  cat << JSON
{
  "attributes": {
    "title": ${title},
    "description": ${description},
    "visState": "${vis_state_escaped}",
    "uiStateJSON": "{}",
    "version": 1,
    "kibanaSavedObjectMeta": {
      "searchSourceJSON": "${search_source_escaped}"
    }
  },
  "references": ${refs}
}
JSON
}

# =============================================================================
# STEP 2a — Bar chart: request count by HTTP status code
# =============================================================================
create_viz_status_bar() {
  log_step "Step 2/5 — Visualisation: Request Count by HTTP Status Code (bar chart)"

  # ── visState ────────────────────────────────────────────────────────────────
  # X-axis : date_histogram on @timestamp (auto interval)
  # Split  : terms on http_status_code (top 10 by count, stacked bars)
  # Metric : count
  local vis_state_raw
  vis_state_raw=$(cat << 'VISSTATE'
{
  "title": "Request Count by HTTP Status Code",
  "type": "histogram",
  "params": {
    "type": "histogram",
    "grid": {"categoryLines": false},
    "categoryAxes": [
      {
        "id": "CategoryAxis-1",
        "type": "category",
        "position": "bottom",
        "show": true,
        "style": {},
        "scale": {"type": "linear"},
        "labels": {"show": true, "filter": true, "truncate": 100},
        "title": {}
      }
    ],
    "valueAxes": [
      {
        "id": "ValueAxis-1",
        "name": "LeftAxis-1",
        "type": "value",
        "position": "left",
        "show": true,
        "style": {},
        "scale": {"type": "linear", "mode": "normal"},
        "labels": {"show": true, "rotate": 0, "filter": false, "truncate": 100},
        "title": {"text": "Request Count"}
      }
    ],
    "seriesParams": [
      {
        "show": true,
        "type": "histogram",
        "mode": "stacked",
        "data": {"label": "Count", "id": "1"},
        "valueAxis": "ValueAxis-1",
        "drawLinesBetweenPoints": true,
        "lineWidth": 2,
        "showCircles": true
      }
    ],
    "addTooltip": true,
    "addLegend": true,
    "legendPosition": "right",
    "times": [],
    "addTimeMarker": false,
    "palette": {"type": "palette", "name": "default"},
    "isVislibVis": true,
    "detailedTooltip": true
  },
  "uiState": {},
  "aggs": [
    {
      "id": "1",
      "enabled": true,
      "type": "count",
      "params": {},
      "schema": "metric"
    },
    {
      "id": "2",
      "enabled": true,
      "type": "date_histogram",
      "params": {
        "field": "@timestamp",
        "timeRange": {"from": "now-1h", "to": "now"},
        "useNormalizedEsInterval": true,
        "scaleMetricValues": false,
        "interval": "auto",
        "drop_partials": false,
        "min_doc_count": 1,
        "extended_bounds": {}
      },
      "schema": "segment"
    },
    {
      "id": "3",
      "enabled": true,
      "type": "terms",
      "params": {
        "field": "http_status_code",
        "orderBy": "1",
        "order": "desc",
        "size": 10,
        "otherBucket": false,
        "otherBucketLabel": "Other",
        "missingBucket": false,
        "missingBucketLabel": "Missing",
        "customLabel": "HTTP Status Code"
      },
      "schema": "group"
    }
  ]
}
VISSTATE
)

  local vis_state_escaped
  vis_state_escaped=$(echo "$vis_state_raw" | json_str)

  # Empty KQL — visualise all log levels (info + warn + error)
  local search_source_escaped
  search_source_escaped=$(make_search_source "" "[]")

  local payload
  payload=$(build_viz_payload \
    '"Request Count by HTTP Status Code"' \
    '"Stacked bar chart: request volume by HTTP status code (2xx/4xx/5xx) over time"' \
    "$vis_state_escaped" \
    "$search_source_escaped")

  kbn_upsert POST \
    "/api/saved_objects/visualization/${VIZ_STATUS_ID}?overwrite=true" \
    "$payload" \
    "Visualisation: Request Count by HTTP Status Code"
}

# =============================================================================
# STEP 2b — Line chart: P95 response time over time
# =============================================================================
create_viz_response_time() {
  log_step "Step 3/5 — Visualisation: P95 Response Time (line chart)"

  # ── visState ────────────────────────────────────────────────────────────────
  # X-axis  : date_histogram on @timestamp (auto interval)
  # Y-axis  : 95th percentile of response_time_ms
  local vis_state_raw
  vis_state_raw=$(cat << 'VISSTATE'
{
  "title": "P95 Response Time (ms)",
  "type": "line",
  "params": {
    "type": "line",
    "grid": {"categoryLines": false},
    "categoryAxes": [
      {
        "id": "CategoryAxis-1",
        "type": "category",
        "position": "bottom",
        "show": true,
        "style": {},
        "scale": {"type": "linear"},
        "labels": {"show": true, "filter": true, "truncate": 100},
        "title": {}
      }
    ],
    "valueAxes": [
      {
        "id": "ValueAxis-1",
        "name": "LeftAxis-1",
        "type": "value",
        "position": "left",
        "show": true,
        "style": {},
        "scale": {"type": "linear", "mode": "normal"},
        "labels": {"show": true, "rotate": 0, "filter": false, "truncate": 100},
        "title": {"text": "Response Time (ms)"}
      }
    ],
    "seriesParams": [
      {
        "show": true,
        "type": "line",
        "mode": "normal",
        "data": {"label": "95th percentile of response_time_ms", "id": "1"},
        "valueAxis": "ValueAxis-1",
        "drawLinesBetweenPoints": true,
        "lineWidth": 2,
        "interpolate": "linear",
        "showCircles": true
      }
    ],
    "addTooltip": true,
    "addLegend": true,
    "legendPosition": "right",
    "times": [],
    "addTimeMarker": false,
    "palette": {"type": "palette", "name": "default"},
    "isVislibVis": true,
    "detailedTooltip": true,
    "truncateLegend": true,
    "maxLegendLines": 1
  },
  "uiState": {},
  "aggs": [
    {
      "id": "1",
      "enabled": true,
      "type": "percentiles",
      "params": {
        "field": "response_time_ms",
        "percents": [95],
        "keyed": false,
        "customLabel": "P95 Response Time (ms)"
      },
      "schema": "metric"
    },
    {
      "id": "2",
      "enabled": true,
      "type": "date_histogram",
      "params": {
        "field": "@timestamp",
        "timeRange": {"from": "now-1h", "to": "now"},
        "useNormalizedEsInterval": true,
        "scaleMetricValues": false,
        "interval": "auto",
        "drop_partials": false,
        "min_doc_count": 1,
        "extended_bounds": {}
      },
      "schema": "segment"
    }
  ]
}
VISSTATE
)

  local vis_state_escaped
  vis_state_escaped=$(echo "$vis_state_raw" | json_str)

  # Filter to events that actually have a response_time_ms value
  # (excludes internal Logstash housekeeping events with no timing data)
  local search_source_escaped
  search_source_escaped=$(make_search_source "response_time_ms: *" "[]")

  local payload
  payload=$(build_viz_payload \
    '"P95 Response Time (ms)"' \
    '"95th-percentile response latency in milliseconds, from the response_time_ms field emitted by the Express request logger"' \
    "$vis_state_escaped" \
    "$search_source_escaped")

  kbn_upsert POST \
    "/api/saved_objects/visualization/${VIZ_RESPTIME_ID}?overwrite=true" \
    "$payload" \
    "Visualisation: P95 Response Time"
}

# =============================================================================
# STEP 2c — Data table: top 10 error messages
# =============================================================================
create_viz_error_table() {
  log_step "Step 4/5 — Visualisation: Top 10 Error Messages (data table)"

  # ── visState ────────────────────────────────────────────────────────────────
  # Row bucket : terms on log_message.keyword (top 10 by count)
  # Metric     : count
  # The KQL filter (log_level: error) is in the searchSourceJSON, not here.
  local vis_state_raw
  vis_state_raw=$(cat << 'VISSTATE'
{
  "title": "Top 10 Error Messages",
  "type": "table",
  "params": {
    "perPage": 10,
    "showPartialRows": false,
    "showMetricsAtAllLevels": false,
    "sort": {"columnIndex": 1, "direction": "desc"},
    "showTotal": false,
    "totalFunc": "sum",
    "colWidth": [],
    "percentageCol": "",
    "row": false
  },
  "uiState": {
    "vis": {
      "params": {
        "sort": {"columnIndex": 1, "direction": "desc"}
      }
    }
  },
  "aggs": [
    {
      "id": "1",
      "enabled": true,
      "type": "count",
      "params": {"customLabel": "Occurrences"},
      "schema": "metric"
    },
    {
      "id": "2",
      "enabled": true,
      "type": "terms",
      "params": {
        "field": "log_message.keyword",
        "orderBy": "1",
        "order": "desc",
        "size": 10,
        "otherBucket": false,
        "otherBucketLabel": "Other",
        "missingBucket": false,
        "missingBucketLabel": "Missing",
        "customLabel": "Error Message"
      },
      "schema": "bucket"
    }
  ]
}
VISSTATE
)

  local vis_state_escaped
  vis_state_escaped=$(echo "$vis_state_raw" | json_str)

  # Build a proper Kibana filter object scoped to error-level events.
  # Using a phrase filter rather than a KQL query string avoids any
  # double-quote escaping issues inside the JSON string chain.
  local error_filter
  error_filter=$(python3 << 'PYEOF'
import json
f = [
    {
        "meta": {
            "alias":    None,
            "negate":   False,
            "disabled": False,
            "type":     "phrase",
            "key":      "log_level",
            "params":   {"query": "error"}
        },
        "query": {"match_phrase": {"log_level": "error"}},
        "$state": {"store": "appState"}
    }
]
print(json.dumps(f))
PYEOF
)

  local search_source_escaped
  search_source_escaped=$(make_search_source "" "$error_filter")

  local payload
  payload=$(build_viz_payload \
    '"Top 10 Error Messages"' \
    '"Data table of the most frequent error-level log messages. Pre-filtered to log_level: error."' \
    "$vis_state_escaped" \
    "$search_source_escaped")

  kbn_upsert POST \
    "/api/saved_objects/visualization/${VIZ_ERRORS_ID}?overwrite=true" \
    "$payload" \
    "Visualisation: Top 10 Error Messages"
}

# =============================================================================
# STEP 3 — Dashboard
# =============================================================================
create_dashboard() {
  log_step "Step 5/5 — Dashboard: App Monitoring"

  # ── Panel layout (48-column grid) ───────────────────────────────────────────
  #
  #   ┌──────────────────────────┬──────────────────────────┐  y=0, h=15
  #   │  Bar: Status Code        │  Line: P95 Response Time │
  #   │  (x=0, w=24)             │  (x=24, w=24)            │
  #   └──────────────────────────┴──────────────────────────┘
  #   ┌─────────────────────────────────────────────────────┐  y=15, h=15
  #   │  Table: Top 10 Error Messages (x=0, w=48)           │
  #   └─────────────────────────────────────────────────────┘
  #
  local panels_raw
  panels_raw=$(cat << 'PANELS'
[
  {
    "version": "8.13.4",
    "type": "visualization",
    "gridData": {"x": 0, "y": 0, "w": 24, "h": 15, "i": "1"},
    "panelIndex": "1",
    "embeddableConfig": {"enhancements": {}},
    "panelRefName": "panel_1",
    "title": "Request Count by HTTP Status Code"
  },
  {
    "version": "8.13.4",
    "type": "visualization",
    "gridData": {"x": 24, "y": 0, "w": 24, "h": 15, "i": "2"},
    "panelIndex": "2",
    "embeddableConfig": {"enhancements": {}},
    "panelRefName": "panel_2",
    "title": "P95 Response Time (ms)"
  },
  {
    "version": "8.13.4",
    "type": "visualization",
    "gridData": {"x": 0, "y": 15, "w": 48, "h": 15, "i": "3"},
    "panelIndex": "3",
    "embeddableConfig": {"enhancements": {}},
    "panelRefName": "panel_3",
    "title": "Top 10 Error Messages"
  }
]
PANELS
)

  local panels_escaped
  panels_escaped=$(echo "$panels_raw" | json_str)

  # Dashboard-level options
  local options_raw='{"useMargins":true,"syncColors":false,"syncCursor":true,"syncTooltips":false,"hidePanelTitles":false}'
  local options_escaped
  options_escaped=$(echo "$options_raw" | json_str)

  # Dashboard-level search source (empty — panels use their own filters)
  local dash_search_source='{"query":{"language":"kuery","query":""},"filter":[]}'
  local dash_search_source_escaped
  dash_search_source_escaped=$(echo "$dash_search_source" | json_str)

  local payload
  payload=$(cat << JSON
{
  "attributes": {
    "title": "App Monitoring",
    "description": "devops-lab-ca — request volume by status code, P95 latency, and top error messages",
    "panelsJSON": "${panels_escaped}",
    "optionsJSON": "${options_escaped}",
    "version": 1,
    "timeRestore": true,
    "timeTo": "now",
    "timeFrom": "now-1h",
    "refreshInterval": {
      "pause": false,
      "value": 30000
    },
    "kibanaSavedObjectMeta": {
      "searchSourceJSON": "${dash_search_source_escaped}"
    }
  },
  "references": [
    {
      "name": "1:panel_1",
      "type": "visualization",
      "id": "${VIZ_STATUS_ID}"
    },
    {
      "name": "2:panel_2",
      "type": "visualization",
      "id": "${VIZ_RESPTIME_ID}"
    },
    {
      "name": "3:panel_3",
      "type": "visualization",
      "id": "${VIZ_ERRORS_ID}"
    }
  ]
}
JSON
)

  kbn_upsert POST \
    "/api/saved_objects/dashboard/${DASHBOARD_ID}?overwrite=true" \
    "$payload" \
    "Dashboard: App Monitoring"
}

# =============================================================================
# Summary
# =============================================================================
print_summary() {
  echo ""
  echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════${NC}"
  echo -e "${GREEN}${BOLD}  Kibana provisioning complete!${NC}"
  echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════${NC}"
  echo ""
  echo -e "  ${BOLD}Objects created / updated${NC}"
  echo -e "  ├─ Data view   : app-logs-* (id: ${DATA_VIEW_ID})"
  echo -e "  ├─ Viz 1       : Request Count by HTTP Status Code"
  echo -e "  ├─ Viz 2       : P95 Response Time (ms)"
  echo -e "  ├─ Viz 3       : Top 10 Error Messages"
  echo -e "  └─ Dashboard   : App Monitoring"
  echo ""
  echo -e "  ${BOLD}Quick links${NC}"
  echo -e "  ┌─ Dashboard:"
  echo -e "  │  ${CYAN}${KIBANA_URL}/app/dashboards#/view/${DASHBOARD_ID}${NC}"
  echo -e "  ├─ Discover (app-logs-*):"
  echo -e "  │  ${CYAN}${KIBANA_URL}/app/discover#/?_a=(index:'${DATA_VIEW_ID}')${NC}"
  echo -e "  └─ All saved objects:"
  echo -e "     ${CYAN}${KIBANA_URL}/app/management/kibana/objects${NC}"
  echo ""
  echo -e "  ${BOLD}Generate test data${NC}"
  echo -e "  curl http://localhost:3000/health"
  echo -e "  curl http://localhost:3000/products"
  echo -e "  curl -X POST http://localhost:3000/products \\"
  echo -e "       -H 'Content-Type: application/json' \\"
  echo -e "       -d '{\"name\":\"Widget\",\"price\":9.99}'"
  echo -e "  curl http://localhost:3000/error   # produces error-level log"
  echo ""
}

# =============================================================================
# Main
# =============================================================================
main() {
  echo ""
  echo -e "${BOLD}╔════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}║   Kibana Setup Script — devops-lab-ca              ║${NC}"
  echo -e "${BOLD}╚════════════════════════════════════════════════════╝${NC}"
  echo -e "  Kibana URL   : ${CYAN}${KIBANA_URL}${NC}"
  echo -e "  Max wait     : ${MAX_WAIT}s"
  echo -e "  Poll interval: ${RETRY_INTERVAL}s"
  echo -e "  API retries  : ${API_RETRY_COUNT} (delay: ${API_RETRY_DELAY}s)"
  echo ""

  check_deps
  wait_for_kibana
  create_data_view
  create_viz_status_bar
  create_viz_response_time
  create_viz_error_table
  create_dashboard
  print_summary
}

main "$@"
