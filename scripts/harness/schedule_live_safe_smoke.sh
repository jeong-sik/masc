#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

: "${PORT:=8935}"
: "${BASE_URL:=http://127.0.0.1:${PORT}}"
BASE_URL="${BASE_URL%/}"
: "${DASHBOARD_URL:=${BASE_URL}}"
DASHBOARD_URL="${DASHBOARD_URL%/}"
: "${MCP_URL:=${BASE_URL}/mcp}"
: "${CURL_TIMEOUT_SEC:=25}"
: "${HTTP_TIMEOUT_SEC:=${CURL_TIMEOUT_SEC}}"
: "${CURL_RETRY_COUNT:=4}"
: "${CURL_RETRY_DELAY_SEC:=1}"
: "${INIT_TIMEOUT_SEC:=30}"
: "${POLL_TIMEOUT_SEC:=150}"
: "${POLL_INTERVAL_SEC:=2}"
: "${DUE_DELAY_SEC:=8}"
: "${RUN_ID:=$(date -u +%Y%m%dT%H%M%SZ)-$$}"
: "${SCHEDULE_ID:=schedule-smoke-${RUN_ID}}"
: "${SMOKE_HEARTH:=scheduler-smoke}"
: "${SMOKE_AUTHOR:=schedule-live-safe-smoke}"
: "${SMOKE_TITLE:=Schedule smoke ${RUN_ID}}"
: "${SMOKE_CONTENT:=Live-safe scheduler smoke ${RUN_ID}: create -> approve -> due -> dispatch -> dashboard proof.}"
: "${SMOKE_TTL_HOURS:=1}"
: "${SMOKE_OPERATOR_REQUESTER:=schedule-smoke-requester}"
: "${SMOKE_OPERATOR_SCHEDULER:=schedule-smoke-scheduler}"
: "${MCP_CLIENT_NAME:=schedule-live-safe-smoke}"
: "${ALLOW_DASHBOARD_DEV_TOKEN:=0}"
: "${ALLOW_DIVERGED_RUNTIME:=0}"
: "${REQUIRE_HARNESS_SOURCE_MATCH:=0}"
: "${PREFLIGHT_ONLY:=0}"
: "${CLEANUP_ON_FAILURE:=1}"
: "${OTEL_METRICS_URL:=}"
: "${PROOF_OUT:=}"

# shellcheck source=scripts/harness/lib/mcp_jsonrpc.sh
source "${REPO_ROOT}/scripts/harness/lib/mcp_jsonrpc.sh"

CREATED_SCHEDULE_ID=""
SCHEDULE_SUCCEEDED=0
LOCAL_SOURCE_COMMIT=""
PREFLIGHT_HEALTH_JSON="{}"
PREFLIGHT_TOOLS_JSON="{}"
RUNTIME_RESOLUTION_JSON="{}"
SCHEDULE_RUNNER_PREFLIGHT_JSON="{}"
HEALTH_PREFLIGHT_SUMMARY_JSON="{}"
TOOLS_LIST_JSON="{}"
REQUIRED_TOOL_SURFACE_JSON="{}"
DASHBOARD_REQUIRED_TOOL_SURFACE_JSON="{}"
REQUIRED_PUBLIC_SCHEDULE_TOOLS_JSON="[]"
SCHEDULE_TOOL_CONTRACT_PROBE_JSON="{}"
FAILURE_STAGE="startup"

log() {
  printf '[schedule-smoke] %s\n' "$*" >&2
}

write_proof_json() {
  local payload="$1"
  if [[ -z "$PROOF_OUT" ]]; then
    return 0
  fi
  mkdir -p "$(dirname "$PROOF_OUT")"
  printf '%s\n' "$payload" >"$PROOF_OUT"
  log "proof written to ${PROOF_OUT}"
}

write_failure_proof() {
  local reason="$1"
  if [[ -z "$PROOF_OUT" ]] || ! command -v jq >/dev/null; then
    return 0
  fi
  local payload
  payload="$(
    jq -cn \
      --arg status "fail" \
      --arg reason "$reason" \
      --arg run_id "$RUN_ID" \
      --arg schedule_id "${CREATED_SCHEDULE_ID:-$SCHEDULE_ID}" \
      --arg dashboard_url "$DASHBOARD_URL" \
      --arg mcp_url "$MCP_URL" \
      --arg local_source_commit "$LOCAL_SOURCE_COMMIT" \
      --arg failure_stage "$FAILURE_STAGE" \
      --arg allow_diverged_runtime "$ALLOW_DIVERGED_RUNTIME" \
      --arg require_harness_source_match "$REQUIRE_HARNESS_SOURCE_MATCH" \
      --arg preflight_only "$PREFLIGHT_ONLY" \
      --argjson runtime_resolution "$RUNTIME_RESOLUTION_JSON" \
      --argjson schedule_runner_preflight "$SCHEDULE_RUNNER_PREFLIGHT_JSON" \
      --argjson health_preflight "$HEALTH_PREFLIGHT_SUMMARY_JSON" \
      --argjson schedule_tool_contract_probe "$SCHEDULE_TOOL_CONTRACT_PROBE_JSON" \
      --argjson required_tool_surface "$REQUIRED_TOOL_SURFACE_JSON" \
      --argjson dashboard_required_tool_surface "$DASHBOARD_REQUIRED_TOOL_SURFACE_JSON" \
      '{
        status:$status,
        reason:$reason,
        failure_stage:$failure_stage,
        run_id:$run_id,
        schedule_id:$schedule_id,
        dashboard_url:$dashboard_url,
        mcp_url:$mcp_url,
        source:{
          harness_repo_commit:$local_source_commit
        },
        runtime_identity_gate:{
          allow_diverged_runtime:($allow_diverged_runtime == "1"),
          require_harness_source_match:($require_harness_source_match == "1"),
          preflight_only:($preflight_only == "1"),
          runtime_resolution:$runtime_resolution,
          health:$health_preflight
        },
        schedule_runner_preflight:$schedule_runner_preflight,
        schedule_tool_contract_probe:$schedule_tool_contract_probe,
        required_tool_surface:$required_tool_surface,
        dashboard_required_tool_surface:$dashboard_required_tool_surface
      }'
  )" && write_proof_json "$payload"
}

