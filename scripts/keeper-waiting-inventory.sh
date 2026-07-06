#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

: "${PORT:=8935}"
: "${BASE_URL:=http://127.0.0.1:${PORT}}"
BASE_URL="${BASE_URL%/}"
: "${MCP_URL:=${BASE_URL}/mcp}"
: "${CURL_TIMEOUT_SEC:=25}"
: "${HTTP_TIMEOUT_SEC:=${CURL_TIMEOUT_SEC}}"
: "${CURL_RETRY_COUNT:=4}"
: "${CURL_RETRY_DELAY_SEC:=1}"
: "${MCP_CLIENT_NAME:=keeper-waiting-inventory-cli}"
: "${MCP_SESSION_ID:=}"
: "${COMPACT:=0}"
: "${PREFLIGHT_ONLY:=0}"
: "${REQUIRE_CURRENT_RUNTIME:=0}"
: "${ALLOW_DIVERGED_RUNTIME:=0}"
: "${PROOF_OUT:=}"

WAITING_TOOL_NAME="masc_keeper_waiting_inventory"
PREFLIGHT_REPORT_JSON=""
FAILURE_STAGE="argument_parse"

# shellcheck source=scripts/harness/lib/mcp_jsonrpc.sh
source "${REPO_ROOT}/scripts/harness/lib/mcp_jsonrpc.sh"

usage() {
  cat <<'USAGE'
Usage: scripts/keeper-waiting-inventory.sh [options]

Read the immutable keeper waiting inventory through the MCP tool
masc_keeper_waiting_inventory and print the tool result JSON.

Options:
  --base-url URL      Dashboard/MCP base URL. Default: http://127.0.0.1:8935.
  --mcp-url URL       MCP endpoint. Overrides --base-url-derived endpoint.
  --base-path PATH    Base path used only to load .masc/auth/codex-mcp-client.token.
  --preflight-only    Check runtime/tool/projection readiness and exit.
  --require-current-runtime
                      Run the same readiness gate before calling the MCP tool.
  --allow-diverged-runtime
                      Allow non-current runtime identity in the readiness gate.
  --proof-out PATH    Write preflight pass/fail JSON proof to PATH.
  --compact           Print compact JSON instead of pretty JSON.
  -h, --help          Show this help.

Environment:
  MCP_TOKEN, MCP_AUTH_TOKEN, MASC_ADMIN_TOKEN are accepted by the shared MCP
  helper. If none are set, the script tries BASE_PATH/.masc/auth/codex-mcp-client.token.
USAGE
}

fail() {
  write_failure_proof "$*" || true
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

truthy() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

write_proof_json() {
  local payload="$1"
  if [[ -z "$PROOF_OUT" ]]; then
    return 0
  fi
  mkdir -p "$(dirname "$PROOF_OUT")"
  printf '%s\n' "$payload" >"$PROOF_OUT"
}

write_failure_proof() {
  local reason="$1"
  if [[ -z "$PROOF_OUT" ]] || ! command -v jq >/dev/null 2>&1; then
    return 0
  fi
  local preflight_json="null"
  if [[ -n "$PREFLIGHT_REPORT_JSON" ]] \
    && printf '%s' "$PREFLIGHT_REPORT_JSON" | jq -e . >/dev/null 2>&1; then
    preflight_json="$PREFLIGHT_REPORT_JSON"
  fi
  local payload
  payload="$(
    jq -cn \
      --arg reason "$reason" \
	      --arg base_url "$BASE_URL" \
	      --arg mcp_url "$MCP_URL" \
	      --arg tool_name "$WAITING_TOOL_NAME" \
	      --arg failure_stage "$FAILURE_STAGE" \
	      --argjson preflight "$preflight_json" \
	      '{
	        schema:"masc.keeper_waiting_inventory_cli_proof.v1",
	        status:"fail",
	        reason:$reason,
	        failure_stage:$failure_stage,
	        dashboard_url:$base_url,
	        mcp_url:$mcp_url,
	        tool_name:$tool_name,
        preflight:$preflight
      }'
  )" && write_proof_json "$payload"
}

