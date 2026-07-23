#!/usr/bin/env bash
set -euo pipefail

REMOTE="origin"
HEAD_BRANCH=""
EXPECTED_HEAD_SHA=""
PR_NUMBER=""
BASE_REF=""

usage() {
  cat <<'EOF'
Usage: scripts/check-pr-sync.sh --head-branch <branch> --expected-head-sha <sha> [--pr-number <num>] [--remote <remote>]
or --base-ref <ref>

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
    --base-ref)
      BASE_REF="${2:-}"
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

extract_dune_project_version() {
  local ref="$1"
  local pkg
  pkg="$(git show "${ref}:dune-project" 2>/dev/null \
    | grep -oE '^[[:space:]]*\(version[[:space:]]+[^)]*\)' \
    | head -n1 \
    | sed -E 's/^[[:space:]]*\(version[[:space:]]+//; s/[[:space:]]*\)$//' )"
  printf '%s\n' "${pkg}"
}

version_gt() {
  local left="$1" right="$2"
  [[ -n "${left}" && -n "${right}" ]] || return 1
  [[ "${left}" != "${right}" ]] && [[ "$(printf '%s\n%s\n' "${left}" "${right}" | sort -V | tail -n1)" == "${left}" ]]
}

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
  echo "::warning title=Stale PR run detected::workflow payload head ${EXPECTED_HEAD_SHA} is stale; remote ${HEAD_BRANCH} is now ${REMOTE_HEAD_SHA}"

  # Attempt to re-trigger CI for the current branch head.
  # GitHub may drop the synchronize event on force push (race condition).
  # gh CLI is available in GitHub Actions runners by default.
  RETRIGGER_OK=false
  if command -v gh >/dev/null 2>&1 && [[ -n "${GITHUB_REPOSITORY:-}" ]]; then
    WORKFLOW_NAME="${GITHUB_WORKFLOW:-CI}"
    echo "[pr-sync] re-triggering workflow '${WORKFLOW_NAME}' on branch ${HEAD_BRANCH}"
    if gh workflow run "${WORKFLOW_NAME}" --ref "${HEAD_BRANCH}" 2>/dev/null; then
      RETRIGGER_OK=true
      echo "[pr-sync] re-trigger dispatched for ${HEAD_BRANCH} (HEAD: ${REMOTE_HEAD_SHA})"
    else
      echo "[pr-sync] re-trigger failed (gh workflow run returned non-zero)"
    fi
  else
    echo "[pr-sync] gh CLI not available or not in GitHub Actions; skipping re-trigger"
  fi

  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      echo "## PR Sync Check"
      echo ""
      echo "- Branch: \`${HEAD_BRANCH}\`"
      echo "- Workflow payload head: \`${EXPECTED_HEAD_SHA}\`"
      echo "- Remote branch head: \`${REMOTE_HEAD_SHA}\`"
      echo ""
      if [[ "$RETRIGGER_OK" == "true" ]]; then
        echo "This run is stale. A new CI run has been dispatched for the current HEAD."
      else
        echo "This run is stale because the branch advanced after the workflow payload was created."
      fi
    } >> "$GITHUB_STEP_SUMMARY"
  fi
  exit 1
fi

if [[ -n "$BASE_REF" ]]; then
  # PRs can be built from a stale base. If base has already moved to a newer
  # package floor, fail fast with a clear remediation instead of letting
  # later guard stages decide the outcome.
  BASE_VERSION="$(extract_dune_project_version "$BASE_REF")"
  HEAD_VERSION="$(extract_dune_project_version "$EXPECTED_HEAD_SHA")"

  # Fail loud instead of warning-only: with a shallow checkout (default
  # actions/checkout depth 1) neither origin/<base> nor the head commit
  # exists locally, both versions come back empty, and the drift gate below
  # would silently never evaluate. A gate that cannot read its inputs must
  # fail, not pass.
  if [[ -z "$BASE_VERSION" ]]; then
    echo "::error title=PR base package version unreadable::Could not read version from ${BASE_REF}:dune-project. Ensure the base branch is fetched locally (checkout fetch-depth)."
    exit 1
  fi

  if [[ -z "$HEAD_VERSION" ]]; then
    echo "::error title=PR head package version unreadable::Could not read version from ${EXPECTED_HEAD_SHA}:dune-project. Ensure the PR head commit is fetched locally."
    exit 1
  fi

  if version_gt "$BASE_VERSION" "$HEAD_VERSION"; then
    echo "::error title=PR base package version drift::Base (${BASE_REF}) is on package ${BASE_VERSION} but PR head ${EXPECTED_HEAD_SHA} is still ${HEAD_VERSION}."
    echo "  Rebase this branch onto ${BASE_REF}, then re-run CI."

    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
      {
        echo "## PR Sync Check"
        echo ""
        echo "- Branch: \`${HEAD_BRANCH}\`"
        echo "- PR base reference: \`${BASE_REF}\` (${BASE_VERSION})"
        echo "- PR head: \`${EXPECTED_HEAD_SHA}\` (${HEAD_VERSION})"
        echo "- Failure: package version in PR head is behind base"
        echo "- Recommended fix: rebase branch onto ${BASE_REF}"
      } >> "$GITHUB_STEP_SUMMARY"
    fi
    exit 1
  fi
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
