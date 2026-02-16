#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Script: synopsys_to_blackduck_migrate_v6_7_2.sh
# Purpose:
#   Audit / Dry-run / Apply / Rollback Synopsys (Polaris / Coverity-on-Polaris)
#   configurations to Black Duck / Coverity patterns across common CI files.
#
# Modes:
#   MODE=audit     : scan & write CSV findings only (migration_changes is guidance)
#   MODE=dry-run   : scan & write CSV + migration_changes contains unified diff (preview)
#   MODE=apply     : apply safe mechanical edits + create in-place backup + optional commit/push
#   MODE=rollback  : restore latest backup + delete migrated file + cleanup backup(s) + optional commit/push
#
# Env inputs (typically set by Azure pipeline step):
#   ROOT (default: .)          - path to cloned target repo
#   MODE (required)            - audit|dry-run|apply|rollback
#   OUT_CSV (required)         - output CSV path (absolute recommended)
#   COMMIT (default: 0)        - 1 to commit changes
#   PUSH (default: 0)          - 1 to push changes
#   REMOTE (default: origin)   - git remote name
#   GITHUB_TOKEN               - required if PUSH=1 (PAT/token for HTTPS push)
#
# Notes:
# - Safety: CSV is NEVER staged/committed by this script.
# - Apply behavior (Azure pipeline YAML only):
#     azure-pipelines.yml -> azure-pipelines_backup_<timestamp>.yml
#     new migrated azure-pipelines.yml written in place
# - Rollback behavior:
#     deletes migrated azure-pipelines.yml/.yaml
#     restores latest azure-pipelines_backup_*.yml/.yaml back to azure-pipelines.yml/.yaml
#     removes any remaining azure-pipelines_backup_*.yml/.yaml files (cleanup)
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
  # Escape for RFC4180-ish CSV (wrap in quotes, double internal quotes)
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

# Very small "build info" heuristic (kept from earlier asks)
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

# Evidence: line-numbered matched lines (limited)
evidence_of_file() {
  local f="$1"
  local pat='polaris|coverity|SynopsysSecurityScan@|SynopsysBridge@|BlackDuckSecurityScan@|synopsys-sig/synopsys-action|--stage[[:space:]]+polaris|--stage[[:space:]]+blackduck|cov-build|cov-analyze|cov-commit-defects'
  awk -v pat="$pat" '
    BEGIN{c=0}
    { if($0 ~ pat){ c++; printf("%d: %s;", NR, $0); if(c>=30) exit } }
  ' "$f" | sed 's/[[:space:]]\+/ /g; s/;$/ /'
}

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

# ============================================================================
# Azure pipeline transform (content-only, used for dry-run and apply)
# ============================================================================
ado_transform_azure_pipelines_content() {
  # reads stdin -> writes stdout (transformed)
  # Implements:
  # - SynopsysSecurityScan -> BlackDuckSecurityScan (scanType polaris -> blackduck) [best-effort]
  # - SynopsysBridge polaris -> blackduck (bridge_build_type + url/token key migrations)
  #
  # IMPORTANT: We intentionally do not "fully rewrite" pipeline; we do minimal safe substitutions.
  sed -E \
    -e 's/(\-\s*task:\s*)SynopsysSecurityScan@([0-9]+)/\1BlackDuckSecurityScan@\2/g' \
    -e "s/(scanType:[[:space:]]*)'polaris'/\1'blackduck'/g" \
    -e 's/(displayName:[[:space:]]*")Synopsys Polaris/\1Black Duck/g' \
    -e 's/(bridge_build_type:[[:space:]]*)"polaris"/\1"blackduck"/g' \
    -e 's/^[[:space:]]*polaris_server_url:.*$/      blackduck_url: "$(BLACKDUCK_URL)"/g' \
    -e 's/^[[:space:]]*polaris_access_token:.*$/      blackduck_api_token: "$(BLACKDUCK_TOKEN)"/g' \
    -e 's/Synopsys Bridge: Coverity on Polaris/Synopsys Bridge: Black Duck Coverity/g' \
    -e 's/Black Duck Coverity on Polaris/Black Duck Coverity/g'
}

