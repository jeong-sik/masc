(* Facade: agent_tool_shell_runtime — thin re-export layer.
   Types, constants, and helpers delegate to dedicated owner modules.
   [handle_tool_execute] lives in [Agent_tool_execute_runtime].
   [handle_tool_search_files] lives in [Keeper_workspace_ops]. *)

type shell_op = Keeper_workspace_op.t =
  | Pwd
  | Ls
  | Cat
  | Rg
  | Git_status
  | Find
  | Head
  | Tail
  | Wc
  | Tree
  | Git_log
  | Git_diff

let shell_op_to_string = Keeper_workspace_op.to_string
let all_shell_ops = Keeper_workspace_op.all
let valid_shell_op_strings = Keeper_workspace_op.valid_strings
let readonly_hint_of_category = Keeper_shell_readonly_policy.readonly_hint_of_category
let diagnosis_of_block_reason = Keeper_shell_readonly_policy.diagnosis_of_block_reason
let tool_dispatch_min_timeout_sec = Keeper_shell_timeout.tool_dispatch_min_timeout_sec
let keeper_shell_ir_native_min_timeout_sec = Keeper_shell_timeout.keeper_shell_ir_native_min_timeout_sec
let rewrite_turn_runtime_paths_to_host =
  Keeper_shell_runtime_paths.rewrite_turn_runtime_paths_to_host

let rewrite_docker_host_paths_to_container =
  Keeper_shell_runtime_paths.rewrite_docker_host_paths_to_container

(* TEL-OK: facade alias only; the Execute handler owns
   execution telemetry and history recording. *)
let handle_tool_execute = Agent_tool_execute_runtime.handle_tool_execute

include Keeper_workspace_ops

module For_testing = struct
  let elapsed_duration_ms = Agent_tool_execute_runtime.For_testing.elapsed_duration_ms
  let deterministic_retry_fields_for_process_result =
    Agent_tool_execute_runtime.For_testing.deterministic_retry_fields_for_process_result
end
