#!/usr/bin/env bash
set -euo pipefail

: "${REQUIRE_PASS:=0}"

usage() {
  cat >&2 <<'USAGE'
Usage: scripts/harness/schedule_live_safe_smoke_proof_check.sh [--require-pass] PROOF.json

Validates schedule_live_safe_smoke proof JSON against its embedded smoke contract.
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

      def nonempty_string($value):
        ($value | type) == "string" and ($value | length) > 0;

      def object_value($value):
        ($value | type) == "object";

      def boolean_value($value):
        ($value | type) == "boolean";

      def number_value($value):
        ($value | type) == "number";

      def string_array($value):
        ($value | type) == "array"
        and all($value[]; (type == "string") and (length > 0));

      def unique_string_array($value):
        string_array($value)
        and (($value | length) > 0)
        and (($value | unique | length) == ($value | length));

      def empty_array($value):
        ($value | type) == "array" and ($value | length) == 0;

      def same_string_set($actual; $expected):
        string_array($actual) and (($actual | sort) == ($expected | sort));

      def tool_present($tools; $name):
        any($tools[]?; (.name == $name) and (.present == true));

      def dashboard_public_tool_ready($tools; $name):
        any(
          $tools[]?;
          (.name == $name)
          and (.present == true)
          and (((.surfaces // []) | index("public_mcp")) != null)
          and (.registered_schema == true)
          and (.dispatch_registered == true)
        );

      def schedule_runner_preflight_errors:
        (.schedule_runner_preflight // null) as $runner
        | emit(object_value($runner);
               "schedule_runner_preflight must be an object")
          + emit(($runner.schema == "masc.schedule.runner_status.v1");
                 "schedule_runner_preflight.schema must be masc.schedule.runner_status.v1")
          + emit(($runner.status == "ok" or $runner.status == "running");
                 "schedule_runner_preflight.status must be ok or running")
          + emit(boolean_value($runner.tick_in_flight);
                 "schedule_runner_preflight.tick_in_flight must be boolean")
          + emit(number_value($runner.tick_count);
                 "schedule_runner_preflight.tick_count must be number")
          + emit(number_value($runner.success_count);
                 "schedule_runner_preflight.success_count must be number")
          + emit(number_value($runner.failure_count);
                 "schedule_runner_preflight.failure_count must be number")
          + emit(number_value($runner.crash_count);
                 "schedule_runner_preflight.crash_count must be number");

      def runner_success_errors:
        (.runner // null) as $runner
        | emit(object_value($runner); "runner must be an object")
          + emit(($runner.status == "ok" or $runner.status == "running");
                 "runner.status must be ok or running")
          + emit(number_value($runner.tick_count);
                 "runner.tick_count must be number")
          + emit(number_value($runner.success_count);
                 "runner.success_count must be number")
          + emit((.schedule_runner_preflight.tick_count | type) != "number"
                 or $runner.tick_count >= .schedule_runner_preflight.tick_count;
                 "runner.tick_count must not be lower than schedule_runner_preflight.tick_count");

      def board_projection_errors:
        (.board_projection // null) as $board
        | (.board_expectation // null) as $expect
        | emit(object_value($expect); "board_expectation must be an object")
          + emit(nonempty_string($expect.hearth);
                 "board_expectation.hearth must be a non-empty string")
          + emit(nonempty_string($expect.title);
                 "board_expectation.title must be a non-empty string")
          + emit(nonempty_string($expect.author);
                 "board_expectation.author must be a non-empty string")
          + emit(nonempty_string($expect.content);
                 "board_expectation.content must be a non-empty string")
          + emit(object_value($expect.meta);
                 "board_expectation.meta must be an object")
          + emit(($expect.meta.smoke_run_id == .run_id);
                 "board_expectation.meta.smoke_run_id must match proof run_id")
          + emit(($expect.meta.smoke == "schedule_live_safe_smoke");
                 "board_expectation.meta.smoke must be schedule_live_safe_smoke")
          + emit(object_value($board); "board_projection must be an object")
          + emit(($board.source == "dashboard_board_projection");
                 "board_projection.source must be dashboard_board_projection")
          + emit(($board.found == true);
                 "board_projection.found must be true")
          + emit(nonempty_string($board.post_id);
                 "board_projection.post_id must be a non-empty string")
          + emit(($board.post_id == .post_id);
                 "board_projection.post_id must match proof post_id")
          + emit(nonempty_string($board.hearth);
                 "board_projection.hearth must be a non-empty string")
          + emit(($board.hearth == $expect.hearth);
                 "board_projection.hearth must match board_expectation.hearth")
          + emit(($board.title == $expect.title);
                 "board_projection.title must match board_expectation.title")
          + emit(($board.author == $expect.author);
                 "board_projection.author must match board_expectation.author")
          + emit(($board.body == $expect.content);
                 "board_projection.body must match board_expectation.content")
          + emit(($board.content == $expect.content);
                 "board_projection.content must match board_expectation.content")
          + emit(($board.meta_smoke_run_id == .run_id);
                 "board_projection.meta_smoke_run_id must match proof run_id")
          + emit(($board.meta_smoke_run_id == $expect.meta.smoke_run_id);
                 "board_projection.meta_smoke_run_id must match board_expectation")
          + emit(($board.meta_smoke == $expect.meta.smoke);
                 "board_projection.meta_smoke must match board_expectation");

      def common_errors($require_pass):
        emit((.status == "fail" or .status == "preflight_pass" or .status == "pass");
             "status must be one of fail, preflight_pass, pass")
        + emit((($require_pass == "1") | not) or (.status != "fail");
               "REQUIRE_PASS rejects fail proof")
        + emit(nonempty_string(.run_id); "run_id must be a non-empty string")
        + emit(nonempty_string(.dashboard_url); "dashboard_url must be a non-empty string")
        + emit(nonempty_string(.mcp_url); "mcp_url must be a non-empty string");

      def failure_stage($value):
        $value == "startup"
        or $value == "preflight"
        or $value == "startup_checks"
        or $value == "token_resolution"
        or $value == "health_probe"
        or $value == "dashboard_tools_probe"
        or $value == "runtime_identity_capture"
        or $value == "schedule_tool_contract"
        or $value == "runtime_identity_gate"
        or $value == "schedule_runner_preflight"
        or $value == "mcp_initialize"
        or $value == "mcp_initialized_notification"
        or $value == "mcp_tools_list"
        or $value == "mcp_tool_surface"
        or $value == "dashboard_tool_surface"
        or $value == "mcp_schedule_create"
        or $value == "dashboard_approval"
        or $value == "schedule_poll"
        or $value == "dashboard_schedule_projection"
        or $value == "dashboard_board_projection"
        or $value == "runner_status"
        or $value == "otel_metrics"
        or $value == "proof_write";

      def failure_errors:
        emit(nonempty_string(.reason); "fail proof reason must be a non-empty string")
        + emit(nonempty_string(.failure_stage);
               "fail proof failure_stage must be a non-empty string")
        + emit(failure_stage(.failure_stage);
               "fail proof failure_stage is not recognized");

      def schedule_tool_contract_probe_errors:
        (.schedule_tool_contract_probe // null) as $probe
        | emit(object_value($probe); "schedule_tool_contract_probe must be an object")
          + emit(($probe.schema == "masc.schedule_tool_contract.probe.v1");
                 "schedule_tool_contract_probe.schema must be masc.schedule_tool_contract.probe.v1")
          + emit(($probe.status == "ok" or $probe.status == "error");
                 "schedule_tool_contract_probe.status must be ok or error")
          + if $probe.status == "ok" then
              emit(unique_string_array($probe.public_schedule_tools);
                   "schedule_tool_contract_probe.public_schedule_tools must be a non-empty unique string array when status=ok")
            else
              emit(nonempty_string($probe.error_kind);
                   "schedule_tool_contract_probe.error_kind must be a non-empty string when status=error")
              + emit(nonempty_string($probe.message);
                     "schedule_tool_contract_probe.message must be a non-empty string when status=error")
            end;

      def schedule_tool_contract_failure_errors:
        if .failure_stage == "schedule_tool_contract" then
          schedule_tool_contract_probe_errors
          + emit((.schedule_tool_contract_probe.status == "error");
                 "schedule_tool_contract fail proof must carry an error probe")
        else
          []
        end;

      def runtime_identity_errors:
        (.runtime_identity_gate // null) as $gate
        | ($gate.runtime_resolution // null) as $runtime
        | emit(object_value($gate); "runtime_identity_gate must be an object")
          + emit(($gate.allow_diverged_runtime == false);
                 "runtime_identity_gate.allow_diverged_runtime must be false for accepted proof")
          + emit(($runtime.deployment_state.status == "current");
                 "runtime deployment_state.status must be current")
          + emit(($runtime.source_mismatch == false);
                 "runtime_resolution.source_mismatch must be false")
          + emit(($runtime.server_workspace_mismatch == false);
                 "runtime_resolution.server_workspace_mismatch must be false")
          + emit(nonempty_string($runtime.runtime_binary_git_commit);
                 "runtime_binary_git_commit must be a non-empty string")
          + emit((($gate.require_harness_source_match == true) | not)
                 or (.source.harness_repo_commit == $runtime.runtime_binary_git_commit);
                 "harness source commit must match runtime commit when require_harness_source_match is true");

      def surface_errors:
        (.required_tool_surface // null) as $mcp
        | (.dashboard_required_tool_surface // null) as $dashboard
        | ($mcp.required // []) as $required_tools
        | ($mcp.tools // []) as $mcp_tools
        | ($dashboard.tools // []) as $dashboard_tools
        | emit(object_value($mcp); "required_tool_surface must be an object")
          + emit(unique_string_array($mcp.required);
                 "required_tool_surface.required must be a non-empty unique string array")
          + emit(empty_array($mcp.missing);
                 "required_tool_surface.missing must be an empty array")
          + emit((($mcp.tools | type) == "array");
                 "required_tool_surface.tools must be an array")
          + emit(all($required_tools[]; . as $name | tool_present($mcp_tools; $name));
                 "required_tool_surface.tools must mark every required tool present")
          + emit(object_value($dashboard); "dashboard_required_tool_surface must be an object")
          + emit(same_string_set($dashboard.required; $required_tools);
                 "dashboard_required_tool_surface.required must match required_tool_surface.required")
          + emit(empty_array($dashboard.missing);
                 "dashboard_required_tool_surface.missing must be an empty array")
          + emit(empty_array($dashboard.no_public_surface);
                 "dashboard_required_tool_surface.no_public_surface must be an empty array")
          + emit((($dashboard.tools | type) == "array");
                 "dashboard_required_tool_surface.tools must be an array")
          + emit(all($required_tools[]; . as $name | dashboard_public_tool_ready($dashboard_tools; $name));
                 "dashboard required tools must be present with public_mcp surface, registered schema, and dispatch");

      def preflight_success_errors:
        runtime_identity_errors
        + schedule_runner_preflight_errors
        + schedule_tool_contract_probe_errors
        + emit((.schedule_tool_contract_probe.status == "ok");
               "preflight_pass proof must carry an ok schedule_tool_contract_probe")
        + surface_errors
        + emit((.runtime_identity_gate.preflight_only == true);
               "preflight_pass proof must set runtime_identity_gate.preflight_only=true");

      def full_success_errors:
        runtime_identity_errors
        + schedule_runner_preflight_errors
        + schedule_tool_contract_probe_errors
        + emit((.schedule_tool_contract_probe.status == "ok");
               "pass proof must carry an ok schedule_tool_contract_probe")
        + surface_errors
        + runner_success_errors
        + board_projection_errors
        + emit((.runtime_identity_gate.preflight_only == false);
               "pass proof must set runtime_identity_gate.preflight_only=false")
        + emit(nonempty_string(.schedule_id); "pass proof schedule_id must be a non-empty string")
        + emit(nonempty_string(.post_id); "pass proof post_id must be a non-empty string")
        + emit((.schedule.status == "succeeded"); "schedule.status must be succeeded")
        + emit((.schedule.last_execution.schedule_id == .schedule_id);
               "schedule.last_execution.schedule_id must match proof schedule_id")
        + emit((.schedule.last_execution.status == "succeeded");
               "schedule.last_execution.status must be succeeded")
        + emit((.schedule.last_execution.detail.post_id == .post_id);
               "schedule.last_execution.detail.post_id must match proof post_id")
        + emit((.dashboard_projection.schedule_id == .schedule_id);
               "dashboard_projection.schedule_id must match proof schedule_id")
        + emit((.dashboard_projection.status == "succeeded");
               "dashboard_projection.status must be succeeded")
        + emit((.dashboard_projection.last_execution.schedule_id == .schedule_id);
               "dashboard_projection.last_execution.schedule_id must match proof schedule_id")
        + emit((.dashboard_projection.last_execution.status == "succeeded");
               "dashboard_projection.last_execution.status must be succeeded")
        + emit((.dashboard_projection.last_execution.detail.post_id == .post_id);
               "dashboard_projection.last_execution.detail.post_id must match proof post_id");

      (.required_tool_surface.required // .dashboard_required_tool_surface.required // []) as $proof_required_tools
      |
      (
        common_errors($require_pass)
        + if .status == "fail" then
            failure_errors + schedule_tool_contract_failure_errors
          elif .status == "preflight_pass" then
            preflight_success_errors
          elif .status == "pass" then
            full_success_errors
          else
            []
          end
      ) as $errors
      | {
          ok: (($errors | length) == 0),
          status: (.status // null),
          require_pass: ($require_pass == "1"),
          proof_path: $proof_path,
          checked_contract: {
            public_schedule_tools: $proof_required_tools
          },
          errors: $errors
        }
    ' "$proof_path"
)" || fail "proof JSON is not parseable or validator failed: ${proof_path}"

if ! printf '%s' "$report" | jq -e '.ok == true' >/dev/null; then
  printf '%s\n' "$report" | jq . >&2
  exit 1
fi

printf '%s\n' "$report"
