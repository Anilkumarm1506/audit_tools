#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Script: synopsys_to_blackduck_migrate_v5.sh
#
# What’s new vs v4:
# ✅ Dry-run shows real diffs reliably (same transforms as apply, on temp copy)
# ✅ Audit CSV includes build_type + package_manager_file (monorepo-aware)
# ✅ invocation_style "unknown" reduced (bridge.yml / env-var patterns / travis/bamboo/gha better classified)
# ✅ Modes: audit | dry-run | apply | rollback (same semantics)
# ✅ Backups per-branch before edits: .migrate_backups/<ts>/<branch>/<file>
# ✅ Apply: backup + update + commit + push (token handled by pipeline)
# ✅ Rollback: git revert last bd-migration commit OR restore latest backups for that branch
#
# Usage (local):
#   MODE=audit    BRANCHES="main,dev" ROOT=/repo OUT_CSV=out.csv ./synopsys_to_blackduck_migrate_v5.sh
#   MODE=dry-run  BRANCHES="main"     ROOT=/repo OUT_CSV=out.csv ./synopsys_to_blackduck_migrate_v5.sh
#   MODE=apply    BRANCHES="main"     ROOT=/repo OUT_CSV=out.csv ./synopsys_to_blackduck_migrate_v5.sh
#   MODE=rollback BRANCHES="main"     ROOT=/repo OUT_CSV=out.csv ./synopsys_to_blackduck_migrate_v5.sh
#
# Env:
#   MODE=audit|dry-run|apply|rollback
#   ROOT=path-to-git-repo
#   OUT_CSV=csv-file (aggregated)
#   BRANCHES="comma,separated,branches" (optional; default current)
#   ALL_BRANCHES=1 (optional; scan all remote branches)
#   REMOTE=origin (default origin)
#   PUSH=1|0 (default 0 for audit/dry-run, 1 for apply/rollback when used by pipeline)
#   COMMIT=1|0 (default 0 for audit/dry-run, 1 for apply/rollback when used by pipeline)
#   ALLOW_DIRTY=1|0 (default 0)
#   MAX_PM_PATHS_PER_TYPE=10 (default 10)
#
# NOTE:
# - This script edits only CI YAML + bridge.yml by default.
# - Jenkinsfile editing is disabled by default (EDIT_JENKINS=0). You can enable if needed.
# ============================================================

ROOT="${ROOT:-.}"
MODE="${MODE:-audit}"                         # audit|dry-run|apply|rollback
OUT_CSV="${OUT_CSV:-synopsys_audit.csv}"

BRANCHES="${BRANCHES:-}"                      # comma-separated list
ALL_BRANCHES="${ALL_BRANCHES:-0}"

REMOTE="${REMOTE:-origin}"
PUSH="${PUSH:-0}"
COMMIT="${COMMIT:-0}"
ALLOW_DIRTY="${ALLOW_DIRTY:-0}"
EDIT_JENKINS="${EDIT_JENKINS:-0}"
STRICT_REPLACE="${STRICT_REPLACE:-0}"         # currently conservative; kept for future

MAX_PM_PATHS_PER_TYPE="${MAX_PM_PATHS_PER_TYPE:-10}"

TS="$(date +%Y%m%d_%H%M%S)"
MIGRATE_TAG="bd-migration:${TS}"
BACKUP_ROOT=".migrate_backups/${TS}"

shopt -s globstar nullglob

# We scan these; we only modify YAML/bridge.yml (and Jenkinsfile only if EDIT_JENKINS=1).
PIPELINE_GLOBS=(
  ".travis.yml"
  "azure-pipelines.yml" "azure-pipelines.yaml"
  ".github/workflows/*.yml" ".github/workflows/*.yaml"
  "bamboo-specs/**/*.yml" "bamboo-specs/**/*.yaml"
  "**/bamboo-specs.yml" "**/bamboo-specs.yaml"
  "bridge.yml" "bridge.yaml"
  "Jenkinsfile" "Jenkinsfile*"
)

