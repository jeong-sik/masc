#!/usr/bin/env bash
# Projects .github/issue-taxonomy.json onto the repository labels.
#
# Ownership is scoped: this script only creates, edits, or deletes labels whose name
# matches an SSOT axis prefix (kind/, area/, ...) or an SSOT flag name. Labels owned by
# other systems - dependabot's `dependencies`, the release gate's `release-blocker` - are
# left alone. An earlier unscoped sweep deleted those and broke both consumers.
#
# Deleting a label removes it from every issue that carried it and emits an unlabeled
# event on each one.
set -euo pipefail

REPO="${1:-jeong-sik/masc}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SSOT="$ROOT/.github/issue-taxonomy.json"
APPLY="${APPLY:-0}"

[ -f "$SSOT" ] || { echo "missing SSOT: $SSOT" >&2; exit 1; }

desired="$(jq -r '
  [ (.axes | to_entries[] | .value.values | to_entries[] | .value),
    (.flags | to_entries[] | .value) ]
  | .[] | [.label, .color, .description] | @tsv' "$SSOT")"

# Every name this script is allowed to touch: axis prefixes plus flag names.
owned_re="$(jq -r '
  ((.axes | keys | map(. + "/")) + (.flags | keys | map(. + "$")))
  | map("^" + .) | join("|")' "$SSOT")"

current_all="$(gh api --paginate "repos/$REPO/labels?per_page=100" --jq '.[].name' | sort)"
current_owned="$(grep -E "$owned_re" <<<"$current_all" || true)"
desired_names="$(cut -f1 <<<"$desired" | sort)"

to_delete="$(comm -13 <(echo "$desired_names") <(echo "$current_owned"))"
to_create="$(comm -23 <(echo "$desired_names") <(echo "$current_owned"))"
foreign_count=$(( $(grep -c . <<<"$current_all") - $(grep -c . <<<"${current_owned:-}" || true) ))

echo "ssot=$(wc -l <<<"$desired_names" | tr -d ' ') owned_in_repo=$(grep -c . <<<"${current_owned:-}" || echo 0) untouched=$foreign_count"
[ -n "$to_create" ] && { echo "to create:"; sed 's/^/  + /' <<<"$to_create"; }
[ -n "$to_delete" ] && { echo "to delete (owned prefix, absent from SSOT):"; sed 's/^/  - /' <<<"$to_delete"; }

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
