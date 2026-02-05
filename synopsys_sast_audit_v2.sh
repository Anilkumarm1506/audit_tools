#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Script: synopsys_sast_audit_v2.sh
# Purpose: SAST-only audit for Synopsys integrations across pipelines + scripts.
#
# CSV Columns:
# repo,branch,build_type,package_manager_file,artifact_type,file_path,ci_type,found_type,invocation_style,script_lines
#
# Multi-branch support:
# - When called multiple times with the same OUT_CSV, it APPENDS rows
# - CSV header is written ONLY ONCE if the file is missing/empty
#
# Build detection:
# - Uses git ls-files (tracked + untracked non-ignored) for speed
# - Adds targeted filesystem fallback to detect marker files even if gitignored
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
# UPDATED: Added Jenkins Coverity plugin pipeline steps.
# ------------------------------------------------------------
DIRECT_SAST_PATTERN='polaris|coverity|coverity-on-polaris|cov-build|cov-analyze|cov-capture|cov-commit-defects|synopsys[- ]?bridge|bridge(\.exe)?|bridge\.yml|bridge\.yaml|--stage[[:space:]]+polaris|--input[[:space:]]+bridge\.ya?ml|synopsys-sig/synopsys-action|SynopsysSecurityScan@|BlackDuckSecurityScan@|CoverityOnPolaris|polaris\.yml|polaris\.yaml|withCoverityEnv|coverityScan|coverityPublisher|covBuild|covAnalyze|covCommitDefects'

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
# CSV header (write once; allow append for multi-branch runs)
# ------------------------------------------------------------
if [[ ! -s "$OUT_CSV" ]]; then
  echo "repo,branch,build_type,package_manager_file,artifact_type,file_path,ci_type,found_type,invocation_style,script_lines" > "$OUT_CSV"