# Detection patterns
DIRECT_PATTERN='polaris|coverity|coverity-on-polaris|cov-build|cov-analyze|cov-capture|cov-commit-defects|synopsys[- ]?bridge|bridge(\.exe)?|bridge\.yml|bridge\.yaml|--stage[[:space:]]+polaris|--stage[[:space:]]+blackduck|--input[[:space:]]+bridge\.ya?ml|synopsys-sig/synopsys-action|SynopsysSecurityScan@|BlackDuckSecurityScan@|CoverityOnPolaris|withCoverityEnv|coverityScan|coverityPublisher|covBuild|covAnalyze|covCommitDefects'

# Helpful env var markers (to improve invocation_style classification)
ENV_MARKERS_PATTERN='POLARIS_SERVER_URL|POLARIS_ACCESS_TOKEN|COVERITY_URL|COVERITY_STREAM|BLACKDUCK_URL|BLACKDUCK_API_TOKEN|BLACKDUCK_TOKEN'

die(){ echo "ERROR: $*" >&2; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }
grep_q(){ grep -Eq "$1" -- "$2" 2>/dev/null; }
grep_in(){ grep -Ein "$1" -- "$2" 2>/dev/null || true; }

csv_escape(){
  echo "$1" | sed -E 's/"/""/g' | tr '\n' ' ' | sed -E 's/[[:space:]]+$//'
}

ensure_csv_header(){
  if [[ ! -s "$OUT_CSV" ]]; then
    echo "repo,branch,build_type,package_manager_file,file_path,ci_type,found_type,invocation_style,evidence" > "$OUT_CSV"
  fi
}

assert_git_repo(){
  git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "ROOT is not a git repo: $ROOT"
}

assert_clean_or_allowed(){
  if [[ "$ALLOW_DIRTY" -ne 1 ]]; then
    [[ -z "$(git -C "$ROOT" status --porcelain)" ]] || die "Repo has uncommitted changes. Commit/stash or set ALLOW_DIRTY=1"
  fi
}

repo_url_of(){
  local url
  url="$(git -C "$ROOT" config --get remote.origin.url 2>/dev/null || true)"
  [[ -n "$url" ]] && echo "$url" || echo "$(basename "$ROOT")"
}

current_branch(){
  local b=""
  b="$(git -C "$ROOT" branch --show-current 2>/dev/null || true)"
  [[ -n "$b" ]] && echo "$b" || echo "unknown"
}

