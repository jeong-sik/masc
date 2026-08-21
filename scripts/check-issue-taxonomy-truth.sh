#!/usr/bin/env bash
# .github/issue-taxonomy.json is the vocabulary SSOT. Prose that lists its values is a copy,
# and a copy goes stale the moment a value is added. This asserts that every value the SSOT
# declares is still named in the docs that enumerate them.
#
# One direction only: SSOT -> docs. A value the docs no longer mention is the harmful case,
# because the gate accepts it while the docs deny it exists.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SSOT="$ROOT/.github/issue-taxonomy.json"
DOCS=("$ROOT/CONTRIBUTING.md" "$ROOT/docs/PRODUCT-OPERATING-PLAN.md")

[ -f "$SSOT" ] || { echo "missing SSOT: $SSOT" >&2; exit 1; }

values="$(jq -r '
  (.axes | to_entries[] | .key as $ax | .value.values | keys[] | "\($ax)/\(.)"),
  (.flags | keys[])' "$SSOT")"

fail=0
for doc in "${DOCS[@]}"; do
  [ -f "$doc" ] || { echo "missing doc: $doc" >&2; fail=1; continue; }
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    name="${v##*/}"
    grep -qF -- "$name" "$doc" || {
      echo "::error file=${doc#"$ROOT/"}::'$v' is in the taxonomy SSOT but '$name' is not named here" >&2
      fail=1
    }
  done <<<"$values"
done

if [ "$fail" -eq 0 ]; then
  echo "issue taxonomy truth: $(grep -c . <<<"$values") values named in ${#DOCS[@]} docs"
fi
exit "$fail"
