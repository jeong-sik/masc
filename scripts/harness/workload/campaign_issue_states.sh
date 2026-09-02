#!/usr/bin/env bash
# Writes masc.github_issue_states.v1 for every issue named in the given
# residual files, using gh. The scoreboard reads this file instead of calling
# gh itself, so scoring stays deterministic and testable.
#
# usage: campaign_issue_states.sh <out.json> <residuals.json>...
set -euo pipefail
out="${1:?out path}"; shift
[ "$#" -ge 1 ] || { echo "usage: $0 <out.json> <residuals.json>..." >&2; exit 2; }
issues=$(jq -r '.entries[].issue | select(. != null)' "$@" | sort -u)
{
  printf '{"schema":"masc.github_issue_states.v1","checked_at":"%s","issues":{' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  first=1
  for issue in $issues; do
    repo="${issue%%#*}"; number="${issue##*#}"
    state=$(gh issue view "$number" --repo "$repo" --json state -q .state)
    [ "$first" -eq 1 ] || printf ','
    printf '"%s":"%s"' "$issue" "$state"
    first=0
  done
  printf '}}\n'
} > "$out"
jq . "$out" > /dev/null
echo "issue states: $(jq '.issues | length' "$out") -> $out"
