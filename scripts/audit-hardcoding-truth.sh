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
if rg -q 'Tool_catalog\.is_main_worktree_boundary_exempt' lib/keeper/keeper_tool_registry.ml; then
  echo "PASS: main-worktree boundary delegates to Tool_catalog effect-domain metadata."
else
  mark_confirmed "main-worktree boundary still uses local tool-name allowlist"
  rg -n 'is_main_worktree_boundary_exempt_with_input|Tool_name\.of_string|Keeper |Masc ' \
    lib/keeper/keeper_tool_registry.ml || true
fi

if rg -q 'type effect_domain' lib/tool_catalog.ml lib/tool_catalog.mli; then
  echo "PASS: Tool_catalog exposes typed effect_domain metadata."
else
  mark_confirmed "Tool_catalog lacks typed effect_domain metadata"
fi

section "Confirmed String/Heuristic Semantics"
print_matches \
  "keeper agent surface still derives affordance groups from tool-name strings" \
  lib/keeper/keeper_agent_run.ml \
  'tool_required_affordances|String\.starts_with|String\.equal[[:space:]]+[a-zA-Z_]+[[:space:]]+"(keeper|masc)_[^"]+"|List\.mem[[:space:]]+[a-zA-Z_]+[[:space:]]+turn_affordances'

print_matches \
  "runtime catalog still has model-label/provider heuristics" \
  lib/runtime_catalog.ml \
  'prefix_classification_vocabulary|bare_heuristic|is_kimi_model_id|is_moonshot_base_url|String\.starts_with|List\.mem[[:space:]]+provider[[:space:]]+\['

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
