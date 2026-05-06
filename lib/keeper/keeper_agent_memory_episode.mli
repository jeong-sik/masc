(** Keeper_agent_memory_episode -- post-run episode persistence adapter.

    Keeps OAS memory persistence details out of [Keeper_agent_run],
    preserving the keeper runner as a thin orchestration layer. *)

(** Emit an [episode.flush] activity payload via [Coord_hooks.activity_emit_fn].
    No-op if both [episodes] and [procedures] are zero. Logs and counts
    non-cancel exceptions; re-raises [Eio.Cancel.Cancelled]. *)
val emit_flush_activity :
  config:Coord_utils.config ->
  keeper_name:string ->
  turn:int ->
  episodes:int ->
  procedures:int ->
  ?outcome:string ->
  tags:string list ->
  unit ->
  unit

(** Persist a successful turn snapshot as an OAS episode and flush incremental
    procedures. Logs and swallows non-cancel exceptions. *)
val record_success :
  config:Coord_utils.config ->
  keeper_name:string ->
  memory:Agent_sdk.Memory.t ->
  turn:int ->
  trace_id:string ->
  snapshot:Keeper_memory_policy.keeper_state_snapshot ->
  unit ->
  unit

(** Classify [error_kind] into the matching {!Agent_stress.stress_kind}.
    Returns [None] for kinds that do not map to a pre-existing stress
    dimension. *)
val stress_kind_of_error_kind :
  Memory_oas_bridge.error_kind -> Agent_stress.stress_kind option

(** Persist a failed-turn episode and surface the failure to
    [Agent_stress] for non-keepalive failure modes. Logs and swallows
    non-cancel exceptions. *)
val record_failure :
  config:Coord_utils.config ->
  keeper_name:string ->
  memory:Agent_sdk.Memory.t ->
  turn:int ->
  trace_id:string ->
  error_kind:Memory_oas_bridge.error_kind ->
  error_message:string ->
  unit ->
  unit
