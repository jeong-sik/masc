(** Keeper_unified_turn — Single entry point for keeper turns via Agent_core.Agent.run().

    Replaces the 3-path dispatcher (social/scheduled-autonomous/autonomy) with a unified
    observe -> prompt -> Agent.run(tools, guardrails, hooks) loop.
    The model decides what to do; code only enforces safety and observes results.

    Error classification predicates are in [Keeper_error_classify].

    @since Unified Keeper Loop *)

type degraded_retry_decision =
  | No_degraded_retry
  | Degraded_retry_allowed of Keeper_error_classify.degraded_retry

val decide_degraded_retry
  :  base_runtime:string
  -> effective_runtime:string
  -> attempted_runtimes:string list
  -> Agent_core.Error.t
  -> degraded_retry_decision

(** Summary of event-bus signals observed during a single keeper turn.
    Exposed for regression tests. *)
type turn_event_bus_summary =
  { correlation_id : string option
  ; run_id : string option
  ; caused_by : string option
  ; event_count : int
  ; payload_kinds : string list
  }

(** Fold the drained AGENT_CORE event-bus events for a single keeper turn into
    the signals MASC currently consumes. *)
val summarize_turn_event_bus : Agent_core.Event_bus.event list -> turn_event_bus_summary

val turn_event_bus_evidence_detail : turn_event_bus_summary -> string
(** Compact forensic string for observed AGENT_CORE events around a typed overflow. *)

(** Turn-local tool-event pairing state used to detect event-bus integrity
    failures. Exposed for targeted tests. *)
type turn_tool_event_tracker

val create_turn_tool_event_tracker : unit -> turn_tool_event_tracker

val record_turn_tool_events
  :  keeper_name:string
  -> turn_tool_event_tracker
  -> Agent_core.Event_bus.event list
  -> turn_tool_event_tracker

val turn_tool_event_integrity_error
  :  turn_tool_event_tracker
  -> Agent_core.Error.t option

(** Project the initial keeper turn context budget from the routed runtime's
    prevalidated resolution, so lifecycle context math matches the provider
    that will receive the first request. Exposed for regression tests. *)
val resolved_max_context_for_turn
  :  meta:Keeper_meta_contract.keeper_meta
  -> Keeper_context_runtime.max_context_resolution
  -> int

(* runtime→Runtime 숙청: phase-buffer liveness probe 기계 재export 제거
   (단일 runtime 에서 죽은 코드였으므로 제거됨). *)

(** Typed phase-gate output for the first turn pipeline boundary.
    [run_keeper_cycle] converts this record into the manifest
    [Phase_gate_decided] row and then dispatches the matching terminal or
    runtime-routing branch. *)
type turn_plan_status =
  | Turn_plan_dispatch
  | Turn_plan_skipped
  | Turn_plan_cancelled
  | Turn_plan_error

type turn_plan =
  { turn_plan_keeper_turn_id : int
  ; turn_plan_phase : string option
  ; turn_plan_status : turn_plan_status
  ; turn_plan_executable : bool
  ; turn_plan_reason : string
  ; turn_plan_terminal_reason_code : string option
  }

val decide_turn_plan_at_phase_gate
  :  keeper_turn_id:int
  -> supervisor_stop_at_entry:bool
  -> Keeper_state_machine.phase option
  -> turn_plan

val turn_plan_manifest_status : turn_plan -> string
val turn_plan_manifest_decision : turn_plan -> Yojson.Safe.t

(** Resolve the next runtime to try after an auto-recoverable failure.
    Uses the current effective runtime and the default degraded rotation
    candidate, then suppresses suggestions
    that would loop back to a runtime already attempted during the current
    turn. Exposed for targeted tests. *)
val next_fail_open_runtime_for_turn
  :  base_runtime:string
  -> effective_runtime:string
  -> attempted_runtimes:string list
  -> Agent_core.Error.t
  -> Keeper_error_classify.degraded_retry option

(** Record the streaming-cancel observation shared by the Eio.Cancel handler.
    Exposed so tests can pin the supervisor [fiber_stop] branch without forcing
    a live provider cancellation. *)
val record_streaming_cancelled_observation
  :  config:Workspace.config
  -> run_meta:Keeper_meta_contract.keeper_meta
  -> run_generation:int
  -> runtime_id:string
  -> keeper_turn_id:int
  -> unit
  -> unit

type source_disposition =
  | Follow_failure_route
  | Pause_after_transcript_corruption of { detail : string }