ci_type_of(){
  local rel="$1"
  if [[ "$rel" == ".travis.yml" ]]; then echo "travis"
  elif [[ "$rel" == "azure-pipelines.yml" || "$rel" == "azure-pipelines.yaml" ]]; then echo "azure_devops"
  elif [[ "$rel" == .github/workflows/*.yml || "$rel" == .github/workflows/*.yaml ]]; then echo "github_actions"
  elif [[ "$rel" == *bamboo-specs* || "$rel" == *bamboo-specs.y*ml ]]; then echo "bamboo"
  elif [[ "$rel" == Jenkinsfile* ]]; then echo "jenkins"
  elif [[ "$rel" == bridge.y*ml ]]; then echo "bridge_config"
  else echo "unknown"
  fi
}

found_type_of(){
  local f="$1"
  if grep_q "$DIRECT_PATTERN" "$f"; then echo "direct"; else echo "none"; fi
}

# Improved invocation style classifier (reduces "unknown")
invocation_style_of(){
  local f="$1"
  local rel="${f#$ROOT/}"

  # bridge config file itself
  if [[ "$rel" == bridge.y*ml ]]; then
    if grep_q '^\s*stage:\s*$' "$f" || grep_q '^\s*polaris\s*:' "$f" || grep_q '^\s*blackduck\s*:' "$f"; then
      echo "bridge_config_file"; return
    fi
  fi

  # GitHub Synopsys Action
  if grep_q 'uses:\s*synopsys-sig/synopsys-action' "$f"; then
    echo "github_action_synopsys_action"; return
  fi

  # Azure DevOps task extensions
  if grep_q 'SynopsysSecurityScan@|BlackDuckSecurityScan@|CoverityOnPolaris' "$f"; then
    echo "ado_task_extension"; return
  fi

  # Bridge CLI invocation in any script/YAML
  if grep_q '(^|[[:space:]/])bridge([[:space:]]|$)|synopsys[- ]?bridge|--input[[:space:]]+bridge\.ya?ml|--stage[[:space:]]+(polaris|blackduck)' "$f"; then
    echo "bridge_cli"; return
  fi

  # Coverity CLI invocation
  if grep_q 'cov-build|cov-analyze|cov-capture|cov-commit-defects|cov-format-errors' "$f"; then
    echo "coverity_cli"; return
  fi

  # Jenkins plugin steps
  if grep_q 'withCoverityEnv|coverityScan|coverityPublisher|covBuild|covAnalyze|covCommitDefects' "$f"; then
    echo "jenkins_coverity_plugin_steps"; return
  fi

  # Polaris config/env only (seen in Jenkins env blocks etc.)
  if grep_q 'POLARIS_SERVER_URL|POLARIS_ACCESS_TOKEN|polaris_server_url|polaris_access_token' "$f"; then
    echo "polaris_env_or_config"; return
  fi

  echo "unknown"
}

evidence_lines(){
  local f="$1"
  local n=10
  (
    grep_in "$DIRECT_PATTERN|$ENV_MARKERS_PATTERN" "$f" \
      | head -n "$n" \
      | sed -E 's/"/""/g' \
      | tr '\n' ';' \
      | sed 's/;*$//'
  )
}

# ----------------------------
# Build detection (monorepo-aware, multi-path)
# ----------------------------

repo_file_index(){
  git -C "$ROOT" ls-files --cached --others --exclude-standard 2>/dev/null || true
}

collect_paths_with_fallback(){
  local files="$1"
  local regex="$2"
  shift 2
  local -a fallback_names=("$@")

  local out=""
  out="$(echo "$files" | grep -Ei "$regex" | head -n "$MAX_PM_PATHS_PER_TYPE" || true)"

  if [[ -z "$out" && ${#fallback_names[@]} -gt 0 ]]; then
    out="$(cd "$ROOT" && \
      find . -type f \
        -not -path './.git/*' -not -path '*/.git/*' \
        -not -path '*/node_modules/*' -not -path '*/.gradle/*' \
        -not -path '*/target/*' -not -path '*/build/*' \
        \( $(printf -- '-name %q -o ' "${fallback_names[@]}" | sed 's/ -o $//') \) \
        -print 2>/dev/null | sed 's|^\./||' | head -n "$MAX_PM_PATHS_PER_TYPE")" || true
  fi

  if [[ -n "$out" ]]; then
    echo "$out" | paste -sd ';' - | sed 's/;/; /g'
  else
    echo ""
  fi
}

build_info_of_repo(){
  local files; files="$(repo_file_index)"
  [[ -n "$files" ]] || { echo "unknown|unknown"; return; }

  local types=()
  local pm_paths=()

  local maven_paths gradle_paths npm_paths docker_paths

  maven_paths="$(collect_paths_with_fallback "$files" '(^|/)pom\.xml$|(^|/)(mvnw|mvnw\.cmd)$' "pom.xml" "mvnw" "mvnw.cmd")"
  [[ -n "$maven_paths" ]] && { types+=("maven"); pm_paths+=("$maven_paths"); }

  gradle_paths="$(collect_paths_with_fallback "$files" '(^|/)(build\.gradle|build\.gradle\.kts|settings\.gradle|settings\.gradle\.kts|gradle\.properties|gradlew|gradlew\.bat)$' \
    "build.gradle" "build.gradle.kts" "settings.gradle" "settings.gradle.kts" "gradle.properties" "gradlew" "gradlew.bat")"
  [[ -n "$gradle_paths" ]] && { types+=("gradle"); pm_paths+=("$gradle_paths"); }

  npm_paths="$(collect_paths_with_fallback "$files" '(^|/)package\.json$|(^|/)(package-lock\.json|yarn\.lock|pnpm-lock\.ya?ml|pnpm-workspace\.ya?ml|lerna\.json|nx\.json|turbo\.json)$' \
    "package.json" "package-lock.json" "yarn.lock" "pnpm-lock.yaml" "pnpm-lock.yml" "pnpm-workspace.yaml" "pnpm-workspace.yml")"
  [[ -n "$npm_paths" ]] && { types+=("npm"); pm_paths+=("$npm_paths"); }

  docker_paths="$(collect_paths_with_fallback "$files" '(^|/)Dockerfile$|(^|/)docker-compose\.ya?ml$' "Dockerfile" "docker-compose.yml" "docker-compose.yaml")"
  [[ -n "$docker_paths" ]] && { types+=("docker"); pm_paths+=("$docker_paths"); }

  if [[ ${#types[@]} -eq 0 ]]; then echo "unknown|unknown"; return; fi

  local build_out=""; local i
  for i in "${!types[@]}"; do
    [[ -z "$build_out" ]] && build_out="${types[$i]}" || build_out="${build_out}+${types[$i]}"
  done

  local pm_out=""
  for i in "${!types[@]}"; do
    local label="${types[$i]}"
    local paths="${pm_paths[$i]}"
    [[ -z "$paths" ]] && continue
    [[ -z "$pm_out" ]] && pm_out="${label}: ${paths}" || pm_out="${pm_out} || ${label}: ${paths}"
  done

  echo "${build_out}|${pm_out}"
}

# ----------------------------
# File collection
# ----------------------------

collect_target_files(){
  local files=()
  local g f
  for g in "${PIPELINE_GLOBS[@]}"; do
    for f in "$ROOT"/$g; do
      [[ -f "$f" ]] && files+=("${f#$ROOT/}")
    done
  done
  printf "%s\n" "${files[@]}" | awk '!seen[$0]++'
}

# ----------------------------
# Backup + rollback
# ----------------------------

backup_file(){
  local rel="$1"
  local br="$2"
  local dst="$BACKUP_ROOT/$br/$rel"
  mkdir -p "$(dirname "$ROOT/$dst")"
  cp -p "$ROOT/$rel" "$ROOT/$dst"
}

commit_and_push_if_needed(){
  local br="$1"

  [[ "$COMMIT" -eq 1 ]] || { echo "[INFO] COMMIT=0, skipping commit"; return 0; }

  git -C "$ROOT" add -A

  if git -C "$ROOT" diff --cached --quiet; then
    echo "[INFO] No staged changes; skipping commit."
    return 0
  fi

  git -C "$ROOT" commit -m "$MIGRATE_TAG ($br)"

  [[ "$PUSH" -eq 1 ]] || { echo "[INFO] PUSH=0, skipping push"; return 0; }
  git -C "$ROOT" push "$REMOTE" "HEAD:$br"
}

rollback_branch(){
  local br="$1"

  # Prefer revert of last bd-migration commit
  local last
  last="$(git -C "$ROOT" log --grep="^bd-migration:" -n 1 --pretty=format:%H 2>/dev/null || true)"
  if [[ -n "$last" ]]; then
    echo "[ROLLBACK] Reverting $last on $br"
    git -C "$ROOT" revert --no-edit "$last"
    [[ "$PUSH" -eq 1 ]] && git -C "$ROOT" push "$REMOTE" "HEAD:$br"
    return 0
  fi

  # Fallback restore from newest backup for this branch
  local newest
  newest="$(cd "$ROOT" && ls -1d .migrate_backups/*/"$br" 2>/dev/null | sort | tail -n 1 || true)"
  [[ -n "$newest" ]] || die "No migration commit and no backups found for branch $br"

  echo "[ROLLBACK] Restoring from backup dir: $newest"
  (cd "$ROOT" && rsync -a --exclude '.git/' "$newest"/ ./)
  commit_and_push_if_needed "$br"
}

# ----------------------------
# Migration transforms (conservative)
# ----------------------------

transform_bridge_stage(){
  local f="$1"
  perl -0777 -i -pe 's/(--stage\s+)polaris\b/$1blackduck/g' "$f"
}

ensure_blackduck_env_placeholders(){
  local f="$1"
  grep -Eq 'BLACKDUCK_(URL|API_TOKEN|TOKEN)' "$f" && return 0

  perl -0777 -i -pe '
    if ($m =~ /POLARIS_SERVER_URL/ && $m !~ /BLACKDUCK_URL/) {
      $m =~ s/(POLARIS_SERVER_URL[^\n]*\n)/$1# TODO: Set Black Duck connection (prefer secrets\/CI vars)\n# BLACKDUCK_URL=__set_in_ci_secret__\n# BLACKDUCK_API_TOKEN=__set_in_ci_secret__\n/s;
    }
  ' -pe '$m=$_; $_=$m' "$f"
}

transform_bridge_yml_add_blackduck_stage(){
  local f="$1"
  grep -Eq '^\s*blackduck\s*:' "$f" && return 0

  if grep -Eq '^\s*stage:\s*$' "$f" && grep -Eq '^\s*polaris\s*:' "$f"; then
    cat >> "$f" <<'EOF'

  # --- Added by migration script (placeholder) ---
  blackduck:
    # TODO: set these via CI secrets/environment variables
    url: "${BLACKDUCK_URL}"
    apiToken: "${BLACKDUCK_API_TOKEN}"
    project:
      name: "juice-shop"   # TODO: align with your BD project name
      version: "main"      # TODO: align with your BD version naming
EOF
    return 0
  fi

  if grep -Eq '^\s*polaris\s*:' "$f"; then
    cat >> "$f" <<'EOF'

# --- Added by migration script (placeholder) ---
# TODO: This file did not match expected "stage:" layout; review placement/indentation.
blackduck:
  url: "${BLACKDUCK_URL}"
  apiToken: "${BLACKDUCK_API_TOKEN}"
EOF
  fi
}

transform_ado_synopsys_task_to_blackduck(){
  local f="$1"
  if grep -Eq '^\s*-\s*task:\s*SynopsysSecurityScan@' "$f"; then
    perl -0777 -i -pe 's/^(\s*-\s*task:\s*)SynopsysSecurityScan(@[0-9A-Za-z\.\-_]+)?/$1BlackDuckSecurityScan$2/mg' "$f"
    perl -0777 -i -pe 's/(\bscanType:\s*[\"\x27]?)polaris([\"\x27]?)/$1blackduck$2/g' "$f"
    perl -0777 -i -pe 's/\bpolarisService:\s*/blackDuckService: /g' "$f"

    if ! grep -Eq 'TODO: Verify Black Duck' "$f"; then
      perl -0777 -i -pe 's/^(.*BlackDuckSecurityScan@.*\n)/$1  # TODO: Verify Black Duck task inputs (service connection, project\/version, scan mode, wait\/fail conditions)\n/m' "$f"
    fi
  fi
}

transform_ado_add_blackduck_step(){
  local f="$1"
  grep -Eq 'cov-build|cov-analyze|cov-commit-defects' "$f" || return 0
  grep -Eq '^\s*steps\s*:' "$f" || return 0
  grep -Eq 'BlackDuckSecurityScan@' "$f" && return 0

  perl -0777 -i -pe '
    if ($m =~ /-\s*checkout:\s*self.*?\n/s && $m !~ /BlackDuckSecurityScan@/s) {
      $m =~ s/(-\s*checkout:\s*self[^\n]*\n(?:\s*clean:\s*true[^\n]*\n)?)/$1\n- task: BlackDuckSecurityScan@1\n  displayName: "Black Duck SCA Scan (Added by migration script)"\n  inputs:\n    # TODO: configure according to your extension inputs\n    blackDuckService: "BlackDuck-Service-Connection"\n    projectName: "juice-shop"\n    versionName: "$(Build.SourceBranchName)"\n    waitForScan: true\n\n/s;
    }
  ' -pe '$m=$_; $_=$m' "$f"
}

transform_gha_bridge_cli(){
  local f="$1"
  transform_bridge_stage "$f"
  ensure_blackduck_env_placeholders "$f"
}

transform_gha_synopsys_action_add_bd_step(){
  local f="$1"
  grep -Eq 'uses:\s*synopsys-sig/synopsys-action' "$f" || return 0
  grep -Eq 'name:\s*Black Duck Scan' "$f" && return 0

  cat >> "$f" <<'EOF'

# --- Added by migration script (placeholder) ---
# TODO: Add your org-approved Black Duck scan step.
# - name: Black Duck Scan
#   uses: <org-approved-blackduck-action>@<version>
#   with:
#     blackduck.url: ${{ secrets.BLACKDUCK_URL }}
#     blackduck.api.token: ${{ secrets.BLACKDUCK_API_TOKEN }}
#     blackduck.project.name: juice-shop
#     blackduck.project.version: ${{ github.ref_name }}
EOF
}

transform_travis(){
  local f="$1"
  transform_bridge_stage "$f"
  ensure_blackduck_env_placeholders "$f"
}

transform_bamboo(){
  local f="$1"
  transform_bridge_stage "$f"
  ensure_blackduck_env_placeholders "$f"
}

transform_jenkins_if_enabled(){
  local f="$1"
  [[ "$EDIT_JENKINS" -eq 1 ]] || return 0
  transform_bridge_stage "$f"
  ensure_blackduck_env_placeholders "$f"
}

apply_transform_to_path(){
  local rel="$1"
  local abs="$ROOT/$rel"
  local ci; ci="$(ci_type_of "$rel")"

  case "$ci" in
    travis) transform_travis "$abs" ;;
    bamboo) transform_bamboo "$abs" ;;
    azure_devops)
      transform_ado_synopsys_task_to_blackduck "$abs"
      transform_ado_add_blackduck_step "$abs"
      ;;
    github_actions)
      if grep_q '(^|[[:space:]/])bridge([[:space:]]|$)|--input[[:space:]]+bridge\.ya?ml|--stage[[:space:]]+polaris' "$abs"; then
        transform_gha_bridge_cli "$abs"
      fi
      transform_gha_synopsys_action_add_bd_step "$abs"
      ;;
    bridge_config) transform_bridge_yml_add_blackduck_stage "$abs" ;;
    jenkins) transform_jenkins_if_enabled "$abs" ;;
    *) return 1 ;;
  esac
  return 0
}

