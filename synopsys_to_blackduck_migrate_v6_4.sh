synopsys_to_blackduck_migrate_v6_4.sh.txt


Anil Kumar M

​
Anil Kumar M​


Get Outlook for Android
#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Script: synopsys_to_blackduck_migrate_v6_4.sh
# Fixes vs v6:
#   - Removes the self-redefining build_info_of_repo() recursion that caused exit code 139
#   - Corrects build_type/package_manager_file join formatting (no stray brace)
# ============================================================

ROOT="${ROOT:-.}"
MODE="${MODE:-audit}"                       # audit|dry-run|apply|rollback
OUT_CSV="${OUT_CSV:-synopsys_audit.csv}"

# ------------------------------------------------------------
# v6.2 fix: Normalize OUT_CSV path ONCE to avoid double-prefix
# - If OUT_CSV is relative, make it absolute using current working dir
# - If already absolute, keep as-is
# ------------------------------------------------------------
if [[ "${OUT_CSV}" != /* ]]; then
  OUT_CSV="$(pwd)/${OUT_CSV}"
fi

DRYRUN_DIFF_FILE="${DRYRUN_DIFF_FILE:-dryrun_diffs.txt}"

BRANCHES="${BRANCHES:-}"
ALL_BRANCHES="${ALL_BRANCHES:-0}"

REMOTE="${REMOTE:-origin}"
COMMIT="${COMMIT:-0}"
PUSH="${PUSH:-0}"
ALLOW_DIRTY="${ALLOW_DIRTY:-0}"
EDIT_JENKINS="${EDIT_JENKINS:-0}"

MAX_PM_PATHS_PER_TYPE="${MAX_PM_PATHS_PER_TYPE:-10}"

TS="$(date +%Y%m%d_%H%M%S)"
MIGRATE_TAG="bd-migration:${TS}"
BACKUP_ROOT=".migrate_backups/${TS}"

shopt -s globstar nullglob

PIPELINE_GLOBS=(
  ".travis.yml"
  "azure-pipelines.yml" "azure-pipelines.yaml"
  ".github/workflows/*.yml" ".github/workflows/*.yaml"
  "bamboo-specs/**/*.yml" "bamboo-specs/**/*.yaml"
  "**/bamboo-specs.yml" "**/bamboo-specs.yaml"
  "bridge.yml" "bridge.yaml"
  "Jenkinsfile" "Jenkinsfile*"
)

DIRECT_PATTERN='polaris|coverity|coverity-on-polaris|cov-build|cov-analyze|cov-capture|cov-commit-defects|cov-format-errors|synopsys[- ]?bridge|bridge(\.exe)?|bridge\.yml|bridge\.yaml|--stage[[:space:]]+polaris|--stage[[:space:]]+blackduck|--input[[:space:]]+bridge\.ya?ml|synopsys-sig/synopsys-action|SynopsysSecurityScan@|BlackDuckSecurityScan@|CoverityOnPolaris|withCoverityEnv|coverityScan|coverityPublisher|covBuild|covAnalyze|covCommitDefects'

PAT_GHA_ACTION='uses:\s*synopsys-sig/synopsys-action'
PAT_ADO_TASK='SynopsysSecurityScan@|BlackDuckSecurityScan@|CoverityOnPolaris'
PAT_BRIDGE_CLI='(^|[[:space:]/])bridge([[:space:]]|$)|synopsys[- ]?bridge|--input[[:space:]]+bridge\.ya?ml|--stage[[:space:]]+(polaris|blackduck)'
PAT_COVERITY_CLI='cov-build|cov-analyze|cov-capture|cov-commit-defects|cov-format-errors'
PAT_JENKINS_PLUGIN='withCoverityEnv|coverityScan|coverityPublisher|covBuild|covAnalyze|covCommitDefects'
PAT_POLARIS_ENV='POLARIS_SERVER_URL|POLARIS_ACCESS_TOKEN|polaris_server_url|polaris_access_token'
PAT_BRIDGE_CONFIG='^\s*stage:\s*$|^\s*polaris\s*:|^\s*blackduck\s*:'

ENV_MARKERS_PATTERN='POLARIS_SERVER_URL|POLARIS_ACCESS_TOKEN|COVERITY_URL|COVERITY_STREAM|BLACKDUCK_URL|BLACKDUCK_API_TOKEN|BLACKDUCK_TOKEN|blackDuckService|polarisService'

die(){ echo "ERROR: $*" >&2; exit 1; }
grep_q(){ grep -Eq "$1" -- "$2" 2>/dev/null; }
grep_in(){ grep -Ein "$1" -- "$2" 2>/dev/null || true; }

csv_escape(){
  echo "$1" | sed -E 's/"/""/g' | tr '\n' ' ' | sed -E 's/[[:space:]]+$//'
}

ensure_csv_header(){
  if [[ ! -s "$OUT_CSV" ]]; then
    echo "repo,branch,build_type,package_manager_file,file_path,ci_type,found_type,invocation_style,evidence,migration_changes" > "$OUT_CSV"
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

invocation_style_of(){
  local f="$1"
  local rel="${f#$ROOT/}"
  local styles=()

  if [[ "$rel" == bridge.y*ml ]] && grep_q "$PAT_BRIDGE_CONFIG" "$f"; then
    styles+=("bridge_config_file")
  fi

  grep_q "$PAT_GHA_ACTION" "$f"     && styles+=("github_action_synopsys_action")
  grep_q "$PAT_ADO_TASK" "$f"       && styles+=("ado_task_extension")
  grep_q "$PAT_BRIDGE_CLI" "$f"     && styles+=("bridge_cli")
  grep_q "$PAT_COVERITY_CLI" "$f"   && styles+=("coverity_cli")
  grep_q "$PAT_JENKINS_PLUGIN" "$f" && styles+=("jenkins_coverity_plugin_steps")

  if grep_q "$PAT_POLARIS_ENV" "$f" && [[ ${#styles[@]} -eq 0 ]]; then
    styles+=("polaris_env_or_config")
  fi

  if [[ ${#styles[@]} -eq 0 ]]; then
    echo "unknown"
    return
  fi

  local out=""
  local s
  for s in "${styles[@]}"; do
    [[ -z "$out" ]] && out="$s" || out="$out + $s"
  done
  echo "$out"
}

evidence_lines(){
  local f="$1"
  local n=12
  (
    grep_in "$DIRECT_PATTERN|$ENV_MARKERS_PATTERN" "$f" \
      | head -n "$n" \
      | sed -E 's/"/""/g' \
      | tr '\n' ';' \
      | sed 's/;*$//'
  )
}

migration_changes_of(){
  # v6.4 (Option 1): Return a semantic, reviewer-friendly migration summary.
  # This is intended for audit/dry-run reporting (no raw unified diff, no temp paths).
  local rel="$1"
  [[ "$MODE" == "dry-run" ]] || { echo ""; return 0; }

  local abs="$ROOT/$rel"
  [[ -f "$abs" ]] || { echo ""; return 0; }

  local ci; ci="$(ci_type_of "$rel")"
  local summary=""

  # Helpers
  _add(){ local line="$1"; [[ -z "$summary" ]] && summary="$line" || summary+=$'\n'"$line"; }
  _kv(){ local k="$1"; local v="$2"; [[ -n "$v" ]] && _add "  - $k: $v"; }

  case "$ci" in
    azure_devops)
      if grep_q "$PAT_ADO_TASK" "$abs" && grep_q "scanType:[[:space:]]*'?polaris'?" "$abs"; then
        _add "Change: Replace Synopsys Polaris task with Black Duck task (Azure DevOps Extension)"
        _add "Action:"
        _add "  - Replace: SynopsysSecurityScan@1"
        _add "  - With   : BlackDuckSecurityScan@1"
        _add "  - Update inputs mapping:"
        _add "      scanType: 'polaris'  ->  scanType: 'blackduck'"
        _add "      polarisService       ->  blackDuckService (keep same service connection name/value)"
        _add "      projectName / branchName / waitForScan: keep as-is"
        _add "Notes:"
        _add "  - Ensure service connection has Black Duck entitlement/permissions."
        _add "  - Ensure required Black Duck URL/token are configured in the service connection or pipeline variables."
      elif grep_q "$PAT_COVERITY_CLI" "$abs"; then
        _add "Change: Replace direct Coverity CLI workflow with Black Duck (Polaris) execution"
        _add "Action:"
        _add "  - Preferred: Use BlackDuckSecurityScan@1 (scanType: 'blackduck')"
        _add "  - Alternative: Use Synopsys Bridge CLI with --stage blackduck and a bridge.yml blackduck stage"
        _add "Notes:"
        _add "  - Coverity CLI (cov-build/cov-analyze/cov-commit-defects) usually targets Coverity Connect."
        _add "  - For 'Black Duck Coverity in Polaris', ensure pipeline uses Polaris/Bridge/ADO extension path, not Connect commit-defects."
      fi
      ;;
    github_actions)
      if grep_q "$PAT_GHA_ACTION" "$abs"; then
        _add "Change: Update GitHub Action config from Polaris to Black Duck (Synopsys Action)"
        _add "Action:"
        _add "  - Keep: synopsys-sig/synopsys-action@v1"
        _add "  - Replace inputs:"
        _add "      polaris_*  ->  blackduck_* (use BLACKDUCK_URL + BLACKDUCK_API_TOKEN secrets)"
        _add "  - Keep checkout step and job structure"
        _add "Notes:"
        _add "  - Store secrets in GitHub repo/org secrets."
      elif grep_q "$PAT_BRIDGE_CLI" "$abs"; then
        _add "Change: Switch Bridge CLI stage from Polaris to Black Duck (GitHub Actions)"
        _add "Action:"
        _add "  - Update command: bridge --stage polaris  ->  bridge --stage blackduck"
        _add "  - Update bridge.yml: add/use stage.blackduck"
        _add "  - Add secrets: BLACKDUCK_URL, BLACKDUCK_API_TOKEN"
      fi
      ;;
    travis|bamboo)
      if grep_q "$PAT_BRIDGE_CLI" "$abs"; then
        _add "Change: Switch Bridge CLI stage from Polaris to Black Duck"
        _add "Action:"
        _add "  - Update command: bridge --stage polaris  ->  bridge --stage blackduck"
        _add "  - Update bridge.yml: add/use stage.blackduck"
        _add "  - Add env vars/secrets: BLACKDUCK_URL, BLACKDUCK_API_TOKEN"
      fi
      ;;
    bridge_config)
      if grep_q "^[[:space:]]*polaris[[:space:]]*:" "$abs"; then
        _add "Change: Add Black Duck stage to bridge.yml and keep Polaris stage (if still needed)"
        _add "Action:"
        _add "  - Add: stage.blackduck section"
        _add "  - Configure:"
        _add "      url: ${BLACKDUCK_URL}"
        _add "      apiToken: ${BLACKDUCK_API_TOKEN}"
        _add "Notes:"
        _add "  - Keep stage.polaris only if legacy Polaris scans still required."
      fi
      ;;
    jenkins)
      _add "Change: Jenkinsfile detected. Script does not auto-edit Jenkins by default."
      _add "Action:"
      _add "  - Re-run with EDIT_JENKINS=1 to enable Jenkinsfile transformations (if supported by your Jenkins setup)."
      _add "  - Otherwise migrate manually: replace Polaris/Bridge steps with Black Duck stage or supported plugin step."
      ;;
    *)
      ;;
  esac

  printf '%s' "$summary"
}

# Escape for CSV but preserve newlines as literal \n so summaries remain readable.
csv_escape_nl(){
  printf '%s' "$1" \
    | sed -E 's/"/""/g' \
    | sed ':a;N;$!ba;s/\r//g;s/\n/\\n/g' \
    | sed -E 's/[[:space:]]+$//'
}



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
  local pm_map=()

  local maven_paths gradle_paths npm_paths docker_paths

  maven_paths="$(collect_paths_with_fallback "$files" '(^|/)pom\.xml$|(^|/)(mvnw|mvnw\.cmd)$' "pom.xml" "mvnw" "mvnw.cmd")"
  [[ -n "$maven_paths" ]] && { types+=("maven"); pm_map+=("maven: ${maven_paths}"); }

  gradle_paths="$(collect_paths_with_fallback "$files" '(^|/)(build\.gradle|build\.gradle\.kts|settings\.gradle|settings\.gradle\.kts|gradle\.properties|gradlew|gradlew\.bat)$' \
    "build.gradle" "build.gradle.kts" "settings.gradle" "settings.gradle.kts" "gradle.properties" "gradlew" "gradlew.bat")"
  [[ -n "$gradle_paths" ]] && { types+=("gradle"); pm_map+=("gradle: ${gradle_paths}"); }

  npm_paths="$(collect_paths_with_fallback "$files" '(^|/)package\.json$|(^|/)(package-lock\.json|yarn\.lock|pnpm-lock\.ya?ml|pnpm-workspace\.ya?ml|lerna\.json|nx\.json|turbo\.json)$' \
    "package.json" "package-lock.json" "yarn.lock" "pnpm-lock.yaml" "pnpm-lock.yml" "pnpm-workspace.yaml" "pnpm-workspace.yml")"
  [[ -n "$npm_paths" ]] && { types+=("npm"); pm_map+=("npm: ${npm_paths}"); }

  docker_paths="$(collect_paths_with_fallback "$files" '(^|/)Dockerfile$|(^|/)docker-compose\.ya?ml$' "Dockerfile" "docker-compose.yml" "docker-compose.yaml")"
  [[ -n "$docker_paths" ]] && { types+=("docker"); pm_map+=("docker: ${docker_paths}"); }

  if [[ ${#types[@]} -eq 0 ]]; then echo "unknown|unknown"; return; fi

  local build_out=""; local t
  for t in "${types[@]}"; do
    [[ -z "$build_out" ]] && build_out="$t" || build_out="${build_out}+${t}"
  done

  local pm_out=""; local m
  for m in "${pm_map[@]}"; do
    [[ -z "$pm_out" ]] && pm_out="$m" || pm_out="${pm_out} || ${m}"
  done

  echo "${build_out}|${pm_out}"
}

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

backup_file(){
  local rel="$1"
  local br="$2"
  local dst="$BACKUP_ROOT/$br/$rel"
  mkdir -p "$ROOT/$(dirname "$dst")"
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
  local last
  last="$(git -C "$ROOT" log --grep="^bd-migration:" -n 1 --pretty=format:%H 2>/dev/null || true)"
  if [[ -n "$last" ]]; then
    echo "[ROLLBACK] Reverting $last on $br"
    git -C "$ROOT" revert --no-edit "$last"
    [[ "$PUSH" -eq 1 ]] && git -C "$ROOT" push "$REMOTE" "HEAD:$br"
    return 0
  fi

  local newest
  newest="$(cd "$ROOT" && ls -1d .migrate_backups/*/"$br" 2>/dev/null | sort | tail -n 1 || true)"
  [[ -n "$newest" ]] || die "No migration commit and no backups found for branch $br"

  echo "[ROLLBACK] Restoring from backup dir: $newest"
  (cd "$ROOT" && rsync -a --exclude '.git/' "$newest"/ ./)
  commit_and_push_if_needed "$br"
}

transform_bridge_stage(){
  local f="$1"
  perl -0777 -i -pe 's/(--stage\s+)polaris\b/$1blackduck/g' "$f"
}

ensure_blackduck_env_placeholders(){
  local f="$1"
  grep -Eq 'BLACKDUCK_(URL|API_TOKEN|TOKEN)' "$f" && return 0

  if grep -Eq 'POLARIS_SERVER_URL|POLARIS_ACCESS_TOKEN' "$f"; then
    perl -0777 -i -pe '
      if ($m !~ /BLACKDUCK_URL/ && $m =~ /POLARIS_SERVER_URL/) {
        $m =~ s/(POLARIS_SERVER_URL[^\n]*\n)/$1# TODO: Set Black Duck connection (prefer secrets\/CI vars)\n# BLACKDUCK_URL=__set_in_ci_secret__\n# BLACKDUCK_API_TOKEN=__set_in_ci_secret__\n/s;
      }
    ' -pe '$m=$_; $_=$m' "$f"
  fi
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
    perl -0777 -i -pe 's/(\bscanType:\s*["\x27]?)polaris(["\x27]?)/$1blackduck$2/g' "$f"
    perl -0777 -i -pe 's/\bpolarisService:\s*/blackDuckService: /g' "$f"
  fi
}

transform_ado_add_blackduck_step_if_coverity_cli(){
  local f="$1"
  grep -Eq "$PAT_COVERITY_CLI" "$f" || return 0
  grep -Eq '^\s*steps\s*:' "$f" || return 0
  grep -Eq 'BlackDuckSecurityScan@' "$f" && return 0

  perl -0777 -i -pe '
    if ($m =~ /-\s*checkout:\s*self.*?\n/s && $m !~ /BlackDuckSecurityScan@/s) {
      $m =~ s/(-\s*checkout:\s*self[^\n]*\n(?:\s*clean:\s*true[^\n]*\n)?)/$1\n- task: BlackDuckSecurityScan@1\n  displayName: "Black Duck SCA Scan (Added by migration script)"\n  inputs:\n    # TODO: configure according to your extension inputs\n    blackDuckService: "BlackDuck-Service-Connection"\n    projectName: "juice-shop"\n    versionName: "$(Build.SourceBranchName)"\n    waitForScan: true\n\n/s;
    }
  ' -pe '$m=$_; $_=$m' "$f"
}

transform_gha_synopsys_action_add_bd_placeholder(){
  local f="$1"
  grep -Eq "$PAT_GHA_ACTION" "$f" || return 0
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
    travis|bamboo)
      transform_bridge_stage "$abs"
      ensure_blackduck_env_placeholders "$abs"
      ;;
    azure_devops)
      transform_ado_synopsys_task_to_blackduck "$abs"
      transform_ado_add_blackduck_step_if_coverity_cli "$abs"
      ;;
    github_actions)
      if grep_q "$PAT_BRIDGE_CLI" "$abs"; then
        transform_bridge_stage "$abs"
        ensure_blackduck_env_placeholders "$abs"
      fi
      transform_gha_synopsys_action_add_bd_placeholder "$abs"
      ;;
    bridge_config)
      transform_bridge_yml_add_blackduck_stage "$abs"
      ;;
    jenkins)
      transform_jenkins_if_enabled "$abs"
      ;;
    *) return 1 ;;
  esac
  return 0
}

