#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# compare_sast.sh
# Compares Synopsys Coverity SAST vs Polaris/Black Duck SAST CSVs
# on (CWE, Severity, File Path) and produces an HTML report.
#
# Requirements: bash, git, python3
#
# Usage:
#   ./compare_sast.sh \
#     -r https://github.com/Anilkumarm1506/audit_tools.git \
#     -b migration_report \
#     -o comparison_report.html
#
# Optional (override auto-detected file paths inside repo):
#   -c path/to/synopsys_coverity_scan_report_example.csv
#   -p path/to/polaris_blackduck_sast_report_example.csv
# ------------------------------------------------------------

# Defaults
REPO_URL=""
BRANCH="migration_report"
OUT_HTML="comparison_report.html"
COV_FILE=""
POL_FILE=""
WORKDIR=""

usage() {
  cat <<EOF
Usage: $0 -r <repo_url> [-b <branch>] [-o <out.html>] [-c <coverity.csv>] [-p <polaris.csv>] [-w <workdir>]

  -r  Git repo URL (required)
  -b  Git branch to fetch (default: migration_report)
  -o  Output HTML file (default: comparison_report.html)
  -c  Explicit path (in repo) to Coverity CSV
  -p  Explicit path (in repo) to Polaris/Black Duck SAST CSV
  -w  Working directory to clone into (default: mktemp)
EOF
  exit 1
}

while getopts ":r:b:o:c:p:w:h" opt; do
  case ${opt} in
    r) REPO_URL="$OPTARG" ;;
    b) BRANCH="$OPTARG" ;;
    o) OUT_HTML="$OPTARG" ;;
    c) COV_FILE="$OPTARG" ;;
    p) POL_FILE="$OPTARG" ;;
    w) WORKDIR="$OPTARG" ;;
    h) usage ;;
    \?) echo "Invalid option: -$OPTARG" >&2; usage ;;
    :)  echo "Option -$OPTARG requires an argument." >&2; usage ;;
  esac
done

if [[ -z "$REPO_URL" ]]; then
  echo "Error: -r <repo_url> is required." >&2
  usage
fi

# Prepare workspace
CLEANUP_CLONE=0
if [[ -z "${WORKDIR}" ]]; then
  WORKDIR="$(mktemp -d)"
  CLEANUP_CLONE=1
fi

REPO_DIR="${WORKDIR}/repo"

echo "Cloning repo..."
if [[ -d "$REPO_DIR/.git" ]]; then
  echo "Repo dir exists, reusing: $REPO_DIR"
else
  git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$REPO_DIR"
fi

# Auto-discover CSVs if not provided
if [[ -z "$COV_FILE" ]]; then
  # Relaxed patterns for Coverity/Synopsys
  COV_FILE="$(find "$REPO_DIR" -type f \( \
     -iname "*coverity*report*.csv" -o \
     -iname "synopsys*_scan_report*.csv" -o \
     -iname "synopsys*coverity*scan*report*.csv" -o \
     -iname "*synopsys*report*.csv" \
  \) | head -n1 || true)"
fi

if [[ -z "$POL_FILE" ]]; then
  # Relaxed patterns for Polaris/Black Duck SAST
  POL_FILE="$(find "$REPO_DIR" -type f \( \
     -iname "*polaris*report*.csv" -o \
     -iname "*blackduck*sast*report*.csv" -o \
     -iname "polaris*_sast*_report*.csv" \
  \) | head -n1 || true)"
fi

if [[ -z "$COV_FILE" || -z "$POL_FILE" ]]; then
  echo "Error: Could not find required CSV files."
  echo "  Coverity CSV found? [$COV_FILE]"
  echo "  Polaris  CSV found? [$POL_FILE]"
  echo "Tip: pass -c and -p explicitly."
  exit 2
fi

echo "Using:"
echo "  Coverity: $COV_FILE"
echo "  Polaris : $POL_FILE"
echo "Generating: $OUT_HTML"

