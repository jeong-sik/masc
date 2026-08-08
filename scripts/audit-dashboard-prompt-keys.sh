#!/usr/bin/env bash
# Fail when dashboard production code names a prompt key the server cannot emit.
#
# The dashboard decodes and labels prompt blocks by key string. Every referenced
# key must resolve to a current prompt asset or registry constant.
#
# Scope is position-based, not prefix-based. "keeper." also prefixes schedule
# payload kinds (keeper.cron, keeper.smoke) and workspace source tags, which
# are unrelated namespaces. Only strings on a line that also names a prompt-key
# sink are checked. Test files are excluded: a fixture may legitimately feed a
# synthetic key to exercise the missing-block path.
#
# Authority: config/prompts/*.md basenames plus the keys declared in
# lib/prompt_registry/prompt_names.ml.
set -uo pipefail

cd "$(git rev-parse --show-toplevel)"

existing="$(mktemp)"
referenced="$(mktemp)"
trap 'rm -f "$existing" "$referenced"' EXIT

find config/prompts -name '*.md' -print0 \
  | xargs -0 -n1 basename \
  | sed 's/\.md$//' > "$existing"
# Fail rather than contribute nothing if the constants file moves again: a
# silent miss here is how the file sat at a stale path across two renames.
names_file=lib/prompt_registry/prompt_names.ml
if [ ! -f "$names_file" ]; then
  echo "[dashboard-prompt-keys] FAIL - prompt-name constants not at $names_file"
  exit 2
fi
grep -oE '"[a-z_][a-z_.]*"' "$names_file" \
  | tr -d '"' >> "$existing"
sort -u -o "$existing" "$existing"

# A prompt-key sink: the decoder, the assembly panel's stage specs, or the
# block map the server fills. Anything else that says "keeper.x" is a
# different namespace.
SINKS='normalizePromptBlock|promptKeys?|system_prompt_blocks'

# Namespaces are derived from the assets themselves, so a JSON response path
# like prompt.system_prompt_blocks is not mistaken for a prompt key.
ns="$(sed 's/\..*//' "$existing" | sort -u | paste -sd'|' -)"

# -A5 so a key inside a multi-line promptKeys array is seen. Without it the
# sink line holds only "promptKeys: [" and every key on a following line would
# otherwise go unchecked.
grep -rn -A5 --include='*.ts' --exclude='*.test.ts' -E "$SINKS" dashboard/src 2>/dev/null \
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
