#!/usr/bin/env bash
# check-main-branch-protection.sh - detect branch-protection drift for #9738.
#
# This check must fail closed when it cannot read branch-protection settings;
# otherwise CI silently masks required-context drift.
#
# BRANCH_PROTECTION_ALLOW_UNREADABLE=1 opts into warning+bypass when the API
# is unreadable. A 401 means the credential itself is invalid/expired and
# never heals on retry, so consecutive-bypass tracking is available for
# bypass callers: set BRANCH_PROTECTION_UNREADABLE_STATE_FILE to a path that
# persists across runs and the bypass fails closed after
# BRANCH_PROTECTION_UNREADABLE_MAX_CONSECUTIVE (default 3) consecutive 401s.
set -euo pipefail

repo="${BRANCH_PROTECTION_REPOSITORY:-${GITHUB_REPOSITORY:-}}"
branch="${BRANCH_PROTECTION_BRANCH:-${GITHUB_BASE_REF:-${GITHUB_REF_NAME:-main}}}"
required_contexts_csv="${BRANCH_PROTECTION_REQUIRED_CONTEXTS:-CI Gate}"
allow_unreadable="${BRANCH_PROTECTION_ALLOW_UNREADABLE:-0}"
unreadable_state_file="${BRANCH_PROTECTION_UNREADABLE_STATE_FILE:-}"
max_consecutive_unreadable="${BRANCH_PROTECTION_UNREADABLE_MAX_CONSECUTIVE:-3}"
if ! [[ "$max_consecutive_unreadable" =~ ^[0-9]+$ ]]; then
  echo "::error title=Branch protection check misconfigured::BRANCH_PROTECTION_UNREADABLE_MAX_CONSECUTIVE must be a non-negative integer (got '${max_consecutive_unreadable}'); refusing to run with an unparsable fail-closed threshold."
  exit 1
fi

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
  if [[ "$allow_unreadable" == "1" || "$allow_unreadable" == "true" ]]; then
    echo "::warning title=Branch protection check unavailable::Could not read ${repo}/${branch} branch protection with this GitHub token; BRANCH_PROTECTION_ALLOW_UNREADABLE=${allow_unreadable} permits this diagnostic bypass. Details: ${details}"
    exit 0
  fi
  echo "::error title=Branch protection check unavailable::Could not read ${repo}/${branch} branch protection with this GitHub token; refusing to skip drift check. Provide a token that can read branch protection, or set BRANCH_PROTECTION_ALLOW_UNREADABLE=1 only for non-required diagnostics. Details: ${details}"
  exit 1
}

record_consecutive_unauthorized() {
  # Tracks consecutive bypassed 401s in $unreadable_state_file. Returns 1 when
  # the count reaches the fail-closed threshold; no-op (returns 0) when no
  # state file is configured.
  # Called under `if ! ...`, which suspends `set -e` inside the function, so
  # write failures are checked explicitly: a bypass without accounting would
  # reset the count to 1 every run (fail-open), so it fails closed instead.
  [[ -n "$unreadable_state_file" ]] || return 0
  local count=0
  if [[ -f "$unreadable_state_file" ]]; then
    count="$(cat "$unreadable_state_file" 2>/dev/null || printf '0')"
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
  fi
  count=$((count + 1))
  if ! mkdir -p "$(dirname "$unreadable_state_file")" ||
    ! printf '%s\n' "$count" >"$unreadable_state_file"; then
    echo "::error title=Branch protection check failing closed::Could not write consecutive-401 state file '${unreadable_state_file}'; refusing to bypass without accounting. Fix the path or unset BRANCH_PROTECTION_UNREADABLE_STATE_FILE."
    exit 1
  fi
  ((count >= max_consecutive_unreadable)) && return 1
  return 0
}

reset_consecutive_unauthorized() {
  if [[ -n "$unreadable_state_file" && -f "$unreadable_state_file" ]]; then
    printf '0\n' >"$unreadable_state_file"
  fi
}

handle_unauthorized() {
  local output="$1"
  local details
  details="$(escape_workflow_command_data "$output")"
  # 401 means the credential itself is invalid or expired. Unlike a transient
  # flake it never heals on retry, so it stays loud even when bypassed.
  echo "::warning title=Branch protection audit token unauthorized::GitHub API returned 401 for ${repo}/${branch}; the token is invalid or expired (persistent, not a transient flake). Rotate BRANCH_PROTECTION_AUDIT_TOKEN. Details: ${details}"
  if [[ "$allow_unreadable" == "1" || "$allow_unreadable" == "true" ]]; then
    if ! record_consecutive_unauthorized; then
      echo "::error title=Branch protection check failing closed::401 unauthorized for ${max_consecutive_unreadable} consecutive runs; BRANCH_PROTECTION_ALLOW_UNREADABLE no longer bypasses. Rotate BRANCH_PROTECTION_AUDIT_TOKEN."
      exit 1
    fi
    echo "::warning title=Branch protection check unavailable::BRANCH_PROTECTION_ALLOW_UNREADABLE=${allow_unreadable} permits this diagnostic bypass; consecutive 401s fail closed after ${max_consecutive_unreadable} runs when BRANCH_PROTECTION_UNREADABLE_STATE_FILE is set."
    exit 0
  fi
  echo "::error title=Branch protection check unavailable::Could not read ${repo}/${branch} branch protection: 401 unauthorized (invalid or expired token). Rotate BRANCH_PROTECTION_AUDIT_TOKEN, or set BRANCH_PROTECTION_ALLOW_UNREADABLE=1 only for non-required diagnostics. Details: ${details}"
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

reset_consecutive_unauthorized

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
