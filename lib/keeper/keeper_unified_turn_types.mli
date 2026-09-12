(** Keeper_unified_turn_types — pure helpers extracted from
    Keeper_unified_turn (3020 LoC godfile).

    Holds [unit -> Yojson] and JSON projection helpers used by the
    unified keeper turn loop. State-touching orchestration stays in
    Keeper_unified_turn. Re-included by it so existing callers continue
    to use [Keeper_unified_turn.<name>] unchanged. *)

(** One candidate the runtime walk attempted and that ended in an error.
    [runtime_id] is the candidate's own id as the walk named it, never the
    lane it was routed under. [dispatch] says whether the candidate's provider
    or client was invoked: a [Rejected_before_dispatch] entry is the walk's
    own refusal (a candidate missing from the runtime table, a tool surface
    the candidate cannot carry, a provider config it cannot dispatch under),
    and its error is not that candidate's answer. *)
type runtime_attempt_error =
  { runtime_id : string
  ; dispatch : Keeper_attempt_dispatch.t
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
  ; runtime_attempt_errors : runtime_attempt_error list
    (** Every candidate the runtime walk attempted and that ended in an
        error this turn, in walk order, each with its own error and dispatch
        disposition. [last_execution] and [deferred_runtime_lane] both name
        the lane the turn was budgeted under, which sticky ordering can route
        to a different candidate; this list is the only record of which
        candidates the walk actually reached. Empty until a candidate
        errors. *)
  ; lane_terminal_error : Keeper_turn_driver.lane_terminal_error option
    (** The candidate error the runtime walk returned as the lane's error,
        with the candidate that produced it. [None] when the walk never
        returned a candidate's error (no candidate was walked, or the turn
        failed outside the walk). Its origin can differ from the last
        dispatched candidate: on an exhausted lane a typed context overflow
        observed earlier outranks a later recoverable error. *)
  }

val require_last_execution_for_finalize :
  keeper_name:string ->
  turn_state ->
  (Keeper_turn_runtime_budget.runtime_execution, Agent_core.Error.t) result

(** The runtime a "keeper cycle FAILED" report names. *)
type keeper_cycle_failed_runtime =
  | Dispatched_candidate of string
    (** The last candidate whose provider or client was invoked and that
        errored. Chosen only from [Dispatched] attempt errors; a refusal the
        walk made before dispatch never names a candidate here. *)
  | No_candidate_dispatched
    (** No candidate's provider or client was invoked, so there is no
        candidate to name. Rendered as ["none"]; the lane is still reported
        separately, and pre-dispatch refusals stay in the attempt list. *)

(** The candidate whose error the lane returned as its own. *)
type keeper_cycle_failed_terminal_origin =
  | Terminal_error_from of
      { runtime_id : string
      ; attempt : int
      }
    (** The walk returned this candidate's error. It can be an earlier
        candidate than the one the walk ended on. *)
  | Terminal_error_not_from_a_candidate
    (** The walk returned no candidate's error. Rendered as ["none"]. *)

(** Which runtime a "keeper cycle FAILED" report should name, the lane it
    was budgeted under, which candidate the reported error came from, and
    what the (possibly different) next-attempt hint is. See
    [keeper_cycle_failed_runtime_attribution]. *)
type keeper_cycle_failed_runtime_attribution =
  { reported_runtime : keeper_cycle_failed_runtime
    (** The last candidate that actually dispatched and failed this cycle,
        taken from the attempt list — never from the execution record and
        never from a pre-dispatch refusal. *)
  ; lane_runtime_id : string
    (** The deferred-lane assignment this cycle was budgeted under
        ([execution.runtime_id]). Distinct fact from [reported_runtime]. *)
  ; deferred_next_runtime_id : string
    (** The runtime a same-turn deferral queued for the *next* cycle, or
        ["none"] when no deferral occurred. Distinct fact from
        [reported_runtime]; never conflate the two into one field. *)
  ; terminal_error_origin : keeper_cycle_failed_terminal_origin
    (** The candidate whose error the lane returned. Distinct fact from
        [reported_runtime]: the two differ when an earlier candidate's error
        outranked the last candidate's. *)
  ; attempts : runtime_attempt_error list
    (** Every candidate that errored, dispatched or refused, in walk
        order. *)
  }

(** [keeper_cycle_failed_runtime_attribution ~deferred_runtime_lane
    ~lane_runtime_id ~runtime_attempt_errors ~lane_terminal_error] resolves
    the runtime a failure report should name. [lane_runtime_id] (typically
    [execution.runtime_id]) names the deferred-lane assignment this cycle was
    budgeted under, not necessarily the concrete candidate
    [attempt_runtime_candidates] actually dispatched: [Runtime_lane_preference]
    sticky ordering can route a lane keyed by one runtime id to a different
    candidate first. The reported runtime is the last [Dispatched] entry of
    [runtime_attempt_errors]; with no dispatched entry it is
    [No_candidate_dispatched]. The lane id is never substituted for a
    candidate. [deferred_runtime_lane] only supplies
    [deferred_next_runtime_id]; [lane_terminal_error] only supplies
    [terminal_error_origin]. *)
val keeper_cycle_failed_runtime_attribution :
  deferred_runtime_lane:Keeper_turn_driver.deferred_runtime_lane option ->
  lane_runtime_id:string ->
  runtime_attempt_errors:runtime_attempt_error list ->
  lane_terminal_error:Keeper_turn_driver.lane_terminal_error option ->
  keeper_cycle_failed_runtime_attribution

(** Log rendering of [keeper_cycle_failed_runtime]: the candidate id, or
    ["none"] for [No_candidate_dispatched]. *)
val keeper_cycle_failed_runtime_to_string : keeper_cycle_failed_runtime -> string

(** Log rendering of [keeper_cycle_failed_terminal_origin]:
    ["<runtime_id>#<attempt>"], or ["none"] for
    [Terminal_error_not_from_a_candidate]. *)
val keeper_cycle_failed_terminal_origin_to_string :
  keeper_cycle_failed_terminal_origin -> string

(** Log rendering of the attempt list:
    ["[<runtime_id>@<dispatch>=<error preview>, ...]"], in walk order, where
    [<dispatch>] is [Keeper_attempt_dispatch.to_string]. *)
val runtime_attempt_errors_to_string : runtime_attempt_error list -> string

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
