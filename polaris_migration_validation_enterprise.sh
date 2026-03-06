#!/usr/bin/env bash

###############################################################################
# Polaris Migration Validation - Enterprise Bash Script
# Compares OLD Synopsys Polaris tenant vs NEW Black Duck Polaris tenant
#
# Features:
# - auto-detect auth mode
# - auto-detect issues endpoint from common candidates
# - paginated fetch
# - normalized comparison with line tolerance
# - HTML report with charts
# - verbose stage-by-stage echo logging
#
# Required positional inputs:
#   $1 = OLD_PROJECT_ID
#   $2 = NEW_PROJECT_ID
#   $3 = CODE_REPO_BRANCH   (used for both old and new scans)
#
# Required env vars:
#   OLD_BASE_URL, OLD_API_TOKEN
#   NEW_BASE_URL, NEW_API_TOKEN
#
# Optional env vars:
#   PAGE_SIZE (default 500)
#   LINE_TOLERANCE (default 1)
#   OUTPUT_DIR (default ./polaris_compare_output)
#   OLD_AUTH_MODE / NEW_AUTH_MODE: auto | bearer | api_token
#   OLD_AUTH_ENDPOINT / NEW_AUTH_ENDPOINT
#   OLD_ISSUES_ENDPOINT / NEW_ISSUES_ENDPOINT
###############################################################################

set -Eeuo pipefail

#######################################
# Stage 0: helpers
#######################################
echo "=================================================="
echo "STAGE 0: Loading helper functions"
echo "This stage prepares logging, validation, and HTTP helpers."
echo "=================================================="

