(** Memory_hooks — OAS hook adapter for hook-first memory injection.

    RFC-MASC-004 Phase 1: Injects memory as text via
    [extra_system_context] in [BeforeTurnParams] and flushes
    incrementally in [AfterTurn].

    Feature flag: [MASC_MEMORY_HOOK_FIRST] (default false).

    @since v2.265.0 (RFC-MASC-004 Phase 1) *)

(** Create OAS hooks for hook-first memory injection.

    @param agent_name Keeper agent name (for procedure lookup and flush)
    @param config Room configuration (for institution loading)
    @param memory OAS Memory.t instance (for AfterTurn flush)
    @param episode_limit Max episodes to inject (default 30)
    @param procedure_limit Max procedures to inject (default 10)

    Returns a [Hooks.hooks] record with:
    - [before_turn_params]: injects memory text via [extra_system_context]
    - [after_turn]: incrementally flushes episodes/procedures *)
val make :
  agent_name:string ->
  config:Room_utils.config ->
  memory:Agent_sdk.Memory.t ->
  ?episode_limit:int ->
  ?procedure_limit:int ->
  unit ->
  Agent_sdk.Hooks.hooks
