(** Memory_hooks — OAS hook adapter for hook-first memory injection.

    RFC-MASC-004: Instead of imperatively pushing memory into OAS
    [Memory.t] tiers before [Agent.run], this module injects memory
    as text via [extra_system_context] in the [BeforeTurnParams] hook
    and flushes incrementally in the [AfterTurn] hook.

    This eliminates the MASC-to-OAS lifecycle invasion where the former
    [create_memory_full] directly manipulated OAS memory state.

    The hook is composed (via [compose_with_inner]) with existing keeper
    hooks so existing safety/cost/tool-disclosure hooks remain untouched.

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
    ?memory
    ?world_backend
    ~(agent_name : string)
    ~(config : Coord_utils.config)
    ~(episode_limit : int)
    ~(procedure_limit : int)
    ?(world_limit = 8)
    () : string option =
  let sections =
    [ Memory_oas_bridge.load_institution_text ~config
    ; Option.bind memory (fun memory ->
        Memory_oas_bridge.load_world_text ~backend:world_backend
          ~memory ~limit:world_limit)
    ; Memory_oas_bridge.load_episodes_text ~limit:episode_limit
    ; Memory_oas_bridge.load_procedures_text ~agent_name ~limit:procedure_limit
    ]
    |> List.filter_map Fun.id
  in
  match sections with
  | [] -> None
  | parts -> Some (String.concat "\n\n" parts)

let before_turn_params_event_with_current_params event current_params =
  match event with
  | Agent_sdk.Hooks.BeforeTurnParams params ->
      Agent_sdk.Hooks.BeforeTurnParams { params with current_params }
  | _ -> event

let compose_before_turn_params outer inner =
  match outer, inner with
  | None, None -> None
  | Some _, None -> outer
  | None, Some _ -> inner
  | Some f_outer, Some f_inner ->
      Some
        (fun event ->
          match f_outer event with
          | Agent_sdk.Hooks.Continue -> f_inner event
          | Agent_sdk.Hooks.AdjustParams params ->
              let event' =
                before_turn_params_event_with_current_params event params
              in
              (match f_inner event' with
               | Agent_sdk.Hooks.Continue -> Agent_sdk.Hooks.AdjustParams params
               | decision -> decision)
          | decision -> decision)

let compose_with_inner ~memory_hooks ~inner =
  let composed =
    Agent_sdk.Hooks.compose ~outer:memory_hooks ~inner
  in
  { composed with
    before_turn_params =
      compose_before_turn_params
        memory_hooks.Agent_sdk.Hooks.before_turn_params
        inner.Agent_sdk.Hooks.before_turn_params
  }

let record_pipeline_flush
    ~(agent_name : string)
    ~(outcome : string)
    ~(duration_s : float)
    ~(episodes : int)
    ~(procedures : int) =
  let outcome_labels = [ ("agent_name", agent_name); ("outcome", outcome) ] in
  Prometheus.inc_counter
    Prometheus.metric_memory_pipeline_flushes
    ~labels:outcome_labels
    ();
  Prometheus.observe_histogram
    Prometheus.metric_memory_pipeline_flush_duration_seconds
    ~labels:outcome_labels
    duration_s;
  let record_records ~tier count =
    if count > 0 then
      Prometheus.inc_counter
        Prometheus.metric_memory_pipeline_flush_records
        ~labels:[ ("agent_name", agent_name); ("tier", tier) ]
        ~delta:(float_of_int count)
        ()
  in
  record_records ~tier:"episodic" episodes;
  record_records ~tier:"procedural" procedures

let append_runtime_manifest
    ?runtime_manifest_context
    ?runtime_manifest_append
    ?oas_turn_count
    ?(status = "ok")
    ?(decision = `Assoc [])
    event =
  match runtime_manifest_context, runtime_manifest_append with
  | Some context, Some append ->
      let manifest =
        Keeper_runtime_manifest.make_for_context context ~event ?oas_turn_count
          ~status ~decision ()
      in
      (try append manifest with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
         Log.Keeper.warn
           "memory_hooks: runtime manifest append callback failed agent=%s event=%s: %s"
           context.manifest_keeper_name
           (Keeper_runtime_manifest.event_kind_to_string event)
           (Printexc.to_string exn))
  | _ -> ()

(** Create OAS hooks for hook-first memory injection.

    @param agent_name Keeper agent name (for procedure/episode lookup)
    @param config Coord configuration (for institution loading)
    @param memory OAS Memory.t instance (for AfterTurn flush)
    @param episode_limit Max episodes to inject (default 30)
    @param procedure_limit Max procedures to inject (default 10)
    @param flush_incremental Dependency-injection seam for tests; returns
           persisted episode/procedure counts.

    Returns a [Hooks.hooks] record with:
    - [before_turn_params]: injects memory text via [extra_system_context]
    - [after_turn]: incrementally flushes episodes/procedures

    Compose with other hooks via [compose_with_inner] so memory-adjusted
    [BeforeTurnParams] are passed to the inner keeper hooks:
    {[
      let memory_hooks = Memory_hooks.make ~agent_name ~config ~memory () in
      let hooks = Memory_hooks.compose_with_inner ~memory_hooks ~inner:base_hooks
    ]} *)
let make
    ~(agent_name : string)
    ~(config : Coord_utils.config)
    ~(memory : Agent_sdk.Memory.t)
    ?world_backend
    ?(episode_limit = 30)
    ?(procedure_limit = 10)
    ?(flush_incremental = Memory_oas_bridge.flush_incremental)
    ?runtime_manifest_context
    ?runtime_manifest_append
    () : Agent_sdk.Hooks.hooks =
  { Agent_sdk.Hooks.empty with

    before_turn_params = Some (fun event ->
      match event with
      | Agent_sdk.Hooks.BeforeTurnParams { turn; current_params; _ } ->
        let memory_ctx =
          render_memory_context ~memory ?world_backend ~agent_name ~config
            ~episode_limit ~procedure_limit ()
        in
        (match memory_ctx with
         | None ->
           append_runtime_manifest
             ?runtime_manifest_context
             ?runtime_manifest_append
             ~oas_turn_count:turn
             ~status:"skipped"
             ~decision:
               (`Assoc
                 [
                   ("memory_context_present", `Bool false);
                   ("episode_limit", `Int episode_limit);
                   ("procedure_limit", `Int procedure_limit);
                   ( "existing_extra_system_context_present",
                     `Bool (Option.is_some current_params.extra_system_context) );
                   ( "existing_extra_system_context_chars",
                     `Int
                       (match current_params.extra_system_context with
                        | None -> 0
                        | Some text -> String.length text) );
                 ])
             Keeper_runtime_manifest.Memory_injected;
           Agent_sdk.Hooks.Continue
         | Some mem_text ->
           let extra =
             match current_params.extra_system_context with
             | None -> Some mem_text
             | Some existing -> Some (existing ^ "\n\n" ^ mem_text)
           in
           append_runtime_manifest
             ?runtime_manifest_context
             ?runtime_manifest_append
             ~oas_turn_count:turn
             ~status:"injected"
             ~decision:
               (`Assoc
                 [
                   ("memory_context_present", `Bool true);
                   ("memory_context_chars", `Int (String.length mem_text));
                   ( "memory_context_digest",
                     `String (Digest.to_hex (Digest.string mem_text)) );
                   ("episode_limit", `Int episode_limit);
                   ("procedure_limit", `Int procedure_limit);
                   ( "existing_extra_system_context_present",
                     `Bool (Option.is_some current_params.extra_system_context) );
                   ( "existing_extra_system_context_chars",
                     `Int
                       (match current_params.extra_system_context with
                        | None -> 0
                        | Some text -> String.length text) );
                   ( "extra_system_context_chars_after",
                     `Int
                       (match extra with
                        | None -> 0
                        | Some text -> String.length text) );
                 ])
             Keeper_runtime_manifest.Memory_injected;
           Agent_sdk.Hooks.AdjustParams
             { current_params with extra_system_context = extra })
      | _ -> Agent_sdk.Hooks.Continue);

    after_turn = Some (fun event ->
      match event with
      | Agent_sdk.Hooks.AfterTurn { turn; response } ->
        let started_at = Time_compat.now () in
        (try
           let (ep, pr) = flush_incremental ~memory ~agent_name in
           let duration_s = max 0.0 (Time_compat.now () -. started_at) in
           record_pipeline_flush
             ~agent_name
             ~outcome:"success"
             ~duration_s
             ~episodes:ep
             ~procedures:pr;
           if ep > 0 || pr > 0 then
             Log.Keeper.debug
               "memory_hooks: flush_incremental agent=%s episodes=%d procedures=%d"
               agent_name ep pr;
           append_runtime_manifest
             ?runtime_manifest_context
             ?runtime_manifest_append
             ~oas_turn_count:turn
             ~status:"success"
             ~decision:
               (`Assoc
                 [
                   ("episodes_flushed", `Int ep);
                   ("procedures_flushed", `Int pr);
                   ("duration_s", `Float duration_s);
                   ("response_model", `String response.Agent_sdk.Types.model);
                 ])
             Keeper_runtime_manifest.Memory_flushed
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
             Prometheus.inc_counter
               Keeper_metrics.metric_keeper_lifecycle_callback_failures
               ~labels:
                 [("callback", "memory_after_turn_flush")]
               ();
             let duration_s = max 0.0 (Time_compat.now () -. started_at) in
             record_pipeline_flush
               ~agent_name
               ~outcome:"error"
               ~duration_s
               ~episodes:0
               ~procedures:0;
             append_runtime_manifest
               ?runtime_manifest_context
               ?runtime_manifest_append
               ~oas_turn_count:turn
               ~status:"error"
               ~decision:
                 (`Assoc
                   [
                     ("episodes_flushed", `Int 0);
                     ("procedures_flushed", `Int 0);
                     ("duration_s", `Float duration_s);
                     ("error", `String (Printexc.to_string exn));
                     ("response_model", `String response.Agent_sdk.Types.model);
                   ])
               Keeper_runtime_manifest.Memory_flushed;
             Log.Keeper.warn
               "memory_hooks: flush_incremental failed agent=%s: %s"
               agent_name (Printexc.to_string exn));
        Agent_sdk.Hooks.Continue
      | _ -> Agent_sdk.Hooks.Continue);
  }