(** A failed turn normally follows its typed retry/rotate/escalate route —
    including every provider capacity failure. The automatic
    overflow-compaction recovery that used to branch here was removed (#26546)
    because it had never produced a committed compaction on record. #26545
    bounds conversation history only; whole-request provider fit is tracked in
    #26551.
    [Pause_after_transcript_corruption] is terminal for automatic execution:
    typed transcript admission rejected before provider dispatch, so the
    heartbeat durably pauses the Keeper and consumes the selected source into an
    operator-reset-required escalation with no retry successor. *)

type turn_failure =
  { error : Agent_core.Error.t
  ; runtime_id : string
  ; route : Keeper_runtime_failure_route.route
  ; source_disposition : source_disposition
  ; deferred_runtime_lane : Keeper_turn_driver.deferred_runtime_lane option
  }
(** Exact execution identity and typed disposition route for a failed turn.
    The heartbeat queue transitions from this value; it must not reconstruct a
    possibly rotated runtime from Keeper meta. *)

type continuation_delivery_state =
  | Delivery_delivered
  | Delivery_failed
  | Delivery_ambiguous
  | Delivery_recovery_pending

type continuation_delivery_completion =
  | Continuation_delivery_not_required
  | Continuation_delivery_settled_by_terminal_surface_post
  | Continuation_delivery_committed of
      { intent_id : Keeper_continuation_delivery_intent.Intent_id.t
      ; delivery_state : continuation_delivery_state
      }
  | Continuation_delivery_quarantined of { detail : string }
(** [Continuation_delivery_settled_by_terminal_surface_post] means the turn's
    typed terminal-effect boundary and its exact successful
    [keeper_surface_post] tool receipt proved that the continuation was already
    delivered, so creating a second outbox intent would duplicate the reply.
    [Continuation_delivery_committed] means the response and exact destination
    crossed the durable outbox boundary.  Connector settlement is deliberately
    separate: a failed, ambiguous, or recovery-pending projection must not keep
    the source at the active queue head or cause another model run.
    [Continuation_delivery_quarantined] means even that durable boundary could
    not be established.  The exact source is moved to a source-bearing terminal
    receipt for repair while the Keeper continues with other work. *)

type turn_success =
  | Turn_completed of
      { meta : Keeper_meta_contract.keeper_meta
      ; continuation_delivery : continuation_delivery_completion
      }
  | Turn_checkpointed of Keeper_meta_contract.keeper_meta
  | Turn_input_required of Keeper_meta_contract.keeper_meta
  | Turn_cancelled of Keeper_meta_contract.keeper_meta
  | Turn_skipped of Keeper_meta_contract.keeper_meta
(** Typed non-error result of the unified turn boundary. Only
    [Turn_completed] proves that the requested action path finished, and its
    delivery evidence distinguishes sources that required a connector receipt.
    [Turn_checkpointed] and [Turn_input_required] are healthy runtime exits but
    preserve the durable source for continuation. Supervisor cancellation and a
    non-executable phase remain distinct so a durable source cannot be
    acknowledged as completed work. *)

val turn_success_of_stop_reason
  :  meta:Keeper_meta_contract.keeper_meta
  -> continuation_delivery:continuation_delivery_completion
  -> Runtime_agent.stop_reason
  -> turn_success
(** Total typed projection used at the successful runtime boundary. *)

val manual_compaction_preemption_request
  :  wake:Keeper_registry.wake_reason
  -> now:float
  -> Keeper_event_queue.t
  -> Keeper_agent_run.autonomous_yield_request option
(** Pure post-tool boundary decision for an in-flight source turn. Returns a
    durable-stimulus yield only when a separate owner-lane manual compaction is
    pending. The summary names that exact runtime stimulus as the next
    source; a turn already consuming manual compaction never yields to itself. *)

val continuation_delivery_origin_of_wake :
  admitted_channel:Keeper_continuation_channel.t option ->
  Keeper_registry.wake_reason ->
  (Keeper_continuation_delivery_intent.origin option, string) result
(** Join an admitted route to the exact singleton continuation producer that
    caused the turn. A supplied route without an exact typed source match is
    an error, never a successful unrouted delivery. *)

val run_keeper_cycle
  :  before_dispatch_authority:(unit -> (unit, string) result)
  -> ?deferred_runtime_lane:Keeper_turn_driver.deferred_runtime_lane
  -> ?on_deferred_runtime_consumed:(unit -> unit)
  -> config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> publication_recovery_provider:
       Keeper_publication_recovery_availability.provider
  -> observation:Keeper_world_observation.world_observation
  -> generation:int
  -> wake:Keeper_registry.wake_reason
  -> turn_decision:Keeper_world_observation.keeper_cycle_decision
  -> ?shared_context:Agent_core.Context.t
  -> ?event_bus:Agent_core.Event_bus.t
  -> ?hitl_resolution:Keeper_event_queue.hitl_resolution
  -> ?continuation_delivery_origin:Keeper_continuation_delivery_intent.origin
  -> unit
  -> (turn_success, turn_failure) result

(** Run a unified keeper turn.

    1. Builds unified prompt from meta + observation
    2. Calls [Keeper_agent_run.run_turn] with keeper tools and hooks
    3. Observes tool history from result to update metrics
    4. Returns updated keeper_meta

    @param config Workspace configuration
    @param meta Current keeper metadata
    @param observation World state snapshot
    @param generation Current generation counter
    @param wake What triggered this turn (#16, 38-bug campaign PR-5):
    reactive stimulus batch or the proactive cadence tick. Installed on
    [current_turn_observation] via [Keeper_registry.mark_turn_started] so
    the composite observer / dashboard can surface it. Distinct from
    [turn_decision] below, which carries the scheduler verdict into the
    prompt text and owns the execution channel rather than the registry
    observation.
    @param turn_decision The scheduler's cycle decision that fired this turn
    (RFC-0315). Its [channel] drives execution and it is threaded into
    [Keeper_unified_prompt.build_prompt] so the prompt renders the same
    decision without a context-blind recompute. *)
