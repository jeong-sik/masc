#!/usr/bin/env bash
# check-main-branch-protection.sh - detect branch-protection drift for #9738.
#
# The draft PR guard only prevents ready/merge races when GitHub branch
# protection requires the guard checks and applies them to admins.  This check
# keeps that repository setting visible in CI instead of relying on memory of a
# one-time settings change.
set -euo pipefail

repo="${BRANCH_PROTECTION_REPOSITORY:-${GITHUB_REPOSITORY:-}}"
branch="${BRANCH_PROTECTION_BRANCH:-${GITHUB_BASE_REF:-${GITHUB_REF_NAME:-main}}}"
required_contexts_csv="${BRANCH_PROTECTION_REQUIRED_CONTEXTS:-CI Gate,Draft Auto-Merge Guard}"

if [[ -z "$repo" ]]; then
  echo "::error title=Branch protection check misconfigured::BRANCH_PROTECTION_REPOSITORY or GITHUB_REPOSITORY is required."
  exit 1
fi

if [[ "$branch" != "main" ]]; then
  echo "branch protection drift: skipped for branch ${branch}; #9738 guard applies to main"
  exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "::error title=Branch protection check unavailable::GitHub CLI 'gh' is required."
  exit 1
fi

endpoint="repos/${repo}/branches/${branch}/protection"

is_integration_forbidden() {
  local output="$1"
  [[ "$output" == *'"message":"Resource not accessible by integration"'* ]] ||
    [[ "$output" == *"gh: Resource not accessible by integration (HTTP 403)"* ]]
}

escape_workflow_command_data() {
  local value="${1-}"
  value="${value//%/%25}"
  value="${value//$'\r'/%0D}"
  value="${value//$'\n'/%0A}"
  printf '%s' "$value"
}

skip_integration_forbidden() {
  local output="$1"
  local details
  details="$(escape_workflow_command_data "$output")"
  echo "::warning title=Branch protection check unavailable::Could not read ${repo}/${branch} branch protection with this GitHub token; skipping drift check. Details: ${details}"
  exit 0
}

if ! enforce_admins="$(gh api "$endpoint" --jq '.enforce_admins.enabled' 2>&1)"; then
  if is_integration_forbidden "$enforce_admins"; then
    skip_integration_forbidden "$enforce_admins"
  fi
  echo "::error title=Branch protection check failed::Could not read ${repo}/${branch} branch protection: ${enforce_admins}"
  exit 1
fi

if ! contexts="$(gh api "$endpoint" --jq '.required_status_checks.contexts[]?' 2>&1)"; then
  if is_integration_forbidden "$contexts"; then
    skip_integration_forbidden "$contexts"
  fi
  echo "::error title=Branch protection check failed::Could not read required status contexts for ${repo}/${branch}: ${contexts}"
  exit 1
fi

failures=()
if [[ "$enforce_admins" != "true" ]]; then
  failures+=("enforce_admins.enabled=${enforce_admins}; expected true")
fi

IFS=',' read -r -a required_contexts <<<"$required_contexts_csv"
for context in "${required_contexts[@]}"; do
  context="$(printf '%s' "$context" | xargs)"
  [[ -n "$context" ]] || continue
  if ! printf '%s\n' "$contexts" | grep -Fxq "$context"; then
    failures+=("missing required status context: ${context}")
  fi
done

if ((${#failures[@]} > 0)); then
  printf '::error title=Branch protection drift::%s\n' "${failures[*]}"
  printf 'Configured contexts for %s/%s:\n%s\n' "$repo" "$branch" "${contexts:-"(none)"}"
  exit 1
fi

printf 'branch protection drift: OK for %s/%s (enforce_admins=true; required contexts present: %s)\n' \
  "$repo" "$branch" "$required_contexts_csv"