fail() {
  local message="$*"
  write_failure_proof "$message" || true
  printf 'FAIL: %s\n' "$message" >&2
  exit 1
}

truthy() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

read_required_public_schedule_tools_json() {
  local probe status
  probe="$(
    printf '%s' "$PREFLIGHT_TOOLS_JSON" \
      | jq -c '
        def base($contract):
          {
            schema: "masc.schedule_tool_contract.probe.v1",
            source: "dashboard_tools.schedule_tool_contract",
            contract: $contract
          };

        (.schedule_tool_contract // null) as $contract
        | if $contract == null then
            base(null) + {
              status: "error",
              error_kind: "missing_contract",
              message: "schedule_tool_contract is missing",
              public_schedule_tools: []
            }
          elif (($contract | type) != "object") then
            base($contract) + {
              status: "error",
              error_kind: "contract_not_object",
              message: "schedule_tool_contract must be an object",
              actual_type: ($contract | type),
              public_schedule_tools: []
            }
          else
            ($contract.public_schedule_tools // null) as $tools
            | if $tools == null then
                base($contract) + {
                  status: "error",
                  error_kind: "public_schedule_tools_missing",
                  message: "schedule_tool_contract.public_schedule_tools is missing",
                  public_schedule_tools: []
                }
              elif (($tools | type) != "array") then
                base($contract) + {
                  status: "error",
                  error_kind: "public_schedule_tools_not_array",
                  message: "schedule_tool_contract.public_schedule_tools must be an array",
                  actual_type: ($tools | type),
                  public_schedule_tools: []
                }
              elif (($tools | length) == 0) then
                base($contract) + {
                  status: "error",
                  error_kind: "public_schedule_tools_empty",
                  message: "schedule_tool_contract.public_schedule_tools must not be empty",
                  public_schedule_tools: []
                }
              elif (all($tools[]; (type == "string") and (length > 0)) | not) then
                base($contract) + {
                  status: "error",
                  error_kind: "public_schedule_tools_invalid_entry",
                  message: "schedule_tool_contract.public_schedule_tools entries must be non-empty strings",
                  public_schedule_tools: []
                }
              elif (($tools | unique | length) != ($tools | length)) then
                base($contract) + {
                  status: "error",
                  error_kind: "public_schedule_tools_duplicate",
                  message: "schedule_tool_contract.public_schedule_tools must not contain duplicates",
                  public_schedule_tools: []
                }
              else
                base($contract) + {
                  status: "ok",
                  error_kind: null,
                  message: null,
                  public_schedule_tools: $tools
                }
              end
          end
      '
  )" || return 1
  SCHEDULE_TOOL_CONTRACT_PROBE_JSON="$probe"
  status="$(printf '%s' "$probe" | jq -r '.status')"
  if [[ "$status" != "ok" ]]; then
    printf '%s' "$probe" | jq -r '.message' >&2
    return 1
  fi
  REQUIRED_PUBLIC_SCHEDULE_TOOLS_JSON="$(printf '%s' "$probe" | jq -c '.public_schedule_tools')"
}

first_nonempty() {
  local value
  for value in "$@"; do
    if [[ -n "$value" ]]; then
      printf '%s' "$value"
      return 0
    fi
  done
  return 1
}

json_urlencode() {
  jq -nr --arg value "$1" '$value | @uri'
}

admin_token_from_env() {
  first_nonempty \
    "${DASHBOARD_TOKEN:-}" \
    "${MASC_DASHBOARD_TOKEN:-}" \
    "${MASC_ADMIN_TOKEN:-}" \
    "${MCP_TOKEN:-}" \
    "${MCP_AUTH_TOKEN:-}" \
    "${MASC_MCP_BEARER_TOKEN:-}" || true
}

mcp_token_from_env() {
  first_nonempty \
    "${MCP_TOKEN:-}" \
    "${MCP_AUTH_TOKEN:-}" \
    "${MASC_MCP_BEARER_TOKEN:-}" \
    "${MASC_ADMIN_TOKEN:-}" \
    "${DASHBOARD_TOKEN:-}" \
    "${MASC_DASHBOARD_TOKEN:-}" || true
}

fetch_dashboard_dev_token() {
  local body
  if ! body="$(curl -fsS --max-time "$CURL_TIMEOUT_SEC" \
    "${DASHBOARD_URL}/api/v1/dashboard/dev-token")"; then
    return 1
  fi
  printf '%s' "$body" | jq -r '.token // empty'
}

resolve_tokens() {
  FAILURE_STAGE="token_resolution"
  local admin_token mcp_token
  admin_token="$(admin_token_from_env)"
  if [[ -z "$admin_token" ]] && truthy "$ALLOW_DASHBOARD_DEV_TOKEN"; then
    log "no admin token in env; requesting loopback dashboard dev-token"
    admin_token="$(fetch_dashboard_dev_token)" || true
  fi
  if [[ -z "$admin_token" ]]; then
    fail "bearer token required before MCP tools/list. Set DASHBOARD_TOKEN, MASC_DASHBOARD_TOKEN, MASC_ADMIN_TOKEN, MCP_TOKEN, or ALLOW_DASHBOARD_DEV_TOKEN=1 for loopback dev runtime. A CanAdmin token is required for the full side-effecting smoke."
  fi

  mcp_token="$(mcp_token_from_env)"
  if [[ -z "$mcp_token" ]]; then
    mcp_token="$admin_token"
  fi

  DASHBOARD_ADMIN_TOKEN="$admin_token"
  MCP_TOKEN="$mcp_token"
  export MCP_TOKEN DASHBOARD_ADMIN_TOKEN
}

init_mcp_session() {
  FAILURE_STAGE="mcp_initialize"
  if [[ -n "${MCP_SESSION_ID:-}" ]]; then
    export MCP_SESSION_ID
    return 0
  fi

  local headers_file body_file auth_header_file init_body deadline
  headers_file="$(mcp_mktemp_file "schedule-smoke-init" ".headers")"
  body_file="$(mcp_mktemp_file "schedule-smoke-init" ".body")"
  auth_header_file="$(_mcp_auth_header_file "$MCP_TOKEN")"
  init_body="$(
    jq -cn --arg client_name "$MCP_CLIENT_NAME" \
      '{jsonrpc:"2.0", id:1, method:"initialize", params:{protocolVersion:"2025-11-25", clientInfo:{name:$client_name, version:"1.0"}, capabilities:{}}}'
  )"

  deadline=$(( $(date +%s) + INIT_TIMEOUT_SEC ))
  while [[ "$(date +%s)" -lt "$deadline" ]]; do
    : >"$headers_file"
    : >"$body_file"
    if curl -sS --max-time "$CURL_TIMEOUT_SEC" \
      -D "$headers_file" \
      -o "$body_file" \
      -X POST "$MCP_URL" \
      -H 'Content-Type: application/json' \
      -H 'Accept: application/json, text/event-stream' \
      -H "@${auth_header_file}" \
      --data-binary "$init_body" >/dev/null; then
      MCP_SESSION_ID="$(
        awk 'tolower($0) ~ /^mcp-session-id:/ { sub(/^[^:]+:[[:space:]]*/, "", $0); sub(/\r$/, "", $0); print $0; exit }' "$headers_file"
      )"
      MCP_PROTOCOL_VERSION="$(
        awk 'tolower($0) ~ /^mcp-protocol-version:/ { sub(/^[^:]+:[[:space:]]*/, "", $0); sub(/\r$/, "", $0); print $0; exit }' "$headers_file"
      )"
      if [[ -n "$MCP_SESSION_ID" ]]; then
        export MCP_SESSION_ID MCP_PROTOCOL_VERSION
        break
      fi
      if ! jq -e '.error.code == -32002' "$body_file" >/dev/null 2>&1; then
        break
      fi
    fi
    sleep 1
  done

  if [[ -z "${MCP_SESSION_ID:-}" ]]; then
    log "initialize response body:"
    cat "$body_file" >&2 || true
    rm -f "$headers_file" "$body_file" "$auth_header_file"
    fail "MCP initialize did not return Mcp-Session-Id before ${INIT_TIMEOUT_SEC}s"
  fi

  local notify_body notify_code
  FAILURE_STAGE="mcp_initialized_notification"
  notify_body="$(mcp_mktemp_file "schedule-smoke-initialized" ".body")"
  if ! notify_code="$(
    curl -sS --max-time "$CURL_TIMEOUT_SEC" \
      -o "$notify_body" \
      -w '%{http_code}' \
      -X POST "$MCP_URL" \
      -H 'Content-Type: application/json' \
      -H 'Accept: application/json, text/event-stream' \
      -H "mcp-session-id: ${MCP_SESSION_ID}" \
      -H "@${auth_header_file}" \
      --data-binary '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}'
  )"; then
    cat "$notify_body" >&2 || true
    rm -f "$headers_file" "$body_file" "$auth_header_file" "$notify_body"
    fail "notifications/initialized transport failed"
  fi
  case "$notify_code" in
    200|202|204) ;;
    *)
      cat "$notify_body" >&2 || true
      rm -f "$headers_file" "$body_file" "$auth_header_file" "$notify_body"
      fail "notifications/initialized returned HTTP ${notify_code}"
      ;;
  esac

  rm -f "$headers_file" "$body_file" "$auth_header_file" "$notify_body"
}

