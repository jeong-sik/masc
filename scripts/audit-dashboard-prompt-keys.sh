#!/usr/bin/env bash
# Fail when dashboard production code names a prompt key the server cannot emit.
#
# The dashboard decodes and labels prompt blocks by key string. Deleting a
# prompt asset is a server-side change that leaves those strings syntactically
# valid, so a panel keeps rendering a block that resolves to empty instead of
# failing. That happened after #26823 folded keeper.world / keeper.capabilities
# / keeper.constitution into keeper.system: the config panel decoded three
# blocks the server no longer sends and rendered nothing, and the assembly
# panel described six stages whose keys were gone.
#
# Scope is position-based, not prefix-based. "keeper." also prefixes schedule
# payload kinds (keeper.cron, keeper.smoke) and workspace source tags, which
# are unrelated namespaces. Only strings on a line that also names a prompt-key
# sink are checked. Test files are excluded: a fixture may legitimately feed a
# synthetic key to exercise the missing-block path.
#
# Authority: config/prompts/*.md basenames plus the keys declared in
# lib/prompt_registry/keeper_prompt_names.ml.
set -uo pipefail

cd "$(git rev-parse --show-toplevel)"

existing="$(mktemp)"
referenced="$(mktemp)"
trap 'rm -f "$existing" "$referenced"' EXIT

find config/prompts -name '*.md' -print0 \
  | xargs -0 -n1 basename \
  | sed 's/\.md$//' > "$existing"
grep -oE '"[a-z_][a-z_.]*"' lib/prompt_registry/keeper_prompt_names.ml \
  | tr -d '"' >> "$existing"
sort -u -o "$existing" "$existing"

# A prompt-key sink: the decoder, the assembly panel's stage specs, or the
# block map the server fills. Anything else that says "keeper.x" is a
# different namespace.
SINKS='normalizePromptBlock|promptKeys?|system_prompt_blocks'

# Namespaces are derived from the assets themselves, so a JSON response path
# like prompt.system_prompt_blocks is not mistaken for a prompt key.
ns="$(sed 's/\..*//' "$existing" | sort -u | paste -sd'|' -)"

grep -rn --include='*.ts' --exclude='*.test.ts' -E "$SINKS" dashboard/src 2>/dev/null \
  | grep -oE "'(${ns})(\.[a-z_.]+)?'" \
  | tr -d "'" \
  | sort -u > "$referenced"

stale="$(comm -23 "$referenced" "$existing")"

if [ -n "$stale" ]; then
  echo "[dashboard-prompt-keys] FAIL - dashboard names prompt keys that do not exist"
  echo
  printf '%s\n' "$stale" | sed 's/^/  - /'
  echo
  echo "Each resolves to an empty block or a rule that never matches."
  echo "Point it at a key in config/prompts, or delete the reference."
  echo
  while IFS= read -r key; do
    [ -z "$key" ] && continue
    grep -rn --include='*.ts' --exclude='*.test.ts' "'${key}'" dashboard/src 2>/dev/null | sed 's/^/  /'
  done <<< "$stale"
  exit 2
fi

count="$(wc -l < "$referenced" | tr -d ' ')"
echo "[dashboard-prompt-keys] OK - ${count} prompt keys named in dashboard code, all present"