ado_apply_transform_azure_pipelines() {
  local rel="$1"   # azure-pipelines.yml or .yaml
  local abs="$ROOT/$rel"
  [[ -f "$abs" ]] || return 1

  # Only act if file contains Synopsys/Polaris markers
  if ! grep -Eq "SynopsysBridge@|SynopsysSecurityScan@|polaris" -- "$abs"; then
    return 1
  fi

  local tmp
  tmp="$(mktemp)"
  cat "$abs" | ado_transform_azure_pipelines_content > "$tmp"

  # If no changes, stop
  if cmp -s "$abs" "$tmp"; then
    rm -f "$tmp"
    return 1
  fi

  # Apply:
  #  - move original to in-place backup with timestamp
  #  - write new migrated file with original name
  local backup
  if [[ "$abs" == *.yaml ]]; then
    backup="${abs%.yaml}_backup_${TS}.yaml"
  else
    backup="${abs%.yml}_backup_${TS}.yml"
  fi

  mv -f "$abs" "$backup"
  cp -f "$tmp" "$abs"
  rm -f "$tmp"
  log "[APPLY] Updated $rel (backup: $(basename "$backup"))"
  return 0
}

ado_rollback_transform_azure_pipelines() {
  local rel="$1"   # azure-pipelines.yml or .yaml
  local abs="$ROOT/$rel"
  [[ "$MODE" == "rollback" ]] || return 1

  local dir ext
  dir="$(dirname "$abs")"
  ext="${rel##*.}"  # yml/yaml

  local glob
  if [[ "$ext" == "yaml" ]]; then
    glob="${ROOT}/${rel%.yaml}_backup_*.yaml"
  else
    glob="${ROOT}/${rel%.yml}_backup_*.yml"
  fi

  # Pick latest by lexical order (timestamp sortable)
  local latest=""
  for f in $glob; do
    [[ -f "$f" ]] || continue
    latest="$f"
  done

  [[ -n "$latest" ]] || return 1

  # Delete current migrated file (if exists)
  if [[ -f "$abs" ]]; then
    rm -f "$abs"
    log "[ROLLBACK] Deleted $rel"
  fi

  # Restore latest backup to original name (mv removes the backup)
  mv -f "$latest" "$abs"
  log "[ROLLBACK] Restored backup $(basename "$latest") -> $rel"

  # Cleanup: remove any remaining backups (user requested no leftover backup after rollback)
  # This will remove older backups too, to keep repo clean/idempotent.
  # If you later want to preserve history, we can add CLEANUP_ALL_BACKUPS=0 flag.
  if [[ "$ext" == "yaml" ]]; then
    rm -f "${ROOT}/${rel%.yaml}_backup_"*.yaml 2>/dev/null || true
  else
    rm -f "${ROOT}/${rel%.yml}_backup_"*.yml 2>/dev/null || true
  fi

  return 0
}

# ============================================================================
# migration_changes column builder
# ============================================================================
migration_changes_for_file() {
  local rel="$1"
  local abs="$ROOT/$rel"

  if [[ "$MODE" == "audit" ]]; then
    if grep -Eq "SynopsysBridge@" -- "$abs"; then
      echo "Update SynopsysBridge inputs from Polaris to Black Duck: bridge_build_type: blackduck; replace polaris_server_url -> blackduck_url: \$(BLACKDUCK_URL); replace polaris_access_token -> blackduck_api_token: \$(BLACKDUCK_TOKEN)."
      return
    fi
    if grep -Eq "SynopsysSecurityScan@" -- "$abs"; then
      echo "Replace SynopsysSecurityScan@* (scanType: polaris) with your Black Duck ADO task (e.g., BlackDuckSecurityScan@*) and set scanType: blackduck. Validate service connections and inputs."
      return
    fi
    echo "Detected Synopsys/Polaris/Coverity markers. Review and migrate to Black Duck / Coverity configuration as per org standards."
    return
  fi

  if [[ "$MODE" == "dry-run" ]]; then
    # For azure-pipelines.yml/.yaml: produce unified diff of proposed transform (content-only)
    if [[ "$rel" =~ azure-pipelines\.ya?ml$ ]]; then
      local before after
      before="$(mktemp)"
      after="$(mktemp)"
      cp -f "$abs" "$before"
      cat "$abs" | ado_transform_azure_pipelines_content > "$after"
      local d
      d="$(diff -u "$before" "$after" | head -n 200 || true)"
      rm -f "$before" "$after"
      echo "${d:-NO_DIFF}"
      return
    fi

    # For other file types: best-effort guidance
    echo "NO_DIFF_PREVIEW_FOR_THIS_FILE_TYPE"
    return
  fi

  # apply/rollback: keep short note (CSV is mainly for audit/dry-run)
  echo ""
}

