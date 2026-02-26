#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Script: synopsys_to_blackduck_migrate_v6_7_7.sh
# Purpose:
#   Audit / Dry-run / Apply / Rollback Synopsys (Polaris / Coverity-on-Polaris)
#   configurations to Black Duck / Coverity patterns across common CI files.
#
# v6_7_7 updates:
#   - Dry-run CSV "migration_changes": show only +/- changed lines (no headers, no context).
#   - Apply & Dry-run: Rewrite polarisService URL
#       https://<tenant>.polaris.synopsys.com  -->  https://<tenant>.polaris.blackduck.com
#   - Normalize doubled quotes in displayName (""Title"") -> "Title".
#
# v6_7_5 baseline:
#   - Rollback removes backup from the repo by moving it back into place and
#     staging deletion via `git add -A -- <paths>`.
#
# Modes:
#   MODE=audit      : scan & write CSV findings only
#   MODE=dry-run    : scan & write CSV + include proposed diff as last column
#   MODE=apply      : write changes + create azure-pipelines_backup.yml(.yaml) + (optional) commit/push
#   MODE=rollback   : restore from azure-pipelines_backup.yml(.yaml) and DELETE backup + (optional) commit/push
#
# Env inputs (set by your Azure pipeline step):
#   ROOT (default: .)       - path to cloned target repo
#   MODE (required)         - audit|dry-run|apply|rollback
#   OUT_CSV (required)      - output CSV path (absolute recommended; outside repo)
#   COMMIT (default: 0)     - 1 to commit changes
#   PUSH (default: 0)       - 1 to push changes
#   REMOTE (default: origin)
#   GITHUB_TOKEN (required for PUSH=1) - GitHub PAT/token for HTTPS pushes
# ============================================================================

ROOT="${ROOT:-.}"
MODE="${MODE:-}"
OUT_CSV="${OUT_CSV:-}"
COMMIT="${COMMIT:-0}"
PUSH="${PUSH:-0}"
REMOTE="${REMOTE:-origin}"

TS="$(date +%Y%m%d_%H%M%S)"

# -------- Patterns (detection) --------
PAT_ADO_TASK='SynopsysSecurityScan@|BlackDuckSecurityScan@|SynopsysBridge@'
PAT_GHA_ACTION='uses:\s*synopsys-sig/synopsys-action'
PAT_BRIDGE_CLI='(^|[[:space:]/])bridge([[:space:]]|$)|--stage[[:space:]]+polaris|--stage[[:space:]]+blackduck|--input[[:space:]]+bridge\.ya?ml'
PAT_COVERITY_CLI='cov-build|cov-analyze|cov-capture|cov-commit-defects|cov-format-errors'
PAT_JENKINS_PLUGIN='withCoverityEnv|coverityScan|coverityPublisher|covBuild|covAnalyze|covCommitDefects'

PIPELINE_GLOBS=(
  ".travis.yml"
  "azure-pipelines.yml" "azure-pipelines.yaml"
  ".github/workflows/*.yml" ".github/workflows/*.yaml"
  "bamboo-specs/**/*.yml" "bamboo-specs/**/*.yaml"
  "bridge.yml" "bridge.yaml"
  "Jenkinsfile" "Jenkinsfile*"
)

# -------- Utilities --------
log(){ echo "$@" >&2; }
die(){ echo "[ERROR] $*" >&2; exit 1; }

csv_escape() {
  local s="${1//$'\r'/}"
  s="${s//\"/\"\"}"
  printf '"%s"' "$s"
}

ensure_csv_header() {
  mkdir -p "$(dirname "$OUT_CSV")" 2>/dev/null || true
  if [[ ! -s "$OUT_CSV" ]]; then
    echo "repo,branch,build_type,package_manager_file,file_path,ci_type,found_type,invocation_style,evidence,migration_changes" >> "$OUT_CSV"
  fi
}

