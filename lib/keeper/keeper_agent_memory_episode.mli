(** Keeper_agent_memory_episode -- post-run episode persistence adapter.

    Keeps OAS memory persistence details out of [Keeper_agent_run],
    preserving the keeper runner as a thin orchestration layer. *)

(** Emit an [episode.flush] activity payload via [Workspace_hooks.activity_emit_fn].
    No-op if both [episodes] and [procedures] are zero. Logs and counts
    non-cancel exceptions, records a telemetry coverage-gap row, and
    re-raises [Eio.Cancel.Cancelled]. *)
val emit_flush_activity :
  config:Workspace_utils.config ->
  keeper_name:string ->
  turn:int ->
  ?oas_turn_count:int ->
  episodes:int ->
  procedures:int ->
  ?outcome:string ->
  tags:string list ->
  unit ->
  unit

(** Persist a successful turn snapshot as an OAS episode and flush incremental
    procedures. Logs and swallows non-cancel exceptions. *)
val record_success :
  config:Workspace_utils.config ->
  keeper_name:string ->
  memory:Agent_sdk.Memory.t ->
  turn:int ->
  ?oas_turn_count:int ->
  trace_id:string ->
  ?state_snapshot_source:string ->
  snapshot:Keeper_memory_policy.keeper_state_snapshot ->
  unit ->
  unit

(** Persist a failed-turn episode. Logs and swallows
    non-cancel exceptions. *)
val record_failure :
  config:Workspace_utils.config ->
  keeper_name:string ->
  memory:Agent_sdk.Memory.t ->
  turn:int ->
  ?oas_turn_count:int ->
  trace_id:string ->
  error_kind:Memory_oas_bridge.error_kind ->
  error_message:string ->
  unit ->
  unit
