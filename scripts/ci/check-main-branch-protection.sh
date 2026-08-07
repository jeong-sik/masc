#!/usr/bin/env bash
# check-main-branch-protection.sh - detect branch-protection drift for #9738.
#
# This check fails closed when it cannot read branch-protection settings;
# otherwise CI silently masks required-context drift.
set -euo pipefail

repo="${BRANCH_PROTECTION_REPOSITORY:-${GITHUB_REPOSITORY:-}}"
branch="${BRANCH_PROTECTION_BRANCH:-${GITHUB_BASE_REF:-${GITHUB_REF_NAME:-main}}}"
required_contexts_csv="${BRANCH_PROTECTION_REQUIRED_CONTEXTS:-CI Gate}"

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

is_unauthorized() {
  local output="$1"
  [[ "$output" == *'{"status": "401"}'* ]] ||
    [[ "$output" == *"Requires authentication"* ]] ||
    [[ "$output" == *"Bad credentials"* ]] ||
    [[ "$output" == *"(HTTP 401)"* ]]
}

escape_workflow_command_data() {
  local value="${1-}"
  value="${value//%/%25}"
  value="${value//$'\r'/%0D}"
  value="${value//$'\n'/%0A}"
  printf '%s' "$value"
}

handle_integration_forbidden() {
  local output="$1"
  local details
  details="$(escape_workflow_command_data "$output")"
  echo "::error title=Branch protection check unavailable::Could not read ${repo}/${branch} branch protection with this GitHub token; refusing to skip drift check. Provide a token that can read branch protection. Details: ${details}"
  exit 1
}

handle_unauthorized() {
  local output="$1"
  local details
  details="$(escape_workflow_command_data "$output")"
  # 401 means the credential itself is invalid or expired. Unlike a transient
  # flake it never heals on retry, so it names the fix rather than suggesting
  # a retry.
  echo "::error title=Branch protection check unavailable::Could not read ${repo}/${branch} branch protection: 401 unauthorized (invalid or expired token, persistent rather than a transient flake). Rotate BRANCH_PROTECTION_AUDIT_TOKEN. Details: ${details}"
  exit 1
}

if ! enforce_admins="$(gh api "$endpoint" --jq '.enforce_admins.enabled' 2>&1)"; then
  if is_unauthorized "$enforce_admins"; then
    handle_unauthorized "$enforce_admins"
  fi
  if is_integration_forbidden "$enforce_admins"; then
    handle_integration_forbidden "$enforce_admins"
  fi
  echo "::error title=Branch protection check failed::Could not read ${repo}/${branch} branch protection: ${enforce_admins}"
  exit 1
fi

if ! contexts="$(gh api "$endpoint" --jq '.required_status_checks.contexts[]?' 2>&1)"; then
  if is_unauthorized "$contexts"; then
    handle_unauthorized "$contexts"
  fi
  if is_integration_forbidden "$contexts"; then
    handle_integration_forbidden "$contexts"
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