# Run embedded Python for robust CSV parsing and HTML rendering
python3 - <<'PYCODE' "$COV_FILE" "$POL_FILE" "$OUT_HTML"
import csv, html, os, sys, re
from collections import defaultdict, namedtuple

cov_path, pol_path, out_html = sys.argv[1], sys.argv[2], sys.argv[3]

def norm_path(p):
    # Normalize to forward slashes and lowercase, strip leading './'
    p = (p or "").replace("\\", "/")
    p = re.sub(r"/+", "/", p).lstrip("./")
    return p.lower().strip()

def to_int(s, default=None):
    try:
        return int(str(s).strip())
    except Exception:
        return default

Record = namedtuple("Record", [
    "source",       # "coverity" | "polaris"
    "issue_id",
    "checker_or_rule",
    "cwe",          # string or int-like
    "severity",
    "file_path",
    "function",
    "line"
])

def load_coverity(path):
    recs = []
    with open(path, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        # Expected examples have: "Issue ID","Checker","CWE","Severity","File Path","Function","Line" ...
        for r in reader:
            recs.append(Record(
                source="coverity",
                issue_id=(r.get("Issue ID") or "").strip(),
                checker_or_rule=(r.get("Checker") or "").strip(),
                cwe=(r.get("CWE") or "").strip(),
                severity=(r.get("Severity") or "").strip(),
                file_path=norm_path(r.get("File Path")),
                function=(r.get("Function") or "").strip(),
                line=to_int(r.get("Line"))
            ))
    return recs

def load_polaris(path):
    recs = []
    with open(path, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        # Expected examples have: "Issue ID","Rule ID","CWE","Severity","File Path","Function","Line" ...
        for r in reader:
            recs.append(Record(
                source="polaris",
                issue_id=(r.get("Issue ID") or "").strip(),
                checker_or_rule=(r.get("Rule ID") or r.get("Checker") or "").strip(),
                cwe=(r.get("CWE") or "").strip(),
                severity=(r.get("Severity") or "").strip(),
                file_path=norm_path(r.get("File Path")),
                function=(r.get("Function") or "").strip(),
                line=to_int(r.get("Line"))
            ))
    return recs

cov = load_coverity(cov_path)
pol = load_polaris(pol_path)

# Build index by (file_path, CWE-number). If CWE is not numeric, keep as string.
def cwe_key(cwe):
    # Accept numeric or string; normalize "327" or "CWE-327" => "327"
    s = (cwe or "").strip()
    m = re.search(r"(\d+)", s)
    return m.group(1) if m else s.lower()

def make_key(rec):
    return (rec.file_path, cwe_key(rec.cwe))

cov_map = defaultdict(list)
for r in cov:
    cov_map[make_key(r)].append(r)

pol_map = defaultdict(list)
for r in pol:
    pol_map[make_key(r)].append(r)

all_keys = set(cov_map.keys()) | set(pol_map.keys())

matched_pairs = []  # list of (cov_rec, pol_rec)
cov_only = []
pol_only = []

for k in all_keys:
    cov_list = cov_map.get(k, []).copy()
    pol_list = pol_map.get(k, []).copy()

    # Greedy pairing: prefer same function; otherwise nearest line number
    def pair_score(c, p):
        score = 0
        if c.function and p.function and c.function == p.function:
            score -= 1000
        # smaller diff in line number is better (more negative)
        if c.line is not None and p.line is not None:
            score -= abs(c.line - p.line)
        return score

    used_pol = set()
    for ci, c in enumerate(cov_list):
        best = None
        best_j = None
        best_score = None
        for pj, p in enumerate(pol_list):
            if pj in used_pol:
                continue
            s = pair_score(c, p)
            if best is None or s < best_score:
                best, best_j, best_score = (p, pj, s)
        if best is not None:
            used_pol.add(best_j)
            matched_pairs.append((c, best))
        else:
            cov_only.append(c)

    # Remaining Polaris-only for this key
    for pj, p in enumerate(pol_list):
        if pj not in used_pol:
            pol_only.append(p)

# Summaries
def sev(s): return (s or "").strip().title()
def count_by_sev(items, side=None):
    d = defaultdict(int)
    for it in items:
        if side is None:
            # it is tuple pair
            s1 = sev(it[0].severity)
            s2 = sev(it[1].severity)
            d[s1] += 1
            d[s2] += 1
        else:
            d[sev(it.severity)] += 1
    return dict(sorted(d.items(), key=lambda kv: (-kv[1], kv[0])))

summary = {
    "coverity_total": len(cov),
    "polaris_total": len(pol),
    "matched": len(matched_pairs),
    "coverity_only": len(cov_only),
    "polaris_only": len(pol_only),
    "coverity_only_by_sev": count_by_sev(cov_only, side="cov"),
    "polaris_only_by_sev": count_by_sev(pol_only, side="pol"),
}

# HTML rendering
def esc(s):
    return html.escape("" if s is None else str(s))

def row_match(c, p):
    # Highlight severity mismatch
    sev_mismatch = (sev(c.severity) != sev(p.severity))
    sev_cell = f'<td class="sev {esc(sev(c.severity)).lower()}">{esc(c.severity)}</td>' \
               f'<td class="sev {esc(sev(p.severity)).lower()}{" diff" if sev_mismatch else ""}">{esc(p.severity)}</td>'
    return f"""
    <tr>
      <td>Both</td>
      <td>{esc(cwe_key(c.cwe))}</td>
      <td class="path">{esc(c.file_path)}</td>
      {sev_cell}
      <td>{esc(c.issue_id)}</td>
      <td>{esc(p.issue_id)}</td>
      <td>{esc(c.function or "")}</td>
      <td>{esc("" if c.line is None else c.line)}</td>
      <td>{esc(p.function or "")}</td>
      <td>{esc("" if p.line is None else p.line)}</td>
      <td>{esc(c.checker_or_rule or "")}</td>
      <td>{esc(p.checker_or_rule or "")}</td>
    </tr>
    """

def row_single(x):
    who = "Coverity" if x.source == "coverity" else "Polaris"
    return f"""
    <tr class="single">
      <td>{who} only</td>
      <td>{esc(cwe_key(x.cwe))}</td>
      <td class="path">{esc(x.file_path)}</td>
      <td class="sev {esc(sev(x.severity)).lower()}">{esc(x.severity)}</td>
      <td class="sev">-</td>
      <td>{esc(x.issue_id)}</td>
      <td>-</td>
      <td>{esc(x.function or "")}</td>
      <td>{esc("" if x.line is None else x.line)}</td>
      <td>-</td>
      <td>{esc(x.checker_or_rule or "")}</td>
      <td>-</td>
    </tr>
    """

styles = """
<style>
  body{font-family:system-ui,-apple-system,Segoe UI,Roboto,Arial,sans-serif;margin:20px;color:#111}
  h1{margin:0 0 6px 0} .sub{color:#555;margin:0 0 18px 0}
  code{background:#f5f5f5;padding:2px 6px;border-radius:4px}
  .summary{display:flex;gap:24px;flex-wrap:wrap;margin:12px 0 22px 0}
  .card{border:1px solid #e3e3e3;border-radius:8px;padding:12px 16px;min-width:200px;background:#fff}
  .k{color:#555}
  table{border-collapse:collapse;width:100%;font-size:14px}
  th,td{border:1px solid #eaeaea;padding:8px 10px;text-align:left;vertical-align:top}
  thead th{background:#fafafa;position:sticky;top:0;z-index:1}
  tr.single td:first-child{background:#fff8e6}
  .sev.critical{background:#ffe5e5}
  .sev.high{background:#fff0e6}
  .sev.medium{background:#fff7e6}
  .sev.low{background:#eef7ff}
  .sev.diff{outline:2px solid #ff7d7d}
  .path{font-family:ui-monospace, SFMono-Regular, Menlo, Consolas, "Liberation Mono", monospace}
  .legend{font-size:13px;color:#666;margin:6px 0 16px}
  .small{font-size:12px;color:#666}
  .muted{color:#777}
  .grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:8px}
  .mt8{margin-top:8px} .mt16{margin-top:16px}
</style>
"""

summary_html = f"""
<div class="summary">
  <div class="card"><div class="k">Coverity issues</div><div class="v"><b>{summary['coverity_total']}</b></div></div>
  <div class="card"><div class="k">Polaris issues</div><div class="v"><b>{summary['polaris_total']}</b></div></div>
  <div class="card"><div class="k">Matched (same file &amp; CWE)</div><div class="v"><b>{summary['matched']}</b></div></div>
  <div class="card"><div class="k">Coverity-only</div><div class="v"><b>{summary['coverity_only']}</b></div></div>
  <div class="card"><div class="k">Polaris-only</div><div class="v"><b>{summary['polaris_only']}</b></div></div>
</div>

<div class="grid">
  <div class="card">
    <div class="k">Coverity-only by severity</div>
    <div class="small mt8">{'<br>'.join(f"{html.escape(k)}: <b>{v}</b>" for k,v in summary['coverity_only_by_sev'].items()) or '<span class=muted>None</span>'}</div>
  </div>
  <div class="card">
    <div class="k">Polaris-only by severity</div>
    <div class="small mt8">{'<br>'.join(f"{html.escape(k)}: <b>{v}</b>" for k,v in summary['polaris_only_by_sev'].items()) or '<span class=muted>None</span>'}</div>
  </div>
</div>
"""

table_head = """
<table>
  <thead>
    <tr>
      <th>Source</th>
      <th>CWE</th>
      <th>File Path</th>
      <th>Severity (Coverity)</th>
      <th>Severity (Polaris)</th>
      <th>Issue ID (Coverity)</th>
      <th>Issue ID (Polaris)</th>
      <th>Function (Coverity)</th>
      <th>Line (Coverity)</th>
      <th>Line (Polaris)</th>
      <th>Checker / Rule (Coverity)</th>
      <th>Checker / Rule (Polaris)</th>
    </tr>
  </thead>
  <tbody>
"""

rows = []
# Matched first
for c, p in sorted(matched_pairs, key=lambda t: (t[0].file_path, cwe_key(t[0].cwe), (t[0].line or 0))):
    rows.append(row_match(c, p))
# Then uniques (Coverity then Polaris)
for x in sorted(cov_only, key=lambda r: (r.file_path, cwe_key(r.cwe), (r.line or 0))):
    rows.append(row_single(x))
for x in sorted(pol_only, key=lambda r: (r.file_path, cwe_key(r.cwe), (r.line or 0))):
    rows.append(row_single(x))

html_doc = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>SAST Comparison Report</title>
{styles}
</head>
<body>
  <h1>SAST Comparison Report</h1>
  <p class="sub">Comparison key: <code>(normalized file path, CWE)</code>. Function and line are shown to help review close matches.</p>

  {summary_html}

  <div class="legend">
    <b>Legend:</b> Rows marked <i>Both</i> are matched across tools. <i>Coverity/Polaris only</i> exist in only one report.
    Severity cells highlighted with a red outline indicate a mismatch between tools for the matched finding.
  </div>

  {table_head}
  {''.join(rows)}
  </tbody>
</table>

  <p class="small mt16 muted">
    Generated by compare_sast.sh — Inputs assumed to have columns:
    Coverity: Issue ID, Checker, CWE, Severity, File Path, Function, Line;
    Polaris: Issue ID, Rule ID, CWE, Severity, File Path, Function, Line.
  </p>
</body>
</html>
"""

with open(out_html, "w", encoding="utf-8") as f:
    f.write(html_doc)

print(f"Wrote HTML: {out_html}")
PYCODE

echo "Done."

# Optional cleanup
if [[ "$CLEANUP_CLONE" -eq 1 ]]; then
  rm -rf "$WORKDIR"
fi
``
