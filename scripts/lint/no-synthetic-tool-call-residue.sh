#!/usr/bin/env bash
# Guard against reintroducing keeper-side synthetic tool-call fabrication and
# the deleted failed-tool-only completion gate residue from PR #20168.
#
# Real tool evidence must come from OAS/tool execution surfaces. Keeper result
# helpers must not fabricate tool_calls to satisfy progress or visibility gates.
# Historical docs and negative tests are intentionally out of scope; this guard
# protects active executable, prompt-facing, and workflow surfaces.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

MODE="--fail"
case "${1:---fail}" in
  --fail|"") MODE="--fail" ;;
  --print) MODE="--print" ;;
  -h|--help)
    sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    echo "Usage: $0 [--fail|--print]" >&2
    exit 2
    ;;
esac

for tool in find rg sort mktemp wc sed tr; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "[no-synthetic-tool-call-residue] required tool missing: $tool" >&2
    exit 2
  }
done

cd "$ROOT"

ACTIVE_ROOTS=(lib bin scripts config dashboard .github)
RESIDUE_PATTERN='\b(append_synthetic_tool_call|synthetic_tool_call_detail|failed_tool_only_contract_violation|tool_call_has_success_outcome|keeper_synthetic)\b'

current_tmp="$(mktemp -t synthetic-tool-call-residue.current.XXXXXX)"
trap 'rm -f "$current_tmp"' EXIT

{
  for root in "${ACTIVE_ROOTS[@]}"; do
    [[ -e "$root" ]] || continue
    find "$root" \
      \( -path '*/node_modules' -o -path '*/_build' -o -path '*/.git' \) -prune \
      -o -path 'scripts/lint/no-synthetic-tool-call-residue.sh' -prune \
      -o -type f -print
  done
} | sort -u \
  | xargs rg --with-filename --no-heading --line-number --color=never \
      "$RESIDUE_PATTERN" \
  | while IFS=: read -r path line content; do
      [[ -n "${path:-}" && -n "${line:-}" ]] || continue
      while IFS= read -r token; do
        [[ -n "$token" ]] || continue
        printf '%s:%s:synthetic_tool_call_residue:%s\n' "$path" "$line" "$token"
      done < <(printf '%s\n' "$content" | rg -o "$RESIDUE_PATTERN" || true)
    done \
  | sort -u >"$current_tmp" || true

current_count="$(wc -l <"$current_tmp" | tr -d ' ')"

printf "%-44s %8s\n" "metric" "count"
echo "------------------------------------------------------"
printf "%-44s %8s\n" "synthetic_tool_call_residue_hits" "$current_count"

if [[ "$MODE" = "--print" ]]; then
  echo
  echo "[no-synthetic-tool-call-residue] current keys:"
  sed 's/^/  - /' "$current_tmp"
  exit 0
fi

if [[ -s "$current_tmp" ]]; then
  echo
  echo "[no-synthetic-tool-call-residue] DRIFT UP: keeper synthetic tool-call residue reappeared in active surface" >&2
  sed 's/^/  - /' "$current_tmp" >&2
  echo "  Preserve real tool-call evidence: do not fabricate Keeper_agent_result.tool_calls." >&2
  echo "  Keep deleted failed-tool-only completion gate helpers out of keeper runtime code." >&2
  echo "  Historical docs and negative tests are intentionally not scanned by this guard." >&2
  exit 1
fi

echo
echo "[no-synthetic-tool-call-residue] OK"