assert_inputs() {
  [[ -n "$MODE" ]] || die "MODE is required (audit|dry-run|apply|rollback)"
  [[ "$MODE" =~ ^(audit|dry-run|apply|rollback)$ ]] || die "Invalid MODE=$MODE"
  [[ -n "$OUT_CSV" ]] || die "OUT_CSV is required"
  [[ -d "$ROOT" ]] || die "ROOT not found: $ROOT"
  git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "ROOT is not a git repo: $ROOT"
  if [[ "$PUSH" == "1" ]]; then
    [[ -n "${GITHUB_TOKEN:-}" ]] || die "PUSH=1 requires GITHUB_TOKEN in environment"
  fi
}

repo_url_of() {
  local url
  url="$(git -C "$ROOT" config --get "remote.${REMOTE}.url" || true)"
  echo "${url:-unknown}"
}

current_branch() {
  local b
  b="$(git -C "$ROOT" branch --show-current || true)"
  echo "${b:-unknown}"
}

build_info_of_repo() {
  local bt="unknown"
  local pm=()

  [[ -f "$ROOT/package.json" ]] && pm+=("package.json")
  [[ -f "$ROOT/pom.xml" ]] && pm+=("pom.xml")
  [[ -f "$ROOT/build.gradle" ]] && pm+=("build.gradle")
  [[ -f "$ROOT/Dockerfile" ]] && pm+=("Dockerfile")

  if [[ -f "$ROOT/package.json" ]]; then bt="npm"; fi
  if [[ -f "$ROOT/pom.xml" ]]; then bt="${bt/unknown/}maven${bt:+ +$bt}"; fi
  if [[ -f "$ROOT/build.gradle" ]]; then bt="${bt/unknown/}gradle${bt:+ +$bt}"; fi
  if [[ -f "$ROOT/Dockerfile" ]]; then bt="${bt/unknown/}docker${bt:+ +$bt}"; fi

  local pm_join="none"
  if [[ ${#pm[@]} -gt 0 ]]; then pm_join="$(IFS='; '; echo "${pm[*]}")"; fi

  echo "$bt|$pm_join"
}

ci_type_of_path() {
  local p="$1"
  case "$p" in
    *azure-pipelines.y*ml) echo "azure_devops" ;;
    *.github/workflows/*) echo "github_actions" ;;
    *bamboo-specs/*) echo "bamboo" ;;
    *Jenkinsfile*) echo "jenkins" ;;
    *.travis.yml) echo "travis" ;;
    *bridge.y*ml) echo "bridge_config" ;;
    *) echo "unknown" ;;
  esac
}

invocation_style_of_file() {
  local f="$1"
  if grep -Eq "$PAT_GHA_ACTION" -- "$f"; then echo "github_action_synopsys_action"; return; fi
  if grep -Eq "$PAT_ADO_TASK" -- "$f"; then
    if grep -Eq "SynopsysSecurityScan@" -- "$f"; then echo "ado_task_synopsys_security_scan"; return; fi
    if grep -Eq "SynopsysBridge@" -- "$f"; then echo "ado_task_synopsys_bridge"; return; fi
    if grep -Eq "BlackDuckSecurityScan@" -- "$f"; then echo "ado_task_blackduck_security_scan"; return; fi
    echo "ado_task_extension"; return
  fi
  if grep -Eq "$PAT_BRIDGE_CLI" -- "$f"; then echo "bridge_cli"; return; fi
  if grep -Eq "$PAT_COVERITY_CLI" -- "$f"; then echo "coverity_cli"; return; fi
  if grep -Eq "$PAT_JENKINS_PLUGIN" -- "$f"; then echo "jenkins_coverity_plugin"; return; fi
  echo "unknown"
}

evidence_of_file() {
  local f="$1"
  local pat='polaris|coverity|SynopsysSecurityScan@|SynopsysBridge@|BlackDuckSecurityScan@|synopsys-sig/synopsys-action|--stage[[:space:]]+polaris|--stage[[:space:]]+blackduck|cov-build|cov-analyze|cov-commit-defects'
  awk -v pat="$pat" '
    BEGIN{c=0}
    { if($0 ~ pat){ c++; printf("%d: %s;", NR, $0); if(c>=30) exit } }
  ' "$f" | sed 's/[[:space:]]\+/ /g; s/;$/ /'
}

# ---------------- Azure pipeline transform logic ----------------
# Common transforms used by both dry-run and apply
ado_common_transforms() {
  local file="$1"

  # Task swap & naming tweaks
  sed -Ei \
    -e 's/(\-\s*task:\s*)SynopsysSecurityScan@([0-9]+)/\1BlackDuckSecurityScan@\2/g' \
    -e "s/(scanType:[[:space:]]*)'polaris'/\1'blackduck'/g" \
    -e 's/(displayName:[[:space:]]*")Synopsys Polaris/\1Black Duck/g' \
    "$file" 2>/dev/null || true

  # Bridge build type if present
  sed -Ei -e 's/(bridge_build_type:[[:space:]]*)"polaris"/\1"blackduck"/g' "$file" 2>/dev/null || true

  # Legacy keys to Black Duck (rare in this path)
  if grep -Eq '^[[:space:]]*polaris_server_url:' "$file"; then
    sed -Ei -e 's/^[[:space:]]*polaris_server_url:.*$/      blackduck_url: "$(BLACKDUCK_URL)"/' "$file" 2>/dev/null || true
  fi
  if grep -Eq '^[[:space:]]*polaris_access_token:' "$file"; then
    sed -Ei -e 's/^[[:space:]]*polaris_access_token:.*$/      blackduck_api_token: "$(BLACKDUCK_TOKEN)"/' "$file" 2>/dev/null || true
  fi

  # Copy edits naming
  sed -Ei \
    -e 's/Synopsys Bridge: Coverity on Polaris/Synopsys Bridge: Black Duck Coverity/g' \
    -e 's/Black Duck Coverity on Polaris/Black Duck Coverity/g' \
    "$file" 2>/dev/null || true

  # Update polarisService URL domain if a URL is provided (POC cases)
  sed -Ei -e 's#(polarisService:[[:space:]]*["'\'']?)https://([A-Za-z0-9._-]+)\.polaris\.synopsys\.com#\1https://\2.polaris.blackduck.com#g' "$file" 2>/dev/null || true

  # Normalize doubled quotes in displayName
  sed -Ei \
    -e 's/(displayName:[[:space:]]*)"([^"]*)""/\1"\2"/g' \
    -e 's/(displayName:[[:space:]]*)""/\1"/g' \
    "$file" 2>/dev/null || true
}

ado_apply_transform_azure_pipelines() {
  local rel="$1"
  local abs="$ROOT/$rel"
  [[ -f "$abs" ]] || return 1

  # Only attempt if Synopsys/Polaris markers appear
  if ! grep -Eq "SynopsysBridge@|SynopsysSecurityScan@|polaris" -- "$abs"; then
    return 1
  fi

  local tmp
  tmp="$(mktemp)"
  cp -f "$abs" "$tmp"

  ado_common_transforms "$tmp"

  if cmp -s "$abs" "$tmp"; then
    rm -f "$tmp"
    return 1
  fi

  if [[ "$MODE" == "apply" ]]; then
    local backup
    if [[ "$abs" == *.yaml ]]; then
      backup="$ROOT/azure-pipelines_backup.yaml"
    else
      backup="$ROOT/azure-pipelines_backup.yml"
    fi

    rm -f "$backup" || true
    mv -f "$abs" "$backup"
    cp -f "$tmp" "$abs"
    rm -f "$tmp"
    log "[APPLY] Updated $rel (backup: $(basename "$backup"))"
    return 0
  fi

  rm -f "$tmp"
  return 0
}

ado_rollback_transform_azure_pipelines() {
  local rel="$1"
  local abs="$ROOT/$rel"
  [[ "$MODE" == "rollback" ]] || return 1

  local backup=""
  if [[ "$abs" == *.yaml ]]; then
    [[ -f "$ROOT/azure-pipelines_backup.yaml" ]] && backup="$ROOT/azure-pipelines_backup.yaml"
  else
    [[ -f "$ROOT/azure-pipelines_backup.yml" ]] && backup="$ROOT/azure-pipelines_backup.yml"
  fi

  [[ -n "$backup" ]] || return 1

  if [[ -f "$abs" ]]; then
    rm -f "$abs"
    log "[ROLLBACK] Deleted $rel"
  fi

  mv -f "$backup" "$abs"
  log "[ROLLBACK] Restored $(basename "$backup") -> $rel (backup removed)"
  return 0
}

# ---------------- CSV + scanning ----------------
list_pipeline_files() {
  (cd "$ROOT" && {
    shopt -s globstar nullglob
    for g in "${PIPELINE_GLOBS[@]}"; do
      for f in $g; do
        [[ -f "$f" ]] && echo "$f"
      done
    done
  }) | sort -u
}

found_type_of() {
  local abs="$1"
  if grep -Eq 'polaris|coverity|SynopsysSecurityScan@|SynopsysBridge@|synopsys-sig/synopsys-action|cov-build|cov-analyze|cov-commit-defects|--stage[[:space:]]+polaris' -- "$abs"; then
    echo "direct"
  else
    echo "none"
  fi
}

append_csv_row() {
  local repo="$1" branch="$2" build_type="$3" pm="$4" rel="$5" ci="$6" found="$7" inv="$8" ev="$9" mig="${10}"
  {
    csv_escape "$repo"; echo -n ","
    csv_escape "$branch"; echo -n ","
    csv_escape "$build_type"; echo -n ","
    csv_escape "$pm"; echo -n ","
    csv_escape "$rel"; echo -n ","
    csv_escape "$ci"; echo -n ","
    echo -n "$found,"
    csv_escape "$inv"; echo -n ","
    csv_escape "$ev"; echo -n ","
    csv_escape "$mig"
    echo
  } >> "$OUT_CSV"
}

migration_changes_for_file() {
  local rel="$1"
  local abs="$ROOT/$rel"

  if [[ "$MODE" == "audit" ]]; then
    if grep -Eq "SynopsysBridge@" -- "$abs"; then
      echo "Replace SynopsysBridge polaris inputs with Black Duck inputs: bridge_build_type: blackduck; blackduck_url: \$(BLACKDUCK_URL); blackduck_api_token: \$(BLACKDUCK_TOKEN). Update displayName if needed."
      return
    fi
    if grep -Eq "SynopsysSecurityScan@" -- "$abs"; then
      echo "Replace SynopsysSecurityScan@* (scanType: polaris) with BlackDuckSecurityScan@* (scanType: blackduck). Validate service connection fields or POLARIS_* variables."
      return
    fi
    echo "Detected Synopsys/Polaris/Coverity markers. Review and migrate to Black Duck / Coverity patterns as per org standards."
    return
  fi

  if [[ "$MODE" == "dry-run" ]]; then
    local tmp transformed d
    tmp="$(mktemp)"
    transformed="$(mktemp)"
    cp -f "$abs" "$tmp"
    cp -f "$tmp" "$transformed"

    # Apply the same transforms we would in APPLY
    ado_common_transforms "$transformed"

    # Create unified diff, then keep ONLY +/- changed lines (drop headers & context)
    d="$(
      diff -u "$tmp" "$transformed" \
      | sed -E '/^--- |^\+\+\+ |^@@/d; /^[[:space:]]/d; /^[+-]$/d' \
      | head -n 200 || true
    )"

    rm -f "$tmp" "$transformed"
    echo "${d:-NO_DIFF}"
    return
  fi

  echo ""
}

# ---------------- Commit / Push ----------------
set_remote_with_token_for_push() {
  [[ "$PUSH" == "1" ]] || return 0
  local url
  url="$(git -C "$ROOT" config --get "remote.${REMOTE}.url" || true)"
  [[ -n "$url" ]] || die "remote.${REMOTE}.url not found"

  if [[ "$url" =~ ^https://github.com/ ]]; then
    local authed="https://x-access-token:${GITHUB_TOKEN}@github.com/${url#https://github.com/}"
    git -C "$ROOT" remote set-url "$REMOTE" "$authed"
  fi
}

commit_and_push_if_needed() {
  local branch="$1"; shift
  local paths=("$@")

  if git -C "$ROOT" diff --quiet && git -C "$ROOT" diff --cached --quiet; then
    log "[INFO] No changes applied on $branch; skipping commit/push."
    return 0
  fi

  if [[ "$COMMIT" != "1" ]]; then
    log "[INFO] COMMIT=0: changes exist but not committing."
    return 0
  fi

  git -C "$ROOT" config user.email "azure-pipelines@local" || true
  git -C "$ROOT" config user.name "azure-pipelines" || true

  git -C "$ROOT" add -A -- "${paths[@]}" || true

  if git -C "$ROOT" diff --cached --quiet; then
    log "[INFO] Nothing staged; skipping commit/push."
    return 0
  fi

  git -C "$ROOT" commit -m "Synopsys -> Black Duck migration (${MODE}) [${TS}]" || true

  if [[ "$PUSH" == "1" ]]; then
    set_remote_with_token_for_push
    git -C "$ROOT" push "$REMOTE" "HEAD:$branch"
    log "[INFO] Pushed changes to $branch"
  fi
}

# ---------------- Main ----------------
main() {
  assert_inputs

  if [[ "$OUT_CSV" != /* ]]; then OUT_CSV="$(pwd)/$OUT_CSV"; fi
  ensure_csv_header

  local repo branch info build_type pm
  repo="$(repo_url_of)"
  branch="$(current_branch)"
  info="$(build_info_of_repo)"
  build_type="${info%%|*}"
  pm="${info#*|}"

  local rel abs ci found inv ev mig
  local changed_paths=()

  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    abs="$ROOT/$rel"
    [[ -f "$abs" ]] || continue

    ci="$(ci_type_of_path "$rel")"
    found="$(found_type_of "$abs")"
    [[ "$found" == "direct" ]] || continue

    inv="$(invocation_style_of_file "$abs")"
    ev="$(evidence_of_file "$abs")"
    mig="$(migration_changes_for_file "$rel")"

    append_csv_row "$repo" "$branch" "$build_type" "$pm" "$rel" "$ci" "$found" "$inv" "$ev" "$mig"

    if [[ "$rel" =~ ^azure-pipelines\.ya?ml$ ]]; then
      if [[ "$MODE" == "apply" ]]; then
        if ado_apply_transform_azure_pipelines "$rel"; then
          changed_paths+=("$rel")
          if [[ "$rel" == "azure-pipelines.yaml" ]]; then
            changed_paths+=("azure-pipelines_backup.yaml")
          else
            changed_paths+=("azure-pipelines_backup.yml")
          fi
        fi
      elif [[ "$MODE" == "rollback" ]]; then
        if ado_rollback_transform_azure_pipelines "$rel"; then
          changed_paths+=("$rel")
          if [[ "$rel" == "azure-pipelines.yaml" ]]; then
            changed_paths+=("azure-pipelines_backup.yaml")
          else
            changed_paths+=("azure-pipelines_backup.yml")
          fi
        fi
      fi
    fi

  done < <(list_pipeline_files)

  if [[ "$MODE" == "apply" || "$MODE" == "rollback" ]]; then
    if [[ ${#changed_paths[@]} -gt 0 ]]; then
      local uniq=()
      local seen="|"
      for p in "${changed_paths[@]}"; do
        [[ -n "$p" ]] || continue
        if [[ "$seen" != *"|$p|"* ]]; then
          seen+="$p|"
          uniq+=("$p")
        fi
      done
      commit_and_push_if_needed "$branch" "${uniq[@]}"
    else
      log "[INFO] No changes applied on $branch; skipping commit/push."
    fi
  fi

  log "Done."
  log "CSV: $OUT_CSV"
}

main "$@"