timestamp() { date +"%Y-%m-%d %H:%M:%S"; }
log() { echo "[$(timestamp)] $*"; }
fail() { echo "[$(timestamp)] ERROR: $*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

trim_slash() {
  local v="$1"
  echo "${v%/}"
}

#######################################
# Stage 1: validate dependencies and inputs
#######################################
echo
echo "=================================================="
echo "STAGE 1: Validating prerequisites and pipeline inputs"
echo "This stage checks required binaries, environment variables, and input arguments."
echo "=================================================="

require_cmd curl
require_cmd jq
require_cmd python3

OLD_BASE_URL="${OLD_BASE_URL:-}"
OLD_API_TOKEN="${OLD_API_TOKEN:-}"
NEW_BASE_URL="${NEW_BASE_URL:-}"
NEW_API_TOKEN="${NEW_API_TOKEN:-}"

OLD_PROJECT_ID="${1:-}"
NEW_PROJECT_ID="${2:-}"
CODE_REPO_BRANCH="${3:-}"

[[ -n "$OLD_BASE_URL" ]] || fail "OLD_BASE_URL env var is required"
[[ -n "$OLD_API_TOKEN" ]] || fail "OLD_API_TOKEN env var is required"
[[ -n "$NEW_BASE_URL" ]] || fail "NEW_BASE_URL env var is required"
[[ -n "$NEW_API_TOKEN" ]] || fail "NEW_API_TOKEN env var is required"

[[ -n "$OLD_PROJECT_ID" ]] || fail "OLD_PROJECT_ID must be passed as argument 1"
[[ -n "$NEW_PROJECT_ID" ]] || fail "NEW_PROJECT_ID must be passed as argument 2"
[[ -n "$CODE_REPO_BRANCH" ]] || fail "CODE_REPO_BRANCH must be passed as argument 3"

OLD_BASE_URL="$(trim_slash "$OLD_BASE_URL")"
NEW_BASE_URL="$(trim_slash "$NEW_BASE_URL")"

OLD_BRANCH="$CODE_REPO_BRANCH"
NEW_BRANCH="$CODE_REPO_BRANCH"

PAGE_SIZE="${PAGE_SIZE:-500}"
LINE_TOLERANCE="${LINE_TOLERANCE:-1}"
OUTPUT_DIR="${OUTPUT_DIR:-./polaris_compare_output}"

OLD_AUTH_MODE="${OLD_AUTH_MODE:-auto}"   # auto | bearer | api_token
NEW_AUTH_MODE="${NEW_AUTH_MODE:-auto}"

OLD_AUTH_ENDPOINT="${OLD_AUTH_ENDPOINT:-}"
NEW_AUTH_ENDPOINT="${NEW_AUTH_ENDPOINT:-}"

OLD_ISSUES_ENDPOINT="${OLD_ISSUES_ENDPOINT:-}"
NEW_ISSUES_ENDPOINT="${NEW_ISSUES_ENDPOINT:-}"

mkdir -p "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/tmp"

log "Dependencies validated"
log "Old project ID: $OLD_PROJECT_ID"
log "New project ID: $NEW_PROJECT_ID"
log "Shared code repo branch for both tenants: $CODE_REPO_BRANCH"
log "Output directory: $OUTPUT_DIR"
log "Page size: $PAGE_SIZE"
log "Line tolerance: +/-$LINE_TOLERANCE"

#######################################
# Stage 2: define endpoint candidates
#######################################
echo
echo "=================================================="
echo "STAGE 2: Preparing endpoint candidates"
echo "This stage defines common auth and issues endpoints to try."
echo "=================================================="

AUTH_CANDIDATES_DEFAULT=(
  "/api/auth/v2/authenticate"
  "/api/tokens/authenticate"
  "/api/auth/authenticate"
)

ISSUES_CANDIDATES_DEFAULT=(
  "/issues"
  "/api/issues"
  "/api/coverity/issues"
)

log "Prepared common auth endpoint candidates"
log "Prepared common issues endpoint candidates"

#######################################
# Stage 3: HTTP helpers
#######################################
echo
echo "=================================================="
echo "STAGE 3: Initializing HTTP helper functions"
echo "This stage sets up reusable API request logic."
echo "=================================================="

http_get() {
  local url="$1"
  local auth_header_name="$2"
  local auth_header_value="$3"
  local out_file="$4"

  curl -sS \
    -H "Accept: application/json" \
    -H "$auth_header_name: $auth_header_value" \
    "$url" \
    -o "$out_file" \
    -w "%{http_code}"
}

http_post_json() {
  local url="$1"
  local auth_header_name="$2"
  local auth_header_value="$3"
  local body="$4"
  local out_file="$5"

  curl -sS \
    -X POST \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    -H "$auth_header_name: $auth_header_value" \
    -d "$body" \
    "$url" \
    -o "$out_file" \
    -w "%{http_code}"
}

http_post_no_body() {
  local url="$1"
  local auth_header_name="$2"
  local auth_header_value="$3"
  local out_file="$4"

  curl -sS \
    -X POST \
    -H "Accept: application/json" \
    -H "$auth_header_name: $auth_header_value" \
    "$url" \
    -o "$out_file" \
    -w "%{http_code}"
}

#######################################
# Stage 4: auth discovery
#######################################
echo
echo "=================================================="
echo "STAGE 4: Discovering authentication method"
echo "This stage determines whether the tenant accepts:"
echo "  - Authorization: Bearer <JWT>"
echo "  - direct Api-token header"
echo "and optionally exchanges an access token for a JWT."
echo "=================================================="

get_bearer_token() {
  local base_url="$1"
  local api_token="$2"
  local auth_mode="$3"
  local auth_endpoint_override="$4"
  local prefix="$5"

  local auth_resp="$OUTPUT_DIR/tmp/${prefix}_auth_response.json"
  local jwt=""

  if [[ "$auth_mode" == "api_token" ]]; then
    echo ""
    return 0
  fi

  local candidates=()
  if [[ -n "$auth_endpoint_override" ]]; then
    candidates+=("$auth_endpoint_override")
  else
    candidates=("${AUTH_CANDIDATES_DEFAULT[@]}")
  fi

  for ep in "${candidates[@]}"; do
    local url="${base_url}${ep}"
    log "$prefix: Trying auth endpoint $url using direct token header"

    local code
    code="$(http_post_no_body "$url" "Api-token" "$api_token" "$auth_resp" || true)"
    if [[ "$code" =~ ^2 ]]; then
      jwt="$(jq -r '.jwt // .token // .bearerToken // .access_token // .data.jwt // .data.token // empty' "$auth_resp")"
      if [[ -n "$jwt" ]]; then
        log "$prefix: JWT retrieved successfully"
        echo "$jwt"
        return 0
      fi
    fi

    for body in \
      "{\"apiToken\":\"$api_token\"}" \
      "{\"accessToken\":\"$api_token\"}" \
      "{\"token\":\"$api_token\"}"; do
      log "$prefix: Trying auth endpoint $url using JSON body exchange"
      code="$(http_post_json "$url" "Accept" "application/json" "$body" "$auth_resp" || true)"
      if [[ "$code" =~ ^2 ]]; then
        jwt="$(jq -r '.jwt // .token // .bearerToken // .access_token // .data.jwt // .data.token // empty' "$auth_resp")"
        if [[ -n "$jwt" ]]; then
          log "$prefix: JWT retrieved successfully"
          echo "$jwt"
          return 0
        fi
      fi
    done
  done

  if [[ "$auth_mode" == "bearer" ]]; then
    fail "$prefix: AUTH mode forced to bearer, but JWT exchange failed"
  fi

  log "$prefix: JWT exchange not available; will fall back to direct Api-token auth"
  echo ""
}

#######################################
# Stage 5: auth initialization
#######################################
echo
echo "=================================================="
echo "STAGE 5: Initializing tenant authentication"
echo "This stage prepares final auth headers for both tenants."
echo "=================================================="

OLD_BEARER="$(get_bearer_token "$OLD_BASE_URL" "$OLD_API_TOKEN" "$OLD_AUTH_MODE" "$OLD_AUTH_ENDPOINT" "OLD")"
NEW_BEARER="$(get_bearer_token "$NEW_BASE_URL" "$NEW_API_TOKEN" "$NEW_AUTH_MODE" "$NEW_AUTH_ENDPOINT" "NEW")"

if [[ -n "$OLD_BEARER" ]]; then
  OLD_AUTH_HEADER_NAME="Authorization"
  OLD_AUTH_HEADER_VALUE="Bearer $OLD_BEARER"
  log "OLD: Using Authorization Bearer"
else
  OLD_AUTH_HEADER_NAME="Api-token"
  OLD_AUTH_HEADER_VALUE="$OLD_API_TOKEN"
  log "OLD: Using Api-token header"
fi

if [[ -n "$NEW_BEARER" ]]; then
  NEW_AUTH_HEADER_NAME="Authorization"
  NEW_AUTH_HEADER_VALUE="Bearer $NEW_BEARER"
  log "NEW: Using Authorization Bearer"
else
  NEW_AUTH_HEADER_NAME="Api-token"
  NEW_AUTH_HEADER_VALUE="$NEW_API_TOKEN"
  log "NEW: Using Api-token header"
fi

#######################################
# Stage 6: issues endpoint discovery
#######################################
echo
echo "=================================================="
echo "STAGE 6: Discovering issues API endpoint"
echo "This stage tests common issues endpoints and selects the working one."
echo "=================================================="

discover_issues_endpoint() {
  local base_url="$1"
  local project_id="$2"
  local auth_header_name="$3"
  local auth_header_value="$4"
  local endpoint_override="$5"
  local prefix="$6"

  local test_resp="$OUTPUT_DIR/tmp/${prefix}_issues_probe.json"

  local candidates=()
  if [[ -n "$endpoint_override" ]]; then
    candidates+=("$endpoint_override")
  else
    candidates=("${ISSUES_CANDIDATES_DEFAULT[@]}")
  fi

  for ep in "${candidates[@]}"; do
    local url="${base_url}${ep}?projectId=${project_id}&limit=1&offset=0"
    log "$prefix: Probing issues endpoint $url"
    local code
    code="$(http_get "$url" "$auth_header_name" "$auth_header_value" "$test_resp" || true)"

    if [[ "$code" =~ ^2 ]]; then
      if jq -e 'type=="array" or (.items? != null) or (.issues? != null) or (.data? != null)' "$test_resp" >/dev/null 2>&1; then
        log "$prefix: Working issues endpoint found: $ep"
        echo "$ep"
        return 0
      fi
    fi
  done

  fail "$prefix: Could not discover a working issues endpoint. Set ${prefix}_ISSUES_ENDPOINT explicitly."
}

OLD_ISSUES_ENDPOINT="$(discover_issues_endpoint "$OLD_BASE_URL" "$OLD_PROJECT_ID" "$OLD_AUTH_HEADER_NAME" "$OLD_AUTH_HEADER_VALUE" "$OLD_ISSUES_ENDPOINT" "OLD")"
NEW_ISSUES_ENDPOINT="$(discover_issues_endpoint "$NEW_BASE_URL" "$NEW_PROJECT_ID" "$NEW_AUTH_HEADER_NAME" "$NEW_AUTH_HEADER_VALUE" "$NEW_ISSUES_ENDPOINT" "NEW")"

#######################################
# Stage 7: paginated issue download
#######################################
echo
echo "=================================================="
echo "STAGE 7: Fetching all issues with pagination"
echo "This stage downloads all findings from each tenant."
echo "=================================================="

fetch_all_issues() {
  local base_url="$1"
  local project_id="$2"
  local branch="$3"
  local auth_header_name="$4"
  local auth_header_value="$5"
  local issues_endpoint="$6"
  local prefix="$7"

  local combined="$OUTPUT_DIR/${prefix,,}_issues_raw.json"
  local page_file
  local offset=0
  local page_num=1

  echo "[]" > "$combined"

  while true; do
    page_file="$OUTPUT_DIR/tmp/${prefix,,}_page_${page_num}.json"

    local url="${base_url}${issues_endpoint}?projectId=${project_id}&limit=${PAGE_SIZE}&offset=${offset}"
    if [[ -n "$branch" ]]; then
      url="${url}&branch=${branch}"
    fi

    log "$prefix: Downloading page $page_num with offset=$offset"
    local code
    code="$(http_get "$url" "$auth_header_name" "$auth_header_value" "$page_file" || true)"

    [[ "$code" =~ ^2 ]] || fail "$prefix: API download failed for page $page_num. HTTP $code"

    local page_count
    page_count="$(jq -r '
      if type=="array" then length
      elif .items then (.items|length)
      elif .issues then (.issues|length)
      elif .data then (.data|length)
      else 0 end
    ' "$page_file")"

    log "$prefix: Page $page_num returned $page_count findings"

    jq -s '
      .[0] + (
        if .[1]|type=="array" then .[1]
        elif .[1].items then .[1].items
        elif .[1].issues then .[1].issues
        elif .[1].data then .[1].data
        else [] end
      )
    ' "$combined" "$page_file" > "${combined}.tmp"

    mv "${combined}.tmp" "$combined"

    if [[ "$page_count" -lt "$PAGE_SIZE" ]]; then
      log "$prefix: Final page reached"
      break
    fi

    offset=$((offset + PAGE_SIZE))
    page_num=$((page_num + 1))
  done

  local total
  total="$(jq 'length' "$combined")"
  log "$prefix: Total findings downloaded: $total"
}

fetch_all_issues "$OLD_BASE_URL" "$OLD_PROJECT_ID" "$OLD_BRANCH" "$OLD_AUTH_HEADER_NAME" "$OLD_AUTH_HEADER_VALUE" "$OLD_ISSUES_ENDPOINT" "OLD"
fetch_all_issues "$NEW_BASE_URL" "$NEW_PROJECT_ID" "$NEW_BRANCH" "$NEW_AUTH_HEADER_NAME" "$NEW_AUTH_HEADER_VALUE" "$NEW_ISSUES_ENDPOINT" "NEW"

#######################################
# Stage 8: normalize findings
#######################################
echo
echo "=================================================="
echo "STAGE 8: Normalizing findings"
echo "This stage extracts checker, CWE, severity, file path, and line number"
echo "into a consistent comparison shape."
echo "=================================================="

python3 - "$OUTPUT_DIR" <<'PY'
import json, csv, os, re, sys

out_dir = sys.argv[1]

def norm_path(p):
    if not p:
        return ""
    p = p.replace("\\", "/").strip()
    p = re.sub(r"/+", "/", p)
    p = re.sub(r"^\./", "", p)
    p = re.sub(r"^/home/[^/]+/[^/]+/", "", p)
    p = re.sub(r"^[A-Za-z]:/[^/]+/[^/]+/", "", p)
    return p.lower()

def extract(issue):
    loc = issue.get("primaryLocation") or issue.get("location") or {}
    checker = str(issue.get("checkerName") or issue.get("checker") or issue.get("checkerKey") or issue.get("checker_id") or "").strip()
    cwe = str(issue.get("cwe") or issue.get("cweId") or issue.get("cwe_id") or issue.get("weakness") or issue.get("weaknessId") or "").strip()
    sev = str(issue.get("severity") or issue.get("issueSeverity") or "").strip().upper()
    file_path = str(loc.get("filePath") or loc.get("file") or issue.get("filePath") or issue.get("file") or "").strip()
    try:
        line = int(loc.get("line") or issue.get("line") or issue.get("lineNumber") or 0)
    except Exception:
        line = 0
    return [checker, cwe, sev, norm_path(file_path), line]

for prefix in ("old", "new"):
    raw = os.path.join(out_dir, f"{prefix}_issues_raw.json")
    csv_path = os.path.join(out_dir, f"{prefix}_issues_normalized.csv")
    with open(raw, "r", encoding="utf-8") as f:
        data = json.load(f)
    with open(csv_path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["checker", "cwe", "severity", "file", "line"])
        for issue in data:
            w.writerow(extract(issue))
PY

log "Normalized CSV files created:"
log " - $OUTPUT_DIR/old_issues_normalized.csv"
log " - $OUTPUT_DIR/new_issues_normalized.csv"

#######################################
# Stage 9: compare with line tolerance
#######################################
echo
echo "=================================================="
echo "STAGE 9: Comparing findings with line tolerance"
echo "This stage performs strict matching and weak matching."
echo "=================================================="

python3 - "$OUTPUT_DIR" "$LINE_TOLERANCE" <<'PY'
import csv, os, sys, json
from collections import defaultdict, Counter

out_dir = sys.argv[1]
tol = int(sys.argv[2])

def read_csv(path):
    rows = []
    with open(path, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            row["line"] = int(row["line"] or 0)
            rows.append(row)
    return rows

old_rows = read_csv(os.path.join(out_dir, "old_issues_normalized.csv"))
new_rows = read_csv(os.path.join(out_dir, "new_issues_normalized.csv"))

strict_index = defaultdict(list)
weak_index = defaultdict(list)

for r in new_rows:
    strict_index[(r["checker"], r["cwe"], r["severity"], r["file"])].append(r)
    weak_index[(r["checker"], r["cwe"], r["file"])].append(r)

matched = []
missing = []
weak_matched = []
used_new = set()

for o in old_rows:
    candidates = strict_index[(o["checker"], o["cwe"], o["severity"], o["file"])]
    found = None
    for n in candidates:
        nid = id(n)
        if nid in used_new:
            continue
        if abs(n["line"] - o["line"]) <= tol:
            found = n
            used_new.add(nid)
            break
    if found:
        matched.append({"old": o, "new": found})
    else:
        missing.append(o)

remaining_new = []
for n in new_rows:
    if id(n) not in used_new:
        remaining_new.append(n)

for o in missing[:]:
    candidates = weak_index[(o["checker"], o["cwe"], o["file"])]
    found = None
    for n in candidates:
        if abs(n["line"] - o["line"]) <= tol:
            found = n
            break
    if found:
        weak_matched.append({
            "old_checker": o["checker"],
            "old_cwe": o["cwe"],
            "old_severity": o["severity"],
            "old_file": o["file"],
            "old_line": o["line"],
            "new_severity": found["severity"],
            "new_line": found["line"],
        })

def write_csv(path, rows, headers):
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=headers)
        w.writeheader()
        for r in rows:
            w.writerow(r)

write_csv(os.path.join(out_dir, "missing_findings.csv"), missing,
          ["checker", "cwe", "severity", "file", "line"])
write_csv(os.path.join(out_dir, "new_only_findings.csv"), remaining_new,
          ["checker", "cwe", "severity", "file", "line"])
write_csv(os.path.join(out_dir, "weak_matches.csv"), weak_matched,
          ["old_checker", "old_cwe", "old_severity", "old_file", "old_line", "new_severity", "new_line"])

summary = {
    "old_total": len(old_rows),
    "new_total": len(new_rows),
    "matched_strict": len(matched),
    "missing": len(missing),
    "new_only": len(remaining_new),
    "weak_matches": len(weak_matched),
    "line_tolerance": tol,
    "old_severity_counts": dict(Counter(r["severity"] or "UNKNOWN" for r in old_rows)),
    "new_severity_counts": dict(Counter(r["severity"] or "UNKNOWN" for r in new_rows)),
    "old_cwe_counts": dict(Counter(r["cwe"] or "UNKNOWN" for r in old_rows)),
    "new_cwe_counts": dict(Counter(r["cwe"] or "UNKNOWN" for r in new_rows)),
}

with open(os.path.join(out_dir, "summary.json"), "w", encoding="utf-8") as f:
    json.dump(summary, f, indent=2)
PY

log "Comparison completed"
log "Summary JSON created: $OUTPUT_DIR/summary.json"

#######################################
# Stage 10: generate interactive HTML
#######################################
echo
echo "=================================================="
echo "STAGE 10: Generating interactive HTML report"
echo "This stage creates a shareable migration dashboard."
echo "=================================================="

python3 - "$OUTPUT_DIR" <<'PY'
import csv, json, os, sys
from html import escape

out_dir = sys.argv[1]
summary_path = os.path.join(out_dir, "summary.json")
report_path = os.path.join(out_dir, "migration_validation_report.html")

with open(summary_path, "r", encoding="utf-8") as f:
    s = json.load(f)

def read_csv(path):
    if not os.path.exists(path):
        return []
    with open(path, newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))