call_tool_result() {
  local id="$1"
  local tool_name="$2"
  local args_json="$3"
  local payload
  payload="$(mcp_call_tool "$id" "$tool_name" "$args_json" "$MCP_SESSION_ID" "$MCP_TOKEN" "$MCP_URL")"
  if ! mcp_require_tool_ok "$payload" "$tool_name"; then
    fail "${tool_name} tool call failed"
  fi
  printf '%s' "$payload" | mcp_extract_result
}

dashboard_post_json() {
  local path="$1"
  local body_json="$2"
  local auth_header_file body_file resp_file code
  auth_header_file="$(_mcp_auth_header_file "$DASHBOARD_ADMIN_TOKEN")"
  body_file="$(mcp_mktemp_file "schedule-smoke-dashboard-body" ".json")"
  resp_file="$(mcp_mktemp_file "schedule-smoke-dashboard-resp" ".json")"
  printf '%s' "$body_json" >"$body_file"

  if ! code="$(
    curl -sS --max-time "$CURL_TIMEOUT_SEC" \
      -o "$resp_file" \
      -w '%{http_code}' \
      -X POST "${DASHBOARD_URL}${path}" \
      -H 'Content-Type: application/json' \
      -H "@${auth_header_file}" \
      --data-binary "@${body_file}"
  )"; then
    log "dashboard POST transport failed for ${path}"
    cat "$resp_file" >&2 || true
    rm -f "$auth_header_file" "$body_file" "$resp_file"
    return 1
  fi
  if [[ "$code" != "200" ]]; then
    log "dashboard response body:"
    cat "$resp_file" >&2 || true
    rm -f "$auth_header_file" "$body_file" "$resp_file"
    return 1
  fi

  cat "$resp_file"
  rm -f "$auth_header_file" "$body_file" "$resp_file"
}

