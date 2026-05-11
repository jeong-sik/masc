(** Keeper_unified_turn — Single entry point for keeper turns via OAS Agent.run().

    Replaces the 3-path dispatcher (social/scheduled-autonomous/autonomy) with a unified
    observe -> prompt -> Agent.run(tools, guardrails, hooks) loop.
    The model decides what to do; code only enforces safety and observes results.

    Error classification predicates are in [Keeper_error_classify].

    @since Unified Keeper Loop *)

(** Run a unified keeper turn.

    1. Builds unified prompt from meta + observation
    2. Calls [Keeper_agent_run.run_turn] with keeper tools and hooks
    3. Observes tool history from result to update metrics
    4. Returns updated keeper_meta

    @param config Coord configuration
    @param meta Current keeper metadata
    @param observation World state snapshot
    @param generation Current generation counter *)
(** Update keeper metrics by observing what the agent did (tool calls, text output).
    No action classification — metrics are derived from the run result.

    Exposed for testing. *)
(** Cap a single OAS Agent.run timeout to the remaining unified-turn
    wall-clock budget. Returns [None] when too little budget remains to
    schedule another call safely. *)
val bounded_oas_timeout_for_turn_budget :
  estimated_input_tokens:int -> remaining_turn_budget_s:float -> float option

val bounded_oas_timeout_for_turn_budget_with_turn_budget :
  estimated_input_tokens:int ->
  max_turns:int ->
  remaining_turn_budget_s:float ->
  float option