missing = read_csv(os.path.join(out_dir, "missing_findings.csv"))
new_only = read_csv(os.path.join(out_dir, "new_only_findings.csv"))
weak = read_csv(os.path.join(out_dir, "weak_matches.csv"))

sev_labels = sorted(set(s["old_severity_counts"].keys()) | set(s["new_severity_counts"].keys()))
old_sev = [s["old_severity_counts"].get(k, 0) for k in sev_labels]
new_sev = [s["new_severity_counts"].get(k, 0) for k in sev_labels]

top_cwes = sorted(
    set(list(s["old_cwe_counts"].keys())[:15] + list(s["new_cwe_counts"].keys())[:15])
)[:15]
old_cwe = [s["old_cwe_counts"].get(k, 0) for k in top_cwes]
new_cwe = [s["new_cwe_counts"].get(k, 0) for k in top_cwes]

def table(rows, max_rows=200):
    if not rows:
        return "<p><i>None</i></p>"
    headers = rows[0].keys()
    html = ["<table><thead><tr>"]
    for h in headers:
        html.append(f"<th>{escape(str(h))}</th>")
    html.append("</tr></thead><tbody>")
    for r in rows[:max_rows]:
        html.append("<tr>")
        for h in headers:
            html.append(f"<td>{escape(str(r.get(h,'')))}</td>")
        html.append("</tr>")
    html.append("</tbody></table>")
    return "".join(html)

