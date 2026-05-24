(* Facade: keeper_exec_shell — thin re-export layer.
   Types, constants, and helpers live in [Keeper_shell_shared].
   [handle_keeper_shell_ir] lives in [Keeper_shell_bash].
   [handle_keeper_shell] lives in [Keeper_shell_ops].
   [handle_keeper_shell] lives in [Keeper_shell_ops]. *)

include Keeper_shell_shared

let keeper_shell_ir_native_min_timeout_sec = keeper_bash_native_min_timeout_sec

include Keeper_shell_bash

include Keeper_shell_ops

module For_testing = struct
  let elapsed_duration_ms = Keeper_shell_bash.For_testing.elapsed_duration_ms
end