write_cli_success_proof() {
  local inventory_json="$1"
  if [[ -z "$PROOF_OUT" ]]; then
    return 0
  fi
  if [[ -z "$PREFLIGHT_REPORT_JSON" ]]; then
    fail "--proof-out success proof requires preflight evidence"
  fi
  local payload
  payload="$(
    jq -cn \
      --arg base_url "$BASE_URL" \
      --arg mcp_url "$MCP_URL" \
      --arg tool_name "$WAITING_TOOL_NAME" \
      --argjson preflight "$PREFLIGHT_REPORT_JSON" \
      --argjson inventory "$inventory_json" \
      '{
        schema:"masc.keeper_waiting_inventory_cli_proof.v1",
        status:"pass",
        ok:true,
        dashboard_url:$base_url,
        mcp_url:$mcp_url,
        tool_name:$tool_name,
        preflight:$preflight,
        mcp_result:$inventory
      }'
  )" || fail "could not build keeper waiting inventory success proof"
  write_proof_json "$payload"
}

base_path_default() {
  if [[ -n "${BASE_PATH:-}" ]]; then
    printf '%s\n' "$BASE_PATH"
  elif [[ -n "${MASC_BASE_PATH:-}" ]]; then
    printf '%s\n' "$MASC_BASE_PATH"
  else
    printf '%s\n' "$REPO_ROOT"
  fi
}

BASE_PATH="$(base_path_default)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-url)
      BASE_URL="${2%/}"
      MCP_URL="${BASE_URL}/mcp"
      shift 2
      ;;
    --mcp-url)
      MCP_URL="$2"
      shift 2
      ;;
    --base-path)
      BASE_PATH="$2"
      shift 2
      ;;
    --compact)
      COMPACT=1
      shift
      ;;
    --preflight-only)
      PREFLIGHT_ONLY=1
      REQUIRE_CURRENT_RUNTIME=1
      shift
      ;;
    --require-current-runtime)
      REQUIRE_CURRENT_RUNTIME=1
      shift
      ;;
    --allow-diverged-runtime)
      ALLOW_DIVERGED_RUNTIME=1
      shift
      ;;
    --proof-out)
      PROOF_OUT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

if truthy "$PREFLIGHT_ONLY"; then
  PREFLIGHT_ONLY=1
  REQUIRE_CURRENT_RUNTIME=1
else
  PREFLIGHT_ONLY=0
fi

if truthy "$REQUIRE_CURRENT_RUNTIME"; then
  REQUIRE_CURRENT_RUNTIME=1
else
  REQUIRE_CURRENT_RUNTIME=0
fi

if truthy "$ALLOW_DIVERGED_RUNTIME"; then
  ALLOW_DIVERGED_RUNTIME=1
else
  ALLOW_DIVERGED_RUNTIME=0
fi

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

load_mcp_token() {
  if [[ -n "${MCP_TOKEN:-}" || -n "${MCP_AUTH_TOKEN:-}" || -n "${MASC_ADMIN_TOKEN:-}" ]]; then
    return 0
  fi
  local token_file="${BASE_PATH%/}/.masc/auth/codex-mcp-client.token"
  if [[ -f "$token_file" ]]; then
    MCP_TOKEN="$(tr -d '\n' <"$token_file")"
    export MCP_TOKEN
  fi
}

dashboard_tools_json() {
  curl -fsS --max-time "$CURL_TIMEOUT_SEC" "${BASE_URL}/api/v1/dashboard/tools"
}