cancel_schedule_best_effort() {
  local schedule_id="$1"
  local body
  body="$(
    jq -cn --arg schedule_id "$schedule_id" \
      '{schedule_id:$schedule_id, decision:"cancel", reason:"schedule_live_safe_smoke cleanup after failed proof"}'
  )"
  if dashboard_post_json "/api/v1/dashboard/schedule/resolve" "$body" >/dev/null; then
    log "cleanup cancelled schedule ${schedule_id}"
  else
    log "cleanup could not cancel schedule ${schedule_id}; inspect dashboard schedule queue"
  fi
}

cleanup_on_exit() {
  local code=$?
  if [[ "$code" -ne 0 && -n "$CREATED_SCHEDULE_ID" && "$SCHEDULE_SUCCEEDED" -ne 1 ]] \
    && truthy "$CLEANUP_ON_FAILURE"; then
    cancel_schedule_best_effort "$CREATED_SCHEDULE_ID" || true
  fi
}
trap cleanup_on_exit EXIT

health_json() {
  curl -fsS --max-time "$CURL_TIMEOUT_SEC" "${DASHBOARD_URL}/health?full=1"
}

dashboard_tools_json() {
  curl -fsS --max-time "$CURL_TIMEOUT_SEC" "${DASHBOARD_URL}/api/v1/dashboard/tools"
}

