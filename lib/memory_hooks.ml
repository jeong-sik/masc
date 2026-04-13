(** Memory_hooks — OAS hook adapter for hook-first memory injection.

    RFC-MASC-004: Instead of imperatively pushing memory into OAS
    [Memory.t] tiers before [Agent.run], this module injects memory
    as text via [extra_system_context] in the [BeforeTurnParams] hook
    and flushes incrementally in the [AfterTurn] hook.

    This eliminates the MASC-to-OAS lifecycle invasion where the former
    [create_memory_full] directly manipulated OAS memory state.

    The hook is composed (via [Hooks.compose]) with existing keeper hooks
    so existing safety/cost/tool-disclosure hooks remain untouched.

    Phase 1 introduced this as an opt-in path behind
    [MASC_MEMORY_HOOK_FIRST]. Phase 2 made it the only path and
    removed the feature flag. Phase 3 removed all dead imperative
    seeding functions from [Memory_oas_bridge].

    @since v2.265.0 (RFC-MASC-004 Phase 1)
    @since v2.266.0 (RFC-MASC-004 Phase 2-3 — legacy functions removed) *)

(** Build an [extra_system_context] string from episodic, procedural,
    and institutional memory.

    Returns [None] when all memory sources are empty. Sections are
    separated by blank lines.  The caller appends this to any existing
    [extra_system_context] from upstream hooks.

    Pure: no side effects, no OAS state mutation. *)
let render_memory_context
    ~(agent_name : string)
    ~(config : Room_utils.config)
    ~(episode_limit : int)
    ~(procedure_limit : int)
    () : string option =
  let sections =
    [ Memory_oas_bridge.load_institution_text ~config
    ; Memory_oas_bridge.load_episodes_text ~limit:episode_limit
    ; Memory_oas_bridge.load_procedures_text ~agent_name ~limit:procedure_limit
    ]
    |> List.filter_map Fun.id
  in
  match sections with
  | [] -> None
  | parts -> Some (String.concat "\n\n" parts)

(** Create OAS hooks for hook-first memory injection.

    @param agent_name Keeper agent name (for procedure/episode lookup)
    @param config Room configuration (for institution loading)
    @param memory OAS Memory.t instance (for AfterTurn flush)
    @param episode_limit Max episodes to inject (default 30)
    @param procedure_limit Max procedures to inject (default 10)

    Returns a [Hooks.hooks] record with:
    - [before_turn_params]: injects memory text via [extra_system_context]
    - [after_turn]: incrementally flushes episodes/procedures

    Compose with other hooks via [Hooks.compose]:
    {[
      let memory_hooks = Memory_hooks.make ~agent_name ~config ~memory () in
      let hooks = Hooks.compose ~outer:memory_hooks ~inner:base_hooks
    ]} *)
let make
    ~(agent_name : string)
    ~(config : Room_utils.config)
    ~(memory : Agent_sdk.Memory.t)
    ?(episode_limit = 30)
    ?(procedure_limit = 10)
    () : Agent_sdk.Hooks.hooks =
  { Agent_sdk.Hooks.empty with

    before_turn_params = Some (fun event ->
      match event with
      | Agent_sdk.Hooks.BeforeTurnParams { current_params; _ } ->
        let memory_ctx =
          render_memory_context ~agent_name ~config
            ~episode_limit ~procedure_limit ()
        in
        (match memory_ctx with
         | None -> Agent_sdk.Hooks.Continue
         | Some mem_text ->
           let extra =
             match current_params.extra_system_context with
             | None -> Some mem_text
             | Some existing -> Some (existing ^ "\n\n" ^ mem_text)
           in
           Agent_sdk.Hooks.AdjustParams
             { current_params with extra_system_context = extra })
      | _ -> Agent_sdk.Hooks.Continue);

    after_turn = Some (fun event ->
      match event with
      | Agent_sdk.Hooks.AfterTurn _ ->
        let (ep, pr) =
          Memory_oas_bridge.flush_incremental ~memory ~agent_name
        in
        if ep > 0 || pr > 0 then
          Log.Keeper.debug
            "memory_hooks: flush_incremental agent=%s episodes=%d procedures=%d"
            agent_name ep pr;
        Agent_sdk.Hooks.Continue
      | _ -> Agent_sdk.Hooks.Continue);
  }
