#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Script: synopsys_to_blackduck_migrate_v6_7_1.sh
# Purpose:
#   - Audit / Dry-run / Apply / Rollback Synopsys (Polaris / Coverity-on-Polaris)
#     configurations to Black Duck / Coverity in Polaris patterns across common CI files.
#
# Key fixes in v6_7.1 (per your pipeline logs):
#   1) Push auth reliability:
#        - If MODE=apply|rollback and PUSH=1, script requires GITHUB_TOKEN and
#          sets remote.origin.url to token-auth form BEFORE pushing.
#   2) Prevent committing CSV / other artifacts:
#        - git add is restricted to changed pipeline/config files only.
#        - The CSV is written outside the repo working tree (recommended), but even
#          if present, it will NOT be added.
#
# Modes:
#   MODE=audit     : scan & write CSV findings only
#   MODE=dry-run   : scan & write CSV + include proposed diff as last column
#   MODE=apply     : write changes + in-place backup + (optional) commit/push
#   MODE=rollback  : delete new file(s) + restore latest in-place backup + (optional) commit/push
#
# Env inputs (set by your Azure pipeline step):
#   ROOT (default: .)           - path to cloned target repo
#   MODE (required)             - audit|dry-run|apply|rollback
#   OUT_CSV (required)          - output CSV path (absolute recommended)
#   COMMIT (default: 0)         - 1 to commit changes
#   PUSH (default: 0)           - 1 to push changes
#   GITHUB_TOKEN (required for PUSH=1) - GitHub PAT/token for HTTPS pushes
#
# Notes:
# - This script is "best effort" for safe mechanical edits; for ambiguous pipelines,
#   it reports migration_changes in CSV for manual follow-up.
# - It focuses on the Azure DevOps YAML case that you are currently testing,
#   but will still detect other CI footprints for reporting.
# ============================================================================

ROOT="${ROOT:-.}"
MODE="${MODE:-}"
OUT_CSV="${OUT_CSV:-}"
COMMIT="${COMMIT:-0}"
PUSH="${PUSH:-0}"
REMOTE="${REMOTE:-origin}"

TS="$(date +%Y%m%d_%H%M%S)"
BACKUP_SUFFIX="backup_${TS}"

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

# Very small "build info" heuristic (kept from your earlier asks)
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
  # output as "N: text;N: text;..."
  awk -v pat="$pat" '
    BEGIN{c=0}
    { if($0 ~ pat){ c++; printf("%d: %s;", NR, $0); if(c>=30) exit } }
  ' "$f" | sed 's/[[:space:]]\+/ /g; s/;$/ /'
}

# ---------------- Azure pipeline transform logic ----------------
# Goal: migrate Polaris/Coverity-on-Polaris style to Black Duck/Coverity-in-Polaris style
# based on your current testing needs:
# - Update URL key/value to Black Duck
# - Keep file backup in-place; create new updated file