required_schedule_tools_json() {
  printf '%s' "$TOOLS_LIST_JSON" \
    | jq -c --argjson required "$REQUIRED_PUBLIC_SCHEDULE_TOOLS_JSON" '
      | (.result.tools // []) as $tools
      | [ $required[] as $name
          | {
              name:$name,
              present:([ $tools[]? | select(.name == $name) ] | length > 0)
            }
        ] as $presence
      | {
          required:$required,
          tools:$presence,
          missing:[ $presence[] | select(.present | not) | .name ]
        }'
}

required_dashboard_schedule_tools_json() {
  printf '%s' "$PREFLIGHT_TOOLS_JSON" \
    | jq -c --argjson required "$REQUIRED_PUBLIC_SCHEDULE_TOOLS_JSON" '
      | (.tool_inventory.tools // []) as $tools
      | [ $required[] as $name
          | (first($tools[]? | select(.name == $name)) // null) as $tool
          | {
              name:$name,
              present:($tool != null),
              visibility:($tool.visibility // null),
              direct_call_allowed:($tool.direct_call_allowed // null),
              surfaces:($tool.surfaces // []),
              registered_schema:($tool.registered_schema // null),
              dispatch_registered:($tool.dispatch_registered // null)
            }
        ] as $presence
      | {
          required:$required,
          tools:$presence,
          missing:[ $presence[] | select(.present | not) | .name ],
          no_public_surface:[ $presence[] | select(.present and ((.surfaces // []) | index("public_mcp") | not)) | .name ]
        }'
}

capture_preflight_identity() {
  LOCAL_SOURCE_COMMIT="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || true)"
  FAILURE_STAGE="health_probe"
  PREFLIGHT_HEALTH_JSON="$(health_json)" \
    || fail "health probe failed at ${DASHBOARD_URL}/health?full=1"
  FAILURE_STAGE="dashboard_tools_probe"
  PREFLIGHT_TOOLS_JSON="$(dashboard_tools_json)" \
    || fail "dashboard tools probe failed at ${DASHBOARD_URL}/api/v1/dashboard/tools"
  FAILURE_STAGE="runtime_identity_capture"
  RUNTIME_RESOLUTION_JSON="$(
    printf '%s' "$PREFLIGHT_TOOLS_JSON" | jq -c '.runtime_resolution // {}'
  )"
  SCHEDULE_RUNNER_PREFLIGHT_JSON="$(
    printf '%s' "$PREFLIGHT_HEALTH_JSON" | jq -c '.schedule_runner // {}'
  )"
  HEALTH_PREFLIGHT_SUMMARY_JSON="$(
    printf '%s' "$PREFLIGHT_HEALTH_JSON" \
      | jq -c '{build:(.build // null), runtime_truth:(.runtime_truth // null), overall_status:(.overall_status // null), operator_action_required:(.operator_action_required // null)}'
  )"
}

validate_runtime_identity_gate() {
  FAILURE_STAGE="runtime_identity_gate"
  if truthy "$ALLOW_DIVERGED_RUNTIME"; then
    log "runtime identity gate bypassed by ALLOW_DIVERGED_RUNTIME=1"
    return 0
  fi

  local deployment_status source_mismatch server_workspace_mismatch runtime_commit
  local runtime_status local_match
  deployment_status="$(
    printf '%s' "$RUNTIME_RESOLUTION_JSON" \
      | jq -r '.deployment_state.status // "missing"'
  )"
  runtime_status="$(
    printf '%s' "$RUNTIME_RESOLUTION_JSON" | jq -r '.status // "missing"'
  )"
  source_mismatch="$(
    printf '%s' "$RUNTIME_RESOLUTION_JSON" | jq -r '.source_mismatch // false'
  )"
  server_workspace_mismatch="$(
    printf '%s' "$RUNTIME_RESOLUTION_JSON" \
      | jq -r '.server_workspace_mismatch // false'
  )"
  runtime_commit="$(
    printf '%s' "$RUNTIME_RESOLUTION_JSON" \
      | jq -r '.runtime_binary_git_commit // empty'
  )"

  [[ "$deployment_status" == "current" ]] \
    || fail "runtime deployment_state.status=${deployment_status}; expected current. Set ALLOW_DIVERGED_RUNTIME=1 only when intentionally collecting non-current runtime evidence."
  [[ "$source_mismatch" == "false" ]] \
    || fail "runtime_resolution.source_mismatch=true; rebuild/restart before collecting success proof"
  [[ "$server_workspace_mismatch" == "false" ]] \
    || fail "runtime_resolution.server_workspace_mismatch=true; verify runtime worktree before collecting success proof"
  [[ -n "$runtime_commit" ]] \
    || fail "runtime_binary_git_commit missing; binary identity is unproven"

  if truthy "$REQUIRE_HARNESS_SOURCE_MATCH"; then
    [[ -n "$LOCAL_SOURCE_COMMIT" ]] \
      || fail "could not resolve harness repo commit for REQUIRE_HARNESS_SOURCE_MATCH=1"
    local_match="$(
      jq -rn \
        --arg runtime "$runtime_commit" \
        --arg local "$LOCAL_SOURCE_COMMIT" \
        '$runtime == $local'
    )"
    [[ "$local_match" == "true" ]] \
      || fail "runtime_binary_git_commit=${runtime_commit} differs from harness repo HEAD=${LOCAL_SOURCE_COMMIT}"
  fi

  log "runtime identity gate passed deployment=${deployment_status} runtime=${runtime_status} binary=${runtime_commit}"
}

validate_schedule_runner_preflight_gate() {
  FAILURE_STAGE="schedule_runner_preflight"
  if ! printf '%s' "$SCHEDULE_RUNNER_PREFLIGHT_JSON" \
    | jq -e '
      type == "object"
      and .schema == "masc.schedule.runner_status.v1"
      and (.status == "ok" or .status == "running")
      and (.tick_in_flight | type) == "boolean"
      and (.tick_count | type) == "number"
      and (.success_count | type) == "number"
      and (.failure_count | type) == "number"
      and (.crash_count | type) == "number"
    ' >/dev/null; then
    printf '%s\n' "$SCHEDULE_RUNNER_PREFLIGHT_JSON" | jq . >&2 \
      || printf '%s\n' "$SCHEDULE_RUNNER_PREFLIGHT_JSON" >&2
    fail "schedule_runner_preflight is missing, stale, degraded, or malformed"
  fi
  local status tick_count
  status="$(printf '%s' "$SCHEDULE_RUNNER_PREFLIGHT_JSON" | jq -r '.status')"
  tick_count="$(printf '%s' "$SCHEDULE_RUNNER_PREFLIGHT_JSON" | jq -r '.tick_count')"
  log "schedule runner preflight passed status=${status} tick_count=${tick_count}"
}

preflight() {
  FAILURE_STAGE="startup_checks"
  command -v curl >/dev/null || fail "curl is required"
  command -v jq >/dev/null || fail "jq is required"
  resolve_tokens
  log "target dashboard=${DASHBOARD_URL} mcp=${MCP_URL}"
  capture_preflight_identity
  FAILURE_STAGE="schedule_tool_contract"
  read_required_public_schedule_tools_json \
    || fail "dashboard schedule tool contract missing or invalid"
  validate_runtime_identity_gate
  validate_schedule_runner_preflight_gate
  init_mcp_session

  local tools
  FAILURE_STAGE="mcp_tools_list"
  tools="$(mcp_jsonrpc_call 2 "tools/list" '{}' "$MCP_SESSION_ID" "$MCP_TOKEN" "$MCP_URL")"
  TOOLS_LIST_JSON="$tools"
  mcp_require_jsonrpc_ok "$tools" "tools/list" || fail "tools/list JSON-RPC validation failed"
  FAILURE_STAGE="mcp_tool_surface"
  REQUIRED_TOOL_SURFACE_JSON="$(required_schedule_tools_json)"
  FAILURE_STAGE="dashboard_tool_surface"
  DASHBOARD_REQUIRED_TOOL_SURFACE_JSON="$(required_dashboard_schedule_tools_json)"
  local missing
  missing="$(printf '%s' "$REQUIRED_TOOL_SURFACE_JSON" | jq -r '.missing | join(", ")')"
  if [[ -n "$missing" ]]; then
    fail "tools/list did not expose required schedule tools: ${missing}"
  fi
  local dashboard_missing dashboard_no_public
  dashboard_missing="$(
    printf '%s' "$DASHBOARD_REQUIRED_TOOL_SURFACE_JSON" | jq -r '.missing | join(", ")'
  )"
  if [[ -n "$dashboard_missing" ]]; then
    fail "dashboard tool inventory did not expose required schedule tools: ${dashboard_missing}"
  fi
  dashboard_no_public="$(
    printf '%s' "$DASHBOARD_REQUIRED_TOOL_SURFACE_JSON" \
      | jq -r '.no_public_surface | join(", ")'
  )"
  if [[ -n "$dashboard_no_public" ]]; then
    fail "dashboard tool inventory missing public_mcp surface for schedule tools: ${dashboard_no_public}"
  fi
}

write_preflight_success_proof() {
  FAILURE_STAGE="proof_write"
  local proof
  proof="$(
    jq -cn \
      --arg status "preflight_pass" \
      --arg run_id "$RUN_ID" \
      --arg dashboard_url "$DASHBOARD_URL" \
      --arg mcp_url "$MCP_URL" \
      --arg local_source_commit "$LOCAL_SOURCE_COMMIT" \
      --arg allow_diverged_runtime "$ALLOW_DIVERGED_RUNTIME" \
      --arg require_harness_source_match "$REQUIRE_HARNESS_SOURCE_MATCH" \
      --argjson runtime_resolution "$RUNTIME_RESOLUTION_JSON" \
      --argjson schedule_runner_preflight "$SCHEDULE_RUNNER_PREFLIGHT_JSON" \
      --argjson health_preflight "$HEALTH_PREFLIGHT_SUMMARY_JSON" \
      --argjson schedule_tool_contract_probe "$SCHEDULE_TOOL_CONTRACT_PROBE_JSON" \
      --argjson required_tool_surface "$REQUIRED_TOOL_SURFACE_JSON" \
      --argjson dashboard_required_tool_surface "$DASHBOARD_REQUIRED_TOOL_SURFACE_JSON" \
      '{
        status:$status,
        run_id:$run_id,
        dashboard_url:$dashboard_url,
        mcp_url:$mcp_url,
        source:{
          harness_repo_commit:$local_source_commit
        },
        runtime_identity_gate:{
          allow_diverged_runtime:($allow_diverged_runtime == "1"),
          require_harness_source_match:($require_harness_source_match == "1"),
          preflight_only:true,
          runtime_resolution:$runtime_resolution,
          health:$health_preflight
        },
        schedule_runner_preflight:$schedule_runner_preflight,
        schedule_tool_contract_probe:$schedule_tool_contract_probe,
        required_tool_surface:$required_tool_surface,
        dashboard_required_tool_surface:$dashboard_required_tool_surface
      }'
  )"
  write_proof_json "$proof"
  printf '%s\n' "$proof"
}

