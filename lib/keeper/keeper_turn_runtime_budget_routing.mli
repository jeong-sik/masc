(** Fail-open runtime routing helpers for keeper turn budgeting. *)

module EC = Keeper_error_classify

val next_fail_open_runtime_for_turn
  :  base_runtime:string
  -> effective_runtime:string
  -> tool_requirement:Keeper_agent_tool_surface.tool_requirement
  -> attempted_runtimes:string list
  -> Agent_sdk.Error.sdk_error
  -> EC.degraded_retry option

val sdk_error_kind : Agent_sdk.Error.sdk_error -> string

val record_turn_failure_stress
  :  meta:Keeper_meta_contract.keeper_meta
  -> is_auto_recoverable:bool
  -> consecutive:int
  -> threshold:int
  -> err:Agent_sdk.Error.sdk_error
  -> unit
