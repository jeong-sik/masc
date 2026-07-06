#!/usr/bin/env bash
set -euo pipefail

: "${REQUIRE_PASS:=0}"

usage() {
  cat >&2 <<'USAGE'
Usage: scripts/keeper-waiting-inventory-proof-check.sh [--require-pass|--allow-fail] PROOF.json

Validates proof emitted by scripts/keeper-waiting-inventory.sh --proof-out.
Set REQUIRE_PASS=1 or pass --require-pass to reject fail proofs.
USAGE
}

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

truthy() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

require_pass="$REQUIRE_PASS"
case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  --require-pass)
    require_pass=1
    shift
    ;;
  --allow-fail)
    require_pass=0
    shift
    ;;
esac

if [[ $# -ne 1 ]]; then
  usage
  exit 2
fi

if truthy "$require_pass"; then
  require_pass=1
else
  require_pass=0
fi

proof_path="$1"
command -v jq >/dev/null || fail "jq is required"
[[ -f "$proof_path" ]] || fail "proof file not found: ${proof_path}"

report="$(
  jq -ce \
    --arg proof_path "$proof_path" \
    --arg require_pass "$require_pass" \
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

      def error_array($value):
        string_array($value);

      def boolean_value($value):
        ($value | type) == "boolean";

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

      def inventory_projection_errors($projection; $label):
        emit(object_value($projection); ($label + " must be an object"))
        + if object_value($projection) then
            emit(($projection.schema == "masc.dashboard.keeper_waiting_inventory.v1");
                 ($label + " schema mismatch"))
            + emit(($projection.source == "server_keeper_waiting_inventory");
                   ($label + " source mismatch"))
            + emit(string_array($projection.supported_states);
                   ($label + ".supported_states must be a string array"))
            + emit(integer_value($projection.keeper_count);
                   ($label + ".keeper_count must be a non-negative integer"))
            + emit(integer_value($projection.waiting_keeper_count);
                   ($label + ".waiting_keeper_count must be a non-negative integer"))
            + emit(integer_value($projection.row_count);
                   ($label + ".row_count must be a non-negative integer"))
            + emit(integer_value($projection.global_row_count);
                   ($label + ".global_row_count must be a non-negative integer"))
            + emit(array_value($projection.keepers);
                   ($label + ".keepers must be an array"))
            + emit(array_value($projection.global_waiting_on);
                   ($label + ".global_waiting_on must be an array"))
            + if integer_value($projection.keeper_count)
                 and array_value($projection.keepers) then
                emit(($projection.keeper_count == ($projection.keepers | length));
                     ($label + ".keeper_count must match keepers length"))
              else
                []
              end
            + if integer_value($projection.waiting_keeper_count)
                 and integer_value($projection.keeper_count) then
                emit(($projection.waiting_keeper_count <= $projection.keeper_count);
                     ($label + ".waiting_keeper_count must not exceed keeper_count"))
              else
                []
              end
            + if integer_value($projection.row_count)
                 and array_value($projection.keepers) then
                emit(($projection.row_count == keeper_row_total($projection.keepers));
                     ($label + ".row_count must match keeper waiting rows"))
              else
                []
              end
            + if integer_value($projection.global_row_count)
                 and array_value($projection.global_waiting_on) then
                emit(($projection.global_row_count == ($projection.global_waiting_on | length));
                     ($label + ".global_row_count must match global_waiting_on length"))
              else
                []
              end
            + if array_value($projection.keepers) then
                emit(all($projection.keepers[]; keeper_shape($projection.supported_states; .));
                     ($label + ".keepers rows must match schema"))
              else
                []
              end
            + if array_value($projection.global_waiting_on) then
                emit(waiting_rows_shape($projection.global_waiting_on);
                     ($label + ".global_waiting_on rows must match schema"))
              else
                []
              end
          else
            []
          end;

      def inventory_parity_errors($dashboard; $mcp):
        emit(($mcp.schema == $dashboard.schema);
             "mcp_result.schema must match preflight waiting_projection.schema")
        + emit(($mcp.source == $dashboard.source);
               "mcp_result.source must match preflight waiting_projection.source")
        + emit(($mcp.supported_states == $dashboard.supported_states);
               "mcp_result.supported_states must match preflight waiting_projection.supported_states")
        + emit(($mcp.keeper_count == $dashboard.keeper_count);
               "mcp_result.keeper_count must match preflight waiting_projection.keeper_count")
        + emit(($mcp.waiting_keeper_count == $dashboard.waiting_keeper_count);
               "mcp_result.waiting_keeper_count must match preflight waiting_projection.waiting_keeper_count")
        + emit(($mcp.row_count == $dashboard.row_count);
               "mcp_result.row_count must match preflight waiting_projection.row_count")
        + emit(($mcp.global_row_count == $dashboard.global_row_count);
               "mcp_result.global_row_count must match preflight waiting_projection.global_row_count")
        + emit(($mcp.global_pending_confirm_count == $dashboard.global_pending_confirm_count);
               "mcp_result.global_pending_confirm_count must match preflight waiting_projection")
        + emit(($mcp.source_counts == $dashboard.source_counts);
               "mcp_result.source_counts must match preflight waiting_projection.source_counts")
        + emit(($mcp.keepers == $dashboard.keepers);
               "mcp_result.keepers must match preflight waiting_projection.keepers")
        + emit(($mcp.global_waiting_on == $dashboard.global_waiting_on);
               "mcp_result.global_waiting_on must match preflight waiting_projection.global_waiting_on");

      def cli_failure_stage($value):
        $value == "argument_parse"
        or $value == "startup"
        or $value == "token_load"
        or $value == "dashboard_preflight"
        or $value == "mcp_initialize"
        or $value == "mcp_tool_call"
        or $value == "proof_write"
        or $value == "output";

      def common_preflight_errors($require_pass):
        emit((.schema == "masc.keeper_waiting_inventory_preflight.v1");
             "schema must be masc.keeper_waiting_inventory_preflight.v1")
        + emit((.status == "fail" or .status == "preflight_pass");
               "status must be fail or preflight_pass")
        + emit((($require_pass == "1") | not) or (.status == "preflight_pass");
               "REQUIRE_PASS rejects fail proof")
        + emit((.ok == (.status == "preflight_pass"));
               "ok must match status")
        + emit(nonempty_string(.dashboard_url); "dashboard_url must be a non-empty string")
        + emit(nonempty_string(.mcp_url); "mcp_url must be a non-empty string")
        + emit((.tool_name == "masc_keeper_waiting_inventory");
               "tool_name must be masc_keeper_waiting_inventory")
        + emit(error_array(.errors); "errors must be a string array")
        + emit(object_value(.runtime_identity_gate);
               "runtime_identity_gate must be an object")
        + emit(boolean_value(.runtime_identity_gate.allow_diverged_runtime);
               "runtime_identity_gate.allow_diverged_runtime must be boolean")
        + emit(object_value(.runtime_identity_gate.runtime_resolution);
               "runtime_identity_gate.runtime_resolution must be an object")
        + emit(object_value(.waiting_tool_surface);
               "waiting_tool_surface must be an object")
        + emit((.waiting_tool_surface.required == "masc_keeper_waiting_inventory");
               "waiting_tool_surface.required must be masc_keeper_waiting_inventory")
        + emit(boolean_value(.waiting_tool_surface.present);
               "waiting_tool_surface.present must be boolean")
        + emit(object_value(.waiting_projection);
               "waiting_projection must be an object")
        + emit(boolean_value(.waiting_projection.present);
               "waiting_projection.present must be boolean");

      def successful_preflight_errors:
        (.runtime_identity_gate.runtime_resolution // null) as $runtime
        | (.waiting_tool_surface.tool // null) as $tool
        | (.waiting_projection // null) as $projection
        | emit((.errors | length) == 0; "preflight_pass errors must be empty")
          + emit(($runtime.deployment_state.status == "current");
                 "runtime deployment_state.status must be current")
          + emit(nonempty_string($runtime.runtime_binary_git_commit);
                 "runtime_binary_git_commit must be non-empty")
          + emit(($runtime.source_mismatch == false);
                 "source_mismatch must be false")
          + emit(($runtime.server_workspace_mismatch == false);
                 "server_workspace_mismatch must be false")
          + emit((.waiting_tool_surface.present == true);
                 "waiting_tool_surface.present must be true")
          + emit(object_value($tool); "waiting_tool_surface.tool must be an object")
          + emit((($tool.surfaces // []) | index("public_mcp")) != null;
                 "tool must expose public_mcp surface")
          + emit(($tool.registered_schema == true);
                 "tool registered_schema must be true")
          + emit(($tool.dispatch_registered == true);
                 "tool dispatch_registered must be true")
          + emit(($tool.direct_call_allowed == true);
                 "tool direct_call_allowed must be true")
          + emit(($tool.effectDomain == "read_only");
                 "tool effectDomain must be read_only")
          + emit(($tool.implementationStatus == "real");
                 "tool implementationStatus must be real")
          + emit((.waiting_projection.present == true);
                 "waiting_projection.present must be true")
          + emit((.waiting_projection.schema == "masc.dashboard.keeper_waiting_inventory.v1");
                 "waiting_projection schema mismatch")
          + emit((.waiting_projection.source == "server_keeper_waiting_inventory");
                 "waiting_projection source mismatch")
          + emit(string_array(.waiting_projection.supported_states);
                 "waiting_projection.supported_states must be a string array")
          + emit(integer_value(.waiting_projection.keeper_count);
                 "waiting_projection.keeper_count must be a non-negative integer")
          + emit(integer_value(.waiting_projection.waiting_keeper_count);
                 "waiting_projection.waiting_keeper_count must be a non-negative integer")
          + emit(integer_value(.waiting_projection.row_count);
                 "waiting_projection.row_count must be a non-negative integer")
          + emit(integer_value(.waiting_projection.global_row_count);
                 "waiting_projection.global_row_count must be a non-negative integer")
          + emit(array_value(.waiting_projection.keepers);
                 "waiting_projection.keepers must be an array")
          + emit(array_value(.waiting_projection.global_waiting_on);
                 "waiting_projection.global_waiting_on must be an array")
          + if integer_value($projection.keeper_count)
               and array_value($projection.keepers) then
              emit(($projection.keeper_count == ($projection.keepers | length));
                   "waiting_projection.keeper_count must match keepers length")
            else
              []
            end
          + if integer_value($projection.waiting_keeper_count)
               and integer_value($projection.keeper_count) then
              emit(($projection.waiting_keeper_count <= $projection.keeper_count);
                   "waiting_projection.waiting_keeper_count must not exceed keeper_count")
            else
              []
            end
          + if integer_value($projection.row_count)
               and array_value($projection.keepers) then
              emit(($projection.row_count == keeper_row_total($projection.keepers));
                   "waiting_projection.row_count must match keeper waiting rows")
            else
              []
            end
          + if integer_value($projection.global_row_count)
               and array_value($projection.global_waiting_on) then
              emit(($projection.global_row_count == ($projection.global_waiting_on | length));
                   "waiting_projection.global_row_count must match global_waiting_on length")
            else
              []
            end
          + if array_value($projection.keepers) then
              emit(all($projection.keepers[]; keeper_shape($projection.supported_states; .));
                   "waiting_projection.keepers rows must match schema")
            else
              []
            end
          + if array_value($projection.global_waiting_on) then
              emit(waiting_rows_shape($projection.global_waiting_on);
                   "waiting_projection.global_waiting_on rows must match schema")
            else
              []
            end;

      def failed_preflight_errors:
        emit((.errors | length) > 0; "fail proof must include at least one error");

      def preflight_pass_errors_for($proof; $require_pass):
        $proof
        | common_preflight_errors($require_pass)
          + successful_preflight_errors;

      def cli_common_errors($require_pass):
        emit((.schema == "masc.keeper_waiting_inventory_cli_proof.v1");
             "schema must be masc.keeper_waiting_inventory_cli_proof.v1")
        + emit((.status == "fail" or .status == "pass");
               "CLI proof status must be fail or pass")
        + emit((($require_pass == "1") | not) or (.status == "pass");
               "REQUIRE_PASS rejects CLI fail proof")
        + emit(nonempty_string(.dashboard_url); "dashboard_url must be a non-empty string")
        + emit(nonempty_string(.mcp_url); "mcp_url must be a non-empty string")
        + emit((.tool_name == "masc_keeper_waiting_inventory");
               "tool_name must be masc_keeper_waiting_inventory");

      def cli_failure_errors:
        emit((.status == "fail"); "CLI proof status must be fail")
        + emit(nonempty_string(.reason); "CLI fail proof reason must be non-empty")
        + emit(nonempty_string(.failure_stage);
               "CLI fail proof failure_stage must be non-empty")
        + emit(cli_failure_stage(.failure_stage);
               "CLI fail proof failure_stage is not recognized")
        + emit((.preflight == null or object_value(.preflight));
               "CLI fail proof preflight must be null or object");

      def cli_success_errors($require_pass):
        (.preflight // null) as $preflight
        | (.mcp_result // null) as $mcp
        | emit((.status == "pass"); "CLI success proof status must be pass")
          + emit((.ok == true); "CLI success proof ok must be true")
          + emit(object_value($preflight);
                 "CLI success proof preflight must be an object")
          + if object_value($preflight) then
              preflight_pass_errors_for($preflight; "1")
            else
              []
            end
          + inventory_projection_errors($mcp; "mcp_result")
          + if object_value($preflight) and object_value($mcp) then
              inventory_parity_errors($preflight.waiting_projection; $mcp)
            else
              []
            end;

      (
        if .schema == "masc.keeper_waiting_inventory_preflight.v1" then
          common_preflight_errors($require_pass)
          + if .status == "preflight_pass" then
              successful_preflight_errors
            elif .status == "fail" then
              failed_preflight_errors
            else
              []
            end
        elif .schema == "masc.keeper_waiting_inventory_cli_proof.v1" then
          cli_common_errors($require_pass)
          + if .status == "pass" then
              cli_success_errors($require_pass)
            elif .status == "fail" then
              cli_failure_errors
            else
              []
            end
        else
          ["unsupported proof schema"]
        end
      ) as $errors
      | {
          ok:(($errors | length) == 0),
          schema:(.schema // null),
          status:(.status // null),
          require_pass:($require_pass == "1"),
          proof_path:$proof_path,
          checked_contract:{
            tool_name:"masc_keeper_waiting_inventory"
          },
          errors:$errors
        }
    ' "$proof_path"
)" || fail "proof JSON is not parseable or validator failed: ${proof_path}"

if ! printf '%s' "$report" | jq -e '.ok == true' >/dev/null; then
  printf '%s\n' "$report" | jq . >&2
  exit 1
fi

printf '%s\n' "$report"