create_schedule() {
  FAILURE_STAGE="mcp_schedule_create"
  local now due_at args result requires_grant status
  now="$(date +%s)"
  due_at=$(( now + DUE_DELAY_SEC ))
  args="$(
    jq -cn \
      --arg schedule_id "$SCHEDULE_ID" \
      --argjson due_at "$due_at" \
      --arg content "$SMOKE_CONTENT" \
      --arg title "$SMOKE_TITLE" \
      --arg hearth "$SMOKE_HEARTH" \
      --arg author "$SMOKE_AUTHOR" \
      --argjson ttl_hours "$SMOKE_TTL_HOURS" \
      --arg requested_by "$SMOKE_OPERATOR_REQUESTER" \
      --arg scheduled_by "$SMOKE_OPERATOR_SCHEDULER" \
      --arg run_id "$RUN_ID" \
      '{
        schedule_id:$schedule_id,
        due_at_unix:$due_at,
        risk_class:"workspace_write",
        source:"operator_request",
        recurrence_kind:"one_shot",
        requested_by_id:$requested_by,
        requested_by_kind:"human_operator",
        scheduled_by_id:$scheduled_by,
        scheduled_by_kind:"automated_actor",
        board_content:$content,
        board_title:$title,
        board_hearth:$hearth,
        board_author:$author,
        board_ttl_hours:$ttl_hours,
        board_meta:{smoke_run_id:$run_id, smoke:"schedule_live_safe_smoke"}
      }'
  )"

  result="$(call_tool_result 1001 "masc_schedule_create" "$args")"
  CREATED_SCHEDULE_ID="$(printf '%s' "$result" | jq -r '.schedule_id // empty')"
  [[ -n "$CREATED_SCHEDULE_ID" ]] || fail "masc_schedule_create response missing schedule_id"
  [[ "$CREATED_SCHEDULE_ID" == "$SCHEDULE_ID" ]] \
    || fail "created schedule_id mismatch: got ${CREATED_SCHEDULE_ID}, expected ${SCHEDULE_ID}"

  requires_grant="$(printf '%s' "$result" | jq -r '.requires_separate_human_grant // false')"
  status="$(printf '%s' "$result" | jq -r '.status // empty')"
  [[ "$requires_grant" == "true" ]] \
    || fail "workspace_write schedule did not require a separate human grant"
  [[ "$status" == "pending_approval" ]] \
    || fail "created schedule status was ${status}, expected pending_approval"

  log "created pending schedule ${CREATED_SCHEDULE_ID} due_at=${due_at}"
}

