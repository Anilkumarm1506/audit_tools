#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Script: synopsys_sast_audit_v2.sh
# Purpose:
# SAST-only audit for Synopsys integrations across pipelines + scripts.
# Focus: Polaris / Coverity on Polaris / Bridge CLI / Synopsys Action
# Ignore: Synopsys Detect / Black Duck SCA patterns (not searched)
#
# Outputs:
# - Console summary
# - CSV report (default: synopsys_sast_audit.csv)
#
# Usage:
# ./synopsys_sast_audit_v2.sh                 # current repo
# ./synopsys_sast_audit_v2.sh . out.csv       # custom CSV
# ./synopsys_sast_audit_v2.sh /repos out.csv  # all git repos in folder
#
# CSV Columns:
# repo_url,branch,artifact_type,file_path,ci_type,found_type,invocation_style,script_lines
#
# Notes:
# - Pipeline-safe: grep "no match" will not fail
# - Grep-safe: always uses `--` before file
# - Repo URL/branch derived from git metadata (origin + HEAD)
# ============================================================

ROOT="${1:-.}"
OUT_CSV="${2:-synopsys_sast_audit.csv}"

shopt -s globstar nullglob

# ------------------------------------------------------------
# Pipeline file globs (common CI systems)
# ------------------------------------------------------------
PIPELINE_GLOBS=(
  "azure-pipelines.yml" "azure-pipelines.yaml"
  ".github/workflows/*.yml" ".github/workflows/*.yaml"
  "Jenkinsfile" "Jenkinsfile*"
  ".travis.yml"
  "bamboo-specs/**/*.yml" "bamboo-specs/**/*.yaml"
  "**/bamboo-specs.yml" "**/bamboo-specs.yaml"
)

# ------------------------------------------------------------
# Wrapper/script/build globs (where scan logic is often hidden)
# ------------------------------------------------------------
WRAPPER_GLOBS=(
  "ci/**/*"
  "scripts/**/*"
  ".ci/**/*"
  ".github/scripts/**/*"
  ".jenkins/**/*"
  ".build/**/*"
  "build/**/*"
  "tools/**/*"
  "devops/**/*"
  "Makefile" "Makefile.*"
  "**/*.sh"
  "**/*.bash"
  "**/*.ps1"
  "**/*.cmd"
  "**/*.bat"
  "**/*.groovy"
  "**/*.gradle"
  "**/*.kts"
  "**/pom.xml"
  "**/build.gradle"
  "**/package.json"
)

# ------------------------------------------------------------
# SAST "direct evidence" markers (Polaris/Coverity/Bridge/Actions/ADO tasks)
# ------------------------------------------------------------
DIRECT_SAST_PATTERN='polaris|coverity|coverity-on-polaris|cov-build|cov-analyze|cov-capture|cov-commit-defects|synopsys[- ]?bridge|bridge(\.exe)?|bridge\.yml|bridge\.yaml|synopsys-sig/synopsys-action|SynopsysSecurityScan@|BlackDuckSecurityScan@|CoverityOnPolaris|polaris\.yml|polaris\.yaml'

# ------------------------------------------------------------
# "Indirect integration" markers (templates/reuse/shared libs/containers)
# ------------------------------------------------------------
INDIRECT_TEMPLATE_PATTERN='- template:|extends:|resources:|@templates|include:|uses:[[:space:]]*[^[:space:]]+\/[^[:space:]]+@|workflow_call|reusable workflow'
INDIRECT_JENKINS_LIB_PATTERN='@Library\(|library\(|sharedLibrary|vars\/|def[[:space:]]+securityScan|securityScan\(|sastScan\(|polarisScan\(|coverityScan\('
INDIRECT_CONTAINER_PATTERN='docker[[:space:]]+run|container:|image:|services:|podman[[:space:]]+run'

# ------------------------------------------------------------
# Extra keywords used only to qualify indirect hits
# ------------------------------------------------------------
SAST_KEYWORDS_PATTERN='polaris|coverity|synopsys|bridge|sast'

# ------------------------------------------------------------
# CSV header (UPDATED)
# ------------------------------------------------------------
echo "repo_url,branch,artifact_type,file_path,ci_type,found_type,invocation_style,script_lines" > "$OUT_CSV"

# --- Safe grep wrappers (prevent invalid option + avoid pipefail crashes) ---
grep_q() { grep -Eq "$1" -- "$2" 2>/dev/null; }          # quiet true/false
grep_in() { grep -Ein "$1" -- "$2" 2>/dev/null || true; } # numbered output, never fails

