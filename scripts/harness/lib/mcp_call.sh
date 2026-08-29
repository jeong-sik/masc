# shellcheck shell=bash
# MCP tool-call helpers shared by the live harness scripts.
#
# Extracted from scripts/harness_tool_call_quality.sh so that
# harness_coding_eval.sh does not carry a second copy (RFC-0396). Depends on
# call_tool / extract_result / extract_text / extract_error and
# CURL_TIMEOUT_SEC from scripts/harness/lib/test_framework.sh, which callers
# source first.
#
# State: the last raw response and its extracted error live in
# LAST_TOOL_RAW / LAST_TOOL_ERROR, read by the accessors below.

LAST_TOOL_RAW="${LAST_TOOL_RAW:-}"
LAST_TOOL_ERROR="${LAST_TOOL_ERROR:-}"

call_mcp_tool() {
  local req_id="$1"
  local tool_name="$2"
  local args_json="$3"
  local timeout_sec="${4:-$TIMEOUT_SEC}"
  local saved_timeout="${CURL_TIMEOUT_SEC:-25}"

  CURL_TIMEOUT_SEC="$timeout_sec"
  LAST_TOOL_RAW="$(call_tool "$req_id" "$tool_name" "$args_json")"
  CURL_TIMEOUT_SEC="$saved_timeout"

  if printf '%s' "$LAST_TOOL_RAW" | jq -e '._harness_error? != null' >/dev/null 2>&1; then
    LAST_TOOL_ERROR="$(printf '%s' "$LAST_TOOL_RAW" | jq -r '._harness_error.message // "transport error"')"
    return 1
  fi

  LAST_TOOL_ERROR="$(printf '%s' "$LAST_TOOL_RAW" | jq -r '
    if .error?.message then .error.message
    elif (.result?.isError // false) == true then
      ([.result.content[]? | select(.type == "text") | .text] | join(" "))
    else empty end
  ' 2>/dev/null | awk 'NF { print; exit }')"

  if [[ -n "${LAST_TOOL_ERROR}" ]]; then
    return 1
  fi
  return 0
}

tool_result_json() {
  printf '%s' "${LAST_TOOL_RAW}" | extract_result
}

tool_result_payload_json() {
  printf '%s' "${LAST_TOOL_RAW}" | jq -c '
    if ._harness_error? then
      empty
    else
      try (.result.content[0].text | fromjson) catch empty
    end
  '
}

tool_result_text() {
  printf '%s' "${LAST_TOOL_RAW}" | extract_text
}

tool_error_text() {
  if [[ -n "${LAST_TOOL_ERROR}" ]]; then
    printf '%s' "${LAST_TOOL_ERROR}"
  else
    printf '%s' "${LAST_TOOL_RAW}" | extract_error
  fi
}
