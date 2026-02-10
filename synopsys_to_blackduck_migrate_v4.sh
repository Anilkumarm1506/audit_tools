#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Script: synopsys_to_blackduck_migrate_v4.sh
#
# PURPOSE
# - Audit Synopsys/Polaris/Coverity integrations.
# - Migrate Polaris-based SAST configs to Black Duck (SCA) configs in CI YAMLs.
# - Backup + commit + push + rollback support.
#
# MODES
# MODE=audit : only scan + CSV (no modifications)
# MODE=dry-run : show diffs for proposed changes (no modifications)
# MODE=apply : apply changes, backup, commit, push
# MODE=rollback : git-revert migration commits OR restore from backups
#
# BRANCH CONTROL
# BRANCHES="a b c" : scan/migrate only these branches
# ALL_BRANCHES=1 : scan/migrate all local+remote branches (safe but slower)
# Default: current branch only
#
# GIT/PUSH CONTROL
# PUSH=1|0 (default 1)
# REMOTE=origin (default origin)
# COMMIT=1|0 (default 1)
# ALLOW_DIRTY=1|0 (default 0)
#
# EDIT RISK CONTROL
# EDIT_JENKINS=0|1 (default 0) # Jenkinsfile edits are risky; default OFF
# STRICT_REPLACE=0|1 (default 0) # If 1, replaces polaris calls; else adds BD alongside where safe.
#
# ============================================================

ROOT="${ROOT:-.}"
MODE="${MODE:-audit}" # audit|dry-run|apply|rollback
OUT_CSV="${OUT_CSV:-synopsys_audit.csv}"

BRANCHES="${BRANCHES:-}"
ALL_BRANCHES="${ALL_BRANCHES:-0}"

PUSH="${PUSH:-1}"
REMOTE="${REMOTE:-origin}"
COMMIT="${COMMIT:-1}"
ALLOW_DIRTY="${ALLOW_DIRTY:-0}"

EDIT_JENKINS="${EDIT_JENKINS:-0}"
STRICT_REPLACE="${STRICT_REPLACE:-0}"

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

DIRECT_PATTERN='polaris|coverity|coverity-on-polaris|cov-build|cov-analyze|cov-capture|cov-commit-defects|synopsys[- ]?bridge|(^|[[:space:]/])bridge([[:space:]]|$)|bridge\.yml|bridge\.yaml|--stage[[:space:]]+polaris|--stage[[:space:]]+blackduck|--input[[:space:]]+bridge\.ya?ml|synopsys-sig/synopsys-action|SynopsysSecurityScan@|BlackDuckSecurityScan@|CoverityOnPolaris'
SAST_KEYWORDS='polaris|coverity|synopsys|bridge|sast|blackduck'

die(){ echo "ERROR: $*" >&2; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }

grep_q(){ grep -Eq "$1" -- "$2" 2>/dev/null; }
grep_in(){ grep -Ein "$1" -- "$2" 2>/dev/null || true; }

ensure_csv_header(){
  if [[ ! -s "$OUT_CSV" ]]; then
    echo "repo,branch,file_path,ci_type,found_type,invocation_style,evidence" > "$OUT_CSV"
  fi
}

repo_url_of(){
  local repo="$1"
  local url=""
  if git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    url="$(git -C "$repo" config --get remote.origin.url 2>/dev/null || true)"
  fi
  [[ -n "$url" ]] && echo "$url" || echo "$(basename "$repo")"
}

branch_of(){
  local repo="$1"
  local b=""
  b="$(git -C "$repo" branch --show-current 2>/dev/null || true)"
  [[ -n "$b" ]] && echo "$b" || echo "unknown"
}