# --- CSV sanitize (escape quotes, collapse newlines) ---
csv_escape() {
  # Escape double-quotes for CSV, keep as one line
  # shellcheck disable=SC2001
  echo "$1" | sed -E 's/"/""/g' | tr '\n' ' ' | sed -E 's/[[:space:]]+$//'
}

# --- Identify CI type from file path ---
ci_type_of() {
  local f="$1"
  if [[ "$f" == *".github/workflows/"* ]]; then echo "github_actions"
  elif [[ "$(basename "$f")" == "azure-pipelines.yml" || "$(basename "$f")" == "azure-pipelines.yaml" ]]; then echo "azure_devops"
  elif [[ "$(basename "$f")" == Jenkinsfile* ]]; then echo "jenkins"
  elif [[ "$(basename "$f")" == ".travis.yml" ]]; then echo "travis"
  elif [[ "$f" == *"bamboo-specs"* ]]; then echo "bamboo"
  else echo "unknown"
  fi
}

# --- Classify invocation style (best-effort) ---
sast_invocation_style() {
  local f="$1"
  if grep_q 'synopsys-sig/synopsys-action' "$f"; then
    echo "github_action_synopsys_action"
  elif grep_q 'SynopsysSecurityScan@|BlackDuckSecurityScan@|CoverityOnPolaris' "$f"; then
    echo "ado_task_extension"
  elif grep_q 'synopsys[- ]?bridge|(^|[[:space:]])bridge([[:space:]]|$)' "$f"; then
    echo "bridge_cli"
  elif grep_q 'cov-build|cov-analyze|cov-capture|cov-commit-defects' "$f"; then
    echo "coverity_cli"
  elif grep_q 'polaris' "$f"; then
    echo "polaris_cli_or_config"
  else
    echo "unknown"
  fi
}

# --- Evidence lines for report (pipeline-safe) ---
script_lines() {
  local f="$1"
  local n=8
  local pat="$DIRECT_SAST_PATTERN|$INDIRECT_TEMPLATE_PATTERN|$INDIRECT_JENKINS_LIB_PATTERN|$INDIRECT_CONTAINER_PATTERN"
  (
    { grep_in "$pat" "$f"; } \
      | head -n "$n" \
      | sed -E 's/"/""/g' \
      | tr '\n' ';' \
      | sed 's/;*$//'
  )
}

# --- Determine found_type (SAST-only). Approach removed from CSV by request ---
classify_found_type() {
  local f="$1"

  # Direct = visible SAST invocation or task/action/config
  if grep_q "$DIRECT_SAST_PATTERN" "$f"; then
    echo "direct"
    return
  fi

  # Indirect = templates/shared libs/containers with SAST keywords
  if grep_q "$INDIRECT_TEMPLATE_PATTERN" "$f" && grep_q "$SAST_KEYWORDS_PATTERN" "$f"; then
    echo "indirect"
    return
  fi
  if grep_q "$INDIRECT_JENKINS_LIB_PATTERN" "$f"; then
    echo "indirect"
    return
  fi
  if grep_q "$INDIRECT_CONTAINER_PATTERN" "$f" && grep_q "$SAST_KEYWORDS_PATTERN" "$f"; then
    echo "indirect"
    return
  fi

  echo "none"
}

