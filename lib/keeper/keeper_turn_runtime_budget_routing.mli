(** Typed fail-open runtime rotation helpers. *)

module EC = Keeper_error_classify

val next_fail_open_runtime_for_turn
  :  base_runtime:string
  -> effective_runtime:string
  -> attempted_runtimes:string list
  -> Masc_agent_core.Error.sdk_error
  -> EC.degraded_retry option

val sdk_error_kind : Masc_agent_core.Error.sdk_error -> string