(** Full timeout-budget resolution used by the unified turn loop.
    Exposed for regression tests that need to distinguish "an OAS
    call had a bounded budget" from "the turn had no retry budget
    left before dispatch". *)
type oas_timeout_budget_resolution = {
  effective_timeout_sec : float;
  adaptive_timeout_sec : float;
  keeper_turn_timeout_sec : float;
  remaining_turn_budget_sec : float;
  estimated_input_tokens : int;
  max_turns : int;
  source : string;
}

val resolve_bounded_oas_timeout_budget_with_turn_budget :
  allow_wall_clock_retry_budget:bool ->
  is_retry:bool ->
  reserve_degraded_retry_budget:bool ->
  estimated_input_tokens:int ->
  max_turns:int ->
  remaining_turn_budget_s:float ->
  oas_timeout_budget_resolution option

(** Per-attempt watchdog used around the OAS call. It fires before the
    enclosing keeper-turn wall-clock timeout so recoverable provider stalls can
    still rotate through the degraded cascade path. *)
val attempt_watchdog_timeout_sec :
  remaining_turn_budget_s:float -> oas_timeout_budget_resolution -> float

val allow_wall_clock_retry_budget_for_attempt :
  is_retry:bool ->
  degraded_rotation_first_attempt:bool ->
  attempt:int ->
  attempted_cascades:string list ->
  bool

val oas_retry_budget_available_for_turn :
  allow_wall_clock_retry_budget:bool ->
  is_retry:bool ->
  estimated_input_tokens:int ->
  max_turns:int ->
  remaining_turn_budget_s:float ->
  bool

val degraded_retry_slot_phase_budget_sec : float

val degraded_retry_slot_phase_available :
  time_spent_in_turn_s:float -> bool

(** Reclassify a structural OAS timeout only when the current attempt
    actually dispatched with an OAS timeout budget. This prevents a
    pre-retry turn-budget exhaustion from borrowing a stale previous
    attempt budget and incorrectly rotating cascades. *)
val reclassify_oas_timeout_for_attempt :
  timeout_budget:oas_timeout_budget_resolution option ->
  Agent_sdk.Error.sdk_error ->
  Agent_sdk.Error.sdk_error

type degraded_retry_budget_decision =
  | No_degraded_retry
  | Degraded_retry_slot_phase_exhausted of Keeper_error_classify.degraded_retry
  | Degraded_retry_budget_exhausted of Keeper_error_classify.degraded_retry
  | Degraded_retry_allowed of Keeper_error_classify.degraded_retry

val next_fail_open_cascade_for_turn_with_budget :
  ?rotation_cascades:string list ->
  base_cascade:string ->
  effective_cascade:string ->
  tool_requirement:Keeper_agent_tool_surface.tool_requirement ->
  attempted_cascades:string list ->
  estimated_input_tokens:int ->
  max_turns:int ->
  ?time_spent_in_turn_s:float ->
  remaining_turn_budget_s:float ->
  Agent_sdk.Error.sdk_error ->
  degraded_retry_budget_decision

(** Turn-local overflow hint published by the OAS event bus before a
    proactive compaction attempt. Exposed for regression tests. *)
type turn_event_bus_overflow = {
  estimated_tokens : int;
  limit_tokens : int;
}

(** Summary of event-bus signals observed during a single keeper turn.
    Exposed for regression tests. *)
type turn_event_bus_summary = {
  correlation_id : string option;
  overflow_imminent : turn_event_bus_overflow option;
}

(** Fold the drained OAS event-bus events for a single keeper turn into
    the signals MASC currently consumes. *)
val summarize_turn_event_bus :
  Agent_sdk.Event_bus.event list -> turn_event_bus_summary

(** Turn-local tool-event pairing state used to detect event-bus integrity
    failures before side-effect retry logic falls back to unknown input.
    Exposed for targeted tests. *)
type turn_tool_event_tracker

val create_turn_tool_event_tracker : unit -> turn_tool_event_tracker

val record_turn_tool_events :
  ?has_mutating_side_effect_with_input:
    (tool_name:string -> input:Yojson.Safe.t -> bool) ->
  keeper_name:string ->
  turn_tool_event_tracker ->
  Agent_sdk.Event_bus.event list ->
  unit

val turn_tool_event_integrity_error :
  turn_tool_event_tracker -> Agent_sdk.Error.sdk_error option

val committed_mutating_tools_from_events :
  turn_tool_event_tracker -> string list

(** Build the keeper overflow event from either a drained event-bus
    signal or the structured OAS error fallback. Exposed for tests. *)
val context_overflow_event_of_error :
  fallback_tokens:int ->
  ?turn_event_bus:turn_event_bus_summary ->
  Agent_sdk.Error.sdk_error ->
  Keeper_state_machine.event

(** Resolve the initial keeper turn context budget.
    Uses the first available model in the cascade rather than the largest
    fallback model, so lifecycle context math matches the provider that will
    receive the first request. Exposed for regression tests. *)
val resolved_max_context_for_turn :
  meta:Keeper_types.keeper_meta ->
  string list ->
  int

(** Persist paused/resumed state before mutating the live registry/phase.
    Returns [Error] when disk sync fails so callers can surface the failure
    instead of silently diverging runtime vs persisted state. *)
val sync_keeper_paused_state :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  paused:bool ->
  (Keeper_types.keeper_meta, string) result

(** Required-tool contract failures are persistent keeper/provider contract
    failures, not transient provider blips. Repeated occurrences should pause
    the keeper before the generic supervisor crash/restart loop re-enters the
    same prompt and model family. Exposed for regression tests. *)
val should_auto_pause_required_tool_contract_violation :
  paused:bool ->
  consecutive_failures:int ->
  Agent_sdk.Error.sdk_error ->
  bool

(** Ensure local-provider discovery is refreshed before a turn when the
    selected labels depend on runtime discovery. Exposed for targeted tests. *)
val ensure_local_discovery_ready :
  ?refresh:(string list -> bool) ->
  string list ->
  (unit, string) result

(** Deterministic decision for the phase-buffer fallback boundary. This
    does not probe runtime liveness; it only decides whether the selected
    labels warrant an Ollama liveness check before preserving the configured
    [routes.phase_buffer] target. Legacy [local_only] aliases are normalized
    through routes before this decision. *)
type local_only_liveness_decision =
  | Keep_effective_cascade of string
  | Probe_local_only_urls of {
      effective_cascade : string;
      fallback_cascade : string;
      probeable_base_urls : string list;
    }

val decide_local_only_liveness :
  ?resolve_label:(string -> Llm_provider.Provider_config.t option) ->
  base_cascade:string ->
  effective_cascade:string ->
  string list ->
  local_only_liveness_decision

(** When phase routing temporarily forces the phase-buffer route, fail open to the
    keeper's configured base cascade if the local Ollama endpoint is
    unavailable. Explicit legacy [local_only] aliases follow the configured
    [routes.phase_buffer] target. Exposed for targeted tests. *)
val fail_open_local_only_when_unavailable :
  ?resolve_label:(string -> Llm_provider.Provider_config.t option) ->
  ?probe_base_url:(string -> bool) ->
  base_cascade:string ->
  effective_cascade:string ->
  string list ->
  string

(** PR-B: when every label in the resolved cascade points at the
    same [base_url] AND a registered [Cascade_capacity_probe]
    recognises that URL, return [Some url]; otherwise [None].
    Purely structural: does not probe the network. Provider variant
    is never inspected. *)
val resolve_shared_probeable_base_url :
  ?resolve_label:(string -> Llm_provider.Provider_config.t option) ->
  ?can_probe:(string -> bool) ->
  string list ->
  string option

(** PR-B: read the [Cascade_capacity_probe] cache and report whether
    the endpoint is saturated (no available slots while at least one
    request is active or queued).  No cache / failed probe returns
    [false] (fail-open) so a flaky probe never starves the keeper. *)
val is_base_url_saturated :
  ?capacity_lookup:(string -> Cascade_throttle.capacity_info option) ->
  string ->
  bool

(** Upper bound on consecutive saturation skips per keeper (env
    [MASC_MAX_CONSECUTIVE_SATURATION_SKIPS], default 5, floored at
    1).  When a keeper exceeds this count its next dispatch escapes
    the saturation pre-skip path so a stuck or stale probe cannot
    starve the keeper indefinitely. *)
val max_consecutive_saturation_skips : unit -> int

(** Current consecutive-skip count for [keeper_name].  Returns 0 when
    the keeper has no recorded skips. *)
val saturation_skip_count_get : keeper_name:string -> int

(** Increment and return the new consecutive-skip count for
    [keeper_name]. *)
val saturation_skip_count_inc : keeper_name:string -> int

(** Reset [keeper_name]'s consecutive-skip count to zero. *)
val saturation_skip_count_reset : keeper_name:string -> unit

(** Test helper: clear all per-keeper consecutive-skip counters. *)
val saturation_skip_count_clear_all : unit -> unit

(** Pure merge step for runtime-owned fail-open rotation candidates. The
    active path feeds this from the live cascade catalog: catalog order is
    preserved while retaining only reserved recovery profiles and
    keeper-assignable profiles. *)
val fail_open_rotation_cascades_from_catalog :
  catalog_names:string list ->
  keeper_assignable:string list ->
  string list option

(** Resolve the next cascade to try after an auto-recoverable failure.
    Uses the current effective cascade, the turn tool requirement, and
    optionally a runtime/catalog-owned rotation order, then suppresses
    suggestions that would loop back to a cascade already attempted during
    the current turn. Exposed for targeted tests. *)
val next_fail_open_cascade_for_turn :
  ?rotation_cascades:string list ->
  base_cascade:string ->
  effective_cascade:string ->
  tool_requirement:Keeper_agent_tool_surface.tool_requirement ->
  attempted_cascades:string list ->
  Agent_sdk.Error.sdk_error ->
  Keeper_error_classify.degraded_retry option

(** Record the streaming-cancel observation shared by the Eio.Cancel handler.
    Exposed so tests can pin the supervisor [fiber_stop] branch without forcing
    a live provider cancellation. *)
val record_streaming_cancelled_observation :
  config:Coord.config ->
  run_meta:Keeper_types.keeper_meta ->
  run_generation:int ->
  cascade_name:Keeper_execution_receipt.cascade_name ->
  keeper_turn_id:int ->
  unit ->
  unit

val run_keeper_cycle :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  observation:Keeper_world_observation.world_observation ->
  generation:int ->
  ?channel:Keeper_world_observation.keeper_cycle_channel ->
  ?semaphore_wait_ms:int ->
  ?turn_slot_control:Keeper_turn_slot.keeper_turn_slot_control ->
  ?shared_context:Agent_sdk.Context.t ->
  ?selected_item:(string * Cascade_ref.cascade_item) ->
  unit ->
  (Keeper_types.keeper_meta, Agent_sdk.Error.sdk_error) result

val run_unified_turn :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  observation:Keeper_world_observation.world_observation ->
  generation:int ->
  ?channel:Keeper_world_observation.keeper_cycle_channel ->
  ?semaphore_wait_ms:int ->
  ?turn_slot_control:Keeper_turn_slot.keeper_turn_slot_control ->
  ?shared_context:Agent_sdk.Context.t ->
  ?selected_item:(string * Cascade_ref.cascade_item) ->
  unit ->
  (Keeper_types.keeper_meta, Agent_sdk.Error.sdk_error) result
