(** Timeout policy for keeper shell surfaces. *)

val env_float : string -> float -> float

val io_timeout_sec : float
val read_timeout_sec : float
val user_timeout_max_sec : float
val tool_dispatch_min_timeout_sec : float
val keeper_shell_ir_native_min_timeout_sec : float
val keeper_shell_ir_min_timeout_sec_for_args : Yojson.Safe.t -> float
val git_meta_timeout_sec : float

val clamp_shell_timeout :
  ?min_sec:float -> default:float -> Yojson.Safe.t -> float
