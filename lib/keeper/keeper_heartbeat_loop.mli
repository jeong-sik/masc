open Keeper_meta_contract
open Keeper_types_profile

val effective_keepalive_meta :
  base_path:string ->
  fallback:keeper_meta ->
  disk_meta_opt:keeper_meta option ->
  keeper_meta

val sync_keeper_presence :
  ctx:'a context ->
  registry_entry:Keeper_registry.registry_entry ->
  meta_current:keeper_meta ->
  consecutive_failures:int ref ->
  keeper_meta

val collect_keepalive_board_events :
  ctx:'a context ->
  meta_current:keeper_meta ->
  proactive_warmup_elapsed:bool ->
  Keeper_world_observation.pending_board_event list * keeper_meta

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

(** Source-authority gate applied after world scheduling. A durable selection
    failure blocks dispatch. Unread, missing or unanswered Ask sources and
    unread or missing Connector sources retain their selections while
    preserving independent world scheduling. *)
val should_run_turn_after_event_intake :
  scheduled:bool ->
  event_queue_intake_error:
    Keeper_heartbeat_stimulus_intake.event_queue_intake_error option ->
  bool

type keepalive_scheduling_decision = Keeper_heartbeat_loop_scheduling.keepalive_scheduling_decision = {
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

(** Closed accounting status for one keepalive cycle: whether a turn ran in
    this cycle and how it ended. The stored failure streak takes no part in
    it, so a cycle that ran no turn cannot report a failed one (#34673).
    Admission busy performs no turn accounting, crash accounting, or
    work-health refresh. *)
type keepalive_cycle_status =
  | Turn_cycle_turn_succeeded
      (** The turn ran and completed, checkpointed, or asked for input. *)
  | Turn_cycle_turn_failed  (** The turn ran and failed. *)
  | Turn_cycle_without_turn
      (** The cycle ran and no turn did: warmup not elapsed, nothing
          scheduled, the phase gate skipped or cancelled the turn, or the
          Owner is shutting down. *)
  | Turn_cycle_lifecycle_blocked
      (** Lifecycle admission denied intake before the cycle body. *)
  | Turn_cycle_owner_rejected
      (** The Owner registry refused the autonomous turn outside shutdown.
          No turn ran and nothing advanced the failure streak. *)
  | Turn_cycle_interrupted
  | Turn_cycle_crashed
  | Turn_cycle_busy of Keeper_owner.autonomous_block
  | Turn_cycle_rested
      (** The turn ended as {!Keeper_unified_turn.Turn_rested}: the provider
          stated when its quota resets and the refused attempt had no tool
          effect. *)

(** How the turn that ran in this cycle ended. Only a cycle that ran a turn,
    or crashed, has one. *)
type cycle_turn_result =
  | Cycle_turn_succeeded
  | Cycle_turn_failed

type work_heartbeat_action =
  | Refresh_work_heartbeat
  | Preserve_work_heartbeat

type keepalive_cycle_action =
  | Defer_autonomous_work of Keeper_owner.autonomous_block
  | Skip_interrupted_turn
  | Skip_unadmitted_cycle
      (** No turn status and no work-health refresh; the refusing site
          already logged its reason. *)
  | Record_turn_status of cycle_turn_result * work_heartbeat_action
  | Refresh_without_turn_status

val decide_keepalive_cycle_action :
  keepalive_cycle_status -> keepalive_cycle_action
(** Total accounting decision used by the heartbeat effect shell. Only a
    cycle whose turn ran, or that crashed, records a turn status: a succeeded
    or failed turn records and refreshes, a crashed cycle records the failure
    while preserving the existing lease. A cycle without a turn and a rested
    cycle refresh the lease and dispatch neither [Turn_succeeded] nor
    [Turn_failed], so the Keeper's phase and registry failure cause stay as
    they were. Lifecycle-blocked and Owner-rejected cycles record no turn
    status and do not refresh the lease, and neither do operator-interrupted
    cycles. Busy cycles retain their typed admission block without recording
    a turn. *)

val owner_turn_rejection_cycle_status :
  Keeper_owner_registry.command_error -> keepalive_cycle_status
(** Total: the cycle status an Owner-registry rejection of the autonomous
    turn records. [Command_rejected Owner_stopping] and
    [Command_lookup_failed Inventory_stopping] are the shutdown boundary and
    yield [Turn_cycle_without_turn]; every other rejection yields
    [Turn_cycle_owner_rejected]. No other status is returned. *)

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
(** What a failed cycle leaves the next one (RFC-provider-path-rest). A rest
    belongs to the path that received the rate limit or quota answer; the
    keeper waits only while the path it would send next rests.
    [Continue_on_deferred_lane] names the head of the walk that resumes the
    deferred suffix ({!Keeper_turn_driver.resumed_head}), which is not
    resting; a pending input runs on it without a sleep. A resumed turn leaves
    a suffix only after attempting a candidate of the suffix it resumed, and
    that suffix names only the candidates of it the turn did not reach, so
    consecutive immediate cycles walk a shrinking candidate set and end when
    it is empty.
    [Wait_for_path_release] sleeps until [release_at]; [waiting_on] names the
    runtime or assignment whose release that is. A wakeup does not cut it
    short (#34653). *)
type after_failure =
  | Continue_on_deferred_lane of { next_runtime_id : string }
  | Wait_for_path_release of
      { release_at : float
      ; waiting_on : string
      ; basis : Keeper_turn_driver.wait_basis
      }

type keepalive_turn_outcome = {
  meta : keeper_meta;
  cycle_status : keepalive_cycle_status;
  stimuli_acked : bool;
      (** The cycle admitted at least one event-queue stimulus and acked
          every entry of that batch on completion. The loop reads it to
          skip the cadence sleep while more entries are pending. *)
  after_failure : after_failure option;
      (** What the cycle's turn failure or provider rest leaves the next
          cycle; [None] keeps the plain cadence. A rested cycle carries the
          [Wait_for_path_release] its rest names. *)
}

(** Record a swallowed keepalive-cycle exception as a turn failure:
    increments the registry turn-failure counter (shared with
    [Keeper_unified_turn_failure]), bumps the CycleExceptions counter
    and logs at ERROR. Does not raise. *)
val record_crashed_cycle_failure :
  registry_entry:Keeper_registry.registry_entry -> exn -> unit

(** Convert an exception escaping one autonomous cycle into its accounting
    outcome. Operator interrupts are expected cancellation and do not mutate
    the turn-failure counter; every other exception is recorded as a crash. *)
val handle_cycle_exception :
  registry_entry:Keeper_registry.registry_entry ->
  meta:keeper_meta -> exn -> keepalive_turn_outcome

type turn_terminal_settlement =
  { settled : bool
  ; queue_failure : string option
  }

val turn_terminal_settlement :
  label:string ->
  (Keeper_registry_event_queue.turn_ack_result, string) result ->
  turn_terminal_settlement
(** How one admitted entry's turn-end terminal leaves the batch: [settled]
    when a receipt committed or replayed, or when the entry was withdrawn
    while the turn ran ([Turn_selection_withdrawn] is neither a failure nor a
    reason to deliver it again). [queue_failure] carries the detail the loop
    records as an event-queue failure. *)

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
    Gate-deferred tool call) ACKs attention-only
    sources after preserving the continuation, because each one is produced
    after a model round ran with the admitted batch projected. Continuation
    persistence does not imply that every provider retains dynamic observation
    text in canonical history: OpenAI-compatible context is request-only, and
    official-client session replacement may lose its prior context. Delivery
    ACK does not certify model-level answer continuity. Connector attention,
    messages, producer/decision outcomes and scheduled work stay pending until
    a turn completes. Checkpointed messages/outcomes and scheduled occurrences
    rotate within their original urgency lane so later sources remain
    admissible. A HITL resolution
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
    failure, and every cancelled, input-required, skipped, or rested outcome,
    leaves the continuation unsettled. The queue disposition of a failed turn stays
    [Batch_no_action] either way. *)

val after_failure_of_cycle_outcome :
  now:float ->
  Keeper_heartbeat_loop_cycle.cycle_outcome option ->
  after_failure option
(** What a cycle leaves the next one. A failed turn's next dispatch is decided
    at [now] from its route ({!Keeper_turn_driver.next_dispatch_after_failure}).
    A rested turn waits for the release its rest names, decided when the turn
    ended. Every other outcome keeps the plain cadence ([None]). *)

(** Pure: post-turn status event derived from the registry
    turn-failure counter. [turn_fail_count > 0] maps to [Turn_failed];
    [0] maps to [Turn_succeeded]. *)
val turn_status_event :
  turn_fail_count:int -> cycle_turn_result -> Keeper_state_machine.event
(** The status event for a turn that ran in this cycle. The cycle's result
    chooses between [Turn_succeeded] and [Turn_failed]; [turn_fail_count] is
    the stored streak and only fills [consecutive]. *)

val failure_reason_after_turn_status :
  turn_fail_count:int ->
  Keeper_registry.failure_reason option ->
  Keeper_registry.failure_reason option
(** Preserve the current failure cause when the post-turn heartbeat records
    its status. Refresh a turn-failure count only when that is the current
    reason or no reason exists. Preserve a heartbeat-failure count from
    the current workspace I/O failure. Failure producers replace the reason
    when a new failure occurs. *)

val refresh_failure_reason_after_turn :
  registry_entry:Keeper_registry.registry_entry -> turn_fail_count:int -> unit
(** Refresh the registry cause after the loop dispatches turn status.
    The exact originating lane is updated from its latest immutable entry, so
    a concurrent cause is preserved and a same-name replacement is untouched.
    A nonpositive turn-failure count does not write a reason. *)

(** Runs one keepalive turn (event intake, scheduling, optional cycle dispatch).
    The caller classifies lifecycle state and fd/disk pressure
    with {!classify_turn_intake_admission} BEFORE this is invoked, so this
    function must not re-add inline admission gates: doing so would reinstate
    the consume-before-gate churn that hoisting the decision removed. *)
val run_keepalive_unified_turn :
  wake:Keeper_world_observation.cycle_wake ->
  ctx:'a context ->
  registry_entry:Keeper_registry.registry_entry ->
  meta_after_triage:keeper_meta ->
  pending_board_events:Keeper_world_observation.pending_board_event list ->
  stop:bool Atomic.t ->
  proactive_warmup_elapsed:bool ->
  reactive_wake:bool ->
  shared_context:Agent_core.Context.t ->
  deferred_runtime_lane:Keeper_turn_driver.deferred_runtime_lane option ->
  on_deferred_runtime_consumed:(unit -> unit) ->
  settle_deferred_runtime_lane:
    (Keeper_turn_driver.deferred_runtime_lane option -> unit) ->
  keepalive_turn_outcome

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
  proactive_warmup_sec:int -> registry_entry:Keeper_registry.registry_entry ->
  'a context -> keeper_meta -> bool Atomic.t ->
  wakeup:bool Atomic.t -> cadence_sleeping:bool Atomic.t -> unit

module For_testing : sig
  val select_hitl_resolutions :
    base_path:string -> keeper_name:string ->
    stimuli:Keeper_event_queue.stimulus list ->
    peek:(unit -> Keeper_event_queue.hitl_resolution option) ->
    (Keeper_hitl_resolution_batch.t, Keeper_hitl_resolution_batch.join_error) result
  (** Revalidate the actual admitted HITL vector before effects. A contextual
      peek supplies at most one input only when that vector is empty. *)

  val settle_hitl_continuations :
    base_path:string -> keeper_name:string ->
    cycle_outcome:Keeper_heartbeat_loop_cycle.cycle_outcome option ->
    resolutions:Keeper_event_queue.hitl_resolution list ->
    (Keeper_event_queue.hitl_resolution *
     (Keeper_approval_queue.continuation_projection_result, string) result) list
  (** Project each input's own settlement. A non-cancellation failure is
      returned beside that input and does not skip independent siblings. *)

  val hitl_selection_has_recorded_continuation :
    projections:(Keeper_event_queue.hitl_resolution *
      (Keeper_approval_queue.continuation_projection_result, string) result) list ->
    Keeper_event_queue_state.pending_selection -> bool
  (** HITL requires its own successful projection. Other source families keep
      their existing disposition policy; queue terminalization still checks
      the original pending selection and incarnation. *)

  val record_replay_owned_turn_started_reactions :
    ctx:'a context -> keeper_name:string -> Keeper_event_queue.stimulus list -> unit
  (** Production turn-entry recording for the admitted source batch. *)

  val provider_wait_interrupt :
    keeper_name:string ->
    dispatch_snapshot:Runtime.keeper_dispatch_snapshot ->
    assignment_id:string ->
    deferred_runtime_lane:Keeper_turn_driver.deferred_runtime_lane option ->
    basis:Keeper_turn_driver.wait_basis ->
    (now:float -> bool)
  (** Revalidate a provider wait against its dispatch and observed path rest. *)
  (** The production checkpoint retention pass. Counts are observations only.
      Connector conversations rotate with their entire pending suffix in FIFO
      order. Messages, producer/decision outcomes and scheduled occurrences
      retain their original payload and execution scope while rotating to the
      tail of their urgency lane. No source is acknowledged. Failures remain
      explicit; independent selected sources are still attempted. *)
  val retain_checkpoint_continuations :
    base_path:string -> keeper_name:string ->
    Keeper_event_queue_state.pending_selection list -> (unit, string) result

  val checkpoint_source_may_ack : Keeper_event_queue.stimulus_payload -> bool
  (** The same source policy used by post-checkpoint acknowledgement. *)

  (** Whether post-turn HITL settlement may project a continuation before its
      queue source is acknowledged. *)
  val batch_disposition_records_continuation : batch_disposition -> bool

  (** {!Keeper_turn_driver.next_dispatch_after_failure} mapped onto the
      heartbeat sleep. [assignment_id] is what a turn without a deferred suffix
      walks. *)
  val after_failure :
    now:float ->
    assignment_id:string ->
    Keeper_unified_turn.turn_failure ->
    after_failure option

  (** Whether the loop starts another cycle without sleeping. A serving
      deferred suffix is itself unfinished input and starts immediately. A
      path wait and the plain cadence start one only when the cycle acked its
      batch and more stimuli are pending. *)
  val next_cycle_starts_now :
    after_failure:after_failure option ->
    stimuli_acked:bool ->
    pending_stimulus:(unit -> bool) ->
    bool

  (** Scheduling authority chosen from the loop's exact state. A deferred
      runtime suffix takes precedence over cadence because it is unfinished
      input, rather than a fabricated periodic tick. When both are present,
      the label is deferred while {!periodic_cadence_after_cycle} consumes
      the due cadence boundary independently in the same cycle. *)
  val cycle_wake :
    periodic_due:bool ->
    deferred_runtime_lane:Keeper_turn_driver.deferred_runtime_lane option ->
    Keeper_world_observation.cycle_wake

  val periodic_cadence_after_cycle :
    periodic_due:bool ->
    now:float ->
    Keeper_keepalive_signal.periodic_cadence ->
    Keeper_keepalive_signal.periodic_cadence
  (** Advance a due cadence boundary after the cycle even when another wake
      label, including {!Keeper_world_observation.Deferred_runtime_lane},
      authorized the turn. *)

  (** The loop's deferred hint together with its durable file
      ({!Keeper_deferred_runtime_lane_store}). The production loop builds one
      with {!restore_deferred_lane_slot} at start and writes the hint only
      through the functions below, so a restart resumes the frozen suffix. *)
  type deferred_lane_slot

  (** What an assignment walks now, as the restore check sees it. Production
      reads {!Runtime.resolve_assignment}. *)
  type deferred_lane_now =
    | Lane_candidates of string list
    | Lane_missing
    | Lane_unavailable

  (** Load the durable hint for [keeper_name] under [keepers_dir]. A missing file is no hint; a
      store error is logged with its path and also yields no hint, leaving the
      file in place as evidence. A suffix naming an id the assignment no
      longer has as a candidate, or an assignment no longer configured, is
      dropped and its file removed, so an edited [runtime.toml] wins. *)
  val restore_deferred_lane_slot :
    lane_now:(string -> deferred_lane_now) ->
    base_path:string ->
    keepers_dir:string ->
    keeper_name:string ->
    deferred_lane_slot

  (** Persist, then hold, the suffix a failed cycle left behind. *)
  val record_deferred_lane :
    deferred_lane_slot -> Keeper_turn_driver.deferred_runtime_lane -> unit

  (** Dispatch consumed [expected]: the in-process hint is cleared when it is
      still the held one, but its file stays until the cycle settles, so a
      restart while the next runtime runs resumes on it. *)
  val consume_deferred_lane :
    deferred_lane_slot -> Keeper_turn_driver.deferred_runtime_lane -> unit

  (** End of cycle: the suffix the cycle left behind replaces the file, or,
      when it left none, the file of a suffix it dispatched is removed. *)
  val settle_deferred_lane :
    deferred_lane_slot -> Keeper_turn_driver.deferred_runtime_lane option -> unit

  (** The held hint when it was recorded for [assignment_id]. A hint for
      another assignment is dropped and its file removed, as a lane restart
      does. *)
  val deferred_lane_for_assignment :
    deferred_lane_slot ->
    assignment_id:string ->
    Keeper_turn_driver.deferred_runtime_lane option

  (** Run one cycle and settle the deferred lane from its outcome. A raising
      cycle settles [None] so the slot and its durable file agree that no
      suffix is running; the exception propagates with its backtrace. *)
  val run_cycle_and_settle_lane :
    run:(unit -> 'outcome) ->
    settle:('lane option -> unit) ->
    lane_of_outcome:('outcome -> 'lane option) ->
    'outcome
end
