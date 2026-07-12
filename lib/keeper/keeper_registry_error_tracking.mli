(** Error/failure tracking mutations for {!Keeper_registry}.

    The central registry owns the Atomic CAS loop. This sibling module owns
    the field-level update logic; callers pass the parent CAS helper into each
    function. *)

open Keeper_registry_types

val record_crash_entry : registry_entry -> float -> string -> registry_entry

val mark_dead :
  base_path:string ->
  string ->
  at:float ->
  decr_running_count_clamped:(unit -> unit) ->
  update_entry:(base_path:string -> string -> (registry_entry -> registry_entry) -> unit) ->
  unit

val record_restart :
  base_path:string ->
  string ->
  update_entry:(base_path:string -> string -> (registry_entry -> registry_entry) -> unit) ->
  unit

val set_last_error_entry :
  base_path:string ->
  name:string ->
  string ->
  update_entry:(base_path:string -> string -> (registry_entry -> registry_entry) -> unit) ->
  unit

val clear_error :
  base_path:string ->
  string ->
  update_entry:(base_path:string -> string -> (registry_entry -> registry_entry) -> unit) ->
  unit

val set_failure_reason :
  base_path:string ->
  string ->
  failure_reason option ->
  update_entry:(base_path:string -> string -> (registry_entry -> registry_entry) -> unit) ->
  unit

val set_last_correlation_id :
  base_path:string ->
  string ->
  string ->
  update_entry:(base_path:string -> string -> (registry_entry -> registry_entry) -> unit) ->
  unit

val record_crash :
  base_path:string ->
  string ->
  float ->
  string ->
  update_entry:(base_path:string -> string -> (registry_entry -> registry_entry) -> unit) ->
  unit

val restore_supervisor_state :
  base_path:string ->
  string ->
  restart_count:int ->
  last_restart_ts:float ->
  crash_log:(float * string) list ->
  update_entry:(base_path:string -> string -> (registry_entry -> registry_entry) -> unit) ->
  unit
