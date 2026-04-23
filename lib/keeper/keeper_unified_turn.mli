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
  max_context:int -> remaining_turn_budget_s:float -> float option

val bounded_oas_timeout_for_turn_budget_with_turn_budget :
  max_context:int ->
  max_turns:int ->
  remaining_turn_budget_s:float ->
  float option

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
  Oas.Event_bus.event list -> turn_event_bus_summary

(** Build the keeper overflow event from either a drained event-bus
    signal or the structured OAS error fallback. Exposed for tests. *)
val context_overflow_event_of_error :
  fallback_tokens:int ->
  ?turn_event_bus:turn_event_bus_summary ->
  Oas.Error.sdk_error ->
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

(** Ensure local-provider discovery is refreshed before a turn when the
    selected labels depend on runtime discovery. Exposed for targeted tests. *)
val ensure_local_discovery_ready :
  ?refresh:(string list -> bool) ->
  string list ->
  (unit, string) result

(** When phase routing temporarily forces [local_only], fail open to the
    keeper's configured base cascade if the local Ollama endpoint is
    unavailable. Explicit [local_only] keepers are preserved. Exposed for
    targeted tests. *)
val fail_open_local_only_when_unavailable :
  ?resolve_label:(string -> Llm_provider.Provider_config.t option) ->
  ?probe_ollama_base_url:(string -> bool) ->
  base_cascade:string ->
  effective_cascade:string ->
  string list ->
  string

(** Resolve the next cascade to try after an auto-recoverable failure.
    Uses the current effective cascade plus the turn tool requirement, then
    suppresses suggestions that would loop back to a cascade already
    attempted during the current turn. Exposed for targeted tests. *)
val next_fail_open_cascade_for_turn :
  base_cascade:string ->
  effective_cascade:string ->
  tool_requirement:string ->
  attempted_cascades:string list ->
  Oas.Error.sdk_error ->
  Keeper_error_classify.degraded_retry option

val run_keeper_cycle :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  observation:Keeper_world_observation.world_observation ->
  generation:int ->
  ?channel:Keeper_world_observation.keeper_cycle_channel ->
  ?semaphore_wait_ms:int ->
  ?shared_context:Oas.Context.t ->
  unit ->
  (Keeper_types.keeper_meta, Oas.Error.sdk_error) result

val run_unified_turn :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  observation:Keeper_world_observation.world_observation ->
  generation:int ->
  ?channel:Keeper_world_observation.keeper_cycle_channel ->
  ?semaphore_wait_ms:int ->
  ?shared_context:Oas.Context.t ->
  unit ->
  (Keeper_types.keeper_meta, Oas.Error.sdk_error) result
