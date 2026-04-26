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

    Returns a [Hooks.hooks] record with:
    - [before_turn_params]: injects memory text via [extra_system_context]
    - [after_turn]: incrementally flushes episodes/procedures *)
val render_memory_context
  :  agent_name:string
  -> config:Coord_utils.config
  -> episode_limit:int
  -> procedure_limit:int
  -> unit
  -> string option

val make
  :  agent_name:string
  -> config:Coord_utils.config
  -> memory:Agent_sdk.Memory.t
  -> ?episode_limit:int
  -> ?procedure_limit:int
  -> unit
  -> Agent_sdk.Hooks.hooks
