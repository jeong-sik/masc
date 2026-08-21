#!/usr/bin/env bash
# Projects .github/issue-taxonomy.json onto the repository labels.
# Labels absent from the SSOT are deleted. Deleting a label emits an unlabeled event on every issue that carried it.
set -euo pipefail

REPO="${1:-jeong-sik/masc}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SSOT="$ROOT/.github/issue-taxonomy.json"
APPLY="${APPLY:-0}"

[ -f "$SSOT" ] || { echo "missing SSOT: $SSOT" >&2; exit 1; }

desired="$(jq -r '
  [ (.axes | to_entries[] | .value.values | to_entries[] | .value),
    (.flags | to_entries[] | .value),
    (.standalone_labels | to_entries[] | .value) ]
  | .[] | [.label, .color, .description] | @tsv' "$SSOT")"

current="$(gh label list --repo "$REPO" --limit 400 --json name,color,description \
  --jq '.[] | [.name, .color, (.description // "")] | @tsv')"

desired_names="$(cut -f1 <<<"$desired" | sort)"
current_names="$(cut -f1 <<<"$current" | sort)"

to_delete="$(comm -13 <(echo "$desired_names") <(echo "$current_names"))"
to_create="$(comm -23 <(echo "$desired_names") <(echo "$current_names"))"

echo "ssot=$(wc -l <<<"$desired_names" | tr -d ' ') repo=$(wc -l <<<"$current_names" | tr -d ' ')"
[ -n "$to_create" ] && echo "to create:" && echo "$to_create" | sed 's/^/  + /'
[ -n "$to_delete" ] && echo "to delete:" && echo "$to_delete" | sed 's/^/  - /'

if [ "$APPLY" != "1" ]; then
  echo
  echo "Dry run. Re-run with APPLY=1 to apply."
  exit 0
fi

while IFS= read -r name; do
  [ -n "$name" ] || continue
  gh label delete "$name" --repo "$REPO" --yes
done <<<"$to_delete"

while IFS=$'\t' read -r name color desc; do
  [ -n "$name" ] || continue
  gh label create "$name" --repo "$REPO" --color "$color" --description "$desc" 2>/dev/null \
    || gh label edit "$name" --repo "$REPO" --color "$color" --description "$desc"
done <<<"$desired"

echo "done. labels now: $(gh label list --repo "$REPO" --limit 400 --json name --jq 'length')"
