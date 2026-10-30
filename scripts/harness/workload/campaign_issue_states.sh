#!/usr/bin/env bash
# Writes masc.github_issue_states.v1 for every issue named in the given
# residual files, using gh. The scoreboard reads this file instead of calling
# gh itself, so scoring stays deterministic and testable.
#
# The output is written to a temp file and moved into place only after it
# parses, so a gh failure never leaves a truncated file where a good one was.
#
# usage: campaign_issue_states.sh <out.json> <residuals.json>...
set -euo pipefail
out="${1:?out path}"; shift
[ "$#" -ge 1 ] || { echo "usage: $0 <out.json> <residuals.json>..." >&2; exit 2; }
for residuals in "$@"; do
  jq -e '.schema == "masc.keeper_campaign_residuals.v1"' "$residuals" > /dev/null \
    || { echo "$residuals: schema must be masc.keeper_campaign_residuals.v1" >&2; exit 2; }
done
tmp="$(mktemp "${out}.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
issue_re='^[^/[:space:]#]+/[^/[:space:]#]+#[1-9][0-9]*$'
{
  printf '{"schema":"masc.github_issue_states.v1","checked_at":"%s","issues":{' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  first=1
  while IFS= read -r issue; do
    [ -n "$issue" ] || continue
    [[ "$issue" =~ $issue_re ]] || { echo "residual issue must be owner/repo#N, got '$issue'" >&2; exit 2; }
    repo="${issue%%#*}"; number="${issue##*#}"
    state="$(gh issue view "$number" --repo "$repo" --json state -q .state)"
    [ "$first" -eq 1 ] || printf ','
    printf '"%s":"%s"' "$issue" "$state"
    first=0
  done < <(jq -r '.entries[].issue | select(. != null)' "$@" | sort -u)
  printf '}}\n'
} > "$tmp"
jq -e '.schema == "masc.github_issue_states.v1" and (.issues | type == "object")' "$tmp" > /dev/null
mv "$tmp" "$out"
trap - EXIT
echo "issue states: $(jq '.issues | length' "$out") -> $out"
