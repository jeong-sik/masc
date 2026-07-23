#!/usr/bin/env bash
# Hardcoding/truth audit for active MASC implementation surfaces.
# The goal is to separate confirmed semantic debt from broad grep noise.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

FAIL_ON_CONFIRMED=0

usage() {
  cat <<'EOF'
Usage: scripts/audit-hardcoding-truth.sh [--fail-on-confirmed]

Scans active source/CI/test surfaces for hardcoded semantic routing,
heuristic provider classification, fake-test detector noise, and advisory
gates that can hide failures.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --fail-on-confirmed)
      FAIL_ON_CONFIRMED=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if ! command -v rg >/dev/null 2>&1; then
  echo "ERROR: ripgrep (rg) is required" >&2
  exit 2
fi

confirmed=0

section() {
  printf '\n=== %s ===\n' "$1"
}

mark_confirmed() {
  confirmed=$((confirmed + 1))
  printf 'CONFIRMED[%d]: %s\n' "$confirmed" "$1"
}

print_matches() {
  local label="$1"
  local file="$2"
  local pattern="$3"
  local matches
  matches="$(rg -n "$pattern" "$file" 2>/dev/null || true)"
  if [ -n "$matches" ]; then
    mark_confirmed "$label"
    printf '%s\n' "$matches"
  fi
}

echo "=== Hardcoding / Truth Audit ==="
echo "Repo: $(pwd)"
echo "Head: $(git rev-parse --short HEAD 2>/dev/null || echo unknown)"

section "Typed Boundary Metadata"
legacy_helper_pattern='is_main_''worktree_''boundary_''exempt'
legacy_phrase_pattern='main-''worktree ''boundary|worktree ''boundary'
tool_catalog_candidates=(
  lib/tool/tool_catalog.ml
  lib/tool/tool_catalog.mli
  lib/tool_catalog.ml
  lib/tool_catalog.mli
)
tool_catalog_files=()
for file in "${tool_catalog_candidates[@]}"; do
  [ -f "$file" ] && tool_catalog_files+=("$file")
done

legacy_boundary_matches=""
if [ "${#tool_catalog_files[@]}" -gt 0 ]; then
  legacy_boundary_matches="$(
    rg -n "${legacy_helper_pattern}|${legacy_phrase_pattern}" \
      "${tool_catalog_files[@]}" 2>/dev/null || true
  )"
fi
if [ -n "$legacy_boundary_matches" ]; then
  mark_confirmed "legacy checkout follow-up helper surface still exists"
  printf '%s\n' "$legacy_boundary_matches"
else
  echo "PASS: legacy checkout follow-up helper surface is absent."
fi

legacy_effect_pattern='effect_''domain|effect''Domain'
if [ "${#tool_catalog_files[@]}" -gt 0 ] \
  && rg -q "$legacy_effect_pattern" "${tool_catalog_files[@]}"; then
  mark_confirmed "Tool_catalog still exposes generic effect-domain metadata"
else
  echo "PASS: generic Tool_catalog effect-domain metadata is absent."
fi

section "Confirmed String/Heuristic Semantics"
print_matches \
  "keeper agent surface still derives affordance groups from tool-name strings" \
  lib/keeper/keeper_agent_run.ml \
  'tool_required_affordances|String\.starts_with|String\.equal[[:space:]]+[a-zA-Z_]+[[:space:]]+"(keeper|masc)_[^"]+"'

if [ -e lib/provider_adapter.ml ] || [ -e lib/provider_adapter.mli ]; then
  mark_confirmed "legacy Provider_adapter implementation files still exist"
  ls -1 lib/provider_adapter.ml lib/provider_adapter.mli 2>/dev/null || true
else
  echo "PASS: legacy Provider_adapter implementation files are absent."
fi

section "Anti-Fake Detector"
anti_fake_output=""
anti_fake_status=0
set +e
anti_fake_output="$(bash scripts/anti-fake-audit.sh 2>&1)"
anti_fake_status=$?
set -e

printf '%s\n' "$anti_fake_output" | awk '
  /^=== Summary ===/ {in_summary=1}
  in_summary {print}
'
if [ "$anti_fake_status" -eq 1 ]; then
  mark_confirmed "anti-fake detector still reports fake/suspect tests; inspect summary before treating as a CI truth source"
elif [ "$anti_fake_status" -gt 1 ]; then
  echo "$anti_fake_output" >&2
  echo "ERROR: anti-fake audit failed unexpectedly" >&2
  exit "$anti_fake_status"
else
  echo "PASS: anti-fake detector completed without fake-test findings."
fi

section "CI Failure Visibility"
ci_meta_block="$(
  awk '
    /^[[:space:]]{6}- name: Meta bug-class gates/ { in_block = 1 }
    in_block && /^[[:space:]]{2}[A-Za-z0-9_-]+:/ { exit }
    in_block { print }
  ' .github/workflows/ci.yml
)"
if [ -z "$ci_meta_block" ]; then
  mark_confirmed "meta bug-class gates are missing from CI"
elif printf '%s\n' "$ci_meta_block" | rg -q 'continue-on-error:[[:space:]]*true|\|\|[[:space:]]*true'; then
  mark_confirmed "meta bug-class gates are still advisory in CI"
  printf '%s\n' "$ci_meta_block" \
    | rg -n 'continue-on-error:[[:space:]]*true|\|\|[[:space:]]*true' || true
elif printf '%s\n' "$ci_meta_block" | rg -q 'audit-hardcoding-truth\.sh' \
  && ! printf '%s\n' "$ci_meta_block" | rg -q 'audit-hardcoding-truth\.sh[[:space:]]+--fail-on-confirmed'; then
  mark_confirmed "hardcoding audit runs in non-strict mode inside meta gates"
  printf '%s\n' "$ci_meta_block" | rg -n 'audit-hardcoding-truth\.sh' || true
else
  echo "PASS: meta bug-class gates run as blocking CI checks."
fi

section "Broad Active-Source Smell Sample"
rg -n \
  'DESIGN SMELL|hardcoded|heuristic|string matching|String\.starts_with|List\.mem .*\\[ "' \
  lib scripts test .github \
  -g '*.ml' -g '*.mli' -g '*.sh' -g '*.yml' \
  2>/dev/null \
  | rg -v 'audit-hardcoding-truth|anti-fake-audit|_build|vendor|node_modules' \
  | head -80 || true

section "Result"
echo "Confirmed active issue groups: $confirmed"
if [ "$confirmed" -gt 0 ]; then
  echo "Status: findings"
  if [ "$FAIL_ON_CONFIRMED" -eq 1 ]; then
    exit 1
  fi
else
  echo "Status: pass"
fi