# ----------------------------
# Dry-run diff (FIXED, reliable)
# ----------------------------

dry_run_diff_file(){
  local rel="$1"
  local abs="$ROOT/$rel"
  [[ -f "$abs" ]] || return 0

  local tmp
  tmp="$(mktemp)"
  cp -p "$abs" "$tmp"

  case "$(ci_type_of "$rel")" in
    travis) transform_travis "$tmp" ;;
    bamboo) transform_bamboo "$tmp" ;;
    azure_devops)
      transform_ado_synopsys_task_to_blackduck "$tmp"
      transform_ado_add_blackduck_step "$tmp"
      ;;
    github_actions)
      if grep -Eq '(^|[[:space:]/])bridge([[:space:]]|$)|--input[[:space:]]+bridge\.ya?ml|--stage[[:space:]]+polaris' "$tmp"; then
        transform_gha_bridge_cli "$tmp"
      fi
      transform_gha_synopsys_action_add_bd_step "$tmp"
      ;;
    bridge_config) transform_bridge_yml_add_blackduck_stage "$tmp" ;;
    jenkins) transform_jenkins_if_enabled "$tmp" ;;
    *) ;;
  esac

  if ! diff -u -- "$abs" "$tmp" >/dev/null 2>&1; then
    echo
    echo "---- Proposed diff: $rel ----"
    diff -u -- "$abs" "$tmp" || true
    echo "---- End diff: $rel ----"
    rm -f "$tmp"
    return 1
  fi

  rm -f "$tmp"
  return 0
}

