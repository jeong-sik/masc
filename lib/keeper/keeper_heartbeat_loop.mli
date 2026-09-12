open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

val effective_keepalive_meta :
  base_path:string ->
  fallback:keeper_meta ->
  disk_meta_opt:keeper_meta option ->
  keeper_meta

val keeper_agent_status : keeper_meta -> Masc_domain.agent_status

val sync_keeper_presence :
  ctx:'a context ->
  meta_current:keeper_meta ->
  consecutive_failures:int ref ->
  keeper_meta

val collect_keepalive_board_events :
  ctx:'a context ->
  meta_current:keeper_meta ->
  proactive_warmup_elapsed:bool ->
  Keeper_world_observation.pending_board_event list * keeper_meta

val in_turn_liveness_pulse_interval_sec : unit -> float

val emit_in_turn_liveness_pulse :
  ctx:'a context -> meta:keeper_meta -> unit

val with_in_turn_liveness_pulse :
  ctx:'a context ->
  meta:keeper_meta ->
  stop:bool Atomic.t ->
  (unit -> 'b) -> 'b

type heartbeat_event_intake = {
  pending_board_events : Keeper_world_observation.pending_board_event list;
  source_batch : Keeper_heartbeat_source_batch.t;
  diagnostic_selection : Keeper_event_queue_state.pending_selection option;
  event_queue_intake_error :
    Keeper_heartbeat_stimulus_intake.event_queue_intake_error option;
  event_queue_triggers : Keeper_world_observation.event_queue_trigger list;
}

(** Closed pre-intake lifecycle result. *)
type turn_intake_admission =
  | Intake_admitted
  | Intake_lifecycle_blocked of Keeper_lifecycle_admission.autonomous_denial

val classify_turn_intake_admission :
  lifecycle:Keeper_lifecycle_admission.autonomous_admission ->
  turn_intake_admission

val heartbeat_event_intake :
  ctx:'a context ->
  meta_after_triage:keeper_meta ->
  pending_board_events:Keeper_world_observation.pending_board_event list ->
  heartbeat_event_intake

(** Source-authority gate applied after world scheduling. A durable selection
    failure blocks dispatch. A transient Board read remains pending but does
    not suppress other sources already admitted from the same snapshot; when
    it is the only source, no turn is dispatched. *)
val should_run_turn_after_event_intake :
  scheduled:bool ->
  consumed_stimulus_count:int ->
  event_queue_intake_error:
    Keeper_heartbeat_stimulus_intake.event_queue_intake_error option ->
  bool

type keepalive_scheduling_decision = {
  turn_decision : Keeper_world_observation.keeper_cycle_decision;
  should_run_turn : bool;
  verdict_reasons : string list;
  channel : string;
}

val decide_keepalive_scheduling :
  ?wake:Keeper_world_observation.cycle_wake ->
  ?event_queue_triggers:Keeper_world_observation.event_queue_trigger list ->
  stop:bool Atomic.t ->
  meta:keeper_meta ->
  Keeper_world_observation.world_observation ->
  keepalive_scheduling_decision

val provider_timeout_observation_reasons : string list

val record_provider_timeout_observation :
  base_path:string -> keeper_name:string -> unit

(** Closed accounting status for one keepalive cycle. Admission busy performs
    no turn accounting, crash accounting, or work-health refresh. *)
type keepalive_cycle_status =
  | Turn_cycle_completed
  | Turn_cycle_interrupted
  | Turn_cycle_crashed
  | Turn_cycle_busy of Keeper_owner.autonomous_block

type work_heartbeat_action =
  | Refresh_work_heartbeat
  | Preserve_work_heartbeat

type keepalive_cycle_action =
  | Defer_autonomous_work of Keeper_owner.autonomous_block
  | Skip_interrupted_turn
  | Record_turn_status of work_heartbeat_action

val decide_keepalive_cycle_action :
  keepalive_cycle_status -> keepalive_cycle_action
(** Total accounting decision used by the heartbeat effect shell. Completed
    cycles record and refresh. Operator-interrupted cycles record no turn
    status and do not refresh the work-health lease. Crashed cycles record
    while preserving the existing lease, and busy cycles retain their typed
    admission block without recording a turn. *)

val owner_turn_rejection_cycle_status :
  Keeper_owner_registry.command_error -> keepalive_cycle_status
(** Total: the cycle status an Owner-registry rejection of the autonomous
    turn records. [Command_rejected Owner_stopping] and
    [Command_lookup_failed Inventory_stopping] are the shutdown boundary and
    yield [Turn_cycle_completed]; every other rejection yields
    [Turn_cycle_crashed]. Never [Turn_cycle_interrupted] or
    [Turn_cycle_busy]. *)

(** Outcome of one keepalive cycle evaluation.

    [Turn_cycle_interrupted] is an expected operator cancellation: it does not
    record success or failure and leaves selected stimuli pending.
    [Turn_cycle_crashed] means the cycle's catch-all swallowed an exception to
    keep the keeper fiber alive (T6 audit), or a durable event-queue transition
    did not commit. The failure has already been recorded via the durable
    [Keeper_turn_failure_streak] boundary, so the caller dispatches
    [Turn_failed]. [Turn_cycle_busy] preserves its typed admission reason and
    must not dispatch either turn status or refresh the work-as-heartbeat
    lease. *)
(** What a provider retry route asks of the next sleep. A rate limit or
    exhausted quota is the provider's state, so the sleep runs to its end
    ([Serve_wakeup_after_duration], #34653); capacity backpressure also comes
    from MASC's own slot and client capacity envelopes, which clear on their
    own, so that sleep stays [Interrupt_on_wakeup]. *)
type provider_backoff =
  { retry_after_hint : float
  ; wake_policy : Keeper_keepalive_signal.wake_policy
  }

type keepalive_turn_outcome = {
  meta : keeper_meta;
  cycle_status : keepalive_cycle_status;
  stimuli_acked : bool;
      (** The cycle admitted at least one event-queue stimulus and acked
          every entry of that batch on completion. The loop reads it to
          skip the cadence sleep while more entries are pending. *)
  provider_backoff : provider_backoff option;
      (** [Some backoff] when the cycle's turn failure routed as a provider
          retry ([Retry_after_observed] with a [Rate_limited] / [Hard_quota] /
          [Capacity_backpressure] class), carrying the route's own
          [Retry-After] hint when the provider sent one ([0.0] when it did
          not) and the wake policy the class implies. The loop replaces the
          plain cadence with a capped backoff for such a cycle (#26068);
          [None] keeps the cadence. *)
}

(** Record a swallowed keepalive-cycle exception as a turn failure:
    increments the registry turn-failure counter (shared with
    [Keeper_unified_turn_failure]), bumps the CycleExceptions counter
    and logs at ERROR. Does not raise. *)
val record_crashed_cycle_failure :
  base_path:string -> keeper_name:string -> exn -> unit

(** Convert an exception escaping one autonomous cycle into its accounting
    outcome. Operator interrupts are expected cancellation and do not mutate
    the turn-failure counter; every other exception is recorded as a crash. *)
val handle_cycle_exception :
  base_path:string -> meta:keeper_meta -> exn -> keepalive_turn_outcome

type batch_disposition =
  | Batch_ack_completed
  | Batch_ack_attention_only
  | Batch_no_action

val batch_disposition_of_cycle_outcome :
  Keeper_heartbeat_loop_cycle.cycle_outcome option -> batch_disposition
(** The queue action a turn's [cycle_outcome] implies. A completed turn ACKs
    its whole admitted batch, Connector attention included, whatever its
    continuation route: the turn projected every row and chose its actions
    with them in view, and whether it answered is not a reason to deliver
    the same rows again (#34655). Whether it answered is not durably recorded
    yet; #34666 tracks that projection. Every typed checkpoint (durable stimulus arrived, loop guard,
    Gate-deferred tool call, queued chat operation) ACKs attention-only
    sources after preserving the continuation, because each one is produced
    after a model round ran with the admitted batch projected (the agent-core
    checkpoint carries it; an official-client vendor session carries it
    unless that session restarts before the resume); Connector_attention
    stays pending until the resumed turn completes, and a HITL resolution
    stays pending until its continuation receipt is recorded. Every failed,
    cancelled, input-required, or skipped outcome leaves the whole batch
    pending. Provider/runtime failure is not authority to discard input. *)

type continuation_settlement =
  | Continuation_settled_recorded
  | Continuation_settled_failed of
      { route : Keeper_runtime_failure_route.route }
  | Continuation_unsettled

val continuation_settlement_of_cycle_outcome :
  Keeper_heartbeat_loop_cycle.cycle_outcome option -> continuation_settlement
(** How the turn settles the HITL continuation it was handed.
    [Continuation_settled_recorded] follows the batch disposition above: a
    completed or checkpointed turn. [Continuation_settled_failed] is a failed
    turn whose route satisfies {!Keeper_runtime_failure_route.response_observed}:
    the provider answered the request that carried the replay evidence, so
    the evidence is not carried into the next cycle (#32956). Every other
    failure, and every cancelled, input-required, or skipped outcome, leaves
    the continuation unsettled. The queue disposition of a failed turn stays
    [Batch_no_action] either way. *)

(** Pure: post-turn status event derived from the registry
    turn-failure counter. [turn_fail_count > 0] maps to [Turn_failed];
    [0] maps to [Turn_succeeded]. *)
val turn_status_event :
  turn_fail_count:int -> Keeper_state_machine.event

val failure_reason_after_turn_status :
  turn_fail_count:int ->
  Keeper_registry.failure_reason option ->
  Keeper_registry.failure_reason option
(** Preserve a typed configuration root cause when the post-turn heartbeat
    records its generic consecutive-failure observation. Other failures keep
    the existing consecutive-count projection. *)

(** Runs one keepalive turn (event intake, scheduling, optional cycle dispatch).
    The caller classifies lifecycle state and fd/disk pressure
    with {!classify_turn_intake_admission} BEFORE this is invoked, so this
    function must not re-add inline admission gates: doing so would reinstate
    the consume-before-gate churn that hoisting the decision removed. *)
val run_keepalive_unified_turn :
  wake:Keeper_world_observation.cycle_wake ->
  ctx:'a context ->
  meta_after_triage:keeper_meta ->
  pending_board_events:Keeper_world_observation.pending_board_event list ->
  stop:bool Atomic.t ->
  proactive_warmup_elapsed:bool ->
  reactive_wake:bool ->
  shared_context:Agent_core.Context.t ->
  deferred_runtime_lane:Keeper_turn_driver.deferred_runtime_lane option ->
  on_deferred_runtime_consumed:(unit -> unit) ->
  record_deferred_runtime_lane:
    (Keeper_turn_driver.deferred_runtime_lane -> unit) ->
  keepalive_turn_outcome
(** Why the last turn that ran ended before completing is no longer this
    loop's state: {!Keeper_heartbeat_loop_cycle.run_keeper_cycle} records it
    into {!Keeper_last_turn_stop} after every cycle it runs, on every lane,
    and reads it back for the next turn's prompt. *)

val refresh_work_as_heartbeat :
  ctx:'a context ->
  meta_after_proactive:keeper_meta ->
  proactive_warmup_elapsed:bool ->
  work_as_hb:(unit -> bool) ->
  consecutive_failures:int ref ->
  unit

val maybe_write_heartbeat_snapshot :
  ctx:'a context ->
  meta_current:keeper_meta ->
  now_ts:float ->
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
  unit

(** The heartbeat loop body, extracted for reuse by the supervisor.
    Runs synchronously in the calling fiber until [stop] becomes true. *)
val run_heartbeat_loop :
  proactive_warmup_sec:int -> 'a context -> keeper_meta -> bool Atomic.t ->
  wakeup:bool Atomic.t -> cadence_sleeping:bool Atomic.t -> unit

module For_testing : sig
  (** The production retention pass against the durable queue. Counts are
      observations only; no pending source is acknowledged by this pass. *)
  val retain_connector_attention_sources :
    base_path:string -> keeper_name:string ->
    Keeper_event_queue_state.pending_selection list -> unit

  (** Whether post-turn HITL settlement may project a continuation before its
      queue source is acknowledged. *)
  val batch_disposition_records_continuation : batch_disposition -> bool

  (** During autoboot warmup, the next cycle runs at the warmup boundary rather
      than one full heartbeat cadence later. [rate_limited_backoff_sec] is the
      already-capped backoff to sleep instead of the plain cadence after a
      rate-limited failure cycle; pass [cadence_sec] to preserve the plain
      cadence behavior. *)
  val next_keepalive_sleep_duration_sec :
    proactive_warmup_sec:int ->
    proactive_warmup_elapsed:bool ->
    keepalive_started_ts:float ->
    now_ts:float ->
    cadence_sec:float ->
    rate_limited_backoff_sec:float ->
    float

  (** Capped backoff for a rate-limited failure route (#26068). Prefers the
      provider's [Retry-After] hint when above the cadence, falls back to a
      bounded default, and clamps the result to [cap_sec] so a misread header
      can never park the lane. *)
  val failure_route_rate_limited_backoff_hint :
    Keeper_unified_turn.turn_failure -> provider_backoff option

  (** Deferred runtime lane hints have nothing to do with continuation
      delivery; they only shared this module with it. The implementation and
      its live caller both remain, so the export stays too. *)
  val consume_deferred_runtime_lane_hint :
    Keeper_turn_driver.deferred_runtime_lane option ref ->
    Keeper_turn_driver.deferred_runtime_lane ->
    bool
end
