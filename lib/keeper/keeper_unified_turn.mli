(** Keeper_unified_turn — Single entry point for keeper turns via OAS Agent.run().

    Replaces the 3-path dispatcher (social/scheduled-autonomous/autonomy) with a unified
    observe -> prompt -> Agent.run(tools, guardrails, hooks) loop.
    The model decides what to do; code only enforces safety and observes results.

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
(** Cheap persona-derived predicate: returns [true] when the keeper's
    [mention_targets] include one of the verifier role tokens
    (["verifier"; "검증자"]). Used by the dashboard decision-record JSON and
    prompt builder to distinguish verification-authority keepers from the
    rest of the fleet. Pure — does not re-read the persona profile. *)
val is_verifier_role_keeper : Keeper_types.keeper_meta -> bool

(** Derive the ["pending_verification" / ...] trigger list from the
    observation.  When [meta] is supplied, verification-specific triggers
    (currently ["pending_verification"]) are only emitted for keepers whose
    persona declares the verifier role; other keepers see the rest of the
    world unchanged.  When [meta] is omitted, legacy surface-to-all
    behaviour is preserved for diagnostics and snapshot callers. *)
val observed_triggers_of_observation :
  ?meta:Keeper_types.keeper_meta ->
  Keeper_world_observation.world_observation ->
  string list

(** Derive the [["task_claim"; "task_verify"; ...]] affordance list from
    the observation.  Verification affordances ([task_verify]) are gated
    on verifier-role keepers in the same way as
    [observed_triggers_of_observation]; omitting [meta] retains the
    legacy behaviour. *)
val observed_affordances_of_observation :
  ?meta:Keeper_types.keeper_meta ->
  Keeper_world_observation.world_observation ->
  string list

val update_metrics_from_result :
  Keeper_types.keeper_meta ->
  latency_ms:int ->
  observation:Keeper_world_observation.world_observation ->
  ?is_autonomous_turn:bool ->
  (** Compatibility label: still named [update_proactive_rt] because serialized
      runtime fields remain [proactive_*] for now, but it controls scheduled
      autonomous runtime accounting in the unified loop. *)
  ?update_proactive_rt:bool ->
  ?social_state:Keeper_social_model.social_state ->
  ?social_transition_reason:string ->
  Keeper_agent_run.run_result ->
  Keeper_types.keeper_meta

val update_metrics_from_failure :
  Keeper_types.keeper_meta ->
  latency_ms:int ->
  observation:Keeper_world_observation.world_observation ->
  reason:string ->
  ?is_transient:bool ->
  ?social_state:Keeper_social_model.social_state ->
  ?social_transition_reason:string ->
  unit ->
  Keeper_types.keeper_meta

val append_metrics_snapshot :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  observation:Keeper_world_observation.world_observation ->
  result:Keeper_agent_run.run_result ->
  latency_ms:int ->
  turn_cost:float ->
  turn_generation:int ->
  channel:string ->
  snapshot_source:string ->
  context_ratio:float ->
  context_tokens:int ->
  context_max:int ->
  message_count:int ->
  compaction:Keeper_exec_context.compaction_event ->
  handoff_json:Yojson.Safe.t option ->
  ?deliberation_execution:Keeper_deliberation.execution_result ->
  unit ->
  unit

val broadcast_lifecycle_events :
  name:string ->
  turn_generation:int ->
  compaction:Keeper_exec_context.compaction_event ->
  handoff_json:Yojson.Safe.t option ->
  unit

(** Detect transient network errors eligible for retry.
    Uses structured [Oas.Error.sdk_error] pattern matching. *)
val is_transient_network_error : Oas.Error.sdk_error -> bool

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

(** Detect server-side request body parse errors (e.g. Ollama yyjson
    rejecting a malformed request body).  The LLM never
    processed the request, so committed tool results are not at risk
    of duplication.  Used to auto-recover reconcile-safe tools instead
    of requiring manual reconcile. *)
val is_server_rejected_parse_error : Oas.Error.sdk_error -> bool

(** [true] when the keeper should preserve liveness and skip consecutive
    failure counting, even if same-turn retry is still disabled. *)
val is_auto_recoverable_turn_error : Oas.Error.sdk_error -> bool

(** [true] when the provider/tooling violated a required tool-use contract
    by returning text/no-op where a ToolUse block was required. *)
val is_required_tool_contract_violation : Oas.Error.sdk_error -> bool

(** Reclassify any post-commit turn error as a persistent integrity error when
    mutating tool calls already committed in the same turn. *)
val reclassify_error_after_side_effect :
  tool_names:string list ->
  Oas.Error.sdk_error ->
  Oas.Error.sdk_error

val post_commit_failure_kind_of_error :
  Oas.Error.sdk_error -> Keeper_registry.ambiguous_partial_commit_kind

(** [true] when an error represents an ambiguous partial commit after a
    mutating tool call succeeded but the turn failed before a clean result. *)
val is_ambiguous_side_effect_error : Oas.Error.sdk_error -> bool

(** [true] when a structured error indicates context overflow. *)
val is_context_overflow : Oas.Error.sdk_error -> bool

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

(** Build the keeper overflow event from either a drained event-bus
    signal or the structured OAS error fallback. Exposed for tests. *)
val context_overflow_event_of_error :
  fallback_tokens:int ->
  ?turn_event_bus:turn_event_bus_summary ->
  Oas.Error.sdk_error ->
  Keeper_state_machine.event

(** [true] when an error represents terminal cascade exhaustion or a
    final accept-rejected result from the MASC OAS boundary. *)
val is_cascade_exhausted_error : Oas.Error.sdk_error -> bool

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

val run_keeper_cycle :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  observation:Keeper_world_observation.world_observation ->
  generation:int ->
  ?channel:Keeper_world_observation.keeper_cycle_channel ->
  ?semaphore_wait_ms:int ->
  ?shared_context:Agent_sdk.Context.t ->
  unit ->
  (Keeper_types.keeper_meta, Oas.Error.sdk_error) result

val run_unified_turn :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  observation:Keeper_world_observation.world_observation ->
  generation:int ->
  ?channel:Keeper_world_observation.keeper_cycle_channel ->
  ?semaphore_wait_ms:int ->
  ?shared_context:Agent_sdk.Context.t ->
  unit ->
  (Keeper_types.keeper_meta, Oas.Error.sdk_error) result
