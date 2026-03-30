(** Keeper_unified_turn — Single entry point for keeper turns via OAS Agent.run().

    Replaces the 3-path dispatcher (social/proactive/autonomy) with a unified
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
  ?social_state:Keeper_social_model.social_state ->
  Keeper_agent_run.run_result ->
  Keeper_types.keeper_meta

val update_metrics_from_failure :
  Keeper_types.keeper_meta ->
  latency_ms:int ->
  reason:string ->
  ?social_state:Keeper_social_model.social_state ->
  unit ->
  Keeper_types.keeper_meta

val run_unified_turn :
  config:Room.config ->
  meta:Keeper_types.keeper_meta ->
  observation:Keeper_world_observation.world_observation ->
  generation:int ->
  (Keeper_types.keeper_meta, string) result
