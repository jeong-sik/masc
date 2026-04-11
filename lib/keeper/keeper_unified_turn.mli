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

    @param config Room configuration
    @param meta Current keeper metadata
    @param observation World state snapshot
    @param generation Current generation counter *)
(** Update keeper metrics by observing what the agent did (tool calls, text output).
    No action classification — metrics are derived from the run result.

    Exposed for testing. *)
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
  Keeper_agent_run.run_result ->
  Keeper_types.keeper_meta

val update_metrics_from_failure :
  Keeper_types.keeper_meta ->
  latency_ms:int ->
  observation:Keeper_world_observation.world_observation ->
  reason:string ->
  ?is_transient:bool ->
  ?social_state:Keeper_social_model.social_state ->
  unit ->
  Keeper_types.keeper_meta

val append_metrics_snapshot :
  config:Room.config ->
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

(** Detect server-side request body parse errors (e.g. Ollama yyjson
    rejecting a malformed request body).  The LLM never
    processed the request, so committed tool results are not at risk
    of duplication.  Used to auto-recover reconcile-safe tools instead
    of requiring manual reconcile. *)
val is_server_rejected_parse_error : Oas.Error.sdk_error -> bool

(** [true] when the keeper should preserve liveness and skip consecutive
    failure counting, even if same-turn retry is still disabled. *)
val is_auto_recoverable_turn_error : Oas.Error.sdk_error -> bool

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

val run_unified_turn :
  config:Room.config ->
  meta:Keeper_types.keeper_meta ->
  observation:Keeper_world_observation.world_observation ->
  generation:int ->
  ?channel:Keeper_world_observation.unified_turn_channel ->
  ?semaphore_wait_ms:int ->
  ?shared_context:Agent_sdk.Context.t ->
  unit ->
  (Keeper_types.keeper_meta, Oas.Error.sdk_error) result
