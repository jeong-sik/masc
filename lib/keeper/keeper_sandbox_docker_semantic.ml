open Keeper_types
open Agent_tool_shared_runtime

let docker_command_semantic_status ~cmd ~status ~output =
  Exec_core.semantic_status_of_process ~cmd ~output status

let semantic_ok_of_status = function
  | Exec_core.Ok | Exec_core.No_match -> true
  | Exec_core.Partial | Exec_core.Blocked | Exec_core.Timeout | Exec_core.Runtime_error ->
    false