# --- Normalize GitHub URL (ssh -> https) best effort ---
normalize_repo_url() {
  local url="${1:-}"
  # git@github.com:org/repo.git -> https://github.com/org/repo
  if [[ "$url" =~ ^git@github\.com:(.+)\.git$ ]]; then
    echo "https://github.com/${BASH_REMATCH[1]}"
    return
  fi
  # ssh://git@github.com/org/repo.git -> https://github.com/org/repo
  if [[ "$url" =~ ^ssh://git@github\.com/(.+)\.git$ ]]; then
    echo "https://github.com/${BASH_REMATCH[1]}"
    return
  fi
  # https://github.com/org/repo.git -> https://github.com/org/repo
  if [[ "$url" =~ ^https://github\.com/(.+)\.git$ ]]; then
    echo "https://github.com/${BASH_REMATCH[1]}"
    return
  fi
  # leave as-is (Azure Repos, GitLab, Bitbucket, etc.)
  echo "$url"
}

# --- Repo URL from git origin (fallback to folder name if missing) ---
repo_url_of() {
  local repo="$1"
  local url=""
  if git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    url="$(git -C "$repo" config --get remote.origin.url 2>/dev/null || true)"
  fi
  if [[ -z "$url" ]]; then
    echo "$(basename "$repo")"
  else
    normalize_repo_url "$url"
  fi
}

# --- Branch best-effort (handles detached head) ---
branch_of() {
  local repo="$1"
  local b=""

  if git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    # Prefer explicit current branch
    b="$(git -C "$repo" branch --show-current 2>/dev/null || true)"
    if [[ -z "$b" ]]; then
      # symbolic-ref fails on detached HEAD
      b="$(git -C "$repo" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
    fi
    if [[ -z "$b" || "$b" == "HEAD" ]]; then
      # Try to infer from name-rev (e.g., remotes/origin/main)
      b="$(git -C "$repo" name-rev --name-only --no-undefined HEAD 2>/dev/null || true)"
      b="${b#remotes/origin/}"
      b="${b#origin/}"
      b="${b%%^*}"
    fi
  fi

  [[ -n "$b" && "$b" != "undefined" ]] && echo "$b" || echo "unknown"
}

# --- Scan file list and append to CSV ---
scan_files_and_report() {
  local repo="$1"
  local repo_url="$2"
  local branch="$3"
  local artifact_type="$4"
  shift 4
  local files=("$@")

  for abs in "${files[@]}"; do
    [[ -f "$abs" ]] || continue
    local rel="${abs#$repo/}"

    # Skip scanning the audit tool itself (prevents self-match)
    [[ "$rel" == *"synopsys_sast_audit_v1.sh"* ]] && continue
    [[ "$rel" == *"synopsys_sast_audit_v2.sh"* ]] && continue
    [[ "$rel" == *"bd_detect_audit_v2.sh"* ]] && continue

    local found_type
    found_type="$(classify_found_type "$abs")"
    [[ "$found_type" == "none" ]] && continue

    local ci="n/a"
    if [[ "$artifact_type" == "pipeline" ]]; then
      ci="$(ci_type_of "$rel")"
    fi

    local style=""
    if [[ "$found_type" == "direct" ]]; then
      style="$(sast_invocation_style "$abs")"
    fi

    local ex
    ex="$(script_lines "$abs")"

    # Console summary
    echo "[${found_type^^}] ${repo_url}@${branch} :: $rel (artifact=$artifact_type${style:+, style=$style})"

    # CSV row (UPDATED columns)
    local repo_url_e branch_e rel_e ci_e found_e style_e ex_e
    repo_url_e="$(csv_escape "$repo_url")"
    branch_e="$(csv_escape "$branch")"
    rel_e="$(csv_escape "$rel")"
    ci_e="$(csv_escape "$ci")"
    found_e="$(csv_escape "$found_type")"
    style_e="$(csv_escape "$style")"
    ex_e="$(csv_escape "$ex")"

    echo "\"$repo_url_e\",\"$branch_e\",\"$artifact_type\",\"$rel_e\",\"$ci_e\",\"$found_e\",\"$style_e\",\"$ex_e\"" >> "$OUT_CSV"
  done
}

audit_repo() {
  local repo="$1"

  local repo_url branch
  repo_url="$(repo_url_of "$repo")"
  branch="$(branch_of "$repo")"

  local pipeline_files=()
  for g in "${PIPELINE_GLOBS[@]}"; do
    for f in "$repo"/$g; do
      [[ -f "$f" ]] && pipeline_files+=("$f")
    done
  done
  mapfile -t pipeline_files < <(printf "%s\n" "${pipeline_files[@]}" | awk '!seen[$0]++')

  local wrapper_files=()
  for g in "${WRAPPER_GLOBS[@]}"; do
    for f in "$repo"/$g; do
      [[ -f "$f" ]] && wrapper_files+=("$f")
    done
  done
  mapfile -t wrapper_files < <(printf "%s\n" "${wrapper_files[@]}" | awk '!seen[$0]++')

  if [[ ${#pipeline_files[@]} -eq 0 && ${#wrapper_files[@]} -eq 0 ]]; then
    echo "[INFO] $(basename "$repo"): no files matched for scanning"
    return
  fi

  if [[ ${#pipeline_files[@]} -gt 0 ]]; then
    scan_files_and_report "$repo" "$repo_url" "$branch" "pipeline" "${pipeline_files[@]}"
  fi
  if [[ ${#wrapper_files[@]} -gt 0 ]]; then
    scan_files_and_report "$repo" "$repo_url" "$branch" "wrapper_or_script" "${wrapper_files[@]}"
  fi
}

echo "Writing SAST-only report to: $OUT_CSV"
echo

if [[ -d "$ROOT/.git" ]]; then
  audit_repo "$ROOT"
else
  for d in "$ROOT"/*; do
    [[ -d "$d/.git" ]] || continue
    audit_repo "$d"
  done
fi

echo
echo "Done. CSV: $OUT_CSV"
echo "Interpretation:"
echo " - found_type=direct   => Synopsys SAST integration visible (Polaris/Coverity/Bridge/task/action)"
echo " - found_type=indirect => likely via templates/shared libs/container; audit the referenced source"
