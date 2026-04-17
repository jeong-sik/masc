(** Capability — what the shell command will actually do, from policy's view.

    Capability_check.of_ir walks a [Shell_ir.t] and returns the full
    list of capabilities produced.  The walker must be exhaustive: when
    a new [Shell_ir] arm is added the compiler rejects the walker until
    the policy maps it. *)

type t =
  | Read_path of Path_scope.t
  | Write_path of Path_scope.t * Redirect_scope.mode
  | Exec_bin of Bin.t * Shell_ir.arg list
  | Git of Git_op.t
  | Env_set of string * Shell_ir.arg
  | Pipeline_fold of t list

val pp : Format.formatter -> t -> unit
