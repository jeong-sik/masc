#!/usr/bin/env bash
# Guard against re-emergence of pre-RFC-0064 public tool names in the
# descriptor-backed tool surface and keeper-facing prompt/persona/config files.
#
# After the MASC web-alias split, the active keeper-facing public names are:
#   Execute, Read, Edit, Write, Grep, Search, WebSearch, WebFetch
#
# The retired names — Bash, ReadFile, WriteFile, EditFile, SearchFiles,
# SearchWeb, FetchWeb — must not reappear as quoted string literals in active
# tool-surface modules or as prompt-visible tool names in keeper prompts,
# personas, and keeper TOML configs. Prompt-visible text must also not tell
# keepers to call stale implementation names such as keeper_bash or
# keeper_shell. This script is intentionally narrow: it only scans files that
# declare/route public tool names plus prompt/persona/config files that tell
# keepers what to call. Identifiers and code symbols (e.g. OCaml `Read`
# modules) are untouched.
#
# Baseline = 0 occurrences. Allowlist is a debt ledger; entries are exact
# `path:line:literal` keys that drift with line numbers, forcing same-PR
# cleanup if anchors move.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ALLOWLIST="${ROOT}/scripts/lint/no-legacy-tool-surface-name.allowlist"

MODE="--fail"
case "${1:---fail}" in
  --fail|"") MODE="--fail" ;;
  --print) MODE="--print" ;;
  -h|--help)
    sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    echo "Usage: $0 [--fail|--print]" >&2
    exit 2
    ;;
esac

for tool in rg sed sort mktemp comm wc find; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "[no-legacy-tool-surface-name] required tool missing: $tool" >&2
    exit 2
  }
done

cd "$ROOT"

SCAN_GLOBS=(
  "lib/keeper/keeper_tool_descriptor.ml"
  "lib/keeper/keeper_tool_descriptor.mli"
  "lib/keeper/keeper_tool_runtime.ml"
  "lib/keeper/keeper_tool_runtime.mli"
  "lib/keeper/keeper_tool_alias.ml"
  "lib/keeper/keeper_tool_alias.mli"
  "lib/keeper/keeper_tool_registry.ml"
  "lib/keeper/keeper_tool_registry.mli"
  "lib/keeper/keeper_tool_policy.ml"
  "lib/keeper/keeper_tool_policy.mli"
  "lib/keeper_tool_call_log_route_evidence.ml"
  "lib/keeper_tool_call_log_route_evidence.mli"
  "lib/tool_catalog.ml"
  "lib/tool_catalog.mli"
  "lib/tool_catalog_surfaces.ml"
  "lib/tool_catalog_surfaces.mli"
)

PROMPT_SCAN_FILES=("docs/KEEPER-CAPABILITY-MATRIX.md")
for prompt_dir in config/prompts config/personas config/keepers; do
  [[ -d "$prompt_dir" ]] || continue
  while IFS= read -r prompt_file; do
    PROMPT_SCAN_FILES+=("$prompt_file")
  done < <(find "$prompt_dir" -type f | sort)
done

RETIRED_PUBLIC_NAME_PATTERN='Bash|ReadFile|WriteFile|EditFile|SearchFiles|SearchWeb|FetchWeb'
STALE_KEEPER_IMPLEMENTATION_PATTERN='keeper_bash|keeper_shell|keeper_fs_read|keeper_fs_edit|keeper_fs_write|keeper_fs_delete'
LITERAL_PATTERN='"('"$RETIRED_PUBLIC_NAME_PATTERN"')"'
PROMPT_TOKEN_PATTERN='\b('"$RETIRED_PUBLIC_NAME_PATTERN"'|'"$STALE_KEEPER_IMPLEMENTATION_PATTERN"')\b'

current_tmp="$(mktemp -t legacy-tool-surface-name.current.XXXXXX)"
allow_tmp="$(mktemp -t legacy-tool-surface-name.allow.XXXXXX)"
new_tmp="$(mktemp -t legacy-tool-surface-name.new.XXXXXX)"
stale_tmp="$(mktemp -t legacy-tool-surface-name.stale.XXXXXX)"
trap 'rm -f "$current_tmp" "$allow_tmp" "$new_tmp" "$stale_tmp"' EXIT

for file in "${SCAN_GLOBS[@]}"; do
  [[ -f "$file" ]] || continue
  while IFS=: read -r path line content; do
    [[ -n "${path:-}" && -n "${line:-}" ]] || continue
    while IFS= read -r literal; do
      [[ -n "$literal" ]] || continue
      printf '%s:%s:%s\n' "$path" "$line" "$literal"
    done < <(printf '%s\n' "$content" | rg -o --replace '$1' "$LITERAL_PATTERN" || true)
  done < <(rg --with-filename --no-heading --line-number --color=never "$LITERAL_PATTERN" "$file" || true)
done | sort -u >"$current_tmp"

{
  cat "$current_tmp"
  for file in "${PROMPT_SCAN_FILES[@]}"; do
    [[ -f "$file" ]] || continue
    while IFS=: read -r path line content; do
      [[ -n "${path:-}" && -n "${line:-}" ]] || continue
      while IFS= read -r literal; do
        [[ -n "$literal" ]] || continue
        printf '%s:%s:%s\n' "$path" "$line" "$literal"
      done < <(printf '%s\n' "$content" | rg -o "$PROMPT_TOKEN_PATTERN" || true)
    done < <(rg --with-filename --no-heading --line-number --color=never "$PROMPT_TOKEN_PATTERN" "$file" || true)
  done
} | sort -u >"${current_tmp}.next"
mv "${current_tmp}.next" "$current_tmp"

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

printf "%-40s %8s\n" "metric" "count"
echo "------------------------------------------------"
printf "%-40s %8s\n" "legacy_tool_name_literals_current" "$current_count"
printf "%-40s %8s\n" "legacy_tool_name_allowlist_entries" "$allow_count"
printf "%-40s %8s\n" "legacy_tool_name_new_literals" "$new_count"
printf "%-40s %8s\n" "legacy_tool_name_stale_allowlist" "$stale_count"

if [[ "$MODE" = "--print" ]]; then
  echo
  echo "[no-legacy-tool-surface-name] current keys:"
  sed 's/^/  - /' "$current_tmp"
  exit 0
fi

fail=0

if [[ -s "$new_tmp" ]]; then
  echo
  echo "[no-legacy-tool-surface-name] DRIFT UP: legacy tool name re-emerged in active surface" >&2
  sed 's/^/  - /' "$new_tmp" >&2
  echo "  Use the descriptor-owned name (Execute, Read, Edit, Write, Grep, Search, WebSearch, WebFetch)." >&2
  echo "  See lib/keeper/keeper_tool_descriptor.ml for the canonical surface." >&2
  fail=1
fi

if [[ -s "$stale_tmp" ]]; then
  echo
  echo "[no-legacy-tool-surface-name] STALE ALLOWLIST: entries no longer match source" >&2
  sed 's/^/  - /' "$stale_tmp" >&2
  echo "  Remove these from $ALLOWLIST in the same PR." >&2
  fail=1
fi

exit $fail