html = f"""
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>Polaris Migration Validation Report</title>
<script src="https://cdn.plot.ly/plotly-3.4.0.min.js"></script>
<style>
body {{ font-family: Arial, sans-serif; margin: 24px; }}
h1, h2 {{ margin-bottom: 8px; }}
table {{ border-collapse: collapse; width: 100%; margin: 12px 0; }}
th, td {{ border: 1px solid #ddd; padding: 8px; font-size: 13px; text-align: left; }}
th {{ background: #f2f2f2; }}
.card {{ border: 1px solid #ddd; border-radius: 8px; padding: 16px; margin-bottom: 16px; }}
.grid {{ display: grid; grid-template-columns: repeat(3, 1fr); gap: 12px; }}
.metric {{ font-size: 28px; font-weight: bold; }}
.small {{ color: #666; font-size: 12px; }}
</style>
</head>
<body>

<h1>Polaris Migration Validation Report</h1>
<p class="small">Generated from OLD Synopsys tenant vs NEW Black Duck tenant comparison.</p>
<p class="small">Compared branch across both tenants: branch supplied as pipeline input parameter.</p>

<div class="grid">
  <div class="card"><div>Old findings</div><div class="metric">{s['old_total']}</div></div>
  <div class="card"><div>New findings</div><div class="metric">{s['new_total']}</div></div>
  <div class="card"><div>Strict matches</div><div class="metric">{s['matched_strict']}</div></div>
</div>

<div class="grid">
  <div class="card"><div>Missing in new</div><div class="metric">{s['missing']}</div></div>
  <div class="card"><div>New-only findings</div><div class="metric">{s['new_only']}</div></div>
  <div class="card"><div>Weak matches</div><div class="metric">{s['weak_matches']}</div></div>
</div>

<div class="card">
  <h2>Severity Distribution</h2>
  <div id="sev_chart"></div>
</div>

<div class="card">
  <h2>Top CWE Distribution</h2>
  <div id="cwe_chart"></div>
</div>

<div class="card">
  <h2>Missing Findings</h2>
  {table(missing)}
</div>

<div class="card">
  <h2>New-only Findings</h2>
  {table(new_only)}
</div>

<div class="card">
  <h2>Weak Matches</h2>
  {table(weak)}
</div>

<script>
Plotly.newPlot("sev_chart", [
  {{ x: {sev_labels}, y: {old_sev}, type: "bar", name: "Old (Synopsys)" }},
  {{ x: {sev_labels}, y: {new_sev}, type: "bar", name: "New (Black Duck)" }}
], {{ barmode: "group", title: "Severity comparison" }});

Plotly.newPlot("cwe_chart", [
  {{ x: {top_cwes}, y: {old_cwe}, type: "bar", name: "Old (Synopsys)" }},
  {{ x: {top_cwes}, y: {new_cwe}, type: "bar", name: "New (Black Duck)" }}
], {{ barmode: "group", title: "Top CWE comparison" }});
</script>

</body>
</html>
"""