approve_schedule() {
  FAILURE_STAGE="dashboard_approval"
  local body response status
  body="$(
    jq -cn --arg schedule_id "$CREATED_SCHEDULE_ID" \
      '{schedule_id:$schedule_id, decision:"approve"}'
  )"
  response="$(dashboard_post_json "/api/v1/dashboard/schedule/resolve" "$body")" \
    || fail "dashboard approval POST failed"
  if ! printf '%s' "$response" | jq -e '.ok == true and .decision == "approve"' >/dev/null; then
    printf '%s\n' "$response" | jq . >&2 || printf '%s\n' "$response" >&2
    fail "dashboard approval response did not confirm approve"
  fi
  status="$(printf '%s' "$response" | jq -r '.schedule.status // empty')"
  case "$status" in
    scheduled|due) log "approved schedule ${CREATED_SCHEDULE_ID} status=${status}" ;;
    *) fail "approved schedule status was ${status}, expected scheduled or due" ;;
  esac
}

wait_schedule_success() {
  FAILURE_STAGE="schedule_poll"
  local deadline args result status last_status last_error post_id
  args="$(jq -cn --arg schedule_id "$CREATED_SCHEDULE_ID" '{schedule_id:$schedule_id}')"
  deadline=$(( $(date +%s) + POLL_TIMEOUT_SEC ))
  while [[ "$(date +%s)" -lt "$deadline" ]]; do
    result="$(call_tool_result 1101 "masc_schedule_get" "$args")"
    status="$(printf '%s' "$result" | jq -r '.status // empty')"
    last_status="$(printf '%s' "$result" | jq -r '.last_execution.status // empty')"
    last_error="$(printf '%s' "$result" | jq -r '.last_execution.error // empty')"
    post_id="$(printf '%s' "$result" | jq -r '.last_execution.detail.post_id // empty')"

    if [[ "$status" == "succeeded" && "$last_status" == "succeeded" && -n "$post_id" ]]; then
      SCHEDULE_SUCCEEDED=1
      printf '%s' "$result"
      return 0
    fi
    case "$status:$last_status" in
      failed:*|*:failed|rejected:*|cancelled:*|expired:*)
        printf '%s\n' "$result" | jq . >&2 || printf '%s\n' "$result" >&2
        fail "schedule reached terminal non-success state status=${status} last_execution=${last_status} error=${last_error}"
        ;;
    esac
    sleep "$POLL_INTERVAL_SEC"
  done
  fail "schedule ${CREATED_SCHEDULE_ID} did not dispatch successfully within ${POLL_TIMEOUT_SEC}s"
}

wait_dashboard_projection() {
  FAILURE_STAGE="dashboard_schedule_projection"
  local post_id="$1"
  local deadline body row
  deadline=$(( $(date +%s) + POLL_TIMEOUT_SEC ))
  while [[ "$(date +%s)" -lt "$deadline" ]]; do
    if body="$(dashboard_tools_json)"; then
      row="$(
        printf '%s' "$body" \
        | jq -c --arg schedule_id "$CREATED_SCHEDULE_ID" --arg post_id "$post_id" \
            'first(.scheduled_automation.requests[]? | select(.schedule_id == $schedule_id)) // empty'
      )"
      if [[ -n "$row" ]] \
        && printf '%s' "$row" \
          | jq -e --arg post_id "$post_id" \
              '.status == "succeeded"
               and .last_execution.status == "succeeded"
               and .last_execution.detail.post_id == $post_id' >/dev/null; then
        printf '%s' "$row"
        return 0
      fi
    fi
    sleep "$POLL_INTERVAL_SEC"
  done
  fail "dashboard tools projection did not show succeeded schedule ${CREATED_SCHEDULE_ID} with post_id ${post_id}"
}

