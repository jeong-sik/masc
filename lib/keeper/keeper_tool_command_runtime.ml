(* Facade: keeper_tool_command_runtime — thin re-export layer.
   Types, constants, and helpers delegate to dedicated owner modules.
   [handle_tool_execute] lives in [Keeper_tool_execute_runtime].
   [handle_tool_search_files] lives in [Keeper_workspace_ops]. *)

let rewrite_turn_runtime_paths_to_host =
  Keeper_tool_execute_runtime_paths.rewrite_turn_runtime_paths_to_host

let rewrite_docker_host_paths_to_container =
  Keeper_tool_execute_runtime_paths.rewrite_docker_host_paths_to_container

(* TEL-OK: facade alias only; the Execute handler owns
   execution telemetry and history recording. *)
let handle_tool_execute = Keeper_tool_execute_runtime.handle_tool_execute
let handle_tool_execute_with_outcome = Keeper_tool_execute_runtime.handle_tool_execute_with_outcome

include Keeper_workspace_ops

module For_testing = struct
  let elapsed_duration_ms = Keeper_tool_execute_runtime.For_testing.elapsed_duration_ms
end
