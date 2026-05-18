(** Fail-open cascade routing helpers for keeper turn budgeting. *)

module EC = Keeper_error_classify

val fail_open_rotation_cascades_from_catalog
  :  ?excluded_targets:string list
  -> catalog_names:string list
  -> keeper_assignable:string list
  -> unit
  -> string list option

val active_fail_open_rotation_cascades : unit -> string list option

val next_fail_open_cascade_for_turn
  :  ?rotation_cascades:string list
  -> base_cascade:string
  -> effective_cascade:string
  -> tool_requirement:Keeper_agent_tool_surface.tool_requirement
  -> attempted_cascades:string list
  -> Agent_sdk.Error.sdk_error
  -> EC.degraded_retry option

val sdk_error_kind : Agent_sdk.Error.sdk_error -> string

val record_turn_failure_stress
  :  meta:Keeper_types.keeper_meta
  -> is_auto_recoverable:bool
  -> consecutive:int
  -> threshold:int
  -> err:Agent_sdk.Error.sdk_error
  -> unit
