#!/usr/bin/env bash

# Normalize the configured OAS tracking ref without guessing its namespace.
# Branch names retain the historical shorthand; cross-repo review pins must use
# GitHub's exact pull-request ref so CI can fetch and prove their ancestry.
oas_pin_remote_ref() {
  local configured_ref="$1"
  case "${configured_ref}" in
    refs/heads/*)
      [[ "${configured_ref}" != "refs/heads/" ]] || return 1
      printf '%s' "${configured_ref}"
      ;;
    refs/pull/[1-9]*'/head')
      [[ "${configured_ref}" =~ ^refs/pull/[1-9][0-9]*/head$ ]] || return 1
      printf '%s' "${configured_ref}"
      ;;
    refs/* | "")
      return 1
      ;;
    *)
      printf 'refs/heads/%s' "${configured_ref}"
      ;;
  esac
}

oas_pin_require_track_policy() {
  local remote_ref="$1"
  local allow_review_ref="${2:-0}"
  case "${remote_ref}" in
    refs/heads/main)
      return 0
      ;;
    refs/pull/[1-9]*'/head')
      if [[ "${allow_review_ref}" == "1" ]]; then
        return 0
      fi
      echo "OAS review ref ${remote_ref} is allowed only for an explicitly blocked Draft PR" >&2
      echo "  repair: merge the upstream PR and restore OAS_AGENT_SDK_TRACK_REF=main" >&2
      return 1
      ;;
    *)
      echo "unsupported OAS tracking ref: ${remote_ref}" >&2
      echo "  allowed: refs/heads/main, or refs/pull/<number>/head for an explicitly blocked Draft PR" >&2
      return 1
      ;;
  esac
}
