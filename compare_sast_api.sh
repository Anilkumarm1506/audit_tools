#!/usr/bin/env bash
set -euo pipefail

# Minimal deps: bash, curl, jq, python3
# Usage:
#   ./compare_sast_api.sh <PROJECT_ID> [--branch <NAME>] [--cov-branch <NAME>] [--pol-branch <NAME>]
# Notes:
#   --branch sets BOTH --cov-branch and --pol-branch unless they are explicitly provided.
#   Env required: COVERITY_URL, (COV_USER_PASS or COVERITY_AUTH), POLARIS_URL, POLARIS_TOKEN
#
# Coverity issues via /api/v2/issues/search (latest snapshot)  [Synopsys KB example].  [1]
# Polaris SAST issues via Tests + Findings APIs (latest test for branch).             [2][3][4]
# [1] https://sig-synopsys.my.site.com/community/s/article/Coverity-REST-API-example-snapshot-issues
# [2] https://polaris.blackduck.com/developer/default/documentation/c_api-intro
# [3] https://polaris.blackduck.com/developer/default/documentation/t_api-quickstart
# [4] https://documentation.blackduck.com/bundle/polaris-docs/page/polaris/documentation/t_how-to-export-issues.html

# ---- Parse args ----
PROJECT_ID="${1:-}"
[ -n "${PROJECT_ID}" ] || { echo "Usage: $0 <PROJECT_ID> [--branch <NAME>] [--cov-branch <NAME>] [--pol-branch <NAME>]"; exit 1; }
shift || true

COV_BRANCH_FILTER=""
POL_BRANCH_FILTER=""
BOTH_BRANCH=""

while [ "${1:-}" != "" ]; do
  case "$1" in
    --branch)
      shift; BOTH_BRANCH="${1:-}"; [ -n "$BOTH_BRANCH" ] || { echo "--branch requires a value"; exit 1; }
      ;;
    --cov-branch)
      shift; COV_BRANCH_FILTER="${1:-}"; [ -n "$COV_BRANCH_FILTER" ] || { echo "--cov-branch requires a value"; exit 1; }
      ;;
    --pol-branch)
      shift; POL_BRANCH_FILTER="${1:-}"; [ -n "$POL_BRANCH_FILTER" ] || { echo "--pol-branch requires a value"; exit 1; }
      ;;
    -*)
      echo "Unknown option: $1"; exit 1;;
    *)
      echo "Unexpected positional arg: $1"; exit 1;;
  esac
  shift || true
done

# Apply --branch default to both sides if specific flags weren’t used
if [ -n "$BOTH_BRANCH" ]; then
  : "${COV_BRANCH_FILTER:=$BOTH_BRANCH}"
  : "${POL_BRANCH_FILTER:=$BOTH_BRANCH}"
fi

# --------- Config from environment ----------
: "${COVERITY_URL:?Set COVERITY_URL}"
: "${POLARIS_URL:?Set POLARIS_URL}"
: "${POLARIS_TOKEN:?Set POLARIS_TOKEN}"

COV_CURL_AUTH=()
if [ -n "${COV_USER_PASS:-}" ]; then
  COV_CURL_AUTH=(-u "${COV_USER_PASS}")
elif [ -n "${COVERITY_AUTH:-}" ]; then
  COV_CURL_AUTH+=( -H "Authorization: Basic ${COVERITY_AUTH}" )
else
  echo "Set COV_USER_PASS=user:pass or COVERITY_AUTH=base64(user:pass) for Coverity auth"; exit 1
fi

TMP="$(mktemp -d)"
COV_JSON="$TMP/coverity.json"
POL_JSON="$TMP/polaris.json"
OUT_HTML="comparison_report.html"

# --------- Coverity: streams for project (optionally match branch) ------
# Reference: /api/v2/issues/search usage from Synopsys KB.  [1]  [1](https://sig-synopsys.my.site.com/community/s/article/Coverity-REST-API-example-snapshot-issues)
STREAMS_JSON="$(curl -sS "${COV_CURL_AUTH[@]}" -H 'Accept: application/json' \
  "${COVERITY_URL%/}/api/v2/projects?offset=0&rowCount=1000")"

if [ -n "$COV_BRANCH_FILTER" ]; then
  STREAM_NAMES="$(printf "%s" "$STREAMS_JSON" \
    | jq -r --arg P "$PROJECT_ID" --arg B "$COV_BRANCH_FILTER" '
        .projects[] | select(.name==$P) | .streams[]?.name
        | select(.==$B or endswith("/"+$B) or endswith("_"+$B) or contains($B))
      ')"
else
  STREAM_NAMES="$(printf "%s" "$STREAMS_JSON" \
    | jq -r --arg P "$PROJECT_ID" '.projects[] | select(.name==$P) | .streams[]?.name')"
fi

[ -n "$STREAM_NAMES" ] || { 
  echo "Coverity: No streams found for project '$PROJECT_ID' (cov-branch='${COV_BRANCH_FILTER:-*}')"; 
  exit 2; 
}