ado_apply_transform_azure_pipelines() {
  local rel="$1"      # e.g. azure-pipelines.yml
  local abs="$ROOT/$rel"
  [[ -f "$abs" ]] || return 1

  # Only act if file contains SynopsysBridge@ or SynopsysSecurityScan@ / Polaris markers
  if ! grep -Eq "SynopsysBridge@|SynopsysSecurityScan@|polaris" -- "$abs"; then
    return 1
  fi

  local tmp
  tmp="$(mktemp)"

  # Base: copy original to tmp then do conservative edits
  cp -f "$abs" "$tmp"

  # 1) If task is SynopsysSecurityScan@1 with scanType: polaris -> propose BlackDuckSecurityScan@1 and scanType: blackduck
  #    (You can tune this to your org's ADO extension task names if they differ.)
  sed -Ei \
    -e 's/(\-\s*task:\s*)SynopsysSecurityScan@([0-9]+)/\1BlackDuckSecurityScan@\2/g' \
    -e "s/(scanType:[[:space:]]*)'polaris'/\1'blackduck'/g" \
    -e 's/(displayName:[[:space:]]*")Synopsys Polaris/\1Black Duck/g' \
    "$tmp" 2>/dev/null || true

  # 2) If task is SynopsysBridge@1 and inputs indicate polaris:
  #    - bridge_build_type: polaris -> blackduck
  #    - polaris_server_url: ... -> blackduck_url: $(BLACKDUCK_URL)  (or replace literal polaris URL with BLACKDUCK_URL)
  #    - polaris_access_token -> blackduck_api_token (common naming) using $(BLACKDUCK_TOKEN)
  # NOTE: keys vary across orgs; keep safe: only rewrite keys when present.
  sed -Ei \
    -e 's/(bridge_build_type:[[:space:]]*)"polaris"/\1"blackduck"/g' \
    "$tmp" 2>/dev/null || true

  # Replace polaris_server_url key -> blackduck_url, and value:
  # - If value looks like a literal URL, replace with "$(BLACKDUCK_URL)"
  if grep -Eq '^[[:space:]]*polaris_server_url:' "$tmp"; then
    sed -Ei \
      -e 's/^[[:space:]]*polaris_server_url:[[:space:]]*".*"/      blackduck_url: "$(BLACKDUCK_URL)"/' \
      -e 's/^[[:space:]]*polaris_server_url:[[:space:]]*.*$/      blackduck_url: "$(BLACKDUCK_URL)"/' \
      "$tmp" 2>/dev/null || true
  fi

  # Replace polaris_access_token key -> blackduck_api_token (or blackduck_token)
  if grep -Eq '^[[:space:]]*polaris_access_token:' "$tmp"; then
    sed -Ei \
      -e 's/^[[:space:]]*polaris_access_token:[[:space:]]*"\$\(([^)]+)\)"/      blackduck_api_token: "$(\1)"/' \
      -e 's/^[[:space:]]*polaris_access_token:[[:space:]]*"\$\{[^}]+\}"/      blackduck_api_token: "$(BLACKDUCK_TOKEN)"/' \
      -e 's/^[[:space:]]*polaris_access_token:.*$/      blackduck_api_token: "$(BLACKDUCK_TOKEN)"/' \
      "$tmp" 2>/dev/null || true
  fi

  # Update display name hint (cosmetic)
  sed -Ei \
    -e 's/Synopsys Bridge: Coverity on Polaris/Synopsys Bridge: Black Duck Coverity/g' \
    -e 's/Black Duck Coverity on Polaris/Black Duck Coverity/g' \
    "$tmp" 2>/dev/null || true

  # If no changes, stop
  if cmp -s "$abs" "$tmp"; then
    rm -f "$tmp"
    return 1
  fi

  # Apply mode behavior:
  #   - rename original to *_backup_TIMESTAMP.yml
  #   - write new file with original name
  if [[ "$MODE" == "apply" ]]; then
    local backup="${abs%.yml}_backup_${TS}.yml"
    if [[ "$abs" == *.yaml ]]; then
      backup="${abs%.yaml}_backup_${TS}.yaml"
    fi

    mv -f "$abs" "$backup"
    cp -f "$tmp" "$abs"
    rm -f "$tmp"
    log "[APPLY] Updated $rel (backup: $(basename "$backup"))"
    return 0
  fi

  # Dry-run: do not touch FS; caller will diff
  rm -f "$tmp"
  return 0
}

ado_rollback_transform_azure_pipelines() {
  local rel="$1"
  local abs="$ROOT/$rel"
  [[ "$MODE" == "rollback" ]] || return 1

  # If azure-pipelines.yml exists and a backup exists, restore newest backup.
  # 1) Delete current file
  # 2) Move latest *_backup_*.yml back to original name
  local dir base ext
  dir="$(dirname "$abs")"
  base="$(basename "$abs")"
  ext="${base##*.}"  # yml/yaml

  local glob
  if [[ "$ext" == "yaml" ]]; then
    glob="${dir}/azure-pipelines_backup_*.yaml"
  else
    glob="${dir}/azure-pipelines_backup_*.yml"
  fi

  # Pick latest by lexical order (timestamp format ensures sortable)
  local latest=""
  for f in $glob; do
    [[ -f "$f" ]] || continue
    latest="$f"
  done

  if [[ -z "$latest" ]]; then
    return 1
  fi

  if [[ -f "$abs" ]]; then
    rm -f "$abs"
    log "[ROLLBACK] Deleted $rel"
  fi

  mv -f "$latest" "$abs"
  log "[ROLLBACK] Restored backup $(basename "$latest") -> $rel"
  return 0
}