# ----------------------------
# Audit report writer
# ----------------------------

audit_files_to_csv(){
  local br="$1"
  local repo; repo="$(repo_url_of)"
  local info build_type pm_file
  info="$(build_info_of_repo)"
  build_type="${info%%|*}"
  pm_file="${info#*|}"

  local rel abs found ci style ev

  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    abs="$ROOT/$rel"
    [[ -f "$abs" ]] || continue

    found="$(found_type_of "$abs")"
    [[ "$found" == "direct" ]] || continue

    ci="$(ci_type_of "$rel")"
    style="$(invocation_style_of "$abs")"
    ev="$(evidence_lines "$abs")"

    echo "[DIRECT] $repo@$br :: $rel (ci=$ci, style=$style, build=$build_type)"
    echo "\"$(csv_escape "$repo")\",\"$(csv_escape "$br")\",\"$(csv_escape "$build_type")\",\"$(csv_escape "$pm_file")\",\"$(csv_escape "$rel")\",\"$(csv_escape "$ci")\",\"direct\",\"$(csv_escape "$style")\",\"$(csv_escape "$ev")\"" >> "$OUT_CSV"
  done < <(collect_target_files)
}

# ----------------------------
# Branch selection/checkout
# ----------------------------

list_branches(){
  if [[ "$ALL_BRANCHES" -eq 1 ]]; then
    git -C "$ROOT" fetch --all --prune >/dev/null 2>&1 || true
    git -C "$ROOT" for-each-ref --format='%(refname:short)' "refs/remotes/$REMOTE" \
      | sed -E "s|^$REMOTE/||" | grep -vE '^(HEAD)$' | awk '!seen[$0]++'
    return
  fi

  if [[ -n "$BRANCHES" ]]; then
    echo "$BRANCHES" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | awk 'NF' | awk '!seen[$0]++'
    return
  fi

  current_branch
}