# ============================================================================
# Commit / Push (safe)
# ============================================================================
set_remote_with_token_for_push() {
  [[ "$PUSH" == "1" ]] || return 0
  local url
  url="$(git -C "$ROOT" config --get "remote.${REMOTE}.url" || true)"
  [[ -n "$url" ]] || die "remote.${REMOTE}.url not found"

  # Only rewrite https://github.com/... URLs; if already tokenized, keep.
  if [[ "$url" =~ ^https://github.com/ ]]; then
    local authed="https://x-access-token:${GITHUB_TOKEN}@github.com/${url#https://github.com/}"
    git -C "$ROOT" remote set-url "$REMOTE" "$authed"
  fi
}

commit_and_push_if_needed() {
  local branch="$1"; shift
  local files=("$@")

  # Determine if any of the specified files actually changed
  local any_changes=0
  for f in "${files[@]}"; do
    [[ -n "$f" ]] || continue
    # if file removed, diff will show it; use git status porcelain as source of truth
    if [[ -n "$(git -C "$ROOT" status --porcelain -- "$f" 2>/dev/null || true)" ]]; then
      any_changes=1
    fi
  done

  if [[ "$any_changes" -eq 0 ]]; then
    log "[INFO] No changes applied on $branch; skipping commit/push."
    return 0
  fi

  if [[ "$COMMIT" != "1" ]]; then
    log "[INFO] COMMIT=0: changes exist but not committing."
    return 0
  fi

  git -C "$ROOT" config user.email "azure-pipelines@local" || true
  git -C "$ROOT" config user.name "azure-pipelines" || true

  # Stage only listed pipeline/backup files. Never stage CSV.
  git -C "$ROOT" add -- "${files[@]}" || true

  if git -C "$ROOT" diff --cached --quiet; then
    log "[INFO] Nothing staged; skipping commit/push."
    return 0
  fi

  git -C "$ROOT" commit -m "Synopsys â†’ Black Duck migration (${MODE}) [${TS}]" || true

  if [[ "$PUSH" == "1" ]]; then
    set_remote_with_token_for_push
    git -C "$ROOT" push "$REMOTE" "HEAD:$branch"
    log "[INFO] Pushed changes to $branch"
  fi
}

# ============================================================================
# Main
# ============================================================================
main() {
  assert_inputs

  # Normalize OUT_CSV to absolute if it isn't (helps avoid pipeline double-prefix issues)
  if [[ "$OUT_CSV" != /* ]]; then OUT_CSV="$(pwd)/$OUT_CSV"; fi

  ensure_csv_header

  local repo branch info build_type pm
  repo="$(repo_url_of)"
  branch="$(current_branch)"
  info="$(build_info_of_repo)"
  build_type="${info%%|*}"
  pm="${info#*|}"

  local changed_paths=()

  local rel abs ci found inv ev mig
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

    # Apply/rollback actions: Azure pipelines only (your current target)
    if [[ "$MODE" == "apply" && "$rel" =~ azure-pipelines\.ya?ml$ ]]; then
      if ado_apply_transform_azure_pipelines "$rel"; then
        changed_paths+=("$rel")
        # backup name pattern
        changed_paths+=("${rel%.*}_backup_${TS}.${rel##*.}")
      fi
    fi

    if [[ "$MODE" == "rollback" && "$rel" =~ azure-pipelines\.ya?ml$ ]]; then
      if ado_rollback_transform_azure_pipelines "$rel"; then
        changed_paths+=("$rel")
        # In rollback we may have deleted backups; stage azure-pipelines.yml only.
      fi
    fi

  done < <(list_pipeline_files)

  if [[ "$MODE" == "apply" || "$MODE" == "rollback" ]]; then
    if [[ ${#changed_paths[@]} -gt 0 ]]; then
      # de-dup
      local seen="|"
      local uniq=()
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
  if [[ "$MODE" == "apply" ]]; then
    log "Backups (apply): <in-place *_backup_${TS}.yml/.yaml>"
  fi
}

main "$@"
