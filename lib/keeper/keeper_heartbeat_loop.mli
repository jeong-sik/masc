open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

val effective_keepalive_meta :
  base_path:string ->
  fallback:keeper_meta ->
  disk_meta_opt:keeper_meta option ->
  keeper_meta

val repair_identity_drift_for_keepalive :
  ?lifecycle_token:Keeper_lifecycle_reservation.token ->
  ctx:'a context ->
  keeper_meta ->
  keeper_meta option

val keeper_agent_status : keeper_meta -> Masc_domain.agent_status

val repair_identity_drift_for_keepalive :
  ?lifecycle_token:Keeper_lifecycle_reservation.token ->
  ctx:'a context ->
  keeper_meta ->
  keeper_meta option

val sync_keeper_presence :
  ctx:'a context ->
  meta_current:keeper_meta ->
  consecutive_failures:int ref ->
  last_successful_heartbeat_ts:float ref ->
  keeper_meta

val collect_keepalive_board_events :
  ctx:'a context ->
  meta_current:keeper_meta ->
  proactive_warmup_elapsed:bool ->
  approval_pending:bool ->
  keeper_backpressured:bool ->
  provider_cooldown_pending:bool ->
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

type heartbeat_event_intake = {
  pending_board_events : Keeper_world_observation.pending_board_event list;
  consumed_stimulus_count : int;
  consumed_stimuli : Keeper_event_queue.stimulus list;
  claimed_lease : Keeper_registry_event_queue.lease option;
  event_queue_claim_error : string option;
  event_queue_triggers : Keeper_world_observation.event_queue_trigger list;
}

type single_claim_admission =
  | Admit_ready_single
  | Defer_failure_judgment

(** Closed pre-intake admission result. Blocking approval and explicit Keeper
    pause are classified before durable dequeue, just like fd/disk pressure, so
    a blocked cycle does not repeatedly lease and requeue the same stimulus. *)
type turn_intake_admission =
  | Intake_admitted
  | Intake_lifecycle_blocked of Keeper_lifecycle_admission.autonomous_denial
  | Intake_pressure_blocked of Keeper_pressure_admission.block
  | Intake_blocking_approval_pending
  | Intake_keeper_paused

val classify_turn_intake_admission :
  lifecycle:Keeper_lifecycle_admission.autonomous_admission ->
  pressure:Keeper_pressure_admission.decision ->
  blocking_approval_pending:bool ->
  keeper_paused:bool ->
  turn_intake_admission

val heartbeat_event_intake :
  single_claim_admission:single_claim_admission ->
  ctx:'a context ->
  meta_after_triage:keeper_meta ->
  pending_board_events:Keeper_world_observation.pending_board_event list ->
  heartbeat_event_intake

type keepalive_scheduling_decision = {
  turn_decision : Keeper_world_observation.keeper_cycle_decision;
  requested_should_run_turn : bool;
  runtime_backpressure : Keeper_heartbeat_loop_observations.runtime_backpressure_decision;
  pacing_block : float option;
  should_run_turn : bool;
  verdict_reasons : string list;
  channel : string;
}

val decide_keepalive_scheduling :
  ?runtime_id_of_meta:(keeper_meta -> string) ->
  ?runtime_resilience_of_name:(string -> string option) ->
  ?keeper_resilience_of_name:(string -> string option) ->
  ?pacing_block_of_name:(string -> float option) ->
  ?reactive_wake:bool ->
  ?event_queue_triggers:Keeper_world_observation.event_queue_trigger list ->
  stop:bool Atomic.t ->
  meta:keeper_meta ->
  Keeper_world_observation.world_observation ->
  keepalive_scheduling_decision

val provider_timeout_observation_reasons : string list

val record_provider_timeout_observation :
  base_path:string -> keeper_name:string -> unit

val provider_timeout_policy_decision :
  strikes:int -> Agent_sdk.Error.sdk_error -> Keeper_failure_policy.decision option
(** Return the policy decision for a structured provider-timeout error.
    This heartbeat-loop path is reached after the keeper turn returned, so
    timeout evidence is not liveness loss by itself. *)

(** Outcome of one keepalive cycle evaluation.

    [cycle_crashed = true] means the cycle's catch-all swallowed an
    exception to keep the keeper fiber alive (T6 audit), or a durable
    event-queue claim/settlement did not commit. The failure has
    already been recorded via
    [Keeper_registry.increment_turn_failures] — the same counter the
    unified-turn failure path uses — so the caller dispatches
    [Turn_failed]. Such a cycle must not refresh the
    work-as-heartbeat lease. *)
type keepalive_turn_outcome = {
  meta : keeper_meta;
  cycle_crashed : bool;
}