checkout_branch(){
  local br="$1"
  git -C "$ROOT" checkout -q "$br" || git -C "$ROOT" checkout -q -b "$br" "$REMOTE/$br"
}

# ----------------------------
# Main
# ----------------------------

[[ "$MODE" =~ ^(audit|dry-run|apply|rollback)$ ]] || die "Invalid MODE=$MODE"
assert_git_repo
ensure_csv_header

if [[ "$MODE" == "apply" || "$MODE" == "rollback" ]]; then
  assert_clean_or_allowed
fi

echo "Mode: $MODE"
echo "Repo: $ROOT"
echo "CSV : $OUT_CSV"
echo "Backups root (apply): $BACKUP_ROOT"
echo

while IFS= read -r br; do
  [[ -n "$br" ]] || continue
  echo "=== Branch: $br ==="
  checkout_branch "$br"

  # Always audit into CSV
  audit_files_to_csv "$br"

  if [[ "$MODE" == "audit" ]]; then
    continue
  fi

  if [[ "$MODE" == "rollback" ]]; then
    rollback_branch "$br"
    continue
  fi

  if [[ "$MODE" == "dry-run" ]]; then
    changed_any=0
    while IFS= read -r rel; do
      [[ -n "$rel" ]] || continue
      abs="$ROOT/$rel"
      [[ -f "$abs" ]] || continue
      [[ "$(found_type_of "$abs")" == "direct" ]] || continue

      # Jenkins edits are off by default
      if [[ "$(ci_type_of "$rel")" == "jenkins" && "$EDIT_JENKINS" -ne 1 ]]; then
        continue
      fi

      if dry_run_diff_file "$rel"; then
        :
      else
        changed_any=1
      fi
    done < <(collect_target_files)

    [[ "$changed_any" -eq 0 ]] && echo "[INFO] No diffs to show for branch $br"
    continue
  fi

  # MODE=apply
  any_change=0
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    abs="$ROOT/$rel"
    [[ -f "$abs" ]] || continue
    [[ "$(found_type_of "$abs")" == "direct" ]] || continue

    if [[ "$(ci_type_of "$rel")" == "jenkins" && "$EDIT_JENKINS" -ne 1 ]]; then
      echo "[SKIP] Jenkins edits disabled (EDIT_JENKINS=0): $rel"
      continue
    fi

    backup_file "$rel" "$br"
    before="$(sha1sum "$abs" | awk '{print $1}')"
    apply_transform_to_path "$rel" || true
    after="$(sha1sum "$abs" | awk '{print $1}')"

    if [[ "$before" != "$after" ]]; then
      echo "[APPLY] Updated: $rel (backup: $BACKUP_ROOT/$br/$rel)"
      any_change=1
    else
      echo "[INFO] No changes for: $rel"
    fi
  done < <(collect_target_files)

  if [[ "$any_change" -eq 1 ]]; then
    commit_and_push_if_needed "$br"
  else
    echo "[INFO] No changes applied on $br; skipping commit/push."
  fi

done < <(list_branches)

echo
echo "Done."
echo "CSV: $OUT_CSV"
echo "Backups (apply): $BACKUP_ROOT"