jq_stream_filters="$(printf '%s\n' "$STREAM_NAMES" | jq -R '{type:"nameMatcher",class:"Stream",name:.}' | jq -s '.')"

curl -sS "${COV_CURL_AUTH[@]}" \
  -H 'Content-Type: application/json' -H 'Accept: application/json' \
  -X POST "${COVERITY_URL%/}/api/v2/issues/search?includeColumnLabels=true&locale=en_us&offset=0&queryType=bySnapshot&rowCount=10000&sortOrder=asc" \
  -d @- > "$COV_JSON" <<EOF
{
  "filters": [
    {
      "columnKey": "streams",
      "matchMode": "oneOrMoreMatch",
      "matchers": $jq_stream_filters
    }
  ],
  "snapshotScope": { "show": { "scope": "last()", "includeOutdatedSnapshots": false } },
  "columns": ["cid","checker","cwe","displayImpact","displayFile","displayFunction","lineNumber"]
}
EOF

jq -r '
  def norm: tolower|gsub("\\\\";"\/")|gsub("\\/+";"/")|ltrimstr("./");
  [.rows[]?] | map({
    source: "coverity",
    issue_id: (.[0].value|tostring),
    checker_or_rule: (.[1].value|tostring),
    cwe: (.[2].value|tostring),
    severity: (.[3].value|tostring),
    file_path: ((.[4].value|tostring) | norm),
    function: (.[5].value|tostring),
    line: (.[6].value|tostring|tonumber?)
  })' "$COV_JSON" > "$TMP/coverity.min.json"

# --------- Polaris: select latest SAST test for the branch --------------
# Polaris APIs: Use Tests/Findings services; Branch appears in issue exports and
# many clients pass a branchId to findings. We fetch recent tests and filter by branch.  [2][3][4]
# [2](https://polaris.blackduck.com/developer/default/documentation/c_api-intro)[3](https://polaris.blackduck.com/developer/default/documentation/t_api-quickstart)[4](https://documentation.blackduck.com/bundle/polaris-docs/page/polaris/documentation/t_how-to-export-issues.html)

AUTH_HDR=("Authorization: Bearer ${POLARIS_TOKEN}")
HDRS=(-H "Accept: application/json" -H "${AUTH_HDR[0]}")

# 1) Resolve project by name (PROJECT_ID)
POL_PROJECT_JSON="$(curl -sS "${HDRS[@]}" "${POLARIS_URL%/}/api/portfolio/projects?query=name:${PROJECT_ID}&first=50")"
POL_PROJECT_ID="$(printf "%s" "$POL_PROJECT_JSON" | jq -r '.data[]?.id' | head -n1)"
[ -n "$POL_PROJECT_ID" ] || { echo "Polaris: Project not found for '$PROJECT_ID'"; exit 3; }

# 2) Get recent SAST tests and pick the latest matching branch (or any latest if no branch filter)
TESTS_JSON="$(curl -sS "${HDRS[@]}" \
  "${POLARIS_URL%/}/api/tests?projectId=${POL_PROJECT_ID}&toolType=sast&first=50&sort=createdAt|desc")"

