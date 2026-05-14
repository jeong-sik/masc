(** Memory_hooks — OAS hook adapter for hook-first memory injection.

    RFC-MASC-004: Injects memory as text via [extra_system_context]
    in [BeforeTurnParams] and flushes incrementally in [AfterTurn].

    This is the sole memory injection path since Phase 2 (v2.266.0).

    @since v2.265.0 (RFC-MASC-004 Phase 1)
    @since v2.266.0 (RFC-MASC-004 Phase 2 — sole path) *)

(** Create OAS hooks for hook-first memory injection.

    @param agent_name Keeper agent name (for procedure lookup and flush)
    @param config Coord configuration (for institution loading)
    @param memory OAS Memory.t instance (for AfterTurn flush)
    @param episode_limit Max episodes to inject (default 30)
    @param procedure_limit Max procedures to inject (default 10)
    @param flush_incremental Dependency-injection hook for tests; it returns
           persisted episode/procedure counts.

    Returns a [Hooks.hooks] record with:
    - [before_turn_params]: injects memory text via [extra_system_context]
    - [after_turn]: incrementally flushes episodes/procedures *)
val render_memory_context :
  ?memory:Agent_sdk.Memory.t ->
  ?world_backend:Agent_sdk.Memory.long_term_backend ->
  agent_name:string ->
  config:Coord_utils.config ->
  episode_limit:int ->
  procedure_limit:int ->
  ?world_limit:int ->
  unit ->
  string option

val make :
  agent_name:string ->
  config:Coord_utils.config ->
  memory:Agent_sdk.Memory.t ->
  ?world_backend:Agent_sdk.Memory.long_term_backend ->
  ?episode_limit:int ->
  ?procedure_limit:int ->
  ?flush_incremental:
    (memory:Agent_sdk.Memory.t -> agent_name:string -> int * int) ->
  ?runtime_manifest_context:Keeper_runtime_manifest.turn_context ->
  ?runtime_manifest_append:(Keeper_runtime_manifest.t -> unit) ->
  unit ->
  Agent_sdk.Hooks.hooks

val compose_with_inner :
  memory_hooks:Agent_sdk.Hooks.hooks ->
  inner:Agent_sdk.Hooks.hooks ->
  Agent_sdk.Hooks.hooks
(** Compose memory hooks with existing keeper hooks while preserving the
    keeper [before_turn_params] slot.  When memory injects adjusted turn
    params, the inner hook is invoked with those params instead of being
    bypassed by generic OAS hook composition. *)
