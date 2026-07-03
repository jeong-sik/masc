(* keeper_run_tools_setup — extracted from keeper_run_tools.ml.
   Contains the full implementation of prepare_agent_setup. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_agent_tool_surface
open Keeper_agent_result
open Keeper_agent_error
open Keeper_agent_prompt_metrics

let prepare_agent_setup
      ~(config : Workspace.config)
      ~(meta : Keeper_meta_contract.keeper_meta)
      ~(turn_ctx_cell : Keeper_tool_call_log.turn_ctx_cell)
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
      ~(runtime_id : string)
      ~(is_retry : bool)
      ~(turn_affordances : string list)
      ~(config_root : string)
      ~(runtime_config_path : string option)
      ?max_cost_usd
      ~(trajectory_acc : Trajectory.accumulator option)
      ~(tool_overlay : Agent_sdk.Tool_op.t ref option)
      ?runtime_manifest_context
      ?runtime_manifest_append
      ()
  : (Keeper_run_tools_hooks.agent_setup, Agent_sdk.Error.sdk_error) result
  =
  let runtime_id_string = runtime_id in
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
                  Otel_metric_store.inc_counter
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
        ; config_root
        ; runtime_config_path
        }
    ; requested_tool_names = []
    ; receipt_completion_contract_result =
        Keeper_execution_receipt.Contract_unknown
    ; receipt_actionable_signal = None
    ; prompt_blocks = []
    ; extra_system_context_digest = None
    ; extra_system_context_size = None
    }
  in
  let local_search_fn_ref : (query:string -> max_results:int -> Yojson.Safe.t) ref =
    ref (fun ~query:_ ~max_results:_ -> `Assoc [ "results", `List [] ])
  in
  let affinity_k = Keeper_tool_affinity.configured_max_k () in
  if affinity_k > 0
  then (
    let masc_root = Workspace.masc_root_dir config in
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
  let { Keeper_tools_oas.tools = keeper_tools; cleanup = keeper_tools_cleanup } =
    Keeper_tools_oas_bundle.make_tool_bundle
      ~config
      ~meta
      ~ctx_snapshot
      ~search_fn:(fun ~query ~max_results -> !local_search_fn_ref ~query ~max_results)
      ~on_tool_called:(fun name ->
        Keeper_discovered_tools.mark_used acc.discovered ~turn:acc.current_turn ~name)
      ()
  in
  let tools = keeper_tools in
  let tool_index_config =
    { Agent_sdk.Tool_index.default_config with
      top_k = Keeper_config.keeper_tool_search_top_k ()
    }
  in
  let tool_entries = List.map tool_index_entry_of_tool keeper_tools in
  let search_index = Agent_sdk.Tool_index.build ~config:tool_index_config tool_entries in
  let load_scoped_selection_context () =
    let scoped_names = Keeper_tool_policy.keeper_tool_search_scope meta in
    let scoped_set = Hashtbl.create (List.length scoped_names) in
    List.iter (fun n -> Hashtbl.replace scoped_set n true) scoped_names;
    let scoped_tools =
      List.filter
        (fun (t : Agent_sdk.Tool.t) -> Hashtbl.mem scoped_set t.schema.name)
        keeper_tools
    in
    let progressive_tool_index_config =
      { Agent_sdk.Tool_index.default_config with
        top_k = keeper_selection_bm25_prefilter_n
      }
    in
    let scoped_tool_entries = List.map tool_index_entry_of_tool scoped_tools in
    ( scoped_tools
    , Agent_sdk.Tool_index.build ~config:progressive_tool_index_config scoped_tool_entries
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
         Hashtbl.replace tbl t.schema.name
           (Agent_sdk.Types.params_to_input_schema t.schema.parameters))
      keeper_tools;
    tbl
  in
  (local_search_fn_ref
   := fun ~query ~max_results ->
        let core = Keeper_tool_dispatch_runtime.effective_core_tools () in
        let retrieved = Agent_sdk.Tool_index.retrieve search_index query in
        let partition =
          Keeper_run_tools_search.partition_tool_search_hits
            ~core
            ~core_always:Keeper_tool_registry.core_always_tools
            ~allowed:(Keeper_tool_dispatch_runtime.keeper_allowed_tool_names meta)
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
        let masc_schemas = Keeper_tool_dispatch_runtime.masc_schemas_snapshot () in
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
  let all_tool_names =
    List.map (fun (t : Agent_sdk.Tool.t) -> t.schema.name) keeper_tools
  in
  let universe_set = Keeper_tool_policy.tool_name_set all_tool_names in
  let policy_allowed_tool_names =
    Keeper_tool_dispatch_runtime.keeper_allowed_tool_names meta
  in
  (* Descriptor-backed public names are the LLM-visible names; internal
     counterparts are implementation details.

     Order matters: compute [descriptor_public_names] against the UNFILTERED
     internal candidate set. Descriptor/internal names (tool_execute,
     tool_read_file, ...) drive the visible surface.
     Stripping internals before the descriptor expansion check would leave
     [descriptor_public_names] empty and drop "Execute"/"Read"/... from the
     visible surface. See PR #14596 review. *)
  let descriptor_internal_names =
    Keeper_tool_descriptor.public_descriptors
    |> List.concat_map Keeper_tool_descriptor.internal_names
    |> Keeper_types_profile_toml_normalizers.dedupe_keep_order
  in
  (* Only include a public name when its descriptor internal target is
     itself in [policy_allowed_tool_names]. Otherwise the public name (e.g. "Execute")
     could let the LLM invoke a tool whose internal handler the current
     keeper tool_access has explicitly excluded — the descriptor would dispatch to
     a registered-but-disallowed tool. See PR #14574 review. *)
  let descriptor_public_names =
    Keeper_tool_descriptor_resolution.public_names_for_allowed_internal_names
      policy_allowed_tool_names
  in
  (* Now strip the descriptor internal names from the LLM-visible surface,
     after [descriptor_public_names] has been computed. *)
  let policy_allowed_tool_names =
    List.filter
      (fun name -> not (List.mem name descriptor_internal_names))
      policy_allowed_tool_names
  in
  let policy_allowed_tool_names_with_public_descriptors =
    policy_allowed_tool_names @ descriptor_public_names
  in
  let policy_allowed_tool_set =
    let base =
      Keeper_tool_policy.tool_name_set
        policy_allowed_tool_names_with_public_descriptors
    in
    Keeper_tool_policy.StringSet.union
      base
      (Keeper_tool_policy.tool_name_set Keeper_tool_registry.core_always_tools)
  in
  let allowed_public_name_for_internal internal_name =
    Keeper_tool_descriptor_resolution.public_names_for_internal internal_name
    |> List.find_opt (fun public_name ->
      Keeper_tool_policy.StringSet.mem public_name universe_set
      && Keeper_tool_policy.StringSet.mem public_name policy_allowed_tool_set)
  in
  let receipt_turn_count_ref : int option ref = ref None in
  let receipt_model_used_ref : string option ref = ref None in
  let receipt_stop_reason_ref : Runtime_agent.stop_reason option ref =
    ref None
  in
  let receipt_runtime_observation_ref
    : Runtime_observation.runtime_observation option ref
    =
    ref None
  in
  let receipt_response_text_present_ref = ref false in
  let visible_policy_name name =
    (* Preserve names that are already valid public surface entries.
       tool_edit_file and tool_write_file have distinct public aliases
       (Edit, Write); round-tripping through public_name_for_internal always
       picks one descriptor, so a Write entry could be coerced to Edit and then
       deduped. Only canonicalize names that are not themselves valid
       public entries (e.g., internal names like tool_edit_file, or
       unrecognized inputs). *)
    if Keeper_tool_policy.StringSet.mem name universe_set
       && Keeper_tool_policy.StringSet.mem name policy_allowed_tool_set
    then name
    else (
      let canonical = Keeper_tool_resolution.canonical_tool_name name in
      match Keeper_tool_visibility_projection.public_alias_for_internal canonical with
      | Some public
        when Keeper_tool_policy.StringSet.mem public universe_set
             && Keeper_tool_policy.StringSet.mem public policy_allowed_tool_set ->
        public
      | _ -> name)
  in
  let visible_policy_name_opt name =
    let name = visible_policy_name name in
    if Keeper_tool_policy.StringSet.mem name universe_set
       && Keeper_tool_policy.StringSet.mem name policy_allowed_tool_set
    then Some name
    else allowed_public_name_for_internal name
  in
  let filter_visible_policy_surface names =
    names
    |> List.filter_map visible_policy_name_opt
    |> Keeper_types_profile_toml_normalizers.dedupe_keep_order
  in
  let validate_allow_list ~turn raw =
    let raw = raw |> List.map visible_policy_name |> Keeper_types_profile_toml_normalizers.dedupe_keep_order in
    let validated, dropped_names =
      List.fold_right
        (fun n (validated, dropped_names) ->
           if
             Keeper_tool_policy.StringSet.mem n universe_set
             && Keeper_tool_policy.StringSet.mem n policy_allowed_tool_set
           then n :: validated, dropped_names
           else
             match allowed_public_name_for_internal n with
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
  let compute_tool_surface
        ~turn
        ~messages
        ~current_tool_choice
        ~decay_discovered
        ()
    : string list * turn_lane
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
    let core =
      Keeper_tool_dispatch_runtime.effective_core_tools ()
      |> List.filter (fun name ->
        Keeper_tool_policy.StringSet.mem name policy_allowed_tool_set)
    in
    let discovered =
      Keeper_discovered_tools.active_names acc.discovered ~turn
      |> filter_visible_policy_surface
    in
    let () =
      if decay_discovered then ignore (Keeper_discovered_tools.decay acc.discovered ~turn)
    in
    let selection_limit = keeper_selection_top_k in
    let scoped_tools, scoped_search_index = load_scoped_selection_context () in
    let deterministic_prefilter =
      Keeper_tool_selection.deterministic_prefilter_names
        ~search_index:scoped_search_index
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
          let rerank_runtime = Keeper_config.keeper_llm_rerank_runtime () in
          (match
             Runtime_oas_runner.resolve_runtime_providers
               ~runtime_id:rerank_runtime
               ()
           with
           | Error detail ->
             Otel_metric_store.inc_counter
               Keeper_metrics.(to_string ToolSelectionFailures)
               ~labels:[ "keeper", meta.name; "phase", "runtime_resolve" ]
               ();
             Log.Keeper.warn
               "keeper:%s TopK_llm: strict runtime resolution failed for '%s' (%s), \
                falling back to core+prefilter+discovered"
               meta.name
               rerank_runtime
               detail;
             []
           | Ok providers ->
             (match providers with
              | [] ->
                Otel_metric_store.inc_counter
                  Keeper_metrics.(to_string ToolSelectionFailures)
                  ~labels:[ "keeper", meta.name; "phase", "runtime_no_provider" ]
                  ();
                Log.Keeper.warn
                  "keeper:%s TopK_llm: no healthy provider for runtime '%s', falling \
                   back to core+prefilter+discovered"
                  meta.name
                  rerank_runtime;
                []
              | first_provider :: _ ->
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
                        min keeper_selection_bm25_prefilter_n (List.length scoped_tools)
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
                       ~tools:scoped_tools
                   in
                   if Keeper_types_profile.keeper_debug
                   then
                     Log.Keeper.info
                       "keeper:%s TopK_llm selected %d tools (query_len=%d, \
                        candidates=%d)"
                       meta.name
                       (List.length selected)
                       (String.length query_text)
                       (List.length scoped_tools);
                   filter_visible_policy_surface selected
                 with
                 | Eio.Cancel.Cancelled _ as e -> raise e
                 | exn ->
                   Otel_metric_store.inc_counter
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
          Otel_metric_store.inc_counter
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
    let visible_affordance_tool_names =
      preferred_tool_names_for_turn_affordances turn_affordances
      |> filter_visible_policy_surface
      |> Keeper_types_profile_toml_normalizers.dedupe_keep_order
    in
    let merged =
      Keeper_types_profile_toml_normalizers.dedupe_keep_order
        (merged @ visible_affordance_tool_names)
    in
    let schema_filter =
      Agent_sdk.Tool_op.apply
        (Agent_sdk.Tool_op.compose
           [ Agent_sdk.Tool_op.Replace_with merged; acc.tool_overlay ])
        all_tool_names
      |> validate_allow_list ~turn
    in
    let lane : Keeper_agent_tool_surface.turn_lane =
      if is_retry
      then Lane_retry
      else if schema_filter <> []
      then Lane_tool_optional
      else (
        match current_tool_choice with
        | Some Agent_sdk.Types.None_ -> Lane_tool_disabled
        | _ -> Lane_text_only)
    in
    (schema_filter, lane)
  in

  let ctx : Keeper_run_tools_hooks.ctx =
    { acc
    ; agent_name
    ; all_tool_names
    ; compute_tool_surface
    ; config
    ; keeper_tools_cleanup
    ; manifest_keeper_turn_id
    ; meta
    ; turn_ctx_cell
    ; receipt_turn_count_ref
    ; receipt_model_used_ref
    ; receipt_stop_reason_ref
    ; receipt_runtime_observation_ref
    ; receipt_response_text_present_ref
    ; tools
    }
  in
  Keeper_run_tools_hooks.assemble_hooks
    ~ctx ~session ~turn_system_prompt ~user_message ~dynamic_context
    ~history_messages ~prompt_metrics ~shared_context
    ~start_turn_count ~generation
    ~runtime_id_string ~is_retry ~turn_affordances
    ~config_root ~runtime_config_path
    ?max_cost_usd ~trajectory_acc
    ?runtime_manifest_context ?runtime_manifest_append ()
