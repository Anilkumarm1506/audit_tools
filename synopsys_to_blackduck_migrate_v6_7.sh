#!/usr/bin/env bash
# synopsys_to_blackduck_migrate_v6_7.sh
# Stable enterprise-ready version (re-uploaded)

set -euo pipefail

MODE="${MODE:-audit}"
ROOT="${ROOT:-.}"
OUT_CSV="${OUT_CSV:-synopsys_blackduck_migration.csv}"
COMMIT="${COMMIT:-0}"
PUSH="${PUSH:-0}"

TS="$(date +%Y%m%d_%H%M%S)"

csv_header() {
  if [[ ! -f "$OUT_CSV" ]]; then
    echo "repo,branch,build_type,package_manager_file,file_path,ci_type,found_type,invocation_style,evidence,migration_changes" > "$OUT_CSV"
  fi
}

csv_append() {
  echo "$1" >> "$OUT_CSV"
}

csv_header

cd "$ROOT"

REPO_URL="$(git config --get remote.origin.url || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD || echo unknown)"

shopt -s globstar nullglob

PIPELINE_FILES=(
  azure-pipelines.yml
  azure-pipelines.yaml
)

for f in "${PIPELINE_FILES[@]}"; do
  [[ ! -f "$f" ]] && continue

  FOUND=0
  grep -Eq 'SynopsysSecurityScan@|SynopsysBridge@|polaris_' "$f" && FOUND=1

  [[ "$FOUND" -eq 0 ]] && continue

  MIGRATION_CHANGE=""

  if [[ "$MODE" == "dry-run" ]]; then
    MIGRATION_CHANGE="Would replace Synopsys Polaris task with Black Duck (Coverity on Polaris) and update server URL"
  fi

  if [[ "$MODE" == "apply" ]]; then
    BACKUP="${f%.yml}_backup_${TS}.yml"
    mv "$f" "$BACKUP"

    cat > "$f" <<EOF
trigger: none

pool:
  vmImage: ubuntu-latest

steps:
  - checkout: self

  - task: SynopsysBridge@1
    displayName: "Black Duck Coverity on Polaris (SAST)"
    inputs:
      bridge_build_type: "polaris"
      polaris_server_url: "\$(BLACKDUCK_POLARIS_URL)"
      polaris_access_token: "\$(BLACKDUCK_POLARIS_TOKEN)"
      polaris_project_name: "\$(Build.Repository.Name)"
      polaris_branch_name: "\$(Build.SourceBranchName)"
EOF

    MIGRATION_CHANGE="Applied Black Duck Bridge task; backup created as $BACKUP"
  fi

  if [[ "$MODE" == "rollback" ]]; then
    BACKUP_FILE="$(ls ${f%.yml}_backup_*.yml 2>/dev/null | tail -n1 || true)"
    if [[ -n "$BACKUP_FILE" ]]; then
      rm -f "$f"
      mv "$BACKUP_FILE" "$f"
      MIGRATION_CHANGE="Rollback completed using $BACKUP_FILE"
    else
      MIGRATION_CHANGE="Rollback skipped (no backup found)"
    fi
  fi

  csv_append ""$REPO_URL","$BRANCH","unknown","unknown","$f","azure_devops","direct","ado_task","detected Synopsys Polaris","$MIGRATION_CHANGE""
done

if [[ "$COMMIT" -eq 1 ]]; then
  git add .
  git commit -m "Synopsys â†’ Black Duck migration ($MODE) [$TS]" || true
  [[ "$PUSH" -eq 1 ]] && git push || true
fi

echo "Done."
echo "CSV: $OUT_CSV"
