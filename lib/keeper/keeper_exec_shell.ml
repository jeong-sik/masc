(* Facade: keeper_exec_shell — thin re-export layer.
   Types, constants, and helpers delegate to dedicated owner modules.
   [handle_keeper_shell_ir] lives in [Keeper_shell_bash].
   [handle_keeper_shell] lives in [Keeper_shell_ops].
   [handle_keeper_shell] lives in [Keeper_shell_ops]. *)

type shell_op = Keeper_shell_op.t =
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
  | Git_worktree

let shell_op_to_string = Keeper_shell_op.to_string
let all_shell_ops = Keeper_shell_op.all
let valid_shell_op_strings = Keeper_shell_op.valid_strings
let readonly_hint_of_category = Keeper_shell_readonly_policy.readonly_hint_of_category
let diagnosis_of_block_reason = Keeper_shell_readonly_policy.diagnosis_of_block_reason
let gh_min_timeout_sec = Keeper_shell_timeout.gh_min_timeout_sec
let keeper_shell_ir_native_min_timeout_sec = Keeper_shell_timeout.keeper_shell_ir_native_min_timeout_sec
let rewrite_turn_runtime_paths_to_host =
  Keeper_shell_runtime_paths.rewrite_turn_runtime_paths_to_host

let rewrite_docker_host_paths_to_container =
  Keeper_shell_runtime_paths.rewrite_docker_host_paths_to_container

include Keeper_shell_bash

include Keeper_shell_ops

module For_testing = struct
  let elapsed_duration_ms = Keeper_shell_bash.For_testing.elapsed_duration_ms
end
