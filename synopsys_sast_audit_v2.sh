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
# Key Fix (build detection):
# - Build marker discovery includes tracked + untracked (non-ignored) files:
#   git ls-files --cached --others --exclude-standard
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
# CSV header (write once; allow append for multi-branch runs)
# ------------------------------------------------------------
if [[ ! -s "$OUT_CSV" ]]; then
  echo "repo,branch,build_type,package_manager_file,artifact_type,file_path,ci_type,found_type,invocation_style,script_lines" > "$OUT_CSV"
fi

# --- Safe grep wrappers (prevent invalid option + avoid pipefail crashes) ---
grep_q() { grep -Eq "$1" -- "$2" 2>/dev/null; }          # quiet true/false
grep_in() { grep -Ein "$1" -- "$2" 2>/dev/null || true; } # numbered output, never fails

# --- CSV sanitize (escape quotes, collapse newlines) ---
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
