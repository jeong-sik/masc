#!/usr/bin/env bash
# Explicitly select one merge candidate; ordinary PR creation does not run CI.
set -euo pipefail

pr="${1:?usage: select-pr.sh <pr-number> [owner/repo]}"
[[ "$pr" =~ ^[1-9][0-9]*$ ]] || { echo "expected a PR number" >&2; exit 2; }
repo="${2:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
state=$(gh pr view "$pr" --repo "$repo" --json state,isDraft --jq '.state + " " + (.isDraft | tostring)')
case "$state" in
  'OPEN false') gh pr ready "$pr" --repo "$repo" --undo ;;
  'OPEN true') ;;
  *) echo "expected an open PR, got: $state" >&2; exit 1 ;;
esac
gh pr edit "$pr" --repo "$repo" --add-label ci:run
gh pr ready "$pr" --repo "$repo"