ci_type_of(){
  local rel="$1"
  if [[ "$rel" == ".travis.yml" ]]; then echo "travis"
  elif [[ "$rel" == "azure-pipelines.yml" || "$rel" == "azure-pipelines.yaml" ]]; then echo "azure_devops"
  elif [[ "$rel" == .github/workflows/*.yml || "$rel" == .github/workflows/*.yaml ]]; then echo "github_actions"
  elif [[ "$rel" == *bamboo-specs* ]]; then echo "bamboo"
  elif [[ "$rel" == Jenkinsfile* ]]; then echo "jenkins"
  elif [[ "$rel" == bridge.y*ml ]]; then echo "bridge_config"
  else echo "unknown"
  fi
}

invocation_style_of(){
  local f="$1"
  if grep_q 'synopsys-sig/synopsys-action' "$f"; then echo "github_action_synopsys_action"
  elif grep_q 'SynopsysSecurityScan@|BlackDuckSecurityScan@|CoverityOnPolaris' "$f"; then echo "ado_task_extension"
  elif grep_q '--stage[[:space:]]+polaris|--input[[:space:]]+bridge\.ya?ml|synopsys[- ]?bridge|(^|[[:space:]/])bridge([[:space:]]|$)' "$f"; then echo "bridge_cli"
  elif grep_q 'cov-build|cov-analyze|cov-commit-defects|cov-capture|withCoverityEnv' "$f"; then echo "coverity_cli_or_plugin"
  else echo "unknown"
  fi
}

found_type_of(){
  local f="$1"
  if grep_q "$DIRECT_PATTERN" "$f"; then echo "direct"; else echo "none"; fi
}

evidence_lines(){
  local f="$1"
  local n=8
  (
    grep_in "$DIRECT_PATTERN|$SAST_KEYWORDS" "$f" \
      | head -n "$n" \
      | sed -E 's/"/""/g' \
      | tr '\n' ';' \
      | sed 's/;*$//'
  )
}

csv_escape(){
  echo "$1" | sed -E 's/"/""/g' | tr '\n' ' ' | sed -E 's/[[:space:]]+$//'
}

assert_git_repo(){
  git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "ROOT is not a git repo: $ROOT"
}

assert_clean_or_allowed(){
  if [[ "$ALLOW_DIRTY" -ne 1 ]]; then
    [[ -z "$(git -C "$ROOT" status --porcelain)" ]] || die "Repo has uncommitted changes. Commit/stash or set ALLOW_DIRTY=1"
  fi
}

backup_file(){
  local rel="$1"
  local br="$2"
  local dst="$BACKUP_ROOT/$br/$rel"
  mkdir -p "$(dirname "$dst")"
  cp -p "$ROOT/$rel" "$ROOT/$dst"
}

# -------------------------
# YAML-ish transformers (conservative)
# -------------------------

# 1) Replace Bridge CLI stage polaris -> blackduck in scripts (travis/bamboo/gha/yaml shell sections)
transform_bridge_stage(){
  local f="$1"
  # Replace only the --stage argument value
  perl -0777 -i -pe 's/(--stage\s+)polaris\b/$1blackduck/g' "$f"
}

# 2) Add Black Duck env var placeholders where Polaris env vars exist
ensure_blackduck_env_placeholders(){
  local f="$1"
  # If file already mentions BLACKDUCK_URL/TOKEN, do nothing
  grep -Eq 'BLACKDUCK_(URL|API_TOKEN|TOKEN)' "$f" && return 0

  # Add placeholders near POLARIS envs (best-effort, non-breaking comments)
  # Works for YAML env blocks and shell exports inside scripts.
  perl -0777 -i -pe '
    if ($m =~ /POLARIS_SERVER_URL/ && $m !~ /BLACKDUCK_URL/) {
      $m =~ s/(POLARIS_SERVER_URL[^\n]*\n)/$1# TODO: Set Black Duck connection (prefer secrets\/CI vars)\n# BLACKDUCK_URL=__set_in_ci_secret__\n# BLACKDUCK_API_TOKEN=__set_in_ci_secret__\n/s;
    }
  ' -pe '$m=$_; $_=$m' "$f"
}

# 3) bridge.yml: add stage.blackduck if only stage.polaris exists
transform_bridge_yml_add_blackduck_stage(){
  local f="$1"
  # If already has blackduck stage, skip
  grep -Eq '^\s*blackduck\s*:' "$f" && return 0

  # If it has polaris stage, append blackduck stage below polaris (best-effort)
  if grep -Eq '^\s*polaris\s*:' "$f"; then
    cat >> "$f" <<'EOF'

  # --- Added by migration script (placeholder) ---
  blackduck:
    # TODO: set these via CI secrets/environment variables
    url: "${BLACKDUCK_URL}"
    apiToken: "${BLACKDUCK_API_TOKEN}"
    project:
      name: "juice-shop" # TODO: align with your BD project name
      version: "main" # TODO: align with your BD version naming
    # Common optional toggles:
    # scan:
    # mode: "INTELLIGENT" # or "RAPID" depending on your setup
EOF
  fi
}

# 4) Azure DevOps Synopsys task: scanType polaris -> blackduck, and task name -> BlackDuckSecurityScan@1
transform_ado_synopsys_task_to_blackduck(){
  local f="$1"

  # If task exists
  if grep -Eq '^\s*-\s*task:\s*SynopsysSecurityScan@' "$f"; then
    # Switch task name (keep version)
    perl -0777 -i -pe 's/^(\s*-\s*task:\s*)SynopsysSecurityScan(@[0-9A-Za-z\.\-_]+)?/$1BlackDuckSecurityScan$2/mg' "$f"

    # Change scanType: 'polaris' -> 'blackduck'
    perl -0777 -i -pe 's/(\bscanType:\s*[\"\x27]?)polaris([\"\x27]?)/$1blackduck$2/g' "$f"

    # Replace polarisService with blackDuckService if present (keep value)
    perl -0777 -i -pe 's/\bpolarisService:\s*/blackDuckService: /g' "$f"

    # Add TODO notes if not present
    if ! grep -Eq 'TODO: Verify Black Duck' "$f"; then
      perl -0777 -i -pe 's/^(.*BlackDuckSecurityScan@.*\n)/$1 # TODO: Verify Black Duck task inputs (service connection, project\/version, scan mode, wait\/fail conditions)\n/m' "$f"
    fi
  fi
}

# 5) Azure DevOps Coverity CLI pipeline: add Black Duck scan step before/after Coverity safely
# We do NOT remove Coverity steps.
transform_ado_add_blackduck_step(){
  local f="$1"

  # Only if it looks like ADO YAML and contains cov-build or cov-analyze
  grep -Eq 'cov-build|cov-analyze|cov-commit-defects' "$f" || return 0
  grep -Eq '^\s*steps\s*:' "$f" || return 0

  # If already has BlackDuckSecurityScan task, skip
  grep -Eq 'BlackDuckSecurityScan@' "$f" && return 0

  # Insert a task near top after checkout (best-effort)
  perl -0777 -i -pe '
    if ($m =~ /-\s*checkout:\s*self.*?\n/s && $m !~ /BlackDuckSecurityScan@/s) {
      $m =~ s/(-\s*checkout:\s*self[^\n]*\n(?:\s*clean:\s*true[^\n]*\n)?)/$1\n- task: BlackDuckSecurityScan@1\n displayName: "Black Duck SCA Scan (Added by migration script)"\n inputs:\n # TODO: configure according to your extension inputs\n blackDuckService: "BlackDuck-Service-Connection"\n projectName: "juice-shop"\n versionName: "$(Build.SourceBranchName)"\n waitForScan: true\n\n/s;
    }
  ' -pe '$m=$_; $_=$m' "$f"
}

# 6) GitHub Actions: for Bridge CLI workflows, stage polaris->blackduck + add env placeholders
transform_gha_bridge_cli(){
  local f="$1"
  transform_bridge_stage "$f"
  ensure_blackduck_env_placeholders "$f"
}

# 7) GitHub Actions synopsys-action: keep existing polaris step (unless STRICT_REPLACE=1), add BD placeholder step
transform_gha_synopsys_action_add_bd_step(){
  local f="$1"
  grep -Eq 'uses:\s*synopsys-sig/synopsys-action' "$f" || return 0

  if [[ "$STRICT_REPLACE" -eq 1 ]]; then
    # STRICT: we do NOT know an official Black Duck action name universally, so we only add TODO and keep existing.
    :
  fi

  # If BD placeholder already present, skip
  grep -Eq 'name:\s*Black Duck Scan' "$f" && return 0

  cat >> "$f" <<'EOF'

# --- Added by migration script (placeholder) ---
# TODO: Add your org-approved Black Duck scan step.
# - name: Black Duck Scan
# uses: <org-approved-blackduck-action>@<version>
# with:
# blackduck.url: ${{ secrets.BLACKDUCK_URL }}
# blackduck.api.token: ${{ secrets.BLACKDUCK_API_TOKEN }}
# blackduck.project.name: juice-shop
# blackduck.project.version: ${{ github.ref_name }}
EOF
}

# 8) Travis: stage polaris->blackduck and add env placeholders
transform_travis(){
  local f="$1"
  transform_bridge_stage "$f"
  ensure_blackduck_env_placeholders "$f"
}

# 9) Bamboo specs: stage polaris->blackduck and add TODO notes
transform_bamboo(){
  local f="$1"
  transform_bridge_stage "$f"
  ensure_blackduck_env_placeholders "$f"
}

# 10) Jenkins: default no edit. If EDIT_JENKINS=1, replace bridge stage polaris->blackduck in sh blocks.
transform_jenkins_if_enabled(){
  local f="$1"
  [[ "$EDIT_JENKINS" -eq 1 ]] || return 0
  transform_bridge_stage "$f"
  ensure_blackduck_env_placeholders "$f"
}

apply_transform(){
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
      # if it runs bridge CLI
      if grep_q '--stage[[:space:]]+polaris|--input[[:space:]]+bridge\.ya?ml|(^|[[:space:]/])bridge([[:space:]]|$)' "$abs"; then
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

# -------------------------
# git operations
# -------------------------

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

  # Prefer revert of last bd-migration commit on this branch
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

# -------------------------
# scanning/audit
# -------------------------

collect_target_files(){
  local files=()
  local g f
  for g in "${PIPELINE_GLOBS[@]}"; do
    for f in "$ROOT"/$g; do [[ -f "$f" ]] && files+=("${f#$ROOT/}"); done
  done
  printf "%s\n" "${files[@]}" | awk '!seen[$0]++'
}

audit_files(){
  local br="$1"
  local repo; repo="$(repo_url_of "$ROOT")"
  local rel

  while IFS= read -r rel; do
    local abs="$ROOT/$rel"
    local found; found="$(found_type_of "$abs")"
    [[ "$found" == "direct" ]] || continue

    local ci; ci="$(ci_type_of "$rel")"
    local style; style="$(invocation_style_of "$abs")"
    local ev; ev="$(evidence_lines "$abs")"

    echo "[DIRECT] $repo@$br :: $rel (ci=$ci, style=$style)"
    echo "\"$(csv_escape "$repo")\",\"$(csv_escape "$br")\",\"$(csv_escape "$rel")\",\"$(csv_escape "$ci")\",\"direct\",\"$(csv_escape "$style")\",\"$(csv_escape "$ev")\"" >> "$OUT_CSV"
  done < <(collect_target_files)
}

# -------------------------
# branch iteration
# -------------------------

list_branches(){
  if [[ "$ALL_BRANCHES" -eq 1 ]]; then
    # Ensure we have remotes
    git -C "$ROOT" fetch --all --prune >/dev/null 2>&1 || true
    # List remote branches excluding HEAD pointers
    git -C "$ROOT" for-each-ref --format='%(refname:short)' refs/remotes/"$REMOTE" \
      | sed -E "s|^$REMOTE/||" \
      | grep -vE '^(HEAD)$' \
      | awk '!seen[$0]++'
    return
  fi

  if [[ -n "$BRANCHES" ]]; then
    # user-specified list
    for b in $BRANCHES; do echo "$b"; done
    return
  fi

  # default: current
  branch_of "$ROOT"
}

checkout_branch(){
  local br="$1"
  git -C "$ROOT" checkout -q "$br" || {
    # try remote tracking
    git -C "$ROOT" checkout -q -b "$br" "$REMOTE/$br"
  }
}

# -------------------------
# main
# -------------------------

[[ "$MODE" =~ ^(audit|dry-run|apply|rollback)$ ]] || die "Invalid MODE=$MODE"
assert_git_repo
ensure_csv_header

if [[ "$MODE" == "apply" || "$MODE" == "rollback" ]]; then
  assert_clean_or_allowed
fi

echo "Mode: $MODE"
echo "Repo: $ROOT"
echo "CSV : $OUT_CSV"
echo "Backup root (apply): $BACKUP_ROOT"
echo

while IFS= read -r br; do
  [[ -n "$br" ]] || continue
  echo "=== Branch: $br ==="
  checkout_branch "$br"

  # Always audit into CSV
  audit_files "$br"

  if [[ "$MODE" == "audit" ]]; then
    continue
  fi

  if [[ "$MODE" == "rollback" ]]; then
    rollback_branch "$br"
    continue
  fi

  # dry-run/apply: compute diffs
  local_changed=0
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    abs="$ROOT/$rel"
    [[ -f "$abs" ]] || continue
    [[ "$(found_type_of "$abs")" == "direct" ]] || continue

    # Only modify known types; Jenkins default OFF
    ci="$(ci_type_of "$rel")"
    if [[ "$ci" == "jenkins" && "$EDIT_JENKINS" -ne 1 ]]; then
      echo "[SKIP] Jenkins edits disabled (EDIT_JENKINS=0): $rel"
      continue
    fi

    if [[ "$MODE" == "dry-run" ]]; then
      tmp="$(mktemp)"
      cp -p "$abs" "$tmp"
      # apply transforms to temp
      (ROOT="$(dirname "$tmp")" bash -c 'true' ) >/dev/null 2>&1 || true
      # easiest: run transforms by copying tmp back and diffing via perl? We'll just apply on tmp via a subshell.
      # We apply by temporarily pointing abs to tmp using a copy:
      cp -p "$abs" "$tmp"
      # Apply transform by running on tmp through a helper trick: copy tmp to abs? no.
      # Instead, apply_transform expects file under $ROOT; so do a manual dispatch here:
      case "$(ci_type_of "$rel")" in
        travis) transform_travis "$tmp" ;;
        bamboo) transform_bamboo "$tmp" ;;
        azure_devops)
          transform_ado_synopsys_task_to_blackduck "$tmp"
          transform_ado_add_blackduck_step "$tmp"
          ;;
        github_actions)
          if grep -Eq '--stage[[:space:]]+polaris|--input[[:space:]]+bridge\.ya?ml|(^|[[:space:]/])bridge([[:space:]]|$)' "$tmp"; then
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
        local_changed=1
      fi
      rm -f "$tmp"
      continue
    fi

    if [[ "$MODE" == "apply" ]]; then
      # Backup + apply transform in-place
      backup_file "$rel" "$br"
      before_hash="$(sha1sum "$abs" | awk '{print $1}')"
      apply_transform "$rel" || true
      after_hash="$(sha1sum "$abs" | awk '{print $1}')"

      if [[ "$before_hash" != "$after_hash" ]]; then
        echo "[APPLY] Updated: $rel (backup: $BACKUP_ROOT/$br/$rel)"
        local_changed=1
      else
        echo "[INFO] No changes for: $rel"
      fi
    fi
  done < <(collect_target_files)

  if [[ "$MODE" == "apply" && "$local_changed" -eq 1 ]]; then
    commit_and_push_if_needed "$br"
  elif [[ "$MODE" == "apply" ]]; then
    echo "[INFO] No changes applied on $br; skipping commit/push."
  fi

done < <(list_branches)

echo
echo "Done."
echo "CSV: $OUT_CSV"
echo "Backups (apply): $BACKUP_ROOT"
