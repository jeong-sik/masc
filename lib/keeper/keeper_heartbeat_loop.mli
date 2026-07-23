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

type keepalive_scheduling_decision = {
  turn_decision : Keeper_world_observation.keeper_cycle_decision;
  should_run_turn : bool;
  verdict_reasons : string list;
  channel : string;
}

val decide_keepalive_scheduling :
  ?reactive_wake:bool ->
  ?event_queue_triggers:Keeper_world_observation.event_queue_trigger list ->
  stop:bool Atomic.t ->
  meta:keeper_meta ->
  Keeper_world_observation.world_observation ->
  keepalive_scheduling_decision

val provider_timeout_observation_reasons : string list

val record_provider_timeout_observation :
  base_path:string -> keeper_name:string -> unit

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
  compaction_consecutive_failures:int ->
  transcript_quarantine_consecutive_retries:int ->
  Keeper_unified_turn.turn_failure ->
  Keeper_registry_event_queue.settlement
(** Pure queue disposition for a failed cycle. Retry/rotation requeue and a
    deterministic failure creates one judgment successor. This mapping is
    identical when the source lease carried an earlier judgment: the failed
    action's new typed route remains authoritative rather than being collapsed
    into a generic judgment failure.

    [compaction_consecutive_failures] is the keeper's persisted failure streak
    from [keeper_meta.runtime.compaction_rt]. When the disposition carries an
    in-lane provider-overflow compaction outcome that made no durable progress
    ([Compaction_attempt_failed] or a terminal no-compaction), the settlement
    escalates as [Compaction_retry_exhausted] once this failure would reach
    [Keeper_meta_contract.compaction_retry_escalation_threshold] — without the
    ceiling this lane requeues forever, one summarizer LLM call per heartbeat
    cycle (RFC-0351 S0, #25461; 2026-07-21 storm: 284 provider-overflow
    rejections over ~10h, ended only by operator keeper_down). A
    [Compaction_committed] disposition requeues below the threshold so the retry
    reloads a durably smaller checkpoint; at the threshold it escalates as
    [Compaction_floor_exceeded]. [Escalate_after_exact_output_terminal] ignores
    the ordinary route and immediately settles as a typed escalation with no
    successor.

    [transcript_quarantine_consecutive_retries] is the keeper's persisted
    quarantine streak from
    [keeper_meta.runtime.transcript_quarantine_consecutive_retries]. A
    [Requeue_after_transcript_quarantine] disposition requeues below
    [Keeper_meta_contract.transcript_quarantine_retry_escalation_threshold]
    and escalates as [Transcript_quarantine_retry_exhausted] at it — the
    poisoned checkpoint is preserved unmodified by design, so without the
    ceiling the same stimulus loops through the full turn pipeline on every
    heartbeat (#25296). *)

val compaction_outcome_of_cycle_outcome :
  Keeper_heartbeat_loop_cycle.cycle_outcome option ->
  [ `Committed | `Overflow_episode_committed | `Failed | `Recovered ] option
(** Pure mapping from a settled cycle outcome to the compaction-streak stamp
    ([Keeper_meta_store.persist_compaction_outcome]). Manual-lane
    applied/failed outcomes and in-lane provider-overflow dispositions join
    the same per-keeper streak. The streak counts consecutive
    provider-overflow episodes (#25538): an in-lane commit maps to
    [`Overflow_episode_committed] (advances the streak — committed savings
    under an incompressible floor must still reach the ceiling), a completed
    overflow-free turn maps to [`Recovered] (resets it), and only the
    operator's manual commit maps to [`Committed] (count + reset).
    Outcomes with no compaction involvement return [None]. *)

val transcript_quarantine_outcome_of_cycle_outcome :
  Keeper_heartbeat_loop_cycle.cycle_outcome option ->
  [ `Retried | `Recovered ] option
(** Pure mapping from a settled cycle outcome to the transcript-quarantine
    streak stamp
    ({!Keeper_meta_store.persist_transcript_quarantine_outcome}). A failed
    turn with a [Requeue_after_transcript_quarantine] disposition maps to
    [`Retried] (advances the streak — the settlement reads it to escalate
    instead of requeuing at
    [Keeper_meta_contract.transcript_quarantine_retry_escalation_threshold]);
    a completed turn maps to [`Recovered] (resets it — the keeper is no
    longer pinned to the poisoned transcript). Outcomes with no quarantine
    involvement return [None] (#25296). *)

val settlement_of_cycle_outcome :
  base_path:string ->
  settled_at:float ->
  stop_requested:bool ->
  compaction_consecutive_failures:int ->
  transcript_quarantine_consecutive_retries:int ->
  lease:Keeper_registry_event_queue.lease ->
  Keeper_heartbeat_loop_cycle.cycle_outcome option ->
  Keeper_registry_event_queue.settlement
(** Pure lease settlement boundary. Completed work acknowledges; typed
    cancellation and non-executable-phase skips requeue.

    [compaction_consecutive_failures] is the keeper's current failure streak
    from [keeper_meta.runtime.compaction_rt]. A manual-compaction failure — or
    a failed cycle whose disposition carries a no-progress in-lane compaction
    outcome (via {!settlement_of_failure}) — settles as
    [Escalate Compaction_retry_exhausted] once this failure would reach
    [Keeper_meta_contract.compaction_retry_escalation_threshold], and retries
    below it — a requeue is not an ack, so without the ceiling the same
    stimulus re-enters every cycle (RFC-0351 S0, #25461). *)

val project_transition_outbox :
  base_path:string -> keeper_name:string -> (unit, string) result
(** Idempotently materialize the lane's single durable transition into the
    reaction ledger, then retire the outbox entry. New claims remain blocked
    while this projection is incomplete. *)

(** Pure: post-turn status event derived from the registry
    turn-failure counter. [turn_fail_count > 0] maps to [Turn_failed];
    [0] maps to [Turn_succeeded]. *)
val turn_status_event :
  turn_fail_count:int -> Keeper_state_machine.event

(** Runs one keepalive turn (event intake, scheduling, optional cycle dispatch).
    The caller classifies lifecycle state and fd/disk pressure
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
  wakeup:bool Atomic.t -> unit

module For_testing : sig
  val exact_execution_guard :
    base_path:string ->
    keeper_name:string ->
    lease:Keeper_registry_event_queue.lease ->
    Keeper_compaction_llm_summarizer.exact_execution_guard

  val check_cancellation_after_exact_terminal_settlement :
    Keeper_registry_event_queue.settlement -> unit
end
