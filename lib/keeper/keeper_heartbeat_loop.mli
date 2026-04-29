open Keeper_types

val effective_keepalive_meta :
  base_path:string ->
  fallback:keeper_meta ->
  disk_meta_opt:keeper_meta option ->
  keeper_meta

val repair_identity_drift_for_keepalive :
  ctx:'a context -> keeper_meta -> keeper_meta option

val keeper_agent_status : keeper_meta -> Types.agent_status

val repair_identity_drift_for_keepalive :
  ctx:'a context -> keeper_meta -> keeper_meta option

val sync_keeper_presence :
  ctx:'a context ->
  meta_current:keeper_meta ->
  t_presence_start:float ->
  consecutive_failures:int ref ->
  last_successful_heartbeat_ts:float ref ->
  work_as_hb:(unit -> bool) ->
  max_silence:(unit -> float) ->
  keeper_meta

val collect_keepalive_board_events :
  ctx:'a context ->
  meta_current:keeper_meta ->
  proactive_warmup_elapsed:bool ->
  Keeper_world_observation.pending_board_event list * keeper_meta

val in_turn_liveness_pulse_interval_sec : unit -> float

val with_in_turn_liveness_pulse_for_test :
  sw:Eio.Switch.t ->
  clock:'a Eio.Time.clock ->
  interval_sec:float ->
  tick:(unit -> unit) ->
  (unit -> 'b) ->
  'b

val emit_in_turn_liveness_pulse :
  ctx:'a context -> meta:keeper_meta -> unit

val with_in_turn_liveness_pulse :
  ctx:'a context ->
  meta:keeper_meta ->
  stop:bool Atomic.t ->
  (unit -> 'b) -> 'b

val run_keepalive_unified_turn :
  ctx:'a context ->
  meta_after_triage:keeper_meta ->
  pending_board_events:Keeper_world_observation.pending_board_event list ->
  stop:bool Atomic.t ->
  proactive_warmup_elapsed:bool ->
  shared_context:Oas.Context.t ->
  keeper_meta

val refresh_work_as_heartbeat :
  ctx:'a context ->
  meta_after_proactive:keeper_meta ->
  proactive_warmup_elapsed:bool ->
  work_as_hb:(unit -> bool) ->
  last_successful_heartbeat_ts:float ref ->
  consecutive_failures:int ref ->
  unit

val dispatch_recurring_keepalive :
  ctx:'a context ->
  meta_after_proactive:keeper_meta ->
  now_ts:float ->
  int

(** Pure: whether a [Heartbeat_smart] decision should allow the keepalive
    cycle (presence/snapshot/board/turn/recurring) to run.

    Contract: [Skip_busy] -> [true] (cycle continues).
    [Skip_idle] -> [false] (keeper idle, back off).
    [Emit] -> [true]. *)
val smart_heartbeat_cycle_continues : Heartbeat_smart.decision -> bool

val run_smart_heartbeat_gate :
  clock:'a Eio.Time.clock ->
  stop:bool Atomic.t ->
  wakeup:bool Atomic.t ->
  meta_current:keeper_meta ->
  smart_hb_enabled:(unit -> bool) ->
  smart_hb_config:Heartbeat_smart.config ->
  last_successful_heartbeat_ts:float ref ->
  last_heartbeat_cycle_ts:float ref ->
  bool

val maybe_write_heartbeat_snapshot :
  ctx:'a context ->
  meta_current:keeper_meta ->
  now_ts:float ->
  consecutive_hb_failures:int ->
  last_snapshot_ts:float ref ->
  snapshot_interval_sec:int ->
  timing_ring:Keeper_keepalive_signal.stage_timing array ->
  timing_filled:int ->
  unit

val record_keepalive_stage_timing :
  timing_ring:Keeper_keepalive_signal.stage_timing array ->
  timing_cursor:int ref ->
  timing_filled:int ref ->
  ring_sz:int ->
  t_presence_start:float ->
  t_presence_end:float ->
  t_snapshot_start:float ->
  t_snapshot_end:float ->
  t_board_start:float ->
  t_board_end:float ->
  t_turn_start:float ->
  t_turn_end:float ->
  t_recurring_start:float ->
  t_recurring_end:float ->
  unit

(** The heartbeat loop body, extracted for reuse by the supervisor.
    Runs synchronously in the calling fiber until [stop] becomes true. *)
val run_heartbeat_loop :
  proactive_warmup_sec:int -> 'a context -> keeper_meta -> bool Atomic.t ->
  wakeup:bool Atomic.t -> unit
