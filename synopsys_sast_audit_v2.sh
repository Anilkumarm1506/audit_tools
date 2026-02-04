#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Script: synopsys_sast_audit_v2.sh
# Purpose: SAST-only audit for Synopsys integrations across pipelines + scripts.
#
# CSV Columns:
# repo,branch,build_type,package_manager_file,artifact_type,file_path,ci_type,found_type,invocation_style,script_lines
# ============================================================

ROOT="${1:-.}"
OUT_CSV="${2:-synopsys_sast_audit.csv}"

shopt -s globstar nullglob

PIPELINE_GLOBS=(
  "azure-pipelines.yml" "azure-pipelines.yaml"
  ".github/workflows/*.yml" ".github/workflows/*.yaml"
  "Jenkinsfile" "Jenkinsfile*"
  ".travis.yml"
  "bamboo-specs/**/*.yml" "bamboo-specs/**/*.yaml"
  "**/bamboo-specs.yml" "**/bamboo-specs.yaml"
)

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

DIRECT_SAST_PATTERN='polaris|coverity|coverity-on-polaris|cov-build|cov-analyze|cov-capture|cov-commit-defects|synopsys[- ]?bridge|bridge(\.exe)?|bridge\.yml|bridge\.yaml|synopsys-sig/synopsys-action|SynopsysSecurityScan@|BlackDuckSecurityScan@|CoverityOnPolaris|polaris\.yml|polaris\.yaml'

INDIRECT_TEMPLATE_PATTERN='- template:|extends:|resources:|@templates|include:|uses:[[:space:]]*[^[:space:]]+\/[^[:space:]]+@|workflow_call|reusable workflow'
INDIRECT_JENKINS_LIB_PATTERN='@Library\(|library\(|sharedLibrary|vars\/|def[[:space:]]+securityScan|securityScan\(|sastScan\(|polarisScan\(|coverityScan\('
INDIRECT_CONTAINER_PATTERN='docker[[:space:]]+run|container:|image:|services:|podman[[:space:]]+run'

SAST_KEYWORDS_PATTERN='polaris|coverity|synopsys|bridge|sast'

# CSV header (UPDATED)
echo "repo,branch,build_type,package_manager_file,artifact_type,file_path,ci_type,found_type,invocation_style,script_lines" > "$OUT_CSV"

# --- Safe grep wrappers ---
grep_q() { grep -Eq "$1" -- "$2" 2>/dev/null; }
grep_in() { grep -Ein "$1" -- "$2" 2>/dev/null || true; }

# --- CSV sanitize ---
csv_escape() {
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

# --- Determine found_type ---
classify_found_type() {
  local f="$1"

  if grep_q "$DIRECT_SAST_PATTERN" "$f"; then
    echo "direct"; return
  fi

  if grep_q "$INDIRECT_TEMPLATE_PATTERN" "$f" && grep_q "$SAST_KEYWORDS_PATTERN" "$f"; then
    echo "indirect"; return
  fi
  if grep_q "$INDIRECT_JENKINS_LIB_PATTERN" "$f"; then
    echo "indirect"; return
  fi
  if grep_q "$INDIRECT_CONTAINER_PATTERN" "$f" && grep_q "$SAST_KEYWORDS_PATTERN" "$f"; then
    echo "indirect"; return
  fi

  echo "none"
}

# --- Normalize GitHub URL (ssh -> https) best effort ---
normalize_repo_url() {
  local url="${1:-}"
  if [[ "$url" =~ ^git@github\.com:(.+)\.git$ ]]; then
    echo "https://github.com/${BASH_REMATCH[1]}"; return
  fi
  if [[ "$url" =~ ^ssh://git@github\.com/(.+)\.git$ ]]; then
    echo "https://github.com/${BASH_REMATCH[1]}"; return
  fi
  if [[ "$url" =~ ^https://github\.com/(.+)\.git$ ]]; then
    echo "https://github.com/${BASH_REMATCH[1]}"; return
  fi
  echo "$url"
}

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

branch_of() {
  local repo="$1"
  local b=""

  if git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    b="$(git -C "$repo" branch --show-current 2>/dev/null || true)"
    if [[ -z "$b" ]]; then
      b="$(git -C "$repo" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
    fi
    if [[ -z "$b" || "$b" == "HEAD" ]]; then
      b="$(git -C "$repo" name-rev --name-only --no-undefined HEAD 2>/dev/null || true)"
      b="${b#remotes/origin/}"
      b="${b#origin/}"
      b="${b%%^*}"
    fi
  fi

  [[ -n "$b" && "$b" != "undefined" ]] && echo "$b" || echo "unknown"
}

# ------------------------------------------------------------
# Repo file index for build detection (fast & accurate)
# ------------------------------------------------------------
repo_file_index() {
  local repo="$1"
  if git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$repo" ls-files 2>/dev/null || true
  else
    (cd "$repo" && find . -type f -print 2>/dev/null | sed 's|^\./||') || true
  fi
}

# Helpers for multi-build detection
add_once() {
  local val="$1"
  local -n arr="$2"
  local x
  for x in "${arr[@]}"; do [[ "$x" == "$val" ]] && return 0; done
  arr+=("$val")
}

# Return first matching basename from file list and regex (priority-based)
first_match_basename() {
  local files="$1"
  local regex="$2"
  echo "$files" | grep -Ei "$regex" | head -n 1 | awk -F/ '{print $NF}'
}

# ------------------------------------------------------------
# Multi-build detection returning TWO parallel strings:
# - build_type (joined by '+')
# - package_manager_file (joined by '+', aligned with build_type order)
#
# Example:
#   build_type=maven+npm
#   package_manager_file=pom.xml+package.json
# ------------------------------------------------------------
build_info_of_repo() {
  local repo="$1"
  local files
  files="$(repo_file_index "$repo")"
  [[ -n "$files" ]] || { echo "unknown|unknown"; return; }

  local types=()
  local pm_files=()

  # ---- Maven (pom.xml / mvnw) ----
  if echo "$files" | grep -Eqi '(^|/)pom\.xml$|(^|/)(mvnw|mvnw\.cmd)$'; then
    add_once "maven" types
    local f
    f="$(first_match_basename "$files" '(^|/)pom\.xml$')"
    [[ -z "$f" ]] && f="$(first_match_basename "$files" '(^|/)(mvnw|mvnw\.cmd)$')"
    [[ -z "$f" ]] && f="pom.xml"
    pm_files+=("$f")
  fi

  # ---- Gradle (build.gradle/kts, settings.gradle/kts, gradlew) ----
  if echo "$files" | grep -Eqi '(^|/)(build\.gradle|build\.gradle\.kts|settings\.gradle|settings\.gradle\.kts|gradle\.properties|gradlew|gradlew\.bat)$'; then
    add_once "gradle" types
    local f
    f="$(first_match_basename "$files" '(^|/)(build\.gradle\.kts|build\.gradle)$')"
