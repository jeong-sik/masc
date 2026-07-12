(** Keeper_unified_turn — Single entry point for keeper turns via OAS Agent.run().

    Replaces the 3-path dispatcher (social/scheduled-autonomous/autonomy) with a unified
    observe -> prompt -> Agent.run(tools, guardrails, hooks) loop.
    The model decides what to do; code only enforces safety and observes results.

    Error classification predicates are in [Keeper_error_classify].

    @since Unified Keeper Loop *)

type provider_timeout_budget =
  { effective_timeout_sec : float
  ; adaptive_timeout_sec : float
  ; keeper_turn_timeout_sec : float
  ; remaining_turn_budget_sec : float
  ; estimated_input_tokens : int
  ; source : string
  }

val resolve_bounded_provider_timeout_budget_with_turn_budget
  :  allow_wall_clock_retry_budget:bool
  -> is_retry:bool
  -> estimated_input_tokens:int
  -> remaining_turn_budget_s:float
  -> provider_timeout_budget
(** See [Keeper_turn_runtime_budget] for provider timeout planning semantics. *)

val allow_wall_clock_retry_budget_for_attempt
  :  is_retry:bool
  -> degraded_rotation_first_attempt:bool
  -> attempt:int
  -> attempted_runtimes:string list
  -> bool

val degraded_retry_slot_phase_budget_sec : float
val degraded_retry_slot_phase_available : time_spent_in_turn_s:float -> bool

type degraded_retry_budget_decision =
  | No_degraded_retry
  | Degraded_retry_slot_phase_exhausted of Keeper_error_classify.degraded_retry
  | Degraded_retry_allowed of Keeper_error_classify.degraded_retry

val next_fail_open_runtime_for_turn_with_budget
  :  base_runtime:string
  -> effective_runtime:string
  -> attempted_runtimes:string list
  -> estimated_input_tokens:int
  -> ?time_spent_in_turn_s:float
  -> remaining_turn_budget_s:float
  -> Agent_sdk.Error.sdk_error
  -> degraded_retry_budget_decision

(** Turn-local overflow hint published by the OAS event bus before a
    proactive compaction attempt. Exposed for regression tests. *)
type turn_event_bus_overflow =
  { estimated_tokens : int
  ; limit_tokens : int
  }

type turn_event_bus_compaction =
  { before_tokens : int
  ; after_tokens : int
  ; tokens_freed : int
  ; phase_hint : string
  }

(** Summary of event-bus signals observed during a single keeper turn.
    Exposed for regression tests. *)
type turn_event_bus_summary =
  { correlation_id : string option
  ; run_id : string option
  ; caused_by : string option
  ; event_count : int
  ; payload_kinds : string list
  ; overflow_imminent : turn_event_bus_overflow option
  ; context_compact_started_count : int
  ; context_compacted_count : int
  ; last_compaction : turn_event_bus_compaction option
  }

(** Fold the drained OAS event-bus events for a single keeper turn into
    the signals MASC currently consumes. *)
val summarize_turn_event_bus : Agent_sdk.Event_bus.event list -> turn_event_bus_summary

val turn_event_bus_overflow_evidence_detail : turn_event_bus_summary -> string
(** Compact forensic string for preserving OAS compaction/retry event-bus
    evidence inside the keeper overflow blocker detail. *)

(** Turn-local tool-event pairing state used to detect event-bus integrity
    failures before side-effect retry logic falls back to unknown input.
    Exposed for targeted tests. *)
type turn_tool_event_tracker

val create_turn_tool_event_tracker : unit -> turn_tool_event_tracker

val record_turn_tool_events
  :  ?has_mutating_side_effect_with_input:(tool_name:string -> input:Yojson.Safe.t -> bool)
  -> keeper_name:string
  -> turn_tool_event_tracker
  -> Agent_sdk.Event_bus.event list
  -> turn_tool_event_tracker

val turn_tool_event_integrity_error
  :  turn_tool_event_tracker
  -> Agent_sdk.Error.sdk_error option

val committed_mutating_tools_from_events : turn_tool_event_tracker -> string list

(** Build the keeper overflow event from either a drained event-bus
    signal or the structured OAS error fallback. Exposed for tests. *)
val context_overflow_event_of_error
  :  fallback_tokens:int
  -> ?turn_event_bus:turn_event_bus_summary
  -> Agent_sdk.Error.sdk_error
  -> Keeper_state_machine.event

(** Resolve the initial keeper turn context budget from the keeper's routed
    runtime, so lifecycle context math matches the provider that will receive
    the first request. Exposed for regression tests. *)
val resolved_max_context_for_turn : meta:Keeper_meta_contract.keeper_meta -> int

(** Persist paused/resumed state before mutating the live registry/phase.
    Returns [Error] when disk sync fails so callers can surface the failure
    instead of silently diverging runtime vs persisted state. *)
val sync_keeper_paused_state
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> paused:bool
  -> (Keeper_meta_contract.keeper_meta, string) result

(** Completion-contract failures are persistent keeper/provider contract
    failures, not transient provider blips. Repeated occurrences should pause
    the keeper before the generic supervisor crash/restart loop re-enters the
    same prompt and model family. Exposed for regression tests. *)

(** Ensure local-provider discovery is refreshed before a turn when the
    selected labels depend on runtime discovery. Exposed for targeted tests. *)
val ensure_local_discovery_ready
  :  ?refresh:(string list -> bool)
  -> string list
  -> (unit, string) result

(* runtime→Runtime 숙청: phase-buffer liveness probe 기계 재export 제거
   (Keeper_turn_liveness 에서 적출됨 — 단일 runtime 에서 죽은 코드). *)

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
  :  ?cancel_reason:string
  -> config:Workspace.config
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