wait_board_post() {
  FAILURE_STAGE="dashboard_board_projection"
  local post_id="$1"
  local hearth_query deadline body row
  hearth_query="$(json_urlencode "$SMOKE_HEARTH")"
  deadline=$(( $(date +%s) + POLL_TIMEOUT_SEC ))
  while [[ "$(date +%s)" -lt "$deadline" ]]; do
    if body="$(curl -fsS --max-time "$CURL_TIMEOUT_SEC" \
      "${DASHBOARD_URL}/api/v1/dashboard/board?hearth=${hearth_query}&limit=150")"; then
      row="$(
        printf '%s' "$body" \
          | jq -c \
              --arg post_id "$post_id" \
              --arg hearth "$SMOKE_HEARTH" \
              --arg title "$SMOKE_TITLE" \
              --arg author "$SMOKE_AUTHOR" \
              --arg content "$SMOKE_CONTENT" \
              --arg run_id "$RUN_ID" '
              first(.posts[]? | select((.id // .post_id // "") == $post_id)) as $post
              | if $post == null then
                  empty
                elif ($post.hearth // null) != $hearth
                  or ($post.title // null) != $title
                  or ($post.author // null) != $author
                  or ($post.body // null) != $content
                  or ($post.content // null) != $content
                  or ($post.meta.smoke_run_id // null) != $run_id
                  or ($post.meta.smoke // null) != "schedule_live_safe_smoke" then
                  empty
                else
                  {
                    source:"dashboard_board_projection",
                    found:true,
                    post_id:($post.id // $post.post_id // ""),
                    hearth:($post.hearth // null),
                    title:($post.title // null),
                    author:($post.author // null),
                    body:($post.body // null),
                    content:($post.content // null),
                    meta_smoke_run_id:($post.meta.smoke_run_id // null),
                    meta_smoke:($post.meta.smoke // null)
                  }
                end
            '
      )"
      if [[ -n "$row" ]]; then
        printf '%s' "$row"
        return 0
      fi
    fi
    sleep "$POLL_INTERVAL_SEC"
  done
  fail "dashboard board projection did not show exact smoke post ${post_id} in hearth ${SMOKE_HEARTH}"
}

check_runner_status() {
  FAILURE_STAGE="runner_status"
  local body status
  body="$(health_json)"
  status="$(printf '%s' "$body" | jq -r '.schedule_runner.status // empty')"
  case "$status" in
    ok|running)
      printf '%s' "$body" \
        | jq -c '{status:.schedule_runner.status, tick_count:.schedule_runner.tick_count, success_count:.schedule_runner.success_count, last_counts:.schedule_runner.last_counts, otel:.otel.status}'
      ;;
    *)
      printf '%s\n' "$body" | jq '.schedule_runner' >&2 || printf '%s\n' "$body" >&2
      fail "schedule_runner health status is ${status}"
      ;;
  esac
}

check_optional_otel_metrics() {
  FAILURE_STAGE="otel_metrics"
  if [[ -z "$OTEL_METRICS_URL" ]]; then
    log "OTEL_METRICS_URL not set; raw Otel scrape proof skipped"
    return 0
  fi
  local body
  body="$(curl -fsS --max-time "$CURL_TIMEOUT_SEC" "$OTEL_METRICS_URL")" \
    || fail "failed to fetch OTEL_METRICS_URL=${OTEL_METRICS_URL}"
  if ! printf '%s' "$body" | grep -q 'masc_schedule_runner_dispatch_total'; then
    fail "OTEL_METRICS_URL did not expose masc_schedule_runner_dispatch_total"
  fi
  log "raw Otel scrape exposed masc_schedule_runner_dispatch_total"
}

main() {
  FAILURE_STAGE="preflight"
  preflight
  if truthy "$PREFLIGHT_ONLY"; then
    write_preflight_success_proof
    return 0
  fi

  create_schedule
  approve_schedule

  local schedule_json dashboard_row post_id board_projection runner_json
  schedule_json="$(wait_schedule_success)"
  post_id="$(printf '%s' "$schedule_json" | jq -r '.last_execution.detail.post_id')"
  dashboard_row="$(wait_dashboard_projection "$post_id")"
  board_projection="$(wait_board_post "$post_id")"
  runner_json="$(check_runner_status)"
  check_optional_otel_metrics

  local proof
  FAILURE_STAGE="proof_write"
  proof="$(
    jq -cn \
    --arg status "pass" \
    --arg run_id "$RUN_ID" \
    --arg schedule_id "$CREATED_SCHEDULE_ID" \
    --arg post_id "$post_id" \
    --arg dashboard_url "$DASHBOARD_URL" \
    --arg mcp_url "$MCP_URL" \
    --arg smoke_hearth "$SMOKE_HEARTH" \
    --arg smoke_title "$SMOKE_TITLE" \
    --arg smoke_author "$SMOKE_AUTHOR" \
    --arg smoke_content "$SMOKE_CONTENT" \
    --arg local_source_commit "$LOCAL_SOURCE_COMMIT" \
    --arg allow_diverged_runtime "$ALLOW_DIVERGED_RUNTIME" \
    --arg require_harness_source_match "$REQUIRE_HARNESS_SOURCE_MATCH" \
    --arg preflight_only "$PREFLIGHT_ONLY" \
    --argjson runtime_resolution "$RUNTIME_RESOLUTION_JSON" \
    --argjson schedule_runner_preflight "$SCHEDULE_RUNNER_PREFLIGHT_JSON" \
    --argjson health_preflight "$HEALTH_PREFLIGHT_SUMMARY_JSON" \
    --argjson schedule_tool_contract_probe "$SCHEDULE_TOOL_CONTRACT_PROBE_JSON" \
    --argjson required_tool_surface "$REQUIRED_TOOL_SURFACE_JSON" \
    --argjson dashboard_required_tool_surface "$DASHBOARD_REQUIRED_TOOL_SURFACE_JSON" \
    --argjson schedule "$schedule_json" \
    --argjson dashboard_projection "$dashboard_row" \
    --argjson board_projection "$board_projection" \
    --argjson runner "$runner_json" \
    '{
      status:$status,
      run_id:$run_id,
      schedule_id:$schedule_id,
      post_id:$post_id,
      dashboard_url:$dashboard_url,
      mcp_url:$mcp_url,
      board_expectation:{
        hearth:$smoke_hearth,
        title:$smoke_title,
        author:$smoke_author,
        content:$smoke_content,
        meta:{
          smoke_run_id:$run_id,
          smoke:"schedule_live_safe_smoke"
        }
      },
      source:{
        harness_repo_commit:$local_source_commit
      },
      runtime_identity_gate:{
        allow_diverged_runtime:($allow_diverged_runtime == "1"),
        require_harness_source_match:($require_harness_source_match == "1"),
        preflight_only:($preflight_only == "1"),
        runtime_resolution:$runtime_resolution,
        health:$health_preflight
      },
      schedule_runner_preflight:$schedule_runner_preflight,
      schedule_tool_contract_probe:$schedule_tool_contract_probe,
      required_tool_surface:$required_tool_surface,
      dashboard_required_tool_surface:$dashboard_required_tool_surface,
      schedule:$schedule,
      dashboard_projection:$dashboard_projection,
      board_projection:$board_projection,
      runner:$runner
    }'
  )"
  write_proof_json "$proof"
  printf '%s\n' "$proof"
}

main "$@"
