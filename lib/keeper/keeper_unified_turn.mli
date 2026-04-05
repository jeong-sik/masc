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

(** Detect transient TCP/TLS errors eligible for retry. Exposed for testing. *)
val is_transient_network_error : string -> bool

(** Parse the provider-reported available context limit from an overflow error. *)
val context_overflow_limit : string -> int option

(** [true] when an error string should trigger overflow recovery handling. *)
val should_attempt_context_overflow_retry : string -> bool

val overflow_retry_history_budget :
  available_context:int ->
  system_prompt:string ->
  user_message:string ->
  int

val run_unified_turn :
  config:Room.config ->
  meta:Keeper_types.keeper_meta ->
  observation:Keeper_world_observation.world_observation ->
  generation:int ->
  ?channel:Keeper_world_observation.unified_turn_channel ->
  unit ->
  (Keeper_types.keeper_meta, string) result
