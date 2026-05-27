(* keeper_run_tools_setup — extracted from keeper_run_tools.ml.
   Contains the full implementation of prepare_agent_setup. *)

open Keeper_types
open Keeper_agent_tool_surface
open Keeper_agent_result
open Keeper_agent_error
open Keeper_agent_prompt_metrics

let prepare_agent_setup
      ~(config : Coord.config)
      ~(meta : Keeper_types.keeper_meta)
      ~(ctx_work : working_context)
      ~(session : Keeper_types.session_context)
      ~(base_system_prompt : string)
      ~(turn_system_prompt : string)
      ~(user_message : string)
      ~(dynamic_context : string)
      ~(history_messages : Agent_sdk.Types.message list)
      ~(prompt_metrics : Keeper_agent_prompt_metrics.prompt_metrics)
      ~(shared_context : Agent_sdk.Context.t)
      ~(context_injector : Agent_sdk.Hooks.context_injector)
      ~(start_turn_count : int)
      ~(generation : int)
      ~(max_turns : int)
      ~(cascade_name : Cascade_name.t)
      ~(is_retry : bool)
      ~(turn_affordances : string list)
      ~(required_tool_names : string list)
      ~(config_root : string)
      ~(cascade_config_path : string option)
      ~(gemini_mcp_disabled : bool)
      ~(approval_mode_effective : string option)
      ~(approval_mode_derived : bool)
      ?(actionable_signal = false)
      ?max_cost_usd
      ~(trajectory_acc : Trajectory.accumulator option)
      ~(tool_overlay : Agent_sdk.Tool_op.t ref option)
      ?runtime_manifest_context
      ?runtime_manifest_append
      ()
  : (Keeper_run_tools_hooks.agent_setup, Agent_sdk.Error.sdk_error) result
  =
  let cascade_name_string = Cascade_name.to_string cascade_name in
  let manifest_keeper_turn_id =
    match runtime_manifest_context with
    | Some ctx -> ctx.Keeper_runtime_manifest.manifest_keeper_turn_id
    | None -> None
  in
  let ctx_snapshot = ctx_work in
  let agent_name = meta.agent_name in
  let acc : Keeper_run_tools_hook_accumulator.hook_accumulator =
    { meta
    ; tool_calls = []
    ; current_turn = 0
    ; completion_contract = Keeper_tool_completion_contract.Allow_text_or_tool
    ; required_tool_use_seen = false
    ; keeper_surface_tool_used = false
    ; discovered =
        Keeper_discovered_tools.create
          ~decay_turns:
            (match Sys.getenv_opt "MASC_KEEPER_TOOL_DECAY_TURNS" with
             | Some s ->
               (match int_of_string_opt s with
                | Some n -> max 1 n
                | None ->
                  Log.Keeper.warn
                    "keeper: MASC_KEEPER_TOOL_DECAY_TURNS=%S is not a valid integer, \
                     using default 5"
                    s;
                  Prometheus.inc_counter
                    Keeper_metrics.(to_string ConfigEnvParseFailures)
                    ~labels:[ "var", "MASC_KEEPER_TOOL_DECAY_TURNS" ]
                    ();
                  5)
             | None -> 5)
    ; tool_overlay =
        (match tool_overlay with
         | Some r -> !r
         | None -> Agent_sdk.Tool_op.Keep_all)
    ; tool_surface =
        { turn_lane = Keeper_agent_tool_surface.Lane_text_only
        ; tool_surface_class = Keeper_agent_tool_surface.Surface_none
        ; tool_requirement = No_tools
        ; visible_tool_count = 0
        ; tool_gate_enabled = false
        ; tool_surface_fallback_used = false
        ; required_tool_names = []
        ; required_tool_candidate_names = []
        ; missing_required_tool_names = []
        ; config_root
        ; cascade_config_path
        ; gemini_mcp_disabled
        ; approval_mode_effective
        ; approval_mode_derived
        }
    ; requested_tool_names = []
    ; requested_tool_names_seen = []
    ; receipt_tool_contract_result =
        Keeper_execution_receipt.Contract_unknown
    ; contract_violation_retries = 0
    }
  in
  let agent_ref : Agent_sdk.Agent.t option ref = ref None in
  let local_search_fn_ref : (query:string -> max_results:int -> Yojson.Safe.t) ref =
    ref (fun ~query:_ ~max_results:_ -> `Assoc [ "results", `List [] ])
  in
  let affinity_k = Keeper_tool_affinity.configured_max_k () in
  if affinity_k > 0
  then (
    let masc_root = Coord.masc_root_dir config in
    let allowed = Keeper_tool_policy.keeper_allowed_tool_names meta in
    let core = Keeper_tool_registry.core_discovery_tools in
    let entries =
      Keeper_tool_affinity.pre_populate_from_history
        ~masc_root
        ~keeper_name:meta.name
        ~allowed_tool_names:allowed
        ~core_tool_names:core
        ~discovered:acc.discovered
        ~max_k:affinity_k
    in
    if entries <> []
    then
      Log.Keeper.routine
        "keeper:%s affinity pre-populated %d tools: [%s]"
        meta.name
        (List.length entries)
        (String.concat
           ", "
           (List.map
              (fun (e : Keeper_tool_affinity.affinity_entry) ->
                 Printf.sprintf "%s(%.1f)" e.tool_name e.score)
              entries)));
  let keeper_tool_bundle =
    Keeper_tools_oas_bundle.make_tool_bundle
      ~config
      ~meta
      ~ctx_snapshot
      ~search_fn:(fun ~query ~max_results -> !local_search_fn_ref ~query ~max_results)
      ~on_tool_called:(fun name ->
        Keeper_discovered_tools.mark_used acc.discovered ~turn:acc.current_turn ~name)
      ()
  in
  let keeper_tools = keeper_tool_bundle.tools in
  let extend_turns_tool = Keeper_extend_turns.make ~agent_ref ~max_turns () in
  let tools = extend_turns_tool :: keeper_tools in
  let tool_usage_before =
    Keeper_tool_observation.keeper_tool_usage_snapshot
      ~base_path:config.base_path
      ~keeper_name:meta.name
  in
  let tool_index_config =
    { Agent_sdk.Tool_index.default_config with
      top_k = Keeper_config.keeper_tool_search_top_k ()
    }
  in
  let tool_entries = List.map tool_index_entry_of_tool keeper_tools in
  let search_index = Agent_sdk.Tool_index.build ~config:tool_index_config tool_entries in
  let load_preset_selection_context () =
    let preset_names = Keeper_tool_policy.keeper_preset_universe_tool_names meta in
    let preset_set = Hashtbl.create (List.length preset_names) in
    List.iter (fun n -> Hashtbl.replace preset_set n true) preset_names;
    let preset_tools =
      List.filter
        (fun (t : Agent_sdk.Tool.t) -> Hashtbl.mem preset_set t.schema.name)
        keeper_tools
    in
    let progressive_tool_index_config =
      { Agent_sdk.Tool_index.default_config with
        top_k = keeper_selection_bm25_prefilter_n
      }
    in
    let preset_tool_entries = List.map tool_index_entry_of_tool preset_tools in
    ( preset_tools
    , Agent_sdk.Tool_index.build ~config:progressive_tool_index_config preset_tool_entries
    )
  in
  let oas_description_map =
    let tbl = Hashtbl.create (List.length keeper_tools) in
    List.iter
      (fun (t : Agent_sdk.Tool.t) ->
         Hashtbl.replace tbl t.schema.name t.schema.description)
      keeper_tools;
    tbl
  in
  let oas_input_schema_map =
    let tbl = Hashtbl.create (List.length keeper_tools) in
    List.iter
      (fun (t : Agent_sdk.Tool.t) ->
         let param_type_str (pt : Agent_sdk.Types.param_type) =
           match pt with
           | String -> "string"
           | Integer -> "integer"
           | Number -> "number"
           | Boolean -> "boolean"
           | Array -> "array"
           | Object -> "object"
         in
         let props =
           List.map
             (fun (p : Agent_sdk.Types.tool_param) ->
                ( p.name
                , `Assoc
                    [ "type", `String (param_type_str p.param_type)
                    ; "description", `String p.description
                    ] ))
             t.schema.parameters
         in
         let required =
           t.schema.parameters
           |> List.filter (fun (p : Agent_sdk.Types.tool_param) -> p.required)
           |> List.map (fun (p : Agent_sdk.Types.tool_param) -> `String p.name)
         in
         let schema =
           `Assoc
             [ "type", `String "object"
             ; "properties", `Assoc props
             ; "required", `List required
             ]
         in
         Hashtbl.replace tbl t.schema.name schema)
      keeper_tools;
    tbl
  in
  (local_search_fn_ref
   := fun ~query ~max_results ->
        let core = Agent_tool_dispatch_runtime.effective_core_tools () in
        let retrieved = Agent_sdk.Tool_index.retrieve search_index query in
        let partition =
          Keeper_run_tools_search.partition_tool_search_hits
            ~core
            ~core_always:Keeper_tool_registry.core_always_tools
            ~allowed:(Agent_tool_dispatch_runtime.keeper_allowed_tool_names meta)
            ~retrieved
            ~max_results
        in
        let raw_hit_count = List.length retrieved in
        let matched_core_names = List.map fst partition.visible_core_hits in
        let core_hit_count = List.length matched_core_names in
        let filtered_by_core = 0 in
        let new_discoveries = partition.discoverable_hits in
        let filtered_by_policy = partition.filtered_by_policy in
        let discovered_names = List.map fst new_discoveries in
        Keeper_discovered_tools.add
          acc.discovered
          ~turn:acc.current_turn
          ~names:discovered_names;
        let masc_schemas = Agent_tool_dispatch_runtime.masc_schemas_snapshot () in
        let result_json ~already_visible (name, score) =
          let help_opt = Tool_help_registry.find_entry masc_schemas name in
          let desc =
            match help_opt with
            | Some e -> `String e.short_description
            | None ->
              (match Hashtbl.find_opt oas_description_map name with
               | Some d -> `String d
               | None -> `Null)
          in
          let when_to_use =
            match help_opt with
            | Some e -> `String e.when_to_use
            | None -> `Null
          in
          let input_schema =
            match
              List.find_opt
                (fun (s : Masc_domain.tool_schema) -> s.name = name)
                masc_schemas
            with
            | Some s -> s.input_schema
            | None ->
              (match Hashtbl.find_opt oas_input_schema_map name with
               | Some j -> j
               | None -> `Null)
          in
          `Assoc
            [ "name", `String name
            ; "score", `Float score
            ; "description", desc
            ; "when_to_use", when_to_use
            ; "input_schema", input_schema
            ; "already_visible", `Bool already_visible
            ]
        in
        let matched_core_results =
          partition.visible_core_hits |> List.map (result_json ~already_visible:true)
        in
        let discovery_results =
          List.map (result_json ~already_visible:false) new_discoveries
        in
        let results = matched_core_results @ discovery_results in
        let hint =
          match discovery_results, matched_core_names with
          | [], [] when raw_hit_count = 0 ->
            "No tools match this query. Try different keywords (e.g., 'worktree', \
             'board', 'github')."
          | [], _ :: _ when filtered_by_policy = 0 ->
            Printf.sprintf
              "Already loaded: %s. Call directly — no search needed."
              (String.concat ", " matched_core_names)
          | [], _ when filtered_by_policy > 0 ->
            let core_part =
              match matched_core_names with
              | [] -> ""
              | names -> Printf.sprintf " Already loaded: %s." (String.concat ", " names)
            in
            Printf.sprintf
              "Found %d matches but all filtered (already visible or policy-denied).%s"
              (filtered_by_policy + List.length matched_core_names)
              core_part
          | [], _ ->
            Printf.sprintf
              "Found %d raw BM25 hits but all are already in your core tool set."
              raw_hit_count
          | _, _ -> "Call any of these tools by name in this or a future turn."
        in
        `Assoc
          ([ "ok", `Bool true
           ; "query", `String query
           ; "results", `List results
           ; "result_count", `Int (List.length results)
           ]
           @ (match matched_core_names with
              | [] -> []
              | names ->
                [ "already_visible", `List (List.map (fun n -> `String n) names) ])
           @ [ ( "diagnostics"
               , `Assoc
                   [ "raw_bm25_hits", `Int raw_hit_count
                   ; "filtered_by_core", `Int filtered_by_core
                   ; "core_hit_count", `Int core_hit_count
                   ; "filtered_by_policy", `Int filtered_by_policy
                   ] )
             ; "hint", `String hint
             ]));
  if Keeper_types_profile.keeper_debug
  then
    Log.Keeper.routine
      "keeper:%s tool visibility: total=%d search_indexed=%d"
      meta.name
      (List.length keeper_tools)
      (List.length tool_entries);
  let always_include_tools = Agent_tool_dispatch_runtime.core_always_tools in
  let all_tool_names =
    "extend_turns" :: List.map (fun (t : Agent_sdk.Tool.t) -> t.schema.name) keeper_tools
  in
  let universe_set = Keeper_tool_policy.tool_name_set all_tool_names in
  let allowed_exec_names = Agent_tool_dispatch_runtime.keeper_allowed_tool_names meta in
  (* RFC-0064 Phase 2: Remove aliased internal names from the LLM-visible
     policy surface. Public aliases are the LLM-visible names; internal
     counterparts are implementation details.

     Order matters: compute [aliased_public_names] against the UNFILTERED
     internal allowlist, because tool_policy.toml / presets still express
     allowlists in descriptor/internal names (tool_execute, tool_read_file, ...).
     Stripping internals before the alias-expansion check would leave
     [aliased_public_names] empty and drop "Execute"/"ReadFile"/... from the
     visible surface. See PR #14596 review. *)
  let aliased_internal_names =
    List.filter_map
      (fun public ->
         match Keeper_tool_alias.route public with
         | Some r -> Some r.internal_name
         | None -> None)
      (Keeper_tool_alias.public_names ())
  in
  (* Only include a public alias name when its routed internal target is
     itself in [allowed_exec_names]. Otherwise the public name (e.g. "Execute")
     could let the LLM invoke a tool whose internal handler the current
     keeper/preset has explicitly excluded — the alias would dispatch to
     a registered-but-disallowed tool. See PR #14574 review. *)
  let allowed_set_for_alias_filter =
    Keeper_tool_policy.tool_name_set allowed_exec_names
  in
  let aliased_public_names =
    List.filter
      (fun public ->
         match Keeper_tool_alias.route public with
         | Some r ->
           Keeper_tool_policy.StringSet.mem r.internal_name allowed_set_for_alias_filter
         | None -> false)
      (Keeper_tool_alias.public_names ())
  in
  (* Now strip the aliased internal names from the LLM-visible surface,
     after [aliased_public_names] has been computed. *)
  let allowed_exec_names =
    List.filter
      (fun name -> not (List.mem name aliased_internal_names))
      allowed_exec_names
  in
  let allowed_exec_names_with_aliases = allowed_exec_names @ aliased_public_names in
  let allowed_exec_set =
    let base = Keeper_tool_policy.tool_name_set allowed_exec_names_with_aliases in
    Keeper_tool_policy.StringSet.union
      base
      (Keeper_tool_policy.tool_name_set Keeper_tool_registry.core_always_tools)
  in
  let allowed_public_alias_for_internal internal_name =
    List.find_map
      (fun public_name ->
         match Keeper_tool_alias.route public_name with
         | Some route
           when String.equal route.internal_name internal_name
                && Keeper_tool_policy.StringSet.mem public_name universe_set
                && Keeper_tool_policy.StringSet.mem public_name allowed_exec_set ->
           Some public_name
         | _ -> None)
      (Keeper_tool_alias.public_names ())
  in
  let max_tools_per_turn =
    if is_retry
    then Keeper_config.keeper_retry_max_tools_per_turn ()
    else Keeper_config.keeper_max_tools_per_turn ()
  in
  let visible_always_include_tools = always_include_tools in
  (* Receipt refs: written sequentially after OAS execution, kept as refs
     because the facade (keeper_agent_run.ml) writes them post-run. *)
  let reported_tool_names_ref : string list ref = ref [] in
  let observed_tool_names_ref : string list ref = ref [] in
  let canonical_tool_names_ref : string list ref = ref [] in
  let unexpected_tool_names_ref : string list ref = ref [] in
  let actual_keeper_tool_names_ref : string list ref = ref [] in
  let receipt_turn_count_ref : int option ref = ref None in
  let receipt_model_used_ref : string option ref = ref None in
  let receipt_stop_reason_ref : Cascade_runner.stop_reason option ref =
    ref None
  in
  let receipt_cascade_observation_ref
    : Cascade_observation.cascade_observation option ref
    =
    ref None
  in
  let receipt_response_text_present_ref = ref false in
  let keeper_has_owned_active_task () =
    Option.is_some (owned_active_task_id_for_meta ~config ~meta:acc.meta)
  in
  let current_task_required_tools () =
    match owned_active_task_id_for_meta ~config ~meta:acc.meta with
    | None -> []
    | Some task_id ->
      let task_id = Keeper_id.Task_id.to_string task_id in
      let tasks =
        try Coord.get_tasks_raw config with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
          Prometheus.inc_counter
            Keeper_metrics.(to_string TaskLoadFailures)
            ~labels:[ "keeper", meta.name; "phase", "task_contract_load" ]
            ();
          Log.Keeper.warn
            "keeper:%s failed to load current task contract for %s: %s"
            meta.name
            task_id
            (Printexc.to_string exn);
          []
      in
      (match
         List.find_opt
           (fun (task : Masc_domain.task) -> String.equal task.id task_id)
           tasks
       with
       | Some (task : Masc_domain.task) ->
         (match task.contract with
          | Some contract -> Keeper_types.dedupe_keep_order contract.required_tools
          | None -> [])
       | None -> [])
  in
  let visible_policy_name name =
    (* Preserve names that are already valid public surface entries.
       tool_edit_file has two public aliases (EditFile, WriteFile) with different
       schemas; round-tripping through public_name_for_internal always
       picks EditFile, so any WriteFile entry would be coerced to Edit and then
       deduped. Only canonicalize names that are not themselves valid
       public entries (e.g., internal names like tool_edit_file, or
       unrecognized inputs). *)
    if Keeper_tool_policy.StringSet.mem name universe_set
       && Keeper_tool_policy.StringSet.mem name allowed_exec_set
    then name
    else (
      let canonical = Keeper_tool_resolution.canonical_tool_name name in
      match Keeper_tool_name_projection.public_alias_for_internal canonical with
      | Some public
        when Keeper_tool_policy.StringSet.mem public universe_set
             && Keeper_tool_policy.StringSet.mem public allowed_exec_set ->
        public
      | _ -> name)
  in
  let visible_policy_name_opt name =
    let name = visible_policy_name name in
    if Keeper_tool_policy.StringSet.mem name universe_set
       && Keeper_tool_policy.StringSet.mem name allowed_exec_set
    then Some name
    else allowed_public_alias_for_internal name
  in
  let filter_visible_policy_surface names =
    names
    |> List.filter_map visible_policy_name_opt
    |> Keeper_types.dedupe_keep_order
  in
  let validate_allow_list ~turn raw =
    let raw = raw |> List.map visible_policy_name |> Keeper_types.dedupe_keep_order in
    let validated, dropped_names =
      List.fold_right
        (fun n (validated, dropped_names) ->
           if
             Keeper_tool_policy.StringSet.mem n universe_set
             && Keeper_tool_policy.StringSet.mem n allowed_exec_set
           then n :: validated, dropped_names
           else
             match allowed_public_alias_for_internal n with
             | Some public_name -> public_name :: validated, dropped_names
             | None -> validated, n :: dropped_names)
        raw
        ([], [])
    in
    let dropped = List.length dropped_names in
    if dropped > 0
    then (
      let max_logged = 10 in
      let shown = List.filteri (fun i _ -> i < max_logged) dropped_names in
      let omitted = dropped - List.length shown in
      let shown_text = String.concat ", " shown in
      let omitted_suffix =
        if omitted > 0 then Printf.sprintf " (+%d more)" omitted else ""
      in
      Log.Keeper.warn
        "keeper:%s turn:%d AllowList pruned %d tool(s) outside visible policy surface: %s%s"
        meta.name
        turn
        dropped
        shown_text
        omitted_suffix);
    validated
  in
  let fallback_tool_surface ~turn =
    let repo_probe =
      fallback_repo_probe_tool_names
      |> List.find_opt (fun name ->
        Keeper_tool_policy.StringSet.mem name universe_set
        && Keeper_tool_policy.StringSet.mem name allowed_exec_set)
      |> Option.to_list
    in
    validate_allow_list ~turn (fallback_floor_tool_names @ repo_probe)
  in
  let tool_gate_requested_for_turn ~current_tool_choice ~is_last_turn ~allowed_tool_names =
    let caller_requires_tools =
      (* Enumerate every [tool_choice] variant + [None] so a new constructor
         added to [Agent_sdk.Types.tool_choice] surfaces a Warning 8 here.
         [Auto] and [None_] correctly evaluate to [false] (no tool required);
         the old [_ -> false] catch-all would have absorbed any future variant
         in the same direction without review. *)
      match current_tool_choice with
      | Some (Agent_sdk.Types.Any | Agent_sdk.Types.Tool _) -> true
      | Some (Agent_sdk.Types.Auto | Agent_sdk.Types.None_)
      | None ->
        false
    in
    max_turns > 1
    && (not is_last_turn)
    && (caller_requires_tools
        || turn_affordances_require_tool_gate_with_allowed
             ~record_suppression_metric:true
             ~allowed_tool_names
             turn_affordances)
  in
  let satisfied_required_tool_names () =
    acc.tool_calls
    |> List.map (fun (detail : tool_call_detail) -> detail.tool_name, detail.outcome)
    |> satisfied_required_tool_names_of_outcomes
  in
  let compute_tool_surface
        ~turn
        ~messages
        ~current_tool_choice
        ~decay_discovered
        ?(actionable_signal = false)
        ()
    : computed_tool_surface
    =
    let last_user_text =
      List.fold_left
        (fun acc (m : Agent_sdk.Types.message) ->
           match m.role with
           | Agent_sdk.Types.User -> Agent_sdk.Types.text_of_content m.content
           | _ -> acc)
        ""
        messages
    in
    let query_text =
      (if String.trim last_user_text <> "" then last_user_text else user_message)
      |> Keeper_tool_query.tool_query_text_of_user_message
    in
    let max_tools = max_tools_per_turn in
    let core =
      Agent_tool_dispatch_runtime.effective_core_tools ()
      |> List.filter (fun name -> Keeper_tool_policy.StringSet.mem name allowed_exec_set)
    in
    let discovered =
      Keeper_discovered_tools.active_names acc.discovered ~turn
      |> filter_visible_policy_surface
    in
    let () =
      if decay_discovered then ignore (Keeper_discovered_tools.decay acc.discovered ~turn)
    in
    let selection_limit = min max_tools keeper_selection_top_k in
    let preset_tools, preset_search_index = load_preset_selection_context () in
    let deterministic_prefilter =
      Keeper_tool_selection.deterministic_prefilter_names
        ~search_index:preset_search_index
        ~query_text
        ~selection_limit
        ~core
      |> filter_visible_policy_surface
    in
    let llm_rerank_enabled = Keeper_config.keeper_llm_rerank_enabled () in
    let llm_selected =
      if llm_rerank_enabled
      then (
        match Eio_context.get_switch_opt (), Eio_context.get_net_opt () with
        | Some sw, Some net ->
          let rerank_cascade = Keeper_config.keeper_llm_rerank_cascade () in
          (match
             Cascade_catalog_runtime.resolve_named_providers_strict
               ~sw
               ~net
               ~cascade_name:rerank_cascade
               ()
           with
           | Error detail ->
             Prometheus.inc_counter
               Keeper_metrics.(to_string ToolSelectionFailures)
               ~labels:[ "keeper", meta.name; "phase", "cascade_resolve" ]
               ();
             Log.Keeper.warn
               "keeper:%s TopK_llm: strict cascade resolution failed for '%s' (%s), \
                falling back to core+prefilter+discovered"
               meta.name
               rerank_cascade
               detail;
             []
           | Ok providers ->
             (match Cascade_config.filter_healthy_strict ~sw ~net providers with
              | Error rejection ->
                Prometheus.inc_counter
                  Keeper_metrics.(to_string ToolSelectionFailures)
                  ~labels:[ "keeper", meta.name; "phase", "cascade_health" ]
                  ();
                Log.Keeper.warn
                  "keeper:%s TopK_llm: strict health filter rejected cascade '%s' (%s), \
                   falling back to core+prefilter+discovered"
                  meta.name
                  rerank_cascade
                  (Cascade_config.health_filter_rejection_to_string rejection);
                []
              | Ok [] ->
                Prometheus.inc_counter
                  Keeper_metrics.(to_string ToolSelectionFailures)
                  ~labels:[ "keeper", meta.name; "phase", "cascade_no_provider" ]
                  ();
                Log.Keeper.warn
                  "keeper:%s TopK_llm: no healthy provider for cascade '%s', falling \
                   back to core+prefilter+discovered"
                  meta.name
                  rerank_cascade;
                []
              | Ok (first_provider :: _) ->
                let rerank_fn =
                  Agent_sdk.Tool_selector.default_rerank_fn
                    ~sw
                    ~net
                    ~provider:first_provider
                    ~k:selection_limit
                    ()
                in
                let strategy =
                  Agent_sdk.Tool_selector.TopK_llm
                    { k = selection_limit
                    ; bm25_prefilter_n =
                        min keeper_selection_bm25_prefilter_n (List.length preset_tools)
                    ; always_include = core
                    ; confidence_threshold = 0.3
                    ; rerank_fn
                    }
                in
                (try
                   let selected =
                     Agent_sdk.Tool_selector.select_names
                       ~strategy
                       ~context:query_text
                       ~tools:preset_tools
                   in
                   if Keeper_types_profile.keeper_debug
                   then
                     Log.Keeper.info
                       "keeper:%s TopK_llm selected %d tools (query_len=%d, \
                        candidates=%d)"
                       meta.name
                       (List.length selected)
                       (String.length query_text)
                       (List.length preset_tools);
                   filter_visible_policy_surface selected
                 with
                 | Eio.Cancel.Cancelled _ as e -> raise e
                 | exn ->
                   Prometheus.inc_counter
                     Keeper_metrics.(to_string ToolSelectionFailures)
                     ~labels:[ "keeper", meta.name; "phase", "topk_llm" ]
                     ();
                   Log.Keeper.warn
                     "keeper:%s TopK_llm failed (%s), falling back to \
                      core+prefilter+discovered"
                     meta.name
                     (Printexc.to_string exn);
                   [])))
        | _ ->
          Prometheus.inc_counter
            Keeper_metrics.(to_string ToolSelectionFailures)
            ~labels:[ "keeper", meta.name; "phase", "topk_llm_no_eio" ]
            ();
          Log.Keeper.warn
            "keeper:%s TopK_llm: Eio context unavailable, falling back to \
             core+prefilter+discovered"
            meta.name;
          [])
      else []
    in
    let merged =
      Keeper_tool_selection.merge_tool_selection_boundary
        ~core
        ~deterministic_prefilter
        ~llm_selected
        ~discovered
    in
    let required_tool_names_raw =
      required_tool_names_for_turn
        ~current_task_required_tool_names:(current_task_required_tools ())
        ~per_call_required_tool_names:required_tool_names
      |> List.map Keeper_tool_resolution.canonical_tool_name
      |> Keeper_types.dedupe_keep_order
    in
    let required_tool_names =
      outstanding_required_tool_names
        ~required_tool_names:required_tool_names_raw
        ~satisfied_tool_names:(satisfied_required_tool_names ())
    in
    let current_tool_choice =
      match current_tool_choice with
      | Some (Agent_sdk.Types.Any | Agent_sdk.Types.Tool _)
        when required_tool_names_raw <> [] && required_tool_names = [] -> None
      | _ -> current_tool_choice
    in
    let visible_required_tool_names =
      required_tool_names |> validate_allow_list ~turn |> Keeper_types.dedupe_keep_order
    in
    let visible_affordance_tool_names =
      preferred_tool_names_for_turn_affordances turn_affordances
      |> filter_visible_policy_surface
      |> Keeper_types.dedupe_keep_order
    in
    let merged =
      Keeper_types.dedupe_keep_order
        (merged @ visible_required_tool_names @ visible_affordance_tool_names)
    in
    let selection_mode : Keeper_agent_tool_surface.tool_selection_mode =
      if llm_rerank_enabled
      then Selection_deterministic_plus_llm_hint
      else Selection_core_plus_prefilter_plus_discovered
    in
    let deterministic_floor_set =
      Keeper_types.dedupe_keep_order
        (core @ deterministic_prefilter @ List.sort String.compare discovered)
    in
    let llm_only_count =
      List.length
        (List.filter (fun n -> not (List.mem n deterministic_floor_set)) llm_selected)
    in
    let all_allowed =
      Agent_sdk.Tool_op.apply
        (Agent_sdk.Tool_op.compose
           [ Agent_sdk.Tool_op.Replace_with merged; acc.tool_overlay ])
        all_tool_names
      |> validate_allow_list ~turn
    in
    let core_count = List.length (Agent_tool_dispatch_runtime.effective_core_tools ()) in
    let discovered_count =
      List.length (Keeper_discovered_tools.active_names acc.discovered ~turn)
    in
    let per_call_turn = turn - start_turn_count in
    let is_last_turn = per_call_turn >= max_turns in
    let is_warning_zone = per_call_turn >= max_turns - 1 in
    let all_allowed, tool_surface_fallback_used =
      if all_allowed = []
      then (
        let fallback_allowed = fallback_tool_surface ~turn in
        if fallback_allowed <> [] then fallback_allowed, true else all_allowed, false)
      else all_allowed, false
    in
    let last_turn_safe = Keeper_tool_policy.last_turn_safe_tool_names () in
    (* Mirror allowed_exec_names_with_aliases: only include a public alias
       in the last-turn-safe set when its routed internal handler is also
       last-turn-safe. Otherwise the public name could re-introduce a tool
       the policy explicitly excluded from the final turn. PR #14574. *)
    let safe_set = Keeper_tool_policy.tool_name_set last_turn_safe in
    let aliased_safe_public =
      List.filter
        (fun public ->
           match Keeper_tool_alias.route public with
           | Some r -> Keeper_tool_policy.StringSet.mem r.internal_name safe_set
           | None -> false)
        (Keeper_tool_alias.public_names ())
    in
    let safe_last_turn_tools = last_turn_safe @ aliased_safe_public in
    let all_allowed =
      if is_last_turn && required_tool_names = []
      then
        Agent_sdk.Tool_op.apply
          (Agent_sdk.Tool_op.Intersect_with safe_last_turn_tools)
          all_allowed
      else all_allowed
    in
    let passive_streak =
      Keeper_passive_loop_detector.current_streak ~keeper_name:meta.name
    in
    let streak_threshold = 3 in
    Prometheus.set_gauge
      Keeper_metrics.(to_string PassiveLoopStreak)
      ~labels:[ "keeper", meta.name ]
      (float_of_int passive_streak);
    let all_allowed =
      Keeper_tool_selection.contract_enforcement_filter
        ~passive_streak
        ~streak_threshold
        ~actionable_signal
        all_allowed
    in
    if passive_streak >= streak_threshold && actionable_signal
    then
      Prometheus.inc_counter
        Keeper_metrics.(to_string PassiveLoopStreakExceeded)
        ~labels:[ "keeper", meta.name ]
        ()
    else ();
    let tool_gate_requested =
      required_tool_names <> []
      || tool_gate_requested_for_turn
           ~current_tool_choice
           ~is_last_turn
           ~allowed_tool_names:all_allowed
    in
    let all_allowed =
      tool_names_for_required_gate_surface
        ~tool_gate_requested
        ~required_tool_names
        all_allowed
    in
    let all_allowed =
      if List.length all_allowed > max_tools
      then (
        Log.Keeper.info
          "context overflow guard: %d tools > max %d, truncating"
          (List.length all_allowed)
          max_tools;
        let required_turn_essential_tool_names =
          if required_tool_names <> []
          then visible_required_tool_names
          else if tool_gate_requested
          then (
            let claim_tools =
              if has_task_claim_affordance turn_affordances
              then [ "keeper_task_claim" ]
              else []
            in
            Keeper_types.dedupe_keep_order (visible_affordance_tool_names @ claim_tools))
          else []
        in
        let essential_names =
          Keeper_types.dedupe_keep_order
            (visible_always_include_tools @ required_turn_essential_tool_names)
        in
        Keeper_run_tools_search.truncate_tool_surface_names ~max_tools ~essential_names all_allowed)
      else all_allowed
    in
    let allowed_canonical_tool_names =
      all_allowed
      |> List.map Keeper_tool_resolution.canonical_tool_name
      |> Keeper_types.dedupe_keep_order
    in
    let missing_required_tool_names =
      List.filter
        (fun name ->
           let canonical = Keeper_tool_resolution.canonical_tool_name name in
           not (List.mem canonical allowed_canonical_tool_names))
        required_tool_names
    in
    let required_tool_candidate_names =
      if tool_gate_requested && required_tool_names = []
      then
        generic_required_tool_candidate_names
          ~has_current_task:(keeper_has_owned_active_task ())
          ~turn_affordances
          ~allowed_tool_names:all_allowed
      else []
    in
    let visible_tool_count = List.length all_allowed in
    let tool_surface_class : Keeper_agent_tool_surface.tool_surface_class =
      if visible_tool_count = 0
      then Surface_none
      else if List.for_all Tool_catalog.is_public_mcp all_allowed
      then Surface_public_only
      else Surface_mixed
    in
    let tool_requirement =
      if visible_tool_count = 0
      then No_tools
      else if tool_gate_requested
      then Required
      else Optional
    in
    let lane : Keeper_agent_tool_surface.turn_lane =
      if is_retry
      then Lane_retry
      else (
        match tool_requirement with
        | Required -> Lane_tool_required
        | Optional -> Lane_tool_optional
        | No_tools ->
          (match current_tool_choice with
           | Some Agent_sdk.Types.None_ -> Lane_tool_disabled
           | _ -> Lane_text_only))
    in
    { all_allowed
    ; absolute_turn = turn
    ; checkpoint_start_turn = start_turn_count
    ; per_call_turn
    ; per_call_max_turns = max_turns
    ; core_count
    ; deterministic_prefilter
    ; deterministic_prefilter_count = List.length deterministic_prefilter
    ; discovered_count
    ; llm_selected_count = llm_only_count
    ; selection_mode
    ; is_last_turn
    ; is_warning_zone
    ; tool_surface_class
    ; tool_requirement
    ; tool_gate_requested
    ; tool_surface_fallback_used
    ; required_tool_names
    ; required_tool_candidate_names
    ; missing_required_tool_names
    ; lane
    ; query_text
    }
  in

  let ctx : Keeper_run_tools_hooks.ctx =
    { acc
    ; agent_name
    ; all_tool_names
    ; compute_tool_surface
    ; config
    ; keeper_tool_bundle
    ; keeper_has_owned_active_task
    ; manifest_keeper_turn_id
    ; max_tools_per_turn
    ; meta
    ; reported_tool_names_ref
    ; observed_tool_names_ref
    ; canonical_tool_names_ref
    ; unexpected_tool_names_ref
    ; actual_keeper_tool_names_ref
    ; receipt_turn_count_ref
    ; receipt_model_used_ref
    ; receipt_stop_reason_ref
    ; receipt_cascade_observation_ref
    ; receipt_response_text_present_ref
    ; tool_usage_before
    ; tools
    }
  in
  Keeper_run_tools_hooks.assemble_hooks
    ~ctx ~session ~user_message ~dynamic_context
    ~history_messages ~prompt_metrics ~shared_context
    ~start_turn_count ~generation ~max_turns
    ~cascade_name_string ~is_retry ~turn_affordances
    ~required_tool_names ~config_root ~cascade_config_path
    ~gemini_mcp_disabled ~approval_mode_effective
    ~approval_mode_derived ~actionable_signal
    ?max_cost_usd ~trajectory_acc
    ?runtime_manifest_context ?runtime_manifest_append ()