(** Record a swallowed keepalive-cycle exception as a turn failure:
    increments the registry turn-failure counter (shared with
    [Keeper_unified_turn_failure]), bumps the CycleExceptions counter
    and logs at ERROR. Does not raise. *)
val record_crashed_cycle_failure :
  base_path:string -> keeper_name:string -> exn -> unit

val settlement_of_failure :
  settled_at:float ->
  Keeper_unified_turn.turn_failure ->
  Keeper_registry_event_queue.settlement
(** Pure queue disposition for a failed cycle. Retry/rotation requeue and a
    deterministic failure creates one judgment successor. This mapping is
    identical when the source lease carried an earlier judgment: the failed
    action's new typed route remains authoritative rather than being collapsed
    into a generic judgment failure. *)

val settlement_of_cycle_outcome :
  settled_at:float ->
  stop_requested:bool ->
  lease:Keeper_registry_event_queue.lease ->
  Keeper_heartbeat_loop_cycle.cycle_outcome option ->
  Keeper_registry_event_queue.settlement
(** Pure lease settlement boundary. Completed work acknowledges; typed
    cancellation and non-executable-phase skips requeue. *)

val project_transition_outbox :
  base_path:string -> keeper_name:string -> (unit, string) result
(** Idempotently materialize the lane's single durable transition into the
    reaction ledger, then retire the outbox entry. New claims remain blocked
    while this projection is incomplete. *)

(** Pure: post-turn status event derived from the registry
    turn-failure counter. [turn_fail_count > 0] maps to [Turn_failed];
    [0] maps to [Turn_succeeded]. *)
val turn_status_event :
  turn_fail_count:int -> max_allowed:int -> Keeper_state_machine.event

(** Runs one keepalive turn (event intake, scheduling, optional cycle dispatch).
    The caller classifies lifecycle state, fd/disk pressure, and typed Blocking HITL ownership
    with {!classify_turn_intake_admission} BEFORE this is invoked, so this
    function must not re-add inline admission gates: doing so would reinstate
    the consume-before-gate churn that hoisting the decision removed. *)
val run_keepalive_unified_turn :
  ctx:'a context ->
  meta_after_triage:keeper_meta ->
  pending_board_events:Keeper_world_observation.pending_board_event list ->
  stop:bool Atomic.t ->
  proactive_warmup_elapsed:bool ->
  reactive_wake:bool ->
  shared_context:Agent_sdk.Context.t ->
  keepalive_turn_outcome

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

(** Pure: whether a [Keeper_heartbeat_smart] decision should allow the keepalive
    cycle (presence/snapshot/board/turn/recurring) to run.

    Contract: [Skip_busy] -> [true] (cycle continues).
    [Skip_idle] -> [false] (keeper idle, back off).
    [Emit] -> [true]. *)
val smart_heartbeat_cycle_continues : Keeper_heartbeat_smart.decision -> bool

(** Pure: post-sleep refinement of [smart_heartbeat_cycle_continues] that
    closes the [MissedWakeup] gap in [KeeperHeartbeat.tla].

    The base helper is computed before the idle sleep, but during a
    [Skip_idle] sleep an external [wakeup_keeper] / board signal can
    flip the wakeup atomic — [interruptible_sleep] returns [Woken] in
    that case. The spec's honest [HeartbeatTick] action requires
    [turn_state' = "running"] when wakeup is consumed, so the cycle
    must continue even though the original decision was [Skip_idle].
    This sibling of #10078 (which lifted the same restriction for
    [Skip_busy]) closes the [Skip_idle] half intentionally left open
    by that fix.

    Contract: returns the base decision unchanged for [Skip_busy] and
    [Emit]; for [Skip_idle], promotes to [true] iff the sleep ended
    with [Woken] (not [Timeout] / [Stopped]). *)
val cycle_continues_after_wake :
  Keeper_heartbeat_smart.decision -> Keeper_keepalive_signal.sleep_outcome -> bool

val visible_consumer_count : unit -> int

val visibility_gate_decision :
  visible_consumers:int ->
  has_pending_signal:bool ->
  now:float ->
  last_heartbeat_cycle_ts:float ->
  Keeper_heartbeat_smart.decision ->
  Keeper_heartbeat_smart.decision

val run_smart_heartbeat_gate :
  config:Workspace.config ->
  clock:'a Eio.Time.clock ->
  stop:bool Atomic.t ->
  wakeup:bool Atomic.t ->
  meta_current:keeper_meta ->
  smart_hb_enabled:(unit -> bool) ->
  smart_hb_config:Keeper_heartbeat_smart.config ->
  last_successful_heartbeat_ts:float ref ->
  last_heartbeat_cycle_ts:float ref ->
  wake_source:Keeper_keepalive_signal.sleep_outcome ref ->
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
