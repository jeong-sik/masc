#!/usr/bin/env bash
# Guard against reintroducing retired #20070-era tool and hidden-runtime husks
# into active code/config/test/dashboard/workflow surfaces.
#
# Historical docs and RFC inventories are intentionally out of scope. They may
# describe removed surfaces. This gate protects only executable or prompt-facing
# project surfaces where a reintroduced module/name would become operational
# debt again.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

MODE="--fail"
case "${1:---fail}" in
  --fail|"") MODE="--fail" ;;
  --print) MODE="--print" ;;
  -h|--help)
    sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    echo "Usage: $0 [--fail|--print]" >&2
    exit 2
    ;;
esac

for tool in find rg sort mktemp wc sed tr; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "[no-retired-tool-husks] required tool missing: $tool" >&2
    exit 2
  }
done

cd "$ROOT"

ACTIVE_ROOTS=(lib test dashboard scripts config .github)

RETIRED_FILE_PATTERN='(^|/)(tool_deep_review|test_tool_deep_review|auto_responder|dashboard_provider_runs|server_openai_compat|openai_compat_error_map)(\.[A-Za-z0-9_]+)?$|(^|/)tool_shard_types_[^/]*\.mli$'
RETIRED_TOKEN_PATTERN='\b(masc_deep_review|Tool_deep_review|Deep_review_runtime_ref|tool_deep_review|auto_responder|Auto_responder|MASC_AUTO_RESPOND|dashboard_provider_runs|Dashboard_provider_runs|server_openai_compat|Server_openai_compat|openai_compat_error_map|Openai_compat_error_map|masc_persona_schema|masc_persona_save|masc_persona_generate|Persona_schema|Persona_save|Persona_generate)\b|/api/v1/agent-runs'

current_tmp="$(mktemp -t retired-tool-husks.current.XXXXXX)"
trap 'rm -f "$current_tmp"' EXIT

{
  while IFS= read -r path; do
    printf '%s:0:retired_file:%s\n' "$path" "$path"
  done < <(
    {
      for root in "${ACTIVE_ROOTS[@]}"; do
        [[ -e "$root" ]] || continue
        find "$root" \
          \( -path '*/node_modules' -o -path '*/_build' -o -path '*/.git' \) -prune \
          -o -path 'scripts/lint/no-retired-tool-husks.sh' -prune \
          -o -type f -print
      done
    } | rg "$RETIRED_FILE_PATTERN" || true
  )

  while IFS=: read -r path line content; do
    [[ -n "${path:-}" && -n "${line:-}" ]] || continue
    while IFS= read -r token; do
      [[ -n "$token" ]] || continue
      printf '%s:%s:retired_token:%s\n' "$path" "$line" "$token"
    done < <(printf '%s\n' "$content" | rg -o "$RETIRED_TOKEN_PATTERN" || true)
  done < <(
    rg --with-filename --no-heading --line-number --color=never \
      --glob '!dashboard/node_modules/**' \
      --glob '!_build/**' \
      --glob '!scripts/lint/no-retired-tool-husks.sh' \
      "$RETIRED_TOKEN_PATTERN" \
      "${ACTIVE_ROOTS[@]}" || true
  )
} | sort -u >"$current_tmp"

current_count="$(wc -l <"$current_tmp" | tr -d ' ')"

printf "%-36s %8s\n" "metric" "count"
echo "------------------------------------------------"
printf "%-36s %8s\n" "retired_tool_husk_hits" "$current_count"

if [[ "$MODE" = "--print" ]]; then
  echo
  echo "[no-retired-tool-husks] current keys:"
  sed 's/^/  - /' "$current_tmp"
  exit 0
fi

if [[ -s "$current_tmp" ]]; then
  echo
  echo "[no-retired-tool-husks] DRIFT UP: retired tool/runtime husk reappeared in active surface" >&2
  sed 's/^/  - /' "$current_tmp" >&2
  echo "  Keep deleted deep-review, auto-responder, dashboard-provider-run," >&2
  echo "  OpenAI-compat route, persona-authoring, and public shard leaf surfaces out of active code." >&2
  echo "  Historical docs/RFC inventories are intentionally not scanned by this guard." >&2
  exit 1
fi

echo
echo "[no-retired-tool-husks] OK"