dryrun_init_file(){ :; }

dry_run_diff_file(){
  local rel="$1"
  local abs="$ROOT/$rel"
  [[ -f "$abs" ]] || return 0

  local tmp; tmp="$(mktemp)"
  cp -p "$abs" "$tmp"

  case "$(ci_type_of "$rel")" in
    travis|bamboo)
      transform_bridge_stage "$tmp"
      ensure_blackduck_env_placeholders "$tmp"
      ;;
    azure_devops)
      transform_ado_synopsys_task_to_blackduck "$tmp"
      transform_ado_add_blackduck_step_if_coverity_cli "$tmp"
      ;;
    github_actions)
      if grep -Eq "$PAT_BRIDGE_CLI" "$tmp"; then
        transform_bridge_stage "$tmp"
        ensure_blackduck_env_placeholders "$tmp"
      fi
      transform_gha_synopsys_action_add_bd_placeholder "$tmp"
      ;;
    bridge_config)
      transform_bridge_yml_add_blackduck_stage "$tmp"
      ;;
    jenkins)
      transform_jenkins_if_enabled "$tmp"
      ;;
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

audit_files_to_csv(){
  local br="$1"
  local repo; repo="$(repo_url_of)"
  local info build_type pm_file
  info="$(build_info_of_repo)"
  build_type="${info%%|*}"
  pm_file="${info#*|}"

  local rel abs found ci style ev chg

  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    abs="$ROOT/$rel"
    [[ -f "$abs" ]] || continue

    found="$(found_type_of "$abs")"
    [[ "$found" == "direct" ]] || continue

    ci="$(ci_type_of "$rel")"
    style="$(invocation_style_of "$abs")"
    ev="$(evidence_lines "$abs")"
    chg="$(migration_changes_of "$rel")"

    echo "[DIRECT] $repo@$br :: $rel (ci=$ci, style=$style, build=$build_type)"
    echo "\"$(csv_escape "$repo")\",\"$(csv_escape "$br")\",\"$(csv_escape "$build_type")\",\"$(csv_escape "$pm_file")\",\"$(csv_escape "$rel")\",\"$(csv_escape "$ci")\",direct,\"$(csv_escape "$style")\",\"$(csv_escape "$ev")\",\"$(csv_escape_nl "$chg")\"" >> "$OUT_CSV"
  done < <(collect_target_files)
}

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

[[ "$MODE" =~ ^(audit|dry-run|apply|rollback)$ ]] || die "Invalid MODE=$MODE"
assert_git_repo
ensure_csv_header

if [[ "$MODE" == "apply" || "$MODE" == "rollback" ]]; then
  assert_clean_or_allowed
fi

if [[ "$MODE" == "dry-run" ]]; then
  dryrun_init_file
fi

echo "Mode: $MODE"
echo "Repo: $ROOT"
echo "CSV : $OUT_CSV"
[[ "$MODE" == "dry-run" ]] && echo "Dry-run diff file: $DRYRUN_DIFF_FILE"
echo "Backups root (apply): $BACKUP_ROOT"
echo "EDIT_JENKINS: $EDIT_JENKINS"
echo

while IFS= read -r br; do
  [[ -n "$br" ]] || continue
  echo "=== Branch: $br ==="
  checkout_branch "$br"

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
if [[ "$MODE" == "dry-run" ]]; then
  echo "Dry-run diffs saved to: $DRYRUN_DIFF_FILE"
fi
echo "Backups (apply): $BACKUP_ROOT"