if [ -n "$POL_BRANCH_FILTER" ]; then
  TEST_ID="$(printf "%s" "$TESTS_JSON" \
    | jq -r --arg B "$POL_BRANCH_FILTER" '
        .data[]
        | select(
            (.attributes.branch // .attributes.branchName // .attributes."branch-name" // "") == $B
            or (.relationships.branch.data.id // "") == $B
          ) | .id' \
    | head -n1)"
else
  TEST_ID="$(printf "%s" "$TESTS_JSON" | jq -r '.data[]?.id' | head -n1)"
fi

[ -n "$TEST_ID" ] || { echo "Polaris: No SAST test found (pol-branch='${POL_BRANCH_FILTER:-*}')"; exit 4; }

# 3) Fetch findings for that test
curl -sS "${HDRS[@]}" \
  "${POLARIS_URL%/}/api/findings?testId=${TEST_ID}&toolType=sast&first=10000" > "$POL_JSON"

jq -r '
  def norm: tolower|gsub("\\\\";"\/")|gsub("\\/+";"/")|ltrimstr("./");
  [.data[]?] | map({
    source: "polaris",
    issue_id: (.id|tostring),
    checker_or_rule: (.attributes.ruleId // .attributes.checker // ""),
    cwe: (.attributes.cwe // ""),
    severity: (.attributes.severity // ""),
    file_path: ((.attributes.location?.filePath // "") | norm),
    function: (.attributes.location?.function // ""),
    line: (.attributes.location?.line // null)
  })' "$POL_JSON" > "$TMP/polaris.min.json"

# --------- Compare & render HTML ---------------------------------------
python3 - "$TMP/coverity.min.json" "$TMP/polaris.min.json" "$OUT_HTML" <<'PY'
import sys, json, re, html
cov_path, pol_path, out_html = sys.argv[1:]
def cwe_key(s):
    s = (s or "").strip()
    m = re.search(r'(\d+)', s)
    return m.group(1) if m else s.lower()
def norm_sev(s): return (s or "").strip().title()
def key(r): return (r.get("file_path",""), cwe_key(r.get("cwe","")))
def load(p): return json.load(open(p))
cov, pol = load(cov_path), load(pol_path)
from collections import defaultdict
cov_map, pol_map = defaultdict(list), defaultdict(list)
for r in cov: cov_map[key(r)].append(r)
for r in pol: pol_map[key(r)].append(r)
allk = set(cov_map)|set(pol_map)
pairs, cov_only, pol_only = [], [], []
for k in sorted(allk):
    cs, ps = cov_map.get(k,[])[:], pol_map.get(k,[])[:]
    used=set()
    for c in cs:
        best, bj, score = None, None, 1e9
        for j,p in enumerate(ps):
            if j in used: continue
            s = 0
            if c.get("function") and p.get("function") and c["function"]==p["function"]: s -= 1000
            if c.get("line") is not None and p.get("line") is not None: s += abs(c["line"]-p["line"])
            if s<score: best,bj,score = p,j,s
        if best is not None: used.add(bj); pairs.append((c,best))
        else: cov_only.append(c)
    for j,p in enumerate(ps):
        if j not in used: pol_only.append(p)
def td(x): return f"<td>{html.escape(str(x) if x is not None else '')}</td>"
def sev_td(s, extra=""): return f'<td class="sev {html.escape(norm_sev(s)).lower()} {extra}">{html.escape(s or "")}</td>'
rows=[]
for c,p in pairs:
    diff = "diff" if norm_sev(c.get("severity"))!=norm_sev(p.get("severity")) else ""
    rows.append("<tr><td>Both</td>"
        f"{td(cwe_key(c.get('cwe')))}"
        f'<td class="path">{html.escape(c.get("file_path",""))}</td>'
        f"{sev_td(c.get('severity'))}{sev_td(p.get('severity'), diff)}"
        f"{td(c.get('issue_id'))}{td(p.get('issue_id'))}"
        f"{td(c.get('function'))}{td(c.get('line'))}"
        f"{td(p.get('function'))}{td(p.get('line'))}"
        f"{td(c.get('checker_or_rule'))}{td(p.get('checker_or_rule'))}</tr>")
def one(x, who): 
    return (f'<tr class="single"><td>{who} only</td>'
            f"{td(cwe_key(x.get('cwe')))}"
            f'<td class="path">{html.escape(x.get("file_path",""))}</td>'
            f'{sev_td(x.get("severity"))}<td class="sev">-</td>'
            f"{td(x.get('issue_id'))}<td>-</td>"
            f"{td(x.get('function'))}{td(x.get('line'))}<td>-</td>"
            f"{td(x.get('checker_or_rule'))}<td>-</td></tr>")
for x in sorted(cov_only, key=lambda r:(r.get("file_path",""), cwe_key(r.get("cwe")), r.get("line") or 0)): rows.append(one(x,"Coverity"))
for x in sorted(pol_only, key=lambda r:(r.get("file_path",""), cwe_key(r.get("cwe")), r.get("line") or 0)): rows.append(one(x,"Polaris"))
html_doc=f"""<!doctype html><html><head><meta charset="utf-8">
<title>SAST Comparison Report</title>
<style>
body{{font-family:system-ui,-apple-system,Segoe UI,Roboto,Arial,sans-serif;margin:20px;color:#111}}
thead th{{background:#fafafa;position:sticky;top:0}} table{{border-collapse:collapse;width:100%;font-size:14px}}
th,td{{border:1px solid #eaeaea;padding:6px 8px;text-align:left;vertical-align:top}}
tr.single td:first-child{{background:#fff8e6}} .sev.critical{{background:#ffe5e5}} .sev.high{{background:#fff0e6}}
.sev.medium{{background:#fff7e6}} .sev.low{{background:#eef7ff}} .sev.diff{{outline:2px solid #ff7d7d}}
.path{{font-family:ui-monospace, SFMono-Regular, Menlo, Consolas, "Liberation Mono", monospace}}
</style></head><body>
<h2>SAST Comparison Report</h2>
<p class="sub">Key: <code>(normalized file path, CWE)</code>. Function/line help verify near-matches.</p>
<table><thead><tr>
<th>Source</th><th>CWE</th><th>File Path</th>
<th>Severity (Coverity)</th><th>Severity (Polaris)</th>
<th>Issue ID (Coverity)</th><th>Issue ID (Polaris)</th>
<th>Function (Coverity)</th><th>Line (Coverity)</th><th>Line (Polaris)</th>
<th>Checker / Rule (Coverity)</th><th>Checker / Rule (Polaris)</th>
</tr></thead><tbody>
{''.join(rows)}
</tbody></table>
</body></html>"""
open(out_html,"w",encoding="utf-8").write(html_doc)
print(out_html)
PY

echo "Wrote: $OUT_HTML"
rm -rf "$TMP"
