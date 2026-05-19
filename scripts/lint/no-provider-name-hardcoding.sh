#!/usr/bin/env bash
# Guard the Provider_adapter removal follow-up: provider/model identity must
# not keep growing in the MASC-owned runtime projection boundary.
#
# This is intentionally narrower than a repo-wide string grep.  Terms like
# "claude", "gemini", or "auto" are valid in auth, agent naming, voice persona,
# and unrelated operator UX code.  The migration risk tracked by
# docs/PROVIDER-ADAPTER-REMOVAL-PLAN.md is the provider-runtime/cascade bridge
# learning concrete provider identity after Provider_adapter was removed.
#
# Allowlist entries are exact `path:line:literal` keys.  They are a debt ledger:
# line drift or deletion makes the entry stale and must be cleaned up in the
# same PR.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ALLOWLIST="${ROOT}/scripts/lint/no-provider-name-hardcoding.allowlist"

MODE="--fail"
case "${1:---fail}" in
  --fail|"") MODE="--fail" ;;
  --print) MODE="--print" ;;
  -h|--help)
    sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    echo "Usage: $0 [--fail|--print]" >&2
    exit 2
    ;;
esac

for tool in rg sed sort mktemp comm; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "[no-provider-name-hardcoding] required tool missing: $tool" >&2
    exit 2
  }
done

cd "$ROOT"

SCAN_FILES=(
  "lib/provider_runtime_projection.ml"
  "lib/cascade/cascade_runtime.ml"
)

LITERAL_PATTERN='"(claude|codex|gemini|llama|llama\.cpp|llamacpp|openrouter|openai_compat|ollama|custom|auto)"'

current_tmp="$(mktemp -t provider-name-hardcoding.current.XXXXXX)"
allow_tmp="$(mktemp -t provider-name-hardcoding.allow.XXXXXX)"
new_tmp="$(mktemp -t provider-name-hardcoding.new.XXXXXX)"
stale_tmp="$(mktemp -t provider-name-hardcoding.stale.XXXXXX)"
trap 'rm -f "$current_tmp" "$allow_tmp" "$new_tmp" "$stale_tmp"' EXIT

for file in "${SCAN_FILES[@]}"; do
  [[ -f "$file" ]] || continue
  while IFS=: read -r path line content; do
    [[ -n "${path:-}" && -n "${line:-}" ]] || continue
    while IFS= read -r literal; do
      [[ -n "$literal" ]] || continue
      printf '%s:%s:%s\n' "$path" "$line" "$literal"
    done < <(printf '%s\n' "$content" | rg -o --replace '$1' "$LITERAL_PATTERN" || true)
  done < <(rg --with-filename --no-heading --line-number --color=never "$LITERAL_PATTERN" "$file" || true)
done | sort -u >"$current_tmp"

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

printf "%-36s %8s\n" "metric" "count"
echo "------------------------------------------------"
printf "%-36s %8s\n" "provider_name_literals_current" "$current_count"
printf "%-36s %8s\n" "provider_name_allowlist_entries" "$allow_count"
printf "%-36s %8s\n" "provider_name_new_literals" "$new_count"
printf "%-36s %8s\n" "provider_name_stale_allowlist" "$stale_count"

if [[ "$MODE" = "--print" ]]; then
  echo
  echo "[no-provider-name-hardcoding] current keys:"
  sed 's/^/  - /' "$current_tmp"
  exit 0
fi

if [[ -s "$new_tmp" ]]; then
  echo
  echo "[no-provider-name-hardcoding] DRIFT UP: new provider/model literals in runtime boundary" >&2
  sed 's/^/  - /' "$new_tmp" >&2
  echo "  Route provider/model truth through OAS runtime bindings or a MASC-local policy overlay." >&2
fi

if [[ -s "$stale_tmp" ]]; then
  echo
  echo "[no-provider-name-hardcoding] STALE allowlist entries" >&2
  sed 's/^/  - /' "$stale_tmp" >&2
  echo "  Remove stale entries when a literal is deleted or moved." >&2
fi

if [[ -s "$new_tmp" || -s "$stale_tmp" ]]; then
  exit 1
fi

echo
echo "[no-provider-name-hardcoding] OK"
