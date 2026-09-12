(** Keeper_unified_turn_types — pure helpers extracted from
    Keeper_unified_turn (3020 LoC godfile).

    Holds [unit -> Yojson] and JSON projection helpers used by the
    unified keeper turn loop. State-touching orchestration stays in
    Keeper_unified_turn. Re-included by it so existing callers continue
    to use [Keeper_unified_turn.<name>] unchanged. *)

(** One candidate the runtime walk dispatched and that answered with an
    error. [runtime_id] is the candidate's own id as the walk named it, never
    the lane it was routed under. *)
type dispatched_runtime_attempt =
  { runtime_id : string
  ; error : Agent_core.Error.t
  }

(** Immutable per-turn accumulator that replaces the casual [ref] cells
    previously threaded through [run_keeper_cycle] and the retry loop. *)
type turn_state =
  { cycle_completed : bool
  ; manifest_seq : int
  ; current_turn_blocker_info : Keeper_meta_contract.blocker_info option
  ; last_execution : Keeper_turn_runtime_budget.runtime_execution option
  ; degraded_retry_info : Keeper_error_classify.degraded_retry option
  ; deferred_runtime_lane : Keeper_turn_driver.deferred_runtime_lane option
  ; runtime_rotation_attempts : Keeper_execution_receipt.runtime_rotation_attempt list
  ; failure_reason : Keeper_turn_fsm.failure_reason option
  ; retry_phase_started_at : float option
  ; dispatched_runtime_attempts : dispatched_runtime_attempt list
    (** Every candidate that dispatched and errored this turn, in dispatch
        order, each with its own error. [last_execution] and
        [deferred_runtime_lane] both name the lane the turn was budgeted
        under, which sticky ordering can route to a different candidate; a
        failure with no deferral hint left no record of who answered at all.
        The decision record and the "keeper cycle FAILED" line named the
        lane key in that case, so payment-required errors from deepseek were
        filed against claude_code (masc#35043, audit L3 2026-09-12). Empty
        until a candidate errors. *)
  }

val require_last_execution_for_finalize :
  keeper_name:string ->
  turn_state ->
  (Keeper_turn_runtime_budget.runtime_execution, Agent_core.Error.t) result

(** The runtime a "keeper cycle FAILED" report names. *)
type keeper_cycle_failed_runtime =
  | Dispatched_candidate of string
    (** The last candidate the runtime walk dispatched and that errored. *)
  | No_candidate_dispatched
    (** The turn failed before any candidate was dispatched, so there is no
        candidate to name. Rendered as ["none"]; the lane is still reported
        separately. *)

(** Which runtime a "keeper cycle FAILED" report should name, the lane it
    was budgeted under, and what the (possibly different) next-attempt hint
    is. See [keeper_cycle_failed_runtime_attribution] (masc#28762,
    masc#35043). *)
type keeper_cycle_failed_runtime_attribution =
  { reported_runtime : keeper_cycle_failed_runtime
    (** The candidate that actually dispatched and failed this cycle, taken
        from the attempt list — never from the execution record. *)
  ; lane_runtime_id : string
    (** The deferred-lane assignment this cycle was budgeted under
        ([execution.runtime_id]). Distinct fact from [reported_runtime]. *)
  ; deferred_next_runtime_id : string
    (** The runtime a same-turn deferral queued for the *next* cycle, or
        ["none"] when no deferral occurred. Distinct fact from
        [reported_runtime]; never conflate the two into one field. *)
  ; attempts : dispatched_runtime_attempt list
    (** Every candidate that dispatched and errored, in dispatch order. *)
  }

(** [keeper_cycle_failed_runtime_attribution ~deferred_runtime_lane
    ~lane_runtime_id ~dispatched_attempts] resolves the runtime a failure
    report should name. [lane_runtime_id] (typically [execution.runtime_id])
    names the deferred-lane assignment this cycle was budgeted under, not
    necessarily the concrete candidate [attempt_runtime_candidates] actually
    dispatched: [Runtime_lane_preference] sticky ordering can route a lane
    keyed by one runtime id to a different candidate first. The reported
    runtime is the last entry of [dispatched_attempts] (the candidate the
    walk ended on); with no attempt it is [No_candidate_dispatched]. The
    lane id is never substituted for a candidate. [deferred_runtime_lane]
    only supplies [deferred_next_runtime_id]. *)
val keeper_cycle_failed_runtime_attribution :
  deferred_runtime_lane:Keeper_turn_driver.deferred_runtime_lane option ->
  lane_runtime_id:string ->
  dispatched_attempts:dispatched_runtime_attempt list ->
  keeper_cycle_failed_runtime_attribution

(** Log rendering of [keeper_cycle_failed_runtime]: the candidate id, or
    ["none"] for [No_candidate_dispatched]. *)
val keeper_cycle_failed_runtime_to_string : keeper_cycle_failed_runtime -> string

(** Log rendering of the attempt list:
    ["[<runtime_id>=<error preview>, ...]"], in dispatch order. *)
val dispatched_runtime_attempts_to_string : dispatched_runtime_attempt list -> string

val degraded_retry_applied_for_turn :
  degraded_retry_info:Keeper_error_classify.degraded_retry option ->
  last_execution:Keeper_turn_runtime_budget.runtime_execution option ->
  bool
(** Whether the deferred lane a previous turn hinted at is the lane this turn
    actually ran on.

    [turn_state.degraded_retry_info] is seeded at [initial_turn_state] from the
    [deferred_runtime_lane] argument and nothing writes it afterwards, so its
    presence means a deferred lane is pending — not that a retry ran. Reporting
    presence as "applied" told an operator a retry had happened on turns where
    none had, and attached a [fallback_reason] derived from the earlier turn's
    failure to this turn's receipt.

    Returns [false] when no execution was recorded: nothing ran, so nothing was
    applied. *)

val turn_event_bus_manifest_decision :
  Keeper_turn_runtime_budget.turn_event_bus_summary -> Yojson.Safe.t

(** [registry_failure_reason_of_terminal_reason terminal ~raw_error]
    maps a [Keeper_turn_terminal.t] disposition to the corresponding
    [Keeper_registry.failure_reason], or [None] for benign terminals
    (Success, External_cancel, timeouts, etc.). [raw_error] is truncated
    via [Keeper_types_profile.short_preview]. *)
val registry_failure_reason_of_terminal_reason :
  ?core_error:Agent_core.Error.t ->
  Keeper_turn_terminal.t ->
  raw_error:string ->
  Keeper_registry.failure_reason option

(** Tracker for matching ToolCalled/ToolCompleted event pairs within a
    single keeper turn. The value is an immutable accumulator; every
    operation returns an updated tracker. *)
type turn_tool_event_tracker

val create_turn_tool_event_tracker : unit -> turn_tool_event_tracker
val turn_tool_event_integrity_error :
  turn_tool_event_tracker -> Agent_core.Error.t option
val turn_tool_completed_count : turn_tool_event_tracker -> int

(** Drive the tracker over a batch of [Agent_core.Event_bus.event]s,
    matching [ToolCalled] <-> [ToolCompleted] pairs and recording integrity
    violations. Returns the updated tracker. *)
val record_turn_tool_events :
  keeper_name:string ->
  turn_tool_event_tracker ->
  Agent_core.Event_bus.event list ->
  turn_tool_event_tracker

(** Record the observation for a streaming turn cancelled externally.
    Reads the fiber_stop flag from [Keeper_registry], emits FSM
    transitions, and writes a terminal observation via
    [Keeper_turn_helpers.record_pre_dispatch_terminal_observation]. *)

val record_streaming_cancelled_observation :
  config:Workspace.config ->
  run_meta:Keeper_meta_contract.keeper_meta ->
  runtime_id:string ->
  keeper_turn_id:int ->
  unit ->
  unit