with open(report_path, "w", encoding="utf-8") as f:
    f.write(html)
PY

log "HTML report created: $OUTPUT_DIR/migration_validation_report.html"

#######################################
# Stage 11: final summary
#######################################
echo
echo "=================================================="
echo "STAGE 11: Printing final migration summary"
echo "This stage shows the key results in the console."
echo "=================================================="

OLD_TOTAL="$(jq -r '.old_total' "$OUTPUT_DIR/summary.json")"
NEW_TOTAL="$(jq -r '.new_total' "$OUTPUT_DIR/summary.json")"
MATCHED_STRICT="$(jq -r '.matched_strict' "$OUTPUT_DIR/summary.json")"
MISSING="$(jq -r '.missing' "$OUTPUT_DIR/summary.json")"
NEW_ONLY="$(jq -r '.new_only' "$OUTPUT_DIR/summary.json")"
WEAK_MATCHES="$(jq -r '.weak_matches' "$OUTPUT_DIR/summary.json")"

echo "Old project ID       : $OLD_PROJECT_ID"
echo "New project ID       : $NEW_PROJECT_ID"
echo "Shared branch        : $CODE_REPO_BRANCH"
echo "Old findings         : $OLD_TOTAL"
echo "New findings         : $NEW_TOTAL"
echo "Strict matches       : $MATCHED_STRICT"
echo "Missing in new       : $MISSING"
echo "New-only findings    : $NEW_ONLY"
echo "Weak matches         : $WEAK_MATCHES"
echo "Line tolerance       : +/-$LINE_TOLERANCE"
echo
echo "Artifacts generated:"
echo " - $OUTPUT_DIR/old_issues_raw.json"
echo " - $OUTPUT_DIR/new_issues_raw.json"
echo " - $OUTPUT_DIR/old_issues_normalized.csv"
echo " - $OUTPUT_DIR/new_issues_normalized.csv"
echo " - $OUTPUT_DIR/missing_findings.csv"
echo " - $OUTPUT_DIR/new_only_findings.csv"
echo " - $OUTPUT_DIR/weak_matches.csv"
echo " - $OUTPUT_DIR/summary.json"
echo " - $OUTPUT_DIR/migration_validation_report.html"
echo
echo "Migration validation script completed successfully."

