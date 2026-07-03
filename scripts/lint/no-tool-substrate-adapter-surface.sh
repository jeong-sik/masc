#!/usr/bin/env bash
# Guard the Keeper tool execution substrate against three regressions:
#
#   1. Descriptor executor variants that turn gh/git/OAS bridge adapters into
#      first-class tool concepts. Those belong behind Shell_ir or runtime
#      plumbing, not in the descriptor executor enum.
#   2. GitHub/PR micro-tool names returning to active descriptor, prompt,
#      policy, or capability-matrix surfaces.
#   3. Internal web MCP names appearing in keeper-facing prompts or workflow
#      guidance where the model-facing aliases are WebSearch / WebFetch.
#
# The scan is intentionally narrow. It does not scan timeout/runtime plumbing
# such as Timeout_policy.Layer.Oas_bridge, and it does not scan dashboard
# reporting metrics that use PR review as a work category.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ALLOWLIST="${ROOT}/scripts/lint/no-tool-substrate-adapter-surface.allowlist"

MODE="--fail"
case "${1:---fail}" in
  --fail|"") MODE="--fail" ;;
  --print) MODE="--print" ;;
  -h|--help)
    sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    echo "Usage: $0 [--fail|--print]" >&2
    exit 2
    ;;
esac

for tool in rg sed sort mktemp comm wc find; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "[no-tool-substrate-adapter-surface] required tool missing: $tool" >&2
    exit 2
  }
done

cd "$ROOT"

EXECUTOR_SCAN_FILES=(
  "lib/keeper/keeper_tool_descriptor.ml"
  "lib/keeper/keeper_tool_descriptor.mli"
)

SURFACE_SCAN_FILES=(
  "lib/keeper/keeper_tool_descriptor.ml"
  "lib/keeper/keeper_tool_descriptor.mli"
  "lib/keeper/keeper_tool_alias.ml"
  "lib/keeper/keeper_tool_alias.mli"
  "lib/tool_catalog.ml"
  "lib/tool_catalog.mli"
  "lib/tool_catalog_surfaces.ml"
  "lib/tool_catalog_surfaces.mli"
  "docs/KEEPER-CAPABILITY-MATRIX.md"
  "docs/KEEPER-FILE-MODEL.md"
  "docs/KEEPER-USER-MANUAL.md"
)

KEEPER_PROMPT_SCAN_FILES=(
  "docs/KEEPER-CAPABILITY-MATRIX.md"
)

while IFS= read -r prompt_file; do
  SURFACE_SCAN_FILES+=("$prompt_file")
  KEEPER_PROMPT_SCAN_FILES+=("$prompt_file")
done < <(find config/prompts -type f | sort)

EXECUTOR_PATTERN='\b(Gh_cli|Git_cli|Oas_bridge)\b'
PR_VERB_PATTERN='pr_(comment|review|close)'
REPO_PR_PATTERN='(gh|github)_pr'
LEGACY_REPO_HELPER_PATTERN='(keeper|github)_pr_[A-Za-z0-9_]*'
GH_COMMIT_PATTERN='gh_'"commit"
GITHUB_COMMENT_PATTERN='github_'"comment"
MICRO_TOOL_PATTERN="\b(${PR_VERB_PATTERN}|${GH_COMMIT_PATTERN}|${GITHUB_COMMENT_PATTERN}|${REPO_PR_PATTERN}|${LEGACY_REPO_HELPER_PATTERN})\b"
INTERNAL_WEB_TOOL_PATTERN='(\b(masc_web_search|masc_web_fetch)\b|\bmasc_web_\*)'

current_tmp="$(mktemp -t tool-substrate-adapter-surface.current.XXXXXX)"
allow_tmp="$(mktemp -t tool-substrate-adapter-surface.allow.XXXXXX)"
new_tmp="$(mktemp -t tool-substrate-adapter-surface.new.XXXXXX)"
stale_tmp="$(mktemp -t tool-substrate-adapter-surface.stale.XXXXXX)"
trap 'rm -f "$current_tmp" "$allow_tmp" "$new_tmp" "$stale_tmp"' EXIT

scan_pattern() {
  local class="$1"
  local pattern="$2"
  shift 2

  for file in "$@"; do
    [[ -f "$file" ]] || continue
    while IFS=: read -r path line content; do
      [[ -n "${path:-}" && -n "${line:-}" ]] || continue
      while IFS= read -r literal; do
        [[ -n "$literal" ]] || continue
        printf '%s:%s:%s:%s\n' "$path" "$line" "$class" "$literal"
      done < <(printf '%s\n' "$content" | rg -o "$pattern" || true)
    done < <(rg --with-filename --no-heading --line-number --color=never "$pattern" "$file" || true)
  done
}

{
  scan_pattern "executor_adapter" "$EXECUTOR_PATTERN" "${EXECUTOR_SCAN_FILES[@]}"
  scan_pattern "micro_tool" "$MICRO_TOOL_PATTERN" "${SURFACE_SCAN_FILES[@]}"
  scan_pattern "internal_web_tool" "$INTERNAL_WEB_TOOL_PATTERN" "${KEEPER_PROMPT_SCAN_FILES[@]}"
} | sort -u >"$current_tmp"

if [[ -f "$ALLOWLIST" ]]; then
  sed -E 's/#.*//; s/[[:space:]]//g; /^$/d' "$ALLOWLIST" | sort -u >"$allow_tmp"
else
  : >"$allow_tmp"
fi

comm -13 "$allow_tmp" "$current_tmp" >"$new_tmp"
comm -23 "$allow_tmp" "$current_tmp" >"$stale_tmp"

current_count="$(wc -l <"$current_tmp" | tr -d ' ')"
allow_count="$(wc -l <"$allow_tmp" | tr -d ' ')"
new_count="$(wc -l <"$new_tmp" | tr -d ' ')"
stale_count="$(wc -l <"$stale_tmp" | tr -d ' ')"

printf "%-44s %8s\n" "metric" "count"
echo "----------------------------------------------------"
printf "%-44s %8s\n" "tool_substrate_forbidden_current" "$current_count"
printf "%-44s %8s\n" "tool_substrate_allowlist_entries" "$allow_count"
printf "%-44s %8s\n" "tool_substrate_new_hits" "$new_count"
printf "%-44s %8s\n" "tool_substrate_stale_allowlist" "$stale_count"

if [[ "$MODE" = "--print" ]]; then
  echo
  echo "[no-tool-substrate-adapter-surface] current keys:"
  sed 's/^/  - /' "$current_tmp"
  exit 0
fi

fail=0

if [[ -s "$new_tmp" ]]; then
  echo
  echo "[no-tool-substrate-adapter-surface] DRIFT UP: forbidden adapter or micro-tool surface reappeared" >&2
  sed 's/^/  - /' "$new_tmp" >&2
  echo "  Keep gh/git work behind Execute/Shell_ir, and model PR work as ordinary CLI/worktree operations." >&2
  echo "  Do not add dedicated PR/GitHub micro-tools to active descriptor, prompt, policy, or capability surfaces." >&2
  echo "  Use WebSearch / WebFetch in keeper-facing prompts; keep masc_web_* names in MCP compatibility docs only." >&2
  fail=1
fi

if [[ -s "$stale_tmp" ]]; then
  echo
  echo "[no-tool-substrate-adapter-surface] STALE ALLOWLIST: entries no longer match source" >&2
  sed 's/^/  - /' "$stale_tmp" >&2
  echo "  Remove these from $ALLOWLIST in the same PR." >&2
  fail=1
fi

exit $fail
