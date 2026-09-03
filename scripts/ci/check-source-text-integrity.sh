#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

scan_paths=(
  bin lib test scripts config packages viewer docs
  ':(exclude)docs/evidence/**'
  ':(exclude)docs/screenshots/**'
)
failed=0

report_matches() {
  local label="$1"
  local matches="$2"
  if [[ -n "$matches" ]]; then
    printf '%s\n%s\n' "source text integrity: ${label}" "$matches" >&2
    failed=1
  fi
}

conflict_matches="$({
  git grep -n -I -E \
    '^(<<<<<<< |>>>>>>> |\|\|\|\|\|\|\| |=======$)' \
    -- "${scan_paths[@]}" || true
})"
report_matches "merge conflict markers" "$conflict_matches"

# These are UTF-8 encodings of the leading characters produced when UTF-8
# text is decoded as Latin-1 and encoded again. Build the patterns from bytes
# so this checker does not contain, and therefore match, its own bad text.
for pattern in \
  "$(printf '\303\242')" \
  "$(printf '\303\203')" \
  "$(printf '\303\202')" \
  "$(printf '\303\260\305\270')" \
  "$(printf '\303\257\302\273\302\277')" \
  "$(printf '\357\277\275')"
do
  mojibake_matches="$({
    git grep -n -I -F "$pattern" -- "${scan_paths[@]}" || true
  })"
  report_matches "mojibake" "$mojibake_matches"
done

registry_prefix='Keeper_runtime_setting_registry\.'
retired_registry_api='(active|active_toml|active_toml_mappings|lifecycle_label)'
registry_matches="$({
  git grep -n -I -E "${registry_prefix}${retired_registry_api}" \
    -- "${scan_paths[@]}" || true
})"
report_matches "removed Keeper registry API" "$registry_matches"

if [[ "$failed" -ne 0 ]]; then
  exit 1
fi

echo "source text integrity: PASS"