fi

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
# UPDATED: detect Jenkins Coverity plugin steps explicitly.
sast_invocation_style() {
  local f="$1"
  if grep_q 'synopsys-sig/synopsys-action' "$f"; then
    echo "github_action_synopsys_action"
  elif grep_q 'withCoverityEnv|coverityScan|coverityPublisher|covBuild|covAnalyze|covCommitDefects' "$f"; then
    echo "jenkins_coverity_plugin_steps"
  elif grep_q 'SynopsysSecurityScan@|BlackDuckSecurityScan@|CoverityOnPolaris' "$f"; then
    echo "ado_task_extension"
  elif grep_q 'synopsys[- ]?bridge|(^|[[:space:]/])bridge([[:space:]]|$)|--stage[[:space:]]+polaris|--input[[:space:]]+bridge\.ya?ml' "$f"; then
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

# --- Determine found_type (SAST-only) ---
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
# Repo file index:
# - tracked + untracked (excluding ignored) for speed & sanity
# ------------------------------------------------------------
repo_file_index() {
  local repo="$1"
  if git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$repo" ls-files --cached --others --exclude-standard 2>/dev/null || true
  else
    (cd "$repo" && find . -type f -print 2>/dev/null | sed 's|^\./||') || true
  fi
}

# ------------------------------------------------------------
# Targeted fallback search for marker files even if gitignored.
# Avoids heavy directories and .git.
# Returns first match relative path or empty.
# ------------------------------------------------------------
find_first_marker_path() {
  local repo="$1"
  shift
  local -a names=("$@")

  ( cd "$repo" && \
    find . -type f \
      -not -path './.git/*' \
      -not -path '*/.git/*' \
      -not -path '*/node_modules/*' \
      -not -path '*/.gradle/*' \
      -not -path '*/target/*' \
      -not -path '*/build/*' \
      \( $(printf -- '-name %q -o ' "${names[@]}" | sed 's/ -o $//') \) \
      -print 2>/dev/null | head -n 1 | sed 's|^\./||' ) || true
}

# Basename match from git-index; if missing, try filesystem fallback
first_match_basename_with_fallback() {
  local repo="$1"
  local files="$2"
  local regex="$3"
  shift 3
  local -a fallback_names=("$@")

  local b=""
  b="$(echo "$files" | grep -Ei "$regex" | head -n 1 | awk -F/ '{print $NF}')"
  if [[ -n "$b" ]]; then
    echo "$b"
    return
  fi

  local p=""
  p="$(find_first_marker_path "$repo" "${fallback_names[@]}")"
  if [[ -n "$p" ]]; then
    echo "$(basename "$p")"
    return
  fi

  echo ""
}

# Helpers for multi-build detection
add_once() {
  local val="$1"
  local -n arr="$2"
  local x
  for x in "${arr[@]}"; do [[ "$x" == "$val" ]] && return 0; done
  arr+=("$val")
}

# ------------------------------------------------------------
# Multi-build detection returning:
# build_type|package_manager_file
# Both may be '+' joined and aligned
# ------------------------------------------------------------
build_info_of_repo() {
  local repo="$1"
  local files
  files="$(repo_file_index "$repo")"
  [[ -n "$files" ]] || { echo "unknown|unknown"; return; }

  local types=()
  local pm_files=()

  # Maven
  if echo "$files" | grep -Eqi '(^|/)pom\.xml$|(^|/)(mvnw|mvnw\.cmd)$' \
     || [[ -n "$(find_first_marker_path "$repo" "pom.xml" "mvnw" "mvnw.cmd")" ]]; then
    add_once "maven" types
    local f
    f="$(first_match_basename_with_fallback "$repo" "$files" '(^|/)pom\.xml$' "pom.xml")"
    [[ -z "$f" ]] && f="$(first_match_basename_with_fallback "$repo" "$files" '(^|/)(mvnw|mvnw\.cmd)$' "mvnw" "mvnw.cmd")"
    [[ -z "$f" ]] && f="pom.xml"
    pm_files+=("$f")
  fi

  # Gradle
  if echo "$files" | grep -Eqi '(^|/)(build\.gradle|build\.gradle\.kts|settings\.gradle|settings\.gradle\.kts|gradle\.properties|gradlew|gradlew\.bat)$' \
     || [[ -n "$(find_first_marker_path "$repo" "build.gradle" "build.gradle.kts" "settings.gradle" "settings.gradle.kts" "gradle.properties" "gradlew" "gradlew.bat")" ]]; then
    add_once "gradle" types
    local f
    f="$(first_match_basename_with_fallback "$repo" "$files" '(^|/)(build\.gradle\.kts|build\.gradle)$' "build.gradle.kts" "build.gradle")"
    [[ -z "$f" ]] && f="$(first_match_basename_with_fallback "$repo" "$files" '(^|/)(settings\.gradle\.kts|settings\.gradle)$' "settings.gradle.kts" "settings.gradle")"
    [[ -z "$f" ]] && f="$(first_match_basename_with_fallback "$repo" "$files" '(^|/)(gradlew|gradlew\.bat)$' "gradlew" "gradlew.bat")"
    [[ -z "$f" ]] && f="build.gradle"
    pm_files+=("$f")
  fi

  # npm ecosystem
  if echo "$files" | grep -Eqi '(^|/)package\.json$|(^|/)(package-lock\.json|yarn\.lock|pnpm-lock\.ya?ml|pnpm-workspace\.ya?ml|lerna\.json|nx\.json|turbo\.json)$' \
     || [[ -n "$(find_first_marker_path "$repo" "package.json" "package-lock.json" "yarn.lock" "pnpm-lock.yaml" "pnpm-lock.yml" "pnpm-workspace.yaml" "pnpm-workspace.yml")" ]]; then
    add_once "npm" types
    local f
    f="$(first_match_basename_with_fallback "$repo" "$files" '(^|/)package\.json$' "package.json")"
    [[ -z "$f" ]] && f="$(first_match_basename_with_fallback "$repo" "$files" '(^|/)(pnpm-lock\.ya?ml|yarn\.lock|package-lock\.json)$' "pnpm-lock.yaml" "pnpm-lock.yml" "yarn.lock" "package-lock.json")"
    [[ -z "$f" ]] && f="package.json"
    pm_files+=("$f")
  fi

  # Docker
  if echo "$files" | grep -Eqi '(^|/)Dockerfile$|(^|/)docker-compose\.ya?ml$' \
     || [[ -n "$(find_first_marker_path "$repo" "Dockerfile" "docker-compose.yml" "docker-compose.yaml")" ]]; then
    add_once "docker" types
    local f
    f="$(first_match_basename_with_fallback "$repo" "$files" '(^|/)Dockerfile$' "Dockerfile")"
    [[ -z "$f" ]] && f="$(first_match_basename_with_fallback "$repo" "$files" '(^|/)docker-compose\.ya?ml$' "docker-compose.yml" "docker-compose.yaml")"
    [[ -z "$f" ]] && f="Dockerfile"
    pm_files+=("$f")
  fi

  # Nothing detected
  if [[ ${#types[@]} -eq 0 ]]; then
    echo "unknown|unknown"
    return
  fi

  # Join with '+'
  local build_out="" file_out=""
  local i
  for i in "${!types[@]}"; do
    if [[ -z "$build_out" ]]; then
      build_out="${types[$i]}"
      file_out="${pm_files[$i]:-unknown}"
    else
      build_out="${build_out}+${types[$i]}"
      file_out="${file_out}+${pm_files[$i]:-unknown}"
    fi
  done

  echo "${build_out}|${file_out}"
}

# --- Scan file list and append to CSV ---
scan_files_and_report() {
  local repo="$1"
  local repo_url="$2"
  local branch="$3"
  local build_type="$4"
  local pm_file="$5"
  local artifact_type="$6"
  shift 6
  local files=("$@")

  for abs in "${files[@]}"; do
    [[ -f "$abs" ]] || continue
    local rel="${abs#$repo/}"

    # Skip scanning the audit tool itself (prevents self-match)
    [[ "$rel" == *"synopsys_sast_audit"*".sh"* ]] && continue
    [[ "$rel" == *"bd_detect_audit"*".sh"* ]] && continue

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

    echo "[${found_type^^}] ${repo_url}@${branch} (build=${build_type}, pm=${pm_file}) :: $rel (artifact=$artifact_type${style:+, style=$style})"

    local repo_e branch_e build_e pm_e rel_e ci_e found_e style_e ex_e
    repo_e="$(csv_escape "$repo_url")"
    branch_e="$(csv_escape "$branch")"
    build_e="$(csv_escape "$build_type")"
    pm_e="$(csv_escape "$pm_file")"
    rel_e="$(csv_escape "$rel")"
    ci_e="$(csv_escape "$ci")"
    found_e="$(csv_escape "$found_type")"
    style_e="$(csv_escape "$style")"
    ex_e="$(csv_escape "$ex")"

    echo "\"$repo_e\",\"$branch_e\",\"$build_e\",\"$pm_e\",\"$artifact_type\",\"$rel_e\",\"$ci_e\",\"$found_e\",\"$style_e\",\"$ex_e\"" >> "$OUT_CSV"
  done
}

audit_repo() {
  local repo="$1"

  local repo_url branch info build_type pm_file
  repo_url="$(repo_url_of "$repo")"
  branch="$(branch_of "$repo")"

  info="$(build_info_of_repo "$repo")"
  build_type="${info%%|*}"
  pm_file="${info#*|}"

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
    scan_files_and_report "$repo" "$repo_url" "$branch" "$build_type" "$pm_file" "pipeline" "${pipeline_files[@]}"
  fi
  if [[ ${#wrapper_files[@]} -gt 0 ]]; then
    scan_files_and_report "$repo" "$repo_url" "$branch" "$build_type" "$pm_file" "wrapper_or_script" "${wrapper_files[@]}"
  fi
}

echo "Writing/Updating SAST-only report to: $OUT_CSV"
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
echo " - found_type=direct => Synopsys SAST integration visible (Polaris/Coverity/Bridge/task/action)"
echo " - found_type=indirect => likely via templates/shared libs/container; audit the referenced source"
