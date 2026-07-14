(** Keeper_unified_turn — Single entry point for keeper turns via OAS Agent.run().

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
  -> Agent_sdk.Error.sdk_error
  -> degraded_retry_decision

val user_message_with_hitl_resolution :
  base_path:string ->
  user_message:string ->
  Keeper_event_queue.hitl_resolution option ->
  string
(** Add the durable HITL resolution output to the model-facing turn input.
    Reject rationale and edited JSON are always explicit and never imply a
    one-shot grant; only an approved journal can render exact authorization. *)

(** Summary of event-bus signals observed during a single keeper turn.
    Exposed for regression tests. *)
type turn_event_bus_summary =
  { correlation_id : string option
  ; run_id : string option
  ; caused_by : string option
  ; event_count : int
  ; payload_kinds : string list
  }

(** Fold the drained OAS event-bus events for a single keeper turn into
    the signals MASC currently consumes. *)
val summarize_turn_event_bus : Agent_sdk.Event_bus.event list -> turn_event_bus_summary

val turn_event_bus_evidence_detail : turn_event_bus_summary -> string
(** Compact forensic string for preserving exact OAS event-bus observations.
    Display evidence only; never parsed for control flow. *)

(** Turn-local tool-event pairing state used to detect event-bus integrity
    failures. Exposed for targeted tests. *)
type turn_tool_event_tracker

val create_turn_tool_event_tracker : unit -> turn_tool_event_tracker

val record_turn_tool_events
  :  keeper_name:string
  -> turn_tool_event_tracker
  -> Agent_sdk.Event_bus.event list
  -> turn_tool_event_tracker

val turn_tool_event_integrity_error
  :  turn_tool_event_tracker
  -> Agent_sdk.Error.sdk_error option

(** Resolve the initial keeper turn context budget from the keeper's routed
    runtime, so lifecycle context math matches the provider that will receive
    the first request. Exposed for regression tests. *)
val resolved_max_context_for_turn : meta:Keeper_meta_contract.keeper_meta -> int

(** Ensure local-provider discovery is refreshed before a turn when the
    selected labels depend on runtime discovery. Exposed for targeted tests. *)
val ensure_local_discovery_ready
  :  ?refresh:(string list -> bool)
  -> string list
  -> (unit, string) result

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
  -> Agent_sdk.Error.sdk_error
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

type source_lease_disposition =
  | Follow_failure_route
  | Acknowledge_after_in_turn_handling
(** A failed turn normally follows its typed retry/rotate/escalate route.
    [Acknowledge_after_in_turn_handling] consumes only the source stimulus when
    the configured in-turn policy already handled the terminal failure; the
    cycle remains failed for receipts, counters, and heartbeat freshness. *)

type turn_failure =
  { error : Agent_sdk.Error.sdk_error
  ; runtime_id : string
  ; route : Keeper_runtime_failure_route.route
  ; source_lease_disposition : source_lease_disposition
  }
(** Exact execution identity and typed disposition route for a failed turn.
    The heartbeat queue settles from this value; it must not reconstruct a
    possibly rotated runtime from Keeper meta. *)

type turn_success =
  | Turn_completed of Keeper_meta_contract.keeper_meta
  | Turn_cancelled of Keeper_meta_contract.keeper_meta
  | Turn_skipped of Keeper_meta_contract.keeper_meta
(** Typed non-error result of the unified turn boundary. Only
    [Turn_completed] proves that the action path ran successfully.
    Supervisor cancellation and a non-executable phase remain distinct so a
    durable source lease cannot be acknowledged as completed work. *)

val run_keeper_cycle
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> observation:Keeper_world_observation.world_observation
  -> generation:int
  -> wake:Keeper_registry.wake_reason
  -> ?channel:Keeper_world_observation.keeper_cycle_channel
  -> ?turn_decision:Keeper_world_observation.keeper_cycle_decision
  -> ?shared_context:Agent_sdk.Context.t
  -> ?event_bus:Agent_sdk.Event_bus.t
  -> ?hitl_resolution:Keeper_event_queue.hitl_resolution
  -> ?continuation_delivery_channel:Keeper_continuation_channel.t
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
    prompt text rather than the registry observation.
    @param turn_decision The scheduler's cycle decision that fired this turn
    (RFC-0315). Threaded into [Keeper_unified_prompt.build_prompt] so the
    prompt renders the real wake reason instead of a context-blind recompute.
    Callers that predate the threading may omit it. *)