# ---------------- CSV + scanning ----------------
list_pipeline_files() {
  # Print candidate files relative to repo root
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

# Build migration_changes for dry-run as diff; for audit, provide actionable steps
migration_changes_for_file() {
  local rel="$1"
  local abs="$ROOT/$rel"

  if [[ "$MODE" == "audit" ]]; then
    if grep -Eq "SynopsysBridge@" -- "$abs"; then
      echo "Replace SynopsysBridge polaris inputs with Black Duck inputs: bridge_build_type: blackduck; blackduck_url: \$(BLACKDUCK_URL); blackduck_api_token: \$(BLACKDUCK_TOKEN). Also update displayName if needed."
      return
    fi
    if grep -Eq "SynopsysSecurityScan@" -- "$abs"; then
      echo "Replace SynopsysSecurityScan@* (scanType: polaris) with BlackDuckSecurityScan@* (scanType: blackduck) OR your org's Black Duck ADO task. Validate service connection fields."
      return
    fi
    echo "Detected Synopsys/Polaris/Coverity markers. Review and migrate to Black Duck / Coverity in Polaris as per org standards."
    return
  fi

  if [[ "$MODE" == "dry-run" ]]; then
    local before tmp after
    tmp="$(mktemp)"
    cp -f "$abs" "$tmp"

    # simulate the same transform for diff generation
    MODE="apply" ado_apply_transform_azure_pipelines "$rel" >/dev/null 2>&1 || true
    # revert file system if apply touched (shouldn't in dry-run, but guard)
    if [[ -f "$abs" && -f "$tmp" ]]; then
      # If apply transformed, it'll have moved original away. Put it back.
      # But we never want dry-run to mutate, so restore from tmp and cleanup any backup we accidentally created.
      # Find any backup created at same path:
      local bglob="${abs%.*}_backup_${TS}.*"
      if compgen -G "$bglob" >/dev/null; then
        rm -f "$abs" || true
        mv -f $bglob "$abs" || true
      fi
      cp -f "$tmp" "$abs"
    fi

    # Instead: generate diff by transforming content in-memory (safer)
    # We'll do that now:
    local transformed
    transformed="$(mktemp)"
    cp -f "$tmp" "$transformed"
    # apply sed transforms onto transformed temp
    sed -Ei \
      -e 's/(\-\s*task:\s*)SynopsysSecurityScan@([0-9]+)/\1BlackDuckSecurityScan@\2/g' \
      -e "s/(scanType:[[:space:]]*)'polaris'/\1'blackduck'/g" \
      -e 's/(displayName:[[:space:]]*")Synopsys Polaris/\1Black Duck/g' \
      "$transformed" 2>/dev/null || true
    sed -Ei -e 's/(bridge_build_type:[[:space:]]*)"polaris"/\1"blackduck"/g' "$transformed" 2>/dev/null || true
    if grep -Eq '^[[:space:]]*polaris_server_url:' "$transformed"; then
      sed -Ei \
        -e 's/^[[:space:]]*polaris_server_url:.*$/      blackduck_url: "$(BLACKDUCK_URL)"/' \
        "$transformed" 2>/dev/null || true
    fi
    if grep -Eq '^[[:space:]]*polaris_access_token:' "$transformed"; then
      sed -Ei \
        -e 's/^[[:space:]]*polaris_access_token:.*$/      blackduck_api_token: "$(BLACKDUCK_TOKEN)"/' \
        "$transformed" 2>/dev/null || true
    fi

    local d
    d="$(diff -u "$tmp" "$transformed" | head -n 200 || true)"
    rm -f "$tmp" "$transformed"
    echo "${d:-NO_DIFF}"
    return
  fi

  # apply/rollback: we can keep column blank or short note (you preferred real diff mainly for dry-run)
  echo ""
}

# ---------------- Commit / Push ----------------
set_remote_with_token_for_push() {
  [[ "$PUSH" == "1" ]] || return 0
  local url
  url="$(git -C "$ROOT" config --get "remote.${REMOTE}.url" || true)"
  [[ -n "$url" ]] || die "remote.${REMOTE}.url not found"

  # Only rewrite https://github.com/... URLs; if already tokenized, keep.
  if [[ "$url" =~ ^https://github.com/ ]]; then
    local authed="https://x-access-token:${GITHUB_TOKEN}@github.com/${url#https://github.com/}"
    git -C "$ROOT" remote set-url "$REMOTE" "$authed"
    # Do not echo authed URL (token)
  fi
}

commit_and_push_if_needed() {
  local branch="$1"
  local changed_files=("$@") # includes branch; we handle below
  shift

  local any_changes=0
  for f in "$@"; do
    if [[ -n "$f" && -e "$ROOT/$f" ]]; then
      if ! git -C "$ROOT" diff --quiet -- "$f" 2>/dev/null; then
        any_changes=1
      fi
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

  # Configure identity (safe)
  git -C "$ROOT" config user.email "azure-pipelines@local" || true
  git -C "$ROOT" config user.name "azure-pipelines" || true

  # IMPORTANT: Only add known pipeline/backup files; never add CSV.
  git -C "$ROOT" add -- "$@" || true

  if git -C "$ROOT" diff --cached --quiet; then
    log "[INFO] Nothing staged; skipping commit/push."
    return 0
  fi

  git -C "$ROOT" commit -m "Synopsys â†’ Black Duck migration (${MODE}) [${TS}]" || true

  if [[ "$PUSH" == "1" ]]; then
    set_remote_with_token_for_push
    # Push current HEAD to same branch
    git -C "$ROOT" push "$REMOTE" "HEAD:$branch"
    log "[INFO] Pushed changes to $branch"
  fi
}

# ---------------- Main ----------------
main() {
  assert_inputs

  # Normalize OUT_CSV to absolute if it isn't (helps avoid double-prefix bugs)
  if [[ "$OUT_CSV" != /* ]]; then OUT_CSV="$(pwd)/$OUT_CSV"; fi

  ensure_csv_header

  local repo branch info build_type pm
  repo="$(repo_url_of)"
  branch="$(current_branch)"
  info="$(build_info_of_repo)"
  build_type="${info%%|*}"
  pm="${info#*|}"

  # Scan files
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

    # Apply/rollback actions (Azure pipelines only for now)
    if [[ "$MODE" == "apply" && "$rel" =~ azure-pipelines\.ya?ml$ ]]; then
      if ado_apply_transform_azure_pipelines "$rel"; then
        # track new file + backup file pattern
        changed_paths+=("$rel")
        # backup name is computed inside function; discover it:
        local bglob
        bglob="$ROOT/${rel%.*}_backup_${TS}.${rel##*.}"
        if compgen -G "$bglob" >/dev/null; then
          # convert to rel path
          changed_paths+=("$(basename "$bglob")")
        else
          # fallback: find any backup in root
          for bf in "$ROOT"/azure-pipelines_backup_"$TS".yml "$ROOT"/azure-pipelines_backup_"$TS".yaml; do
            [[ -f "$bf" ]] && changed_paths+=("$(basename "$bf")")
          done
        fi
      fi
    fi

    if [[ "$MODE" == "rollback" && "$rel" =~ azure-pipelines\.ya?ml$ ]]; then
      if ado_rollback_transform_azure_pipelines "$rel"; then
        changed_paths+=("$rel")
      fi
    fi

  done < <(list_pipeline_files)

  # Commit/push only if we changed something and the caller requested
  if [[ "$MODE" == "apply" || "$MODE" == "rollback" ]]; then
    if [[ ${#changed_paths[@]} -gt 0 ]]; then
      # De-dup and keep only existing paths
      local uniq=()
      local seen=""
      for p in "${changed_paths[@]}"; do
        [[ -n "$p" ]] || continue
        if [[ "$seen" != *"|$p|"* ]]; then
          seen+="|$p|"
          # Only stage if file exists OR it was deleted (rollback deletes azure-pipelines.yml then restores; net exists)
          uniq+=("$p")
        fi
      done

      # Commit/push these paths only
      commit_and_push_if_needed "$branch" "${uniq[@]}"
    else
      log "[INFO] No changes applied on $branch; skipping commit/push."
    fi
  fi

  log "Done."
  log "CSV: $OUT_CSV"
  log "Backups (apply): <in-place azure-pipelines_backup_${TS}.yml/.yaml>"
}

main "$@"
