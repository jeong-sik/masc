#!/usr/bin/env bash
set -euo pipefail

REMOTE="origin"
HEAD_BRANCH=""
EXPECTED_HEAD_SHA=""
PR_NUMBER=""

usage() {
  cat <<'EOF'
Usage: scripts/check-pr-sync.sh --head-branch <branch> --expected-head-sha <sha> [--pr-number <num>] [--remote <remote>]

Checks that the current pull-request run is still aligned with the latest remote branch head.
Fails when the branch has advanced since the workflow payload was created.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote)
      REMOTE="${2:-}"
      shift 2
      ;;
    --head-branch)
      HEAD_BRANCH="${2:-}"
      shift 2
      ;;
    --expected-head-sha)
      EXPECTED_HEAD_SHA="${2:-}"
      shift 2
      ;;
    --pr-number)
      PR_NUMBER="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$HEAD_BRANCH" || -z "$EXPECTED_HEAD_SHA" ]]; then
  echo "--head-branch and --expected-head-sha are required" >&2
  usage >&2
  exit 2
fi

resolve_remote_head_sha() {
  local remote="$1"
  local head_branch="$2"
  local pr_number="$3"
  local remote_head_sha

  remote_head_sha="$(git ls-remote --heads "$remote" "refs/heads/${head_branch}" | awk '{print $1}')"
  if [[ -n "$remote_head_sha" ]]; then
    printf '%s\n' "$remote_head_sha"
    return 0
  fi

  remote_head_sha="$(git ls-remote --heads "$remote" "$head_branch" | awk '{print $1}')"
  if [[ -n "$remote_head_sha" ]]; then
    printf '%s\n' "$remote_head_sha"
    return 0
  fi

  if [[ -n "$pr_number" ]]; then
    remote_head_sha="$(git ls-remote "$remote" "refs/pull/${pr_number}/head" | awk '{print $1}')"
    if [[ -n "$remote_head_sha" ]]; then
      printf '%s\n' "$remote_head_sha"
      return 0
    fi
  fi

  return 1
}

REMOTE_HEAD_SHA="$(resolve_remote_head_sha "$REMOTE" "$HEAD_BRANCH" "$PR_NUMBER" || true)"

if [[ -z "$REMOTE_HEAD_SHA" ]]; then
  if [[ -n "$PR_NUMBER" ]]; then
    echo "::error title=PR head branch missing::Could not resolve ${REMOTE}/${HEAD_BRANCH} or refs/pull/${PR_NUMBER}/head"
  else
    echo "::error title=PR head branch missing::Could not resolve ${REMOTE}/${HEAD_BRANCH}"
  fi
  exit 1
fi

echo "[pr-sync] remote=${REMOTE}"
echo "[pr-sync] head_branch=${HEAD_BRANCH}"
echo "[pr-sync] expected_head_sha=${EXPECTED_HEAD_SHA}"
echo "[pr-sync] remote_head_sha=${REMOTE_HEAD_SHA}"

if [[ "$REMOTE_HEAD_SHA" != "$EXPECTED_HEAD_SHA" ]]; then
  echo "::error title=Stale PR run detected::workflow payload head ${EXPECTED_HEAD_SHA} is stale; remote ${HEAD_BRANCH} is now ${REMOTE_HEAD_SHA}"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      echo "## PR Sync Check"
      echo ""
      echo "- Branch: \`${HEAD_BRANCH}\`"
      echo "- Workflow payload head: \`${EXPECTED_HEAD_SHA}\`"
      echo "- Remote branch head: \`${REMOTE_HEAD_SHA}\`"
      echo ""
      echo "This run is stale because the branch advanced after the workflow payload was created."
    } >> "$GITHUB_STEP_SUMMARY"
  fi
  exit 1
fi

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "## PR Sync Check"
    echo ""
    echo "- Branch: \`${HEAD_BRANCH}\`"
    echo "- Head SHA: \`${EXPECTED_HEAD_SHA}\`"
    echo "- Status: current"
  } >> "$GITHUB_STEP_SUMMARY"
fi

echo "[pr-sync] branch head is current"
