#!/usr/bin/env bash
# check-main-branch-protection.sh - detect branch-protection drift for #9738.
#
# What it guards: main still requires the status contexts named in
# BRANCH_PROTECTION_REQUIRED_CONTEXTS. Dropping one of those is what lets an
# unchecked merge reach main, so it remains the failing assertion.
#
# Main must also require branches to be current and apply the same checks to
# administrators. #30755 merged with no successful CI Gate on its exact head
# while both strict and enforce_admins were false; either regression reopens
# that broken window, so both are failing assertions.
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

if ! protection="$(gh api "$endpoint" --jq '
  (.required_status_checks.contexts[]? | "context=" + .),
  ("strict=" +
    (if (.required_status_checks.strict | type) == "boolean"
     then (.required_status_checks.strict | tostring)
     else "unreadable"
     end)),
  ("enforce_admins=" +
    (if (.enforce_admins.enabled | type) == "boolean"
     then (.enforce_admins.enabled | tostring)
     else "unreadable"
     end))
' 2>&1)"; then
  if is_unauthorized "$protection"; then
    handle_unauthorized "$protection"
  fi
  if is_integration_forbidden "$protection"; then
    handle_integration_forbidden "$protection"
  fi
  echo "::error title=Branch protection check failed::Could not read branch protection settings for ${repo}/${branch}: ${protection}"
  exit 1
fi

contexts="$(printf '%s\n' "$protection" | sed -n 's/^context=//p')"
strict="$(printf '%s\n' "$protection" | sed -n 's/^strict=//p')"
enforce_admins="$(printf '%s\n' "$protection" | sed -n 's/^enforce_admins=//p')"

failures=()

case "$strict" in
  true) ;;
  false) failures+=("required status checks are not strict: branch can be behind main") ;;
  *) failures+=("required_status_checks.strict is unreadable") ;;
esac

case "$enforce_admins" in
  true) ;;
  false) failures+=("admin enforcement is disabled: admins can bypass CI Gate") ;;
  *) failures+=("enforce_admins.enabled is unreadable") ;;
esac

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

printf 'branch protection drift: OK for %s/%s (required contexts present: %s; strict: enabled; admin enforcement: enabled)\n' \
  "$repo" "$branch" "$required_contexts_csv"