build_preflight_report() {
  local dashboard_json allow_diverged
  dashboard_json="$(dashboard_tools_json)" \
    || fail "dashboard tools probe failed at ${BASE_URL}/api/v1/dashboard/tools"
  allow_diverged="$ALLOW_DIVERGED_RUNTIME"
  PREFLIGHT_REPORT_JSON="$(
    printf '%s' "$dashboard_json" \
      | jq -ce \
          --arg dashboard_url "$BASE_URL" \
          --arg mcp_url "$MCP_URL" \
          --arg tool_name "$WAITING_TOOL_NAME" \
          --arg allow_diverged_runtime "$allow_diverged" \
          '
            def emit($condition; $message):
              if $condition then [] else [$message] end;

            def object_value($value):
              ($value | type) == "object";

            def nonempty_string($value):
              ($value | type) == "string" and ($value | length > 0);

            def string_array($value):
              ($value | type) == "array"
              and all($value[]; (type == "string") and (length > 0));

            def number_value($value):
              ($value | type) == "number";

            def array_value($value):
              ($value | type) == "array";

            def integer_value($value):
              number_value($value)
              and $value >= 0
              and $value == ($value | floor);

            def nullable_number($value):
              $value == null or number_value($value);

            def nullable_string($value):
              $value == null or (($value | type) == "string");

            def waiting_row_shape($row):
              object_value($row)
              and ($row | has("keeper_name"))
              and ($row.keeper_name == null or nonempty_string($row.keeper_name))
              and nonempty_string($row.source)
              and nonempty_string($row.waiting_on)
              and nonempty_string($row.wake_producer)
              and ($row | has("since"))
              and nullable_number($row.since)
              and ($row | has("since_iso"))
              and nullable_string($row.since_iso)
              and ($row | has("due_at"))
              and nullable_number($row.due_at)
              and ($row | has("due_at_iso"))
              and nullable_string($row.due_at_iso)
              and nonempty_string($row.next_action)
              and ($row | has("detail"));

            def keeper_shape($supported_states; $keeper):
              object_value($keeper)
              and nonempty_string($keeper.keeper_name)
              and nonempty_string($keeper.state)
              and array_value($supported_states)
              and (($supported_states | index($keeper.state)) != null)
              and array_value($keeper.waiting_on)
              and integer_value($keeper.waiting_count)
              and ($keeper.waiting_count == ($keeper.waiting_on | length))
              and object_value($keeper.sources)
              and ($keeper | has("since"))
              and nullable_number($keeper.since)
              and ($keeper | has("since_iso"))
              and nullable_string($keeper.since_iso)
              and ($keeper | has("due_at"))
              and nullable_number($keeper.due_at)
              and ($keeper | has("due_at_iso"))
              and nullable_string($keeper.due_at_iso)
              and ($keeper.next_action == null or nonempty_string($keeper.next_action))
              and all($keeper.waiting_on[]; waiting_row_shape(.));

            def keeper_row_total($keepers):
              if array_value($keepers) then
                ([$keepers[] | if array_value(.waiting_on) then (.waiting_on | length) else 0 end] | add // 0)
              else
                null
              end;

            def waiting_rows_shape($rows):
              if array_value($rows) then
                all($rows[]; waiting_row_shape(.))
              else
                false
              end;

            (.runtime_resolution // null) as $runtime
            | (.tool_inventory.tools // []) as $tools
            | (first($tools[]? | select(.name == $tool_name)) // null) as $tool
            | (.keeper_waiting_inventory // null) as $projection
            | (
                emit(object_value($runtime); "runtime_resolution must be an object")
                + if ($allow_diverged_runtime == "1") then
                    []
                  else
                    emit(($runtime.deployment_state.status == "current");
                         "runtime deployment_state.status must be current")
                    + emit(($runtime.source_mismatch == false);
                           "runtime_resolution.source_mismatch must be false")
                    + emit(($runtime.server_workspace_mismatch == false);
                           "runtime_resolution.server_workspace_mismatch must be false")
                    + emit(nonempty_string($runtime.runtime_binary_git_commit);
                           "runtime_binary_git_commit must be a non-empty string")
                  end
                + emit(($tool != null);
                       "tool_inventory.tools must contain masc_keeper_waiting_inventory")
                + if ($tool == null) then
                    []
                  else
                    emit((($tool.surfaces // []) | index("public_mcp")) != null;
                         "masc_keeper_waiting_inventory must expose public_mcp surface")
                    + emit(($tool.registered_schema == true);
                           "masc_keeper_waiting_inventory registered_schema must be true")
                    + emit(($tool.dispatch_registered == true);
                           "masc_keeper_waiting_inventory dispatch_registered must be true")
                    + emit(($tool.direct_call_allowed == true);
                           "masc_keeper_waiting_inventory direct_call_allowed must be true")
                    + emit(($tool.effectDomain == "read_only");
                           "masc_keeper_waiting_inventory effectDomain must be read_only")
                    + emit(($tool.implementationStatus == "real");
                           "masc_keeper_waiting_inventory implementationStatus must be real")
                  end
                + emit(object_value($projection);
                       "keeper_waiting_inventory projection must be an object")
                + if object_value($projection) then
                    emit(($projection.schema == "masc.dashboard.keeper_waiting_inventory.v1");
                         "keeper_waiting_inventory schema mismatch")
                    + emit(($projection.source == "server_keeper_waiting_inventory");
                           "keeper_waiting_inventory source mismatch")
                    + emit(string_array($projection.supported_states);
                           "keeper_waiting_inventory.supported_states must be a string array")
                    + emit(integer_value($projection.keeper_count);
                           "keeper_waiting_inventory.keeper_count must be a non-negative integer")
                    + emit(integer_value($projection.waiting_keeper_count);
                           "keeper_waiting_inventory.waiting_keeper_count must be a non-negative integer")
                    + emit(integer_value($projection.row_count);
                           "keeper_waiting_inventory.row_count must be a non-negative integer")
                    + emit(integer_value($projection.global_row_count);
                           "keeper_waiting_inventory.global_row_count must be a non-negative integer")
                    + emit(array_value($projection.keepers);
                           "keeper_waiting_inventory.keepers must be an array")
                    + emit(array_value($projection.global_waiting_on);
                           "keeper_waiting_inventory.global_waiting_on must be an array")
                    + if integer_value($projection.keeper_count)
                         and array_value($projection.keepers) then
                        emit(($projection.keeper_count == ($projection.keepers | length));
                             "keeper_waiting_inventory.keeper_count must match keepers length")
                      else
                        []
                      end
                    + if integer_value($projection.waiting_keeper_count)
                         and integer_value($projection.keeper_count) then
                        emit(($projection.waiting_keeper_count <= $projection.keeper_count);
                             "keeper_waiting_inventory.waiting_keeper_count must not exceed keeper_count")
                      else
                        []
                      end
                    + if integer_value($projection.row_count)
                         and array_value($projection.keepers) then
                        emit(($projection.row_count == keeper_row_total($projection.keepers));
                             "keeper_waiting_inventory.row_count must match keeper waiting rows")
                      else
                        []
                      end
                    + if integer_value($projection.global_row_count)
                         and array_value($projection.global_waiting_on) then
                        emit(($projection.global_row_count == ($projection.global_waiting_on | length));
                             "keeper_waiting_inventory.global_row_count must match global_waiting_on length")
                      else
                        []
                      end
                    + if array_value($projection.keepers) then
                        emit(all($projection.keepers[];
                                 keeper_shape($projection.supported_states; .));
                             "keeper_waiting_inventory.keepers rows must match schema")
                      else
                        []
                      end
                    + if array_value($projection.global_waiting_on) then
                        emit(waiting_rows_shape($projection.global_waiting_on);
                             "keeper_waiting_inventory.global_waiting_on rows must match schema")
                      else
                        []
                      end
                  else
                    []
                  end
              ) as $errors
            | {
                status:($runtime.status // null),
                deployment_state:{
                  status:($runtime.deployment_state.status // null),
                  operator_action_required:
                    (if ($runtime.deployment_state | has("operator_action_required")) then
                       $runtime.deployment_state.operator_action_required
                     else
                       null
                     end),
                  binary_commit_known:
                    (if ($runtime.deployment_state | has("binary_commit_known")) then
                       $runtime.deployment_state.binary_commit_known
                     else
                       null
                     end),
                  upstream:($runtime.deployment_state.upstream // null),
                  deployed:($runtime.deployment_state.deployed // null),
                  runtime_repo:($runtime.deployment_state.runtime_repo // null),
                  workspace:($runtime.deployment_state.workspace // null)
                },
                server_repo_git_commit:($runtime.server_repo_git_commit // null),
                runtime_binary_git_commit:($runtime.runtime_binary_git_commit // null),
                runtime_repo_head_git_commit:
                  ($runtime.runtime_repo_head_git_commit // null),
                source_mismatch:
                  (if ($runtime | has("source_mismatch")) then
                     $runtime.source_mismatch
                   else
                     null
                   end),
                server_workspace_mismatch:
                  (if ($runtime | has("server_workspace_mismatch")) then
                     $runtime.server_workspace_mismatch
                   else
                     null
                   end),
                build:{
                  commit:($runtime.build.commit // null),
                  repo_root:($runtime.build.repo_root // null),
                  executable_path:($runtime.build.executable_path // null),
                  started_at:($runtime.build.started_at // null)
                }
              } as $runtime_summary
            | {
                schema:"masc.keeper_waiting_inventory_preflight.v1",
                status:(if ($errors | length) == 0 then "preflight_pass" else "fail" end),
                ok:(($errors | length) == 0),
                dashboard_url:$dashboard_url,
                mcp_url:$mcp_url,
                tool_name:$tool_name,
                runtime_identity_gate:{
                  allow_diverged_runtime:($allow_diverged_runtime == "1"),
                  runtime_resolution:$runtime_summary
                },
                waiting_tool_surface:{
                  required:$tool_name,
                  present:($tool != null),
                  tool:$tool
                },
                waiting_projection:{
                  present:object_value($projection),
                  schema:($projection.schema // null),
                  source:($projection.source // null),
                  generated_at:($projection.generated_at // null),
                  supported_states:($projection.supported_states // null),
                  keeper_count:($projection.keeper_count // null),
                  waiting_keeper_count:($projection.waiting_keeper_count // null),
                  row_count:($projection.row_count // null),
                  global_row_count:($projection.global_row_count // null),
                  global_pending_confirm_count:($projection.global_pending_confirm_count // null),
                  source_counts:($projection.source_counts // null),
                  keepers:($projection.keepers // null),
                  global_waiting_on:($projection.global_waiting_on // null)
                },
                errors:$errors
              }
          '
  )" || fail "dashboard tools preflight report could not be parsed"
}

run_preflight_gate() {
  build_preflight_report
  write_proof_json "$PREFLIGHT_REPORT_JSON"
  if ! printf '%s' "$PREFLIGHT_REPORT_JSON" | jq -e '.ok == true' >/dev/null; then
    printf '%s\n' "$PREFLIGHT_REPORT_JSON" | jq . >&2
    exit 1
  fi
}

initialize_mcp_session() {
  if [[ -n "${MCP_SESSION_ID:-}" ]]; then
    export MCP_SESSION_ID
    return 0
  fi

  local headers_file body_file auth_header_file init_body protocol_version
  headers_file="$(mcp_mktemp_file "keeper-waiting-inventory-init" ".headers")"
  body_file="$(mcp_mktemp_file "keeper-waiting-inventory-init" ".body")"
  auth_header_file=""
  if [[ -n "${MCP_TOKEN:-}" ]]; then
    auth_header_file="$(_mcp_auth_header_file "$MCP_TOKEN")" || auth_header_file=""
  fi
  init_body="$(
    jq -cn --arg client_name "$MCP_CLIENT_NAME" \
      '{jsonrpc:"2.0", id:1, method:"initialize", params:{protocolVersion:"2025-11-25", clientInfo:{name:$client_name, version:"1.0"}, capabilities:{}}}'
  )"

  local -a init_headers=(
    -H 'Content-Type: application/json'
    -H 'Accept: application/json, text/event-stream'
  )
  if [[ -n "$auth_header_file" ]]; then
    init_headers+=( -H "@$auth_header_file" )
  fi

  if ! curl -sS --max-time "$CURL_TIMEOUT_SEC" -D "$headers_file" -o "$body_file" \
    -X POST "$MCP_URL" "${init_headers[@]}" --data-binary "$init_body" >/dev/null; then
    rm -f "$headers_file" "$body_file" "$auth_header_file"
    fail "MCP initialize failed at ${MCP_URL}"
  fi

  MCP_SESSION_ID="$(
    awk '
      tolower($0) ~ /^mcp-session-id:/ {
        sub(/^[^:]+:[[:space:]]*/, "", $0)
        sub(/\r$/, "", $0)
        print $0
        exit
      }
    ' "$headers_file"
  )"
  protocol_version="$(
    awk '
      tolower($0) ~ /^mcp-protocol-version:/ {
        sub(/^[^:]+:[[:space:]]*/, "", $0)
        sub(/\r$/, "", $0)
        print $0
        exit
      }
    ' "$headers_file"
  )"

  if [[ -z "$MCP_SESSION_ID" ]]; then
    if jq -e . "$body_file" >/dev/null 2>&1; then
      jq . "$body_file" >&2
    else
      cat "$body_file" >&2 || true
    fi
    rm -f "$headers_file" "$body_file" "$auth_header_file"
    fail "MCP initialize did not return Mcp-Session-Id"
  fi

  export MCP_SESSION_ID
  if [[ -n "$protocol_version" ]]; then
    MCP_PROTOCOL_VERSION="$protocol_version"
    export MCP_PROTOCOL_VERSION
  fi

  local -a initialized_headers=(
    -H 'Content-Type: application/json'
    -H 'Accept: application/json, text/event-stream'
    -H "mcp-session-id: ${MCP_SESSION_ID}"
  )
  if [[ -n "$auth_header_file" ]]; then
    initialized_headers+=( -H "@$auth_header_file" )
  fi
  curl -sS --max-time "$CURL_TIMEOUT_SEC" -X POST "$MCP_URL" \
    "${initialized_headers[@]}" \
    --data-binary '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}' \
    >/dev/null || true

  rm -f "$headers_file" "$body_file" "$auth_header_file"
}

main() {
  FAILURE_STAGE="startup"
  require_cmd curl
  require_cmd jq
  FAILURE_STAGE="token_load"
  load_mcp_token
  if [[ "$REQUIRE_CURRENT_RUNTIME" == "1" || -n "$PROOF_OUT" ]]; then
    FAILURE_STAGE="dashboard_preflight"
    run_preflight_gate
    if [[ "$PREFLIGHT_ONLY" == "1" ]]; then
      FAILURE_STAGE="output"
      if [[ "$COMPACT" == "1" ]]; then
        printf '%s\n' "$PREFLIGHT_REPORT_JSON"
      else
        printf '%s\n' "$PREFLIGHT_REPORT_JSON" | jq .
      fi
      exit 0
    fi
  fi
  FAILURE_STAGE="mcp_initialize"
  initialize_mcp_session

  local result
  FAILURE_STAGE="mcp_tool_call"
  result="$(
    mcp_call_tool_result \
      7001 \
      "$WAITING_TOOL_NAME" \
      '{}' \
      "$MCP_SESSION_ID" \
      "${MCP_TOKEN:-}" \
      "$MCP_URL"
  )" || fail "masc_keeper_waiting_inventory call failed"

  if [[ -z "$result" ]]; then
    fail "masc_keeper_waiting_inventory returned empty result"
  fi
  FAILURE_STAGE="proof_write"
  write_cli_success_proof "$result"
  FAILURE_STAGE="output"
  if [[ "$COMPACT" == "1" ]]; then
    printf '%s\n' "$result"
  else
    printf '%s\n' "$result" | jq .
  fi
}

main "$@"
