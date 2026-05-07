(* keeper_run_tools — Step 7 of run_turn: agent setup, tools, progressive
   disclosure, hooks assembly, context reducer.

   Extracted from keeper_agent_run.ml. *)

open Keeper_types
open Keeper_agent_tool_surface
open Keeper_agent_result
open Keeper_agent_error
open Keeper_agent_prompt_metrics

(** Mutable accumulator for OAS hook callbacks.

    OAS hooks (before_turn, on_tool_executed) cannot return values, so
    they write into this single mutable record during Agent.run execution.
    After execution completes, {!freeze} produces an immutable snapshot. *)
type hook_accumulator =
  { mutable meta : Keeper_types.keeper_meta
  ; mutable tool_calls : tool_call_detail list
  ; mutable current_turn : int
  ; mutable completion_contract : Keeper_tool_disclosure.completion_contract
  ; mutable required_tool_use_seen : bool
  ; mutable keeper_surface_tool_used : bool
  ; mutable discovered : Keeper_discovered_tools.t
  ; mutable tool_overlay : Agent_sdk.Tool_op.t
  ; mutable tool_surface : tool_surface_metrics
  ; mutable requested_tool_names : string list
  ; mutable receipt_tool_contract_result : string
  }

(** Immutable snapshot of hook outputs after OAS execution completes. *)
type hook_outputs =
  { out_meta : Keeper_types.keeper_meta
  ; out_tool_calls : tool_call_detail list
  ; out_completion_contract : Keeper_tool_disclosure.completion_contract
  ; out_required_tool_use_seen : bool
  ; out_keeper_surface_tool_used : bool
  ; out_discovered : Keeper_discovered_tools.t
  ; out_tool_overlay : Agent_sdk.Tool_op.t
  ; out_tool_surface : tool_surface_metrics
  ; out_requested_tool_names : string list
  ; out_receipt_tool_contract_result : string
  }

let freeze (acc : hook_accumulator) : hook_outputs =
  { out_meta = acc.meta
  ; out_tool_calls = acc.tool_calls
  ; out_completion_contract = acc.completion_contract
  ; out_required_tool_use_seen = acc.required_tool_use_seen
  ; out_keeper_surface_tool_used = acc.keeper_surface_tool_used
  ; out_discovered = acc.discovered
  ; out_tool_overlay = acc.tool_overlay
  ; out_tool_surface = acc.tool_surface
  ; out_requested_tool_names = acc.requested_tool_names
  ; out_receipt_tool_contract_result = acc.receipt_tool_contract_result
  }

type tool_search_hit_partition =
  { visible_core_hits : (string * float) list
  ; discoverable_hits : (string * float) list
  ; filtered_by_policy : int
  }

let partition_tool_search_hits ~core ~core_always ~allowed ~retrieved
    ~max_results =
  let allowed =
    allowed |> Keeper_tool_alias.expand_universe
  in
  let allowed_set =
    let tbl = Hashtbl.create (List.length allowed) in
    List.iter (fun n -> Hashtbl.replace tbl n ()) allowed;
    List.iter (fun n -> Hashtbl.replace tbl n ()) core_always;
    tbl
  in
  let allowed_retrieved =
    retrieved |> List.filter (fun (name, _) -> Hashtbl.mem allowed_set name)
  in
  let is_core name =
    List.mem name core || List.mem name core_always
  in
  let visible_core_hits =
    allowed_retrieved |> List.filter (fun (name, _) -> is_core name)
  in
  let discoverable_hits =
    allowed_retrieved
    |> List.filter (fun (name, _) -> not (is_core name))
    |> List.filteri (fun i _ -> i < max_results)
  in
  { visible_core_hits
  ; discoverable_hits
  ; filtered_by_policy = List.length retrieved - List.length allowed_retrieved
  }

(** Agent setup produced by Step 7.

    Hook mutations flow through {!acc}, receipt refs are kept for
    facade post-processing writes, and [agent_ref] is created locally
    at the OAS call site. *)
type agent_setup =
  { tools : Agent_sdk.Tool.t list
  ; cleanup : unit -> unit
  ; hooks : Agent_sdk.Hooks.hooks
  ; reducer : Agent_sdk.Context_reducer.t
  ; memory : Agent_sdk.Memory.t
  ; acc : hook_accumulator
  ; initial_tool_surface : computed_tool_surface
  ; initial_tool_surface_blocker : Agent_sdk.Error.sdk_error option ref
  ; all_tool_names : string list
  ; tool_usage_before : (string * int) list
  ; receipt_turn_count_ref : int option ref
  ; receipt_model_used_ref : string option ref
  ; receipt_stop_reason_ref : string option ref
  ; receipt_cascade_observation_ref : Oas_worker.cascade_observation option ref
  ; receipt_response_text_present_ref : bool ref
  ; reported_tool_names_ref : string list ref
  ; observed_tool_names_ref : string list ref
  ; canonical_tool_names_ref : string list ref
  ; unexpected_tool_names_ref : string list ref
  ; actual_keeper_tool_names_ref : string list ref
  }

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
      ~(cascade_name : Keeper_cascade_profile.runtime_name)
      ~(is_retry : bool)
      ~(turn_affordances : string list)
      ~(required_tool_names : string list)
      ~(config_root : string)
      ~(cascade_config_path : string option)
      ~(gemini_mcp_disabled : bool)
      ~(approval_mode_effective : string option)
      ~(approval_mode_derived : bool)
      ?max_cost_usd
      ~(trajectory_acc : Trajectory.accumulator option)
      ~(tool_overlay : Agent_sdk.Tool_op.t ref option)
      ()
  : (agent_setup, Agent_sdk.Error.sdk_error) result
  =
  let cascade_name_string =
    Keeper_cascade_profile.runtime_name_to_string cascade_name
  in
  let ctx_snapshot = ctx_work in
  let agent_name = meta.agent_name in
  let acc : hook_accumulator =
    { meta
    ; tool_calls = []
    ; current_turn = 0
    ; completion_contract = Keeper_tool_disclosure.Allow_text_or_tool
    ; required_tool_use_seen = false
    ; keeper_surface_tool_used = false
    ; discovered = Keeper_discovered_tools.create ~decay_turns:(begin
        match Sys.getenv_opt "MASC_KEEPER_TOOL_DECAY_TURNS" with
        | Some s ->
          (match int_of_string_opt s with
           | Some n -> max 1 n
           | None ->
             Log.Keeper.warn
               "keeper: MASC_KEEPER_TOOL_DECAY_TURNS=%S is not a valid integer, using default 5"
               s;
             Prometheus.inc_counter
               Prometheus.metric_keeper_config_env_parse_failures
               ~labels:[("var", "MASC_KEEPER_TOOL_DECAY_TURNS")]
               ();
             5)
        | None -> 5
      end)
    ; tool_overlay = (match tool_overlay with Some r -> !r | None -> Agent_sdk.Tool_op.Keep_all)
    ; tool_surface =
        { turn_lane = "text_only"
        ; tool_surface_class = "none"
        ; tool_requirement = No_tools
        ; visible_tool_count = 0
        ; tool_gate_enabled = false
        ; tool_surface_fallback_used = false
        ; required_tool_names = []
        ; missing_required_tool_names = []
        ; config_root
        ; cascade_config_path
        ; gemini_mcp_disabled
        ; approval_mode_effective
        ; approval_mode_derived
        }
    ; requested_tool_names = []
    ; receipt_tool_contract_result = "unknown"
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
    Keeper_tools_oas.make_tool_bundle
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
    Keeper_tool_disclosure.keeper_tool_usage_snapshot ~base_path:config.base_path ~keeper_name:meta.name
  in
  let tool_index_config =
    { Agent_sdk.Tool_index.default_config with
      top_k = Keeper_config.keeper_tool_search_top_k ()
    }
  in
  let tool_entries = List.map tool_index_entry_of_tool keeper_tools in
  let search_index = Agent_sdk.Tool_index.build ~config:tool_index_config tool_entries in
  let load_preset_selection_context () =
    let preset_names =
      Keeper_tool_policy.keeper_preset_universe_tool_names meta
    in
    let preset_set = Hashtbl.create (List.length preset_names) in
    List.iter (fun n -> Hashtbl.replace preset_set n true) preset_names;
    let preset_tools =
      List.filter
        (fun (t : Agent_sdk.Tool.t) -> Hashtbl.mem preset_set t.schema.name)
        keeper_tools
    in
    let progressive_tool_index_config =
      { Agent_sdk.Tool_index.default_config with
        top_k = keeper_selection_bm25_prefilter_n }
    in
    let preset_tool_entries = List.map tool_index_entry_of_tool preset_tools in
    (preset_tools,
     Agent_sdk.Tool_index.build ~config:progressive_tool_index_config
       preset_tool_entries)
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
        let core = Keeper_exec_tools.effective_core_tools () in
        let retrieved = Agent_sdk.Tool_index.retrieve search_index query in
        let partition =
          partition_tool_search_hits
            ~core
            ~core_always:Keeper_tool_registry.core_always_tools
            ~allowed:(Keeper_exec_tools.keeper_allowed_tool_names meta)
            ~retrieved
            ~max_results
        in
        let raw_hit_count = List.length retrieved in
        let matched_core_names =
          List.map fst partition.visible_core_hits
        in
        let core_hit_count = List.length matched_core_names in
        let filtered_by_core = 0 in
        let new_discoveries = partition.discoverable_hits in
        let filtered_by_policy = partition.filtered_by_policy in
        let discovered_names = List.map fst new_discoveries in
        Keeper_discovered_tools.add
          acc.discovered
          ~turn:acc.current_turn
          ~names:discovered_names;
        let masc_schemas = Keeper_exec_tools.masc_schemas_snapshot () in
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
          partition.visible_core_hits
          |> List.map (result_json ~already_visible:true)
        in
        let discovery_results =
          List.map
            (result_json ~already_visible:false)
            new_discoveries
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
  let always_include_tools = Keeper_exec_tools.core_always_tools in
  let all_tool_names =
    "extend_turns" :: List.map (fun (t : Agent_sdk.Tool.t) -> t.schema.name) keeper_tools
  in
  let universe_set = Keeper_tool_policy.tool_name_set all_tool_names in
  let allowed_exec_names = Keeper_exec_tools.keeper_allowed_tool_names meta in
  let allowed_exec_names_with_aliases =
    Keeper_tool_alias.expand_universe allowed_exec_names
  in
  let allowed_exec_set =
    let base = Keeper_tool_policy.tool_name_set allowed_exec_names_with_aliases in
    Keeper_tool_policy.StringSet.union base
      (Keeper_tool_policy.tool_name_set Keeper_tool_registry.core_always_tools)
  in
  let max_tools_per_turn =
    if is_retry
    then Keeper_config.keeper_retry_max_tools_per_turn ()
    else Keeper_config.keeper_max_tools_per_turn ()
  in
  let visible_always_include_tools =
    always_include_tools
  in
  (* Receipt refs: written sequentially after OAS execution, kept as refs
     because the facade (keeper_agent_run.ml) writes them post-run. *)
  let reported_tool_names_ref : string list ref = ref [] in
  let observed_tool_names_ref : string list ref = ref [] in
  let canonical_tool_names_ref : string list ref = ref [] in
  let unexpected_tool_names_ref : string list ref = ref [] in
  let actual_keeper_tool_names_ref : string list ref = ref [] in
  let receipt_turn_count_ref : int option ref = ref None in
  let receipt_model_used_ref : string option ref = ref None in
  let receipt_stop_reason_ref : string option ref = ref None in
  let receipt_cascade_observation_ref : Oas_worker.cascade_observation option ref =
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
        try Coord.get_tasks_raw config
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
          Prometheus.inc_counter
            Prometheus.metric_keeper_task_load_failures
            ~labels:[("keeper", meta.name); ("phase", "task_contract_load")]
            ();
          Log.Keeper.warn
            "keeper:%s failed to load current task contract for %s: %s"
            meta.name
            task_id
            (Printexc.to_string exn);
          []
      in
      match
        List.find_opt (fun (task : Masc_domain.task) -> String.equal task.id task_id)
          tasks
      with
      | Some (task : Masc_domain.task) -> (
        match task.contract with
        | Some contract -> Keeper_types.dedupe_keep_order contract.required_tools
        | None -> [])
      | None -> []
  in
  let validate_allow_list ~turn raw =
    let raw = raw in
    let validated, dropped_names =
      List.partition
        (fun n ->
           Keeper_tool_policy.StringSet.mem n universe_set
           && Keeper_tool_policy.StringSet.mem n allowed_exec_set)
        raw
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
        "keeper:%s turn:%d AllowList pruned %d tool(s) outside dispatch universe: %s%s"
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
  let tool_gate_requested_for_turn
      ~current_tool_choice ~is_last_turn ~allowed_tool_names =
    let caller_requires_tools =
      match current_tool_choice with
      | Some (Agent_sdk.Types.Any | Agent_sdk.Types.Tool _) -> true
      | _ -> false
    in
    max_turns > 1
    && not is_last_turn
    && (caller_requires_tools
        || turn_affordances_require_tool_gate_with_allowed
             ~record_suppression_metric:true ~allowed_tool_names turn_affordances)
  in
  let compute_tool_surface ~turn ~messages ~current_tool_choice ~decay_discovered
      : computed_tool_surface =
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
      |> Keeper_tool_disclosure.tool_query_text_of_user_message
    in
    let max_tools = max_tools_per_turn in
    let core =
      Keeper_exec_tools.effective_core_tools ()
      |> List.filter (fun name -> Keeper_tool_policy.StringSet.mem name allowed_exec_set)
    in
    let discovered =
      Keeper_discovered_tools.active_names acc.discovered ~turn
    in
    let () =
      if decay_discovered then ignore (Keeper_discovered_tools.decay acc.discovered ~turn)
    in
    let selection_limit = min max_tools keeper_selection_top_k in
    let preset_tools, preset_search_index =
      load_preset_selection_context ()
    in
    let deterministic_prefilter =
      Keeper_tool_disclosure.deterministic_prefilter_names
        ~search_index:preset_search_index
        ~query_text
        ~selection_limit
        ~core
    in
    let llm_rerank_enabled = Keeper_config.keeper_llm_rerank_enabled () in
    let llm_selected =
      if llm_rerank_enabled then
        (match Eio_context.get_switch_opt (), Eio_context.get_net_opt () with
         | Some sw, Some net ->
             let rerank_cascade =
               Keeper_config.keeper_llm_rerank_cascade ()
             in
             (match
                Cascade_catalog_runtime.resolve_named_providers_strict
                  ~sw ~net
                  ~cascade_name:rerank_cascade
                  ()
              with
              | Error detail ->
                  Prometheus.inc_counter
                    Prometheus.metric_keeper_tool_selection_failures
                    ~labels:[("keeper", meta.name); ("phase", "cascade_resolve")]
                    ();
                  Log.Keeper.warn
                    "keeper:%s TopK_llm: strict cascade resolution failed for '%s' (%s), falling back to core+prefilter+discovered"
                    meta.name
                    rerank_cascade
                    detail;
                  []
              | Ok providers ->
                  (match Cascade_config.filter_healthy_strict ~sw ~net providers with
                   | Error rejection ->
                       Prometheus.inc_counter
                         Prometheus.metric_keeper_tool_selection_failures
                         ~labels:[("keeper", meta.name); ("phase", "cascade_health")]
                         ();
                       Log.Keeper.warn
                         "keeper:%s TopK_llm: strict health filter rejected cascade '%s' (%s), falling back to core+prefilter+discovered"
                         meta.name
                         rerank_cascade
                         (Cascade_config.health_filter_rejection_to_string rejection);
                       []
                   | Ok [] ->
                       Prometheus.inc_counter
                         Prometheus.metric_keeper_tool_selection_failures
                         ~labels:[("keeper", meta.name); ("phase", "cascade_no_provider")]
                         ();
                       Log.Keeper.warn
                         "keeper:%s TopK_llm: no healthy provider for cascade '%s', falling back to core+prefilter+discovered"
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
                               min
                                 keeper_selection_bm25_prefilter_n
                                 (List.length preset_tools)
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
                          if Keeper_types_profile.keeper_debug then
                            Log.Keeper.info
                              "keeper:%s TopK_llm selected %d tools (query_len=%d, candidates=%d)"
                              meta.name
                              (List.length selected)
                              (String.length query_text)
                              (List.length preset_tools);
                          selected
                        with
                        | Eio.Cancel.Cancelled _ as e -> raise e
                        | exn ->
                            Prometheus.inc_counter
                              Prometheus.metric_keeper_tool_selection_failures
                              ~labels:[("keeper", meta.name); ("phase", "topk_llm")]
                              ();
                            Log.Keeper.warn
                              "keeper:%s TopK_llm failed (%s), falling back to core+prefilter+discovered"
                              meta.name
                              (Printexc.to_string exn);
                            [])))
         | _ ->
           Prometheus.inc_counter
             Prometheus.metric_keeper_tool_selection_failures
             ~labels:[("keeper", meta.name); ("phase", "topk_llm_no_eio")]
             ();
           Log.Keeper.warn
             "keeper:%s TopK_llm: Eio context unavailable, falling back to core+prefilter+discovered"
             meta.name;
           [])
      else []
    in
    let merged =
      Keeper_tool_disclosure.merge_tool_selection_boundary
        ~core
        ~deterministic_prefilter
        ~llm_selected
        ~discovered

    in
    let required_tool_names =
      required_tool_names_for_turn
        ~current_task_required_tool_names:(current_task_required_tools ())
        ~per_call_required_tool_names:required_tool_names
      |> Keeper_types.dedupe_keep_order
    in
    let visible_required_tool_names =
      required_tool_names

      |> validate_allow_list ~turn
      |> Keeper_types.dedupe_keep_order
    in
    let visible_affordance_tool_names =
      preferred_tool_names_for_turn_affordances turn_affordances
      |> validate_allow_list ~turn
      |> Keeper_types.dedupe_keep_order
    in
    let merged =
      Keeper_types.dedupe_keep_order
        (merged @ visible_required_tool_names @ visible_affordance_tool_names)
    in
    let selection_mode =
      if llm_rerank_enabled
      then "deterministic_plus_llm_hint"
      else "core_plus_prefilter_plus_discovered"
    in
    let deterministic_floor_set =
      Keeper_types.dedupe_keep_order
        (core @ deterministic_prefilter @ List.sort String.compare discovered)
    in
    let llm_only_count =
      List.length
        (List.filter
           (fun n -> not (List.mem n deterministic_floor_set))
           llm_selected)
    in
    let all_allowed =
      Agent_sdk.Tool_op.apply
        (Agent_sdk.Tool_op.compose
           [ Agent_sdk.Tool_op.Replace_with merged
           ; acc.tool_overlay
           ])
        all_tool_names
      |> validate_allow_list ~turn
    in
    let core_count = List.length (Keeper_exec_tools.effective_core_tools ()) in
    let discovered_count =
      List.length (Keeper_discovered_tools.active_names acc.discovered ~turn)
    in
    let per_call_turn = turn - start_turn_count in
    let is_last_turn = per_call_turn >= max_turns in
    let is_warning_zone = per_call_turn >= max_turns - 1 in
    let all_allowed, tool_surface_fallback_used =
      if all_allowed = [] then
        let fallback_allowed = fallback_tool_surface ~turn in
        if fallback_allowed <> [] then fallback_allowed, true else all_allowed, false
      else
        all_allowed, false
    in
    let safe_last_turn_tools =
      Keeper_tool_policy.last_turn_safe_tool_names ()
      |> Keeper_tool_alias.expand_universe
    in
    let all_allowed =
      if is_last_turn && required_tool_names = [] then
        Agent_sdk.Tool_op.apply
          (Agent_sdk.Tool_op.Intersect_with safe_last_turn_tools)
          all_allowed
      else
        all_allowed
    in
    let tool_gate_requested =
      required_tool_names <> []
      || tool_gate_requested_for_turn ~current_tool_choice ~is_last_turn
           ~allowed_tool_names:all_allowed
    in
    let all_allowed =
      tool_names_for_required_gate_surface ~tool_gate_requested all_allowed
    in
    let all_allowed =
      if List.length all_allowed > max_tools then (
        Log.Keeper.info
          "context overflow guard: %d tools > max %d, truncating"
          (List.length all_allowed)
          max_tools;
        let required_turn_essential_tool_names =
          if required_tool_names <> [] then visible_required_tool_names
          else if tool_gate_requested then
            let claim_tools =
              if has_task_claim_affordance turn_affordances
              then [ "keeper_task_claim" ]
              else []
            in
            Keeper_types.dedupe_keep_order
              (visible_affordance_tool_names @ claim_tools)
          else []
        in
        let essential_names =
          Keeper_types.dedupe_keep_order
            (visible_always_include_tools @ required_turn_essential_tool_names)
        in
        let essential =
          List.filter (fun name -> List.mem name essential_names) all_allowed
        in
        let non_essential =
          List.filter
            (fun name -> not (List.mem name visible_always_include_tools))
            all_allowed
        in
        let budget = max_tools - List.length essential in
        essential @ List.filteri (fun i _ -> i < budget) non_essential)
      else
        all_allowed
    in
    let missing_required_tool_names =
      List.filter
        (fun name -> not (List.mem name all_allowed))
        required_tool_names
    in
    let visible_tool_count = List.length all_allowed in
    let tool_surface_class =
      if visible_tool_count = 0 then "none"
      else if List.for_all Tool_catalog.is_public_mcp all_allowed then
        "public_only"
      else
        "mixed"
    in
    let tool_requirement =
      if visible_tool_count = 0 then No_tools
      else if tool_gate_requested then Required
      else Optional
    in
    let lane =
      if is_retry then "retry"
      else match tool_requirement with
        | Required -> "tool_required"
        | Optional -> "tool_optional"
        | No_tools ->
            (match current_tool_choice with
             | Some Agent_sdk.Types.None_ -> "tool_disabled"
             | _ -> "text_only")
    in
    { all_allowed
    ; absolute_turn = turn
    ; checkpoint_start_turn = start_turn_count
    ; per_call_turn
    ; per_call_max_turns = max_turns
    ; core_count
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
    ; missing_required_tool_names
    ; lane
    ; query_text
    }
  in
  let initial_tool_surface =
    compute_tool_surface
      ~turn:(start_turn_count + 1)
      ~messages:history_messages
      ~current_tool_choice:None
      ~decay_discovered:false
  in
  acc.tool_surface <-
    { turn_lane = initial_tool_surface.lane
    ; tool_surface_class = initial_tool_surface.tool_surface_class
    ; tool_requirement = initial_tool_surface.tool_requirement
    ; visible_tool_count = List.length initial_tool_surface.all_allowed
    ; tool_gate_enabled = initial_tool_surface.tool_gate_requested
    ; tool_surface_fallback_used = initial_tool_surface.tool_surface_fallback_used
    ; required_tool_names = initial_tool_surface.required_tool_names
    ; missing_required_tool_names =
        initial_tool_surface.missing_required_tool_names
    ; config_root
    ; cascade_config_path
    ; gemini_mcp_disabled
    ; approval_mode_effective
    ; approval_mode_derived
    };
  let initial_tool_surface_blocker = ref None in
  let initial_tool_surface_result =
    if initial_tool_surface.missing_required_tool_names <> [] then (
      acc.receipt_tool_contract_result <- "tool_surface_mismatch";
      initial_tool_surface_blocker :=
        Some
          (sdk_error_of_keeper_internal_error
             (Keeper_tool_surface_mismatch
                { keeper_name = meta.name
                ; required_tools = initial_tool_surface.required_tool_names
                ; missing_required_tools =
                    initial_tool_surface.missing_required_tool_names
                ; visible_tools = initial_tool_surface.all_allowed
                }));
      Ok initial_tool_surface)
    else if initial_tool_surface.tool_gate_requested
            && initial_tool_surface.all_allowed = []
    then (
      acc.receipt_tool_contract_result <- "no_tool_capable_provider";
      Prometheus.inc_counter
        Prometheus.metric_empty_tool_universe_observed
        ~labels:
          [ ("keeper_name", meta.name);
            ("turn_lane", initial_tool_surface.lane);
            ( "fallback_used",
              string_of_bool initial_tool_surface.tool_surface_fallback_used );
          ]
        ();
      initial_tool_surface_blocker :=
        Some
          (sdk_error_of_keeper_internal_error
             (Keeper_tool_surface_empty
                { keeper_name = meta.name
                ; turn_lane = initial_tool_surface.lane
                ; affordances = turn_affordances
                ; fallback_used = initial_tool_surface.tool_surface_fallback_used
                }));
      Ok initial_tool_surface)
    else
      Ok initial_tool_surface
  in
  match initial_tool_surface_result with
  | Error err -> Error err
  | Ok initial_tool_surface ->
  acc.requested_tool_names <- initial_tool_surface.all_allowed;
  let discover_work_nudge () : string option =
    let meta = acc.meta in
    match meta.work_discovery_enabled with
    | Some false -> None
    | _ ->
      let interval =
        Option.value ~default:600 meta.work_discovery_interval_sec in
      let since_last =
        Time_compat.now ()
        -. meta.runtime.proactive_rt.last_work_discovery_ts
      in
      if since_last < float_of_int interval then None
      else
        let sources =
          Option.value ~default:[] meta.work_discovery_sources in
        let chunks =
          List.filter_map
            (fun src ->
               match src with
               | "stale_tasks" | "unclaimed_tasks" ->
                 (try
                    let backlog = Coord.read_backlog config in
                    let unclaimed =
                      List.filter
                        (fun (t : Masc_domain.task) ->
                          t.task_status = Masc_domain.Todo)
                        backlog.tasks
                    in
                    match unclaimed with
                    | [] -> None
                    | tasks ->
                      let n = min 5 (List.length tasks) in
                      let preview =
                        List.filteri (fun i _ -> i < n) tasks
                        |> List.map (fun (t : Masc_domain.task) ->
                             Printf.sprintf "  - %s (p%d): %s"
                               t.id t.priority
                               (String_util.utf8_safe
                                  ~max_bytes:83 ~suffix:"…" t.title
                                |> String_util.to_string))
                        |> String.concat "\n"
                      in
                      Some (Printf.sprintf
                        "**Unclaimed tasks (%d total, showing %d):**\n%s"
                        (List.length tasks) n preview)
                  with
                  | Eio.Cancel.Cancelled _ as e -> raise e
                  | exn ->
                    Keeper_callback_failure.record
                      ~base_dir:config.base_path
                      ~meta
                      ~callback:"work_discovery_nudge"
                      exn;
                    None)
               | _ -> None)
            sources
        in
        let guidance_section =
          match meta.work_discovery_guidance with
          | Some g when String.trim g <> "" ->
            Some (Printf.sprintf "**Operator guidance:** %s" (String.trim g))
          | _ -> None
        in
        let sections =
          chunks
          @ (match guidance_section with Some s -> [s] | None -> [])
        in
        let active_schema_guard =
          "Use only tool schemas currently shown by the runtime. If an \
           execution tool is absent from the active schema list, do not name \
           or call it; emit [STATE] or use a visible handoff/status tool."
        in
        let unknown_tool_guard =
          Keeper_tool_guidance.render_unknown_tool_guard ()
        in
        (match sections with
         | [] -> None
         | _ ->
           Some (Printf.sprintf
             "## Discovered Work (auto, %ds interval)\n\n%s\n\n\
              ### Use the smallest real action now\n\
              %s\n\n\
              %s\n\n\
              Do not print fenced pseudo-calls. Pick the smallest viable \
              action and emit one or more structured tool calls now."
             interval (String.concat "\n\n" sections) active_schema_guard
             unknown_tool_guard))
  in
  let meta_ref = ref acc.meta in
  let base_hooks =
    Keeper_hooks_oas.make_hooks
      ~config
      ~meta_ref
      ~generation
      ?max_cost_usd
      ?trajectory_acc
      ~on_tool_executed:(fun
          ~tool_name
          ~input
          ~output_text
          ~success
          ~duration_ms
          ~provider ->
        let route_evidence =
          Keeper_tool_call_log.route_evidence_json_of_tool_io
            ~tool_name
            ~input
            ~output_text
        in
        (match Keeper_registry.get ~base_path:config.base_path meta.name with
         | Some entry ->
           acc.meta <- entry.meta;
           meta_ref := entry.meta
         | None -> ());
        acc.tool_calls <-
          { tool_name
          ; provider
          ; outcome = if success then "ok" else "error"
          ; latency_ms = duration_ms
          ; route_evidence
          }
          :: acc.tool_calls)
      ~discover_work_nudge
      ~passive_loop_nudge:(fun () ->
        Keeper_passive_loop_detector.nudge_message ~keeper_name:acc.meta.name)
      ()
  in
  let before_turn_hook : Agent_sdk.Hooks.hooks =
    { Agent_sdk.Hooks.empty with
      before_turn_params =
        Some
          (fun event ->
             match event with
             | Agent_sdk.Hooks.BeforeTurnParams
                 { turn; current_params; messages; last_tool_results; _ } ->
               let hook_t0 = Time_compat.now () in
               acc.current_turn <- turn;
               let intent =
                 if Keeper_config.keeper_adaptive_thinking_mode () then
                   let last_tool_calls =
                     let rev = List.rev messages in
                     let rec scan = function
                       | [] -> []
                       | (msg : Agent_sdk.Types.message) :: rest ->
                         let names =
                           List.filter_map
                             (function
                               | Agent_sdk.Types.ToolUse { name; _ } -> Some name
                               | _ -> None)
                             msg.content
                         in
                         if names <> [] then names else scan rest
                     in
                     scan rev
                   in
                   let retry_count = if is_retry then 1 else 0 in
                   Some
                     (Keeper_turn_intent.classify
                        ~last_tool_calls
                        ~last_user_message:(Some user_message)
                        ~retry_count)
                 else
                   None
               in
               let cascade_seed =
                 Cascade_inference.for_cascade ~name:cascade_name_string
               in
               let current_budget =
                 match cascade_seed.thinking_budget with
                 | Some _ as v -> v
                 | None -> current_params.thinking_budget
               in
               let adaptive_thinking_budget =
                 adaptive_thinking_budget
                   ~enabled:(Keeper_config.keeper_adaptive_thinking_enabled ())
                   ~is_retry
                   ~last_tool_results
                   ~user_message
                   ~dynamic_context
                   ~current_budget
                   ~intent
               in
               let adaptive_thinking_override =
                 match intent with
                 | Some i ->
                   Some (Keeper_turn_intent.equal i Keeper_turn_intent.Cognitive)
                 | None -> None
               in
               let current_params =
                 { current_params with
                   thinking_budget = adaptive_thinking_budget
                 ; enable_thinking =
                     (match adaptive_thinking_override with
                      | Some _ as v -> v
                      | None -> current_params.enable_thinking)
                 }
               in
               let ctx =
                 if String.trim dynamic_context = ""
                 then current_params.extra_system_context
                 else (
                   match current_params.extra_system_context with
                   | None -> Some dynamic_context
                   | Some existing -> Some (existing ^ "\n\n" ^ dynamic_context))
               in
               let ctx =
                 match Masc_context_injector.render_temporal_summary shared_context with
                 | None -> ctx
                 | Some temporal ->
                   (match ctx with
                    | None -> Some temporal
                    | Some existing -> Some (existing ^ "\n\n" ^ temporal))
               in
               let ctx =
                 match acc.meta.current_task_id with
                 | Some task_id ->
                     let last_tool_names =
                       let rev = List.rev messages in
                       let rec scan = function
                         | [] -> []
                         | (msg : Agent_sdk.Types.message) :: rest ->
                           let names =
                             List.filter_map
                               (function
                                 | Agent_sdk.Types.ToolUse { name; _ } -> Some name
                                 | _ -> None)
                               msg.content
                           in
                           if names <> [] then names else scan rest
                       in
                       scan rev
                     in
                     let is_claim_only_turn =
                       List.exists is_claim_tool_name last_tool_names
                       && List.for_all is_claim_context_tool_name last_tool_names
                     in
                     if is_claim_only_turn then
                       let nudge =
                         Printf.sprintf
                           "[CLAIMED TASK] You hold %s. Do NOT call claim_next again. \
                            Use an execution tool visible in your active runtime schema \
                            to start working on it now. If no execution tool is visible, \
                            emit [STATE] with the blocker instead of inventing a tool \
                            name."
                           (Keeper_id.Task_id.to_string task_id)
                       in
                       (match ctx with
                        | None -> Some nudge
                        | Some existing -> Some (existing ^ "\n\n" ^ nudge))
                     else
                       ctx
                 | None -> ctx
               in
               let computed_surface =
                 compute_tool_surface
                   ~turn
                   ~messages
                   ~current_tool_choice:current_params.tool_choice
                   ~decay_discovered:true
               in
               if Keeper_types_profile.keeper_debug
               then
                 Log.Keeper.info
                   "tool_disclosure keeper=%s core=%d deterministic_prefilter=%d \
                    discovered=%d llm_selected=%d llm_rerank=%b allowed=%d query_len=%d \
                    mode=%s"
                   meta.name
                   computed_surface.core_count
                   computed_surface.deterministic_prefilter_count
                   computed_surface.discovered_count
                   computed_surface.llm_selected_count
                   (Keeper_config.keeper_llm_rerank_enabled ())
                   (List.length computed_surface.all_allowed)
                   (String.length computed_surface.query_text)
                   computed_surface.selection_mode;
               let append_ctx ctx text =
                 Some
                   (match ctx with
                    | None -> text
                    | Some e -> e ^ "\n\n" ^ text)
               in
               let ctx =
                 if computed_surface.is_last_turn
                    && computed_surface.required_tool_names <> []
                 then
                   append_ctx
                     ctx
                     (Printf.sprintf
                        "[REQUIRED TOOLS - FINAL TURN] This Agent.run call is on \
                         its final turn, but this message has explicit \
                                 required_tools: %s. You MUST either use every \
                                 required tool now or return a concise blocker naming \
                         the missing policy/tool/runtime condition."
                        (String.concat ", " computed_surface.required_tool_names))
                 else if computed_surface.is_last_turn
                 then
                   append_ctx
                     ctx
                     (Printf.sprintf
                        "[LAST TURN] Per-call turn %d/%d. This is your final turn in this \
                         Agent.run call. You MUST emit a \
                         [STATE]...[/STATE] block now summarizing what you accomplished \
                         and what the next generation should do. Do NOT start new tool \
                         work. Three escape hatches, in priority order: \
                         (1) call extend_turns if the task is almost finished and more \
                         turns will close it out; \
                         (2) call keeper_board_post to hand off the current task and ask \
                         another keeper or operator for judgment when the work needs a \
                         decision you cannot make alone; \
                         (3) if you claimed a task, close it NOW before session ends \
                         with keeper_task_done or keeper_task_submit_for_verification."
                        computed_surface.per_call_turn
                        computed_surface.per_call_max_turns)
                 else if is_retry
                 then
                   append_ctx
                     ctx
                     (Printf.sprintf
                         "[RETRY] The previous attempt overflowed the model context. Stay \
                         concise, prefer already-loaded context, and only use the \
                         smallest essential tool set if a tool call is strictly \
                         necessary. Current tool budget: %d."
                        max_tools_per_turn)
                 else if computed_surface.is_warning_zone
                 then
                   append_ctx
                     ctx
                     (Printf.sprintf
                        "[BUDGET] %d/%d turns used in this Agent.run call. Wrap up current \
                         work and emit a \
                         [STATE] block. If more turns will genuinely finish the task, \
                         call extend_turns. If you are blocked on a decision or \
                         external input, post a question to the board via \
                         keeper_board_post rather than burning turns retrying — that is \
                         the intended judgment-escalation path."
                        computed_surface.per_call_turn
                        computed_surface.per_call_max_turns)
                 else ctx
               in
               if computed_surface.is_warning_zone
               then
                 Log.Keeper.info
                   "keeper:%s per_call_turn_budget absolute_turn=%d checkpoint_start_turn=%d \
                    per_call_turn=%d/%d last_turn=%b"
                   meta.name
                   computed_surface.absolute_turn
                   computed_surface.checkpoint_start_turn
                   computed_surface.per_call_turn
                   computed_surface.per_call_max_turns
                   computed_surface.is_last_turn;
               let all_allowed = computed_surface.all_allowed in
               let tool_filter = Agent_sdk.Guardrails.AllowList all_allowed in
               let tool_choice =
                 if computed_surface.required_tool_names <> []
                    && all_allowed <> []
                 then
                   Some
                     (preferred_tool_choice_for_required_tool_names
                        ~required_tool_names:computed_surface.required_tool_names
                        ~allowed_tool_names:all_allowed)
                 else if computed_surface.is_last_turn
                 then current_params.tool_choice
                 else if computed_surface.tool_gate_requested && all_allowed <> []
                 then
                   Some
                     (preferred_tool_choice_for_required_turn
                        ~has_current_task:(keeper_has_owned_active_task ())
                        ~turn_affordances ~allowed_tool_names:all_allowed)
                 else current_params.tool_choice
               in
               let turn_completion_contract =
                 match computed_surface.tool_gate_requested, tool_choice with
                 | true, Some Agent_sdk.Types.Auto ->
                   Keeper_tool_disclosure.completion_contract_of_tool_choice
                     tool_choice
                 | true, _ ->
                   Keeper_tool_disclosure.Require_tool_use
                 | false, _ ->
                   Keeper_tool_disclosure.completion_contract_of_tool_choice
                     tool_choice
               in
               acc.completion_contract <- turn_completion_contract;
               if turn_completion_contract = Keeper_tool_disclosure.Require_tool_use
               then acc.required_tool_use_seen <- true;
               let lane = computed_surface.lane in
               acc.requested_tool_names <- all_allowed;
               acc.tool_surface <-
                 { turn_lane = lane
                 ; tool_surface_class = computed_surface.tool_surface_class
                 ; tool_requirement = computed_surface.tool_requirement
                 ; visible_tool_count = List.length all_allowed
                 ; tool_gate_enabled = computed_surface.tool_gate_requested
                 ; tool_surface_fallback_used = computed_surface.tool_surface_fallback_used
                 ; required_tool_names = computed_surface.required_tool_names
                 ; missing_required_tool_names =
                     computed_surface.missing_required_tool_names
                 ; config_root
                 ; cascade_config_path
                 ; gemini_mcp_disabled
                 ; approval_mode_effective
                 ; approval_mode_derived
                 };
               let thinking_enabled_effective =
                 match current_params.enable_thinking with
                 | Some b -> b
                 | None -> Keeper_config.keeper_enable_thinking ()
               in
               Keeper_tool_call_log.set_turn_context
                 ~keeper_name:meta.name
                 ~agent_name:meta.agent_name
                 ~lane
                 ?tool_choice:(Option.map
                   (fun choice ->
                     Yojson.Safe.to_string
                       (Agent_sdk.Types.tool_choice_to_json choice))
                   tool_choice)
                 ~thinking_enabled:thinking_enabled_effective
                 ?thinking_budget:current_params.thinking_budget
                 ~prompt_fingerprint:prompt_metrics.fingerprint
                 ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
                 ~session_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
                 ~generation
                 ~turn
                 ~keeper_turn_id:turn
                 ?task_id:(Option.map Keeper_id.Task_id.to_string acc.meta.current_task_id)
                 ~goal_ids:meta.active_goal_ids
                 ~sandbox_profile:
                   (Keeper_types.sandbox_profile_to_string meta.sandbox_profile)
                 ~sandbox_root:
                   (Keeper_sandbox.keeper_visible_root_abs_of_meta ~config meta)
                 ~allowed_paths:(Keeper_alerting_path.effective_allowed_paths ~meta)
                 ~network_mode:
                   (Keeper_types.network_mode_to_string meta.network_mode)
                 ?approval_mode:approval_mode_effective
                 ~tool_surface_class:computed_surface.tool_surface_class
                 ~visible_tool_count:(List.length all_allowed)
                 ~required_tools:computed_surface.required_tool_names
                 ~missing_required_tools:computed_surface.missing_required_tool_names
                 ~cascade_profile:cascade_name_string
                 ();
               (let now = Time_compat.now () in
                let hook_elapsed_ms = Keeper_timing.round1 ((now -. hook_t0) *. 1000.0) in
                Keeper_registry.set_turn_decision_stage
                  ~base_path:config.base_path meta.name
                  Keeper_registry.Decision_tool_policy_selected;
                Keeper_registry.set_turn_cascade_state
                  ~base_path:config.base_path meta.name
                  Keeper_registry.Cascade_selecting;
                let disclosure_json =
                  `Assoc
                    [ "ts_unix", `Float now
                    ; "event", `String "tool_disclosure"
                    ; "keeper_name", `String meta.name
                    ; "turn", `Int turn
                    ; "checkpoint_start_turn", `Int computed_surface.checkpoint_start_turn
                    ; "per_call_turn", `Int computed_surface.per_call_turn
                    ; "per_call_max_turns", `Int computed_surface.per_call_max_turns
                    ; "selection_mode", `String computed_surface.selection_mode
                    ; "core_count", `Int computed_surface.core_count
                    ; "deterministic_prefilter_count", `Int computed_surface.deterministic_prefilter_count
                    ; "discovered_count", `Int computed_surface.discovered_count
                    ; "llm_selected_count", `Int computed_surface.llm_selected_count
                    ; "final_visible", `Int (List.length all_allowed)
                    ; "turn_lane", `String lane
                    ; "tool_surface_class", `String computed_surface.tool_surface_class
                    ; "tool_requirement", tool_requirement_to_yojson computed_surface.tool_requirement
                    ; "tool_gate_enabled", `Bool computed_surface.tool_gate_requested
                    ; "tool_surface_fallback_used", `Bool computed_surface.tool_surface_fallback_used
                    ; "hook_ms", `Float hook_elapsed_ms
                    ]
                in
                try
                  Keeper_types_support.append_jsonl_line
                    (Keeper_types_support.keeper_decision_log_path config meta.name)
                    disclosure_json
                with
                | Eio.Cancel.Cancelled _ as e -> raise e
                | exn ->
                  Prometheus.inc_counter
                    Prometheus.metric_keeper_decision_audit_flush_failures
                    ~labels:[("keeper", meta.name)]
                    ();
                  Log.Keeper.warn
                    "keeper:%s tool_disclosure jsonl append failed: %s"
                    meta.name
                    (Printexc.to_string exn));
               Eio.Fiber.yield ();
               Agent_sdk.Hooks.AdjustParams
                 { current_params with
                   extra_system_context = ctx
                 ; tool_choice
                 ; tool_filter_override = Some tool_filter
                 }
             | _ -> Agent_sdk.Hooks.Continue)
    }
  in
  let hooks = Agent_sdk.Hooks.compose ~outer:before_turn_hook ~inner:base_hooks in
  let base_dir = Coord.masc_root_dir config in
  let memory_session_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
  let memory_backend =
    Memory_oas_bridge.make_backend
      ~agent_name
      ~base_dir
      ~session_id:memory_session_id
      ()
  in
  let memory =
    Agent_sdk.Memory.create ~long_term:memory_backend ()
  in
  let hooks =
    let mem_hooks =
      Memory_hooks.make
        ~agent_name ~config ~memory
        ~world_backend:memory_backend
        ~episode_limit:30
        ~procedure_limit:10 ()
    in
    Memory_hooks.compose_with_inner ~memory_hooks:mem_hooks ~inner:hooks
  in
  (* Tier K4b/K4c: install the tool-emission PostToolUse hook so
     tagged tool results flow into this keeper's own accumulator
     during Agent.run. The drain happens in keeper_post_turn.ml
     [apply_tool_emission_wirein] BEFORE [apply_multimodal_wirein],
     keyed by the SAME keeper name (stable across turns).
     When [MASC_TOOL_EMISSION] is off the hook is a no-op (see
     [Keeper_tool_emission_hook] for the gating). *)
  let hooks =
    let acc =
      Keeper_tool_emission_hook.accumulator_for_keeper agent_name
    in
    Keeper_tool_emission_hook.install_into_hooks acc hooks
  in
  let reducer =
    let hydrator_steps =
      match Keeper_artifact_hydrator.reducer_from_env () with
      | Some r -> [ r ]
      | None -> []
    in
    Agent_sdk.Context_reducer.compose (
      hydrator_steps @ [
      Agent_sdk.Context_reducer.drop_thinking;
      Agent_sdk.Context_reducer.stub_tool_results ~keep_recent:3;
      Agent_sdk.Context_reducer.prune_tool_outputs ~max_output_len:4000;
      Agent_sdk.Context_reducer.cap_message_tokens
        ~max_tokens:Env_config_keeper.KeeperReducer.cap_message_tokens
        ~keep_recent:Env_config_keeper.KeeperReducer.cap_message_keep_recent;
      Agent_sdk.Context_reducer.repair_dangling_tool_calls;
      {
        Agent_sdk.Context_reducer.strategy =
          Agent_sdk.Context_reducer.Custom
            Keeper_context_core.repair_broken_tool_call_pairs;
      };
      Agent_sdk.Context_reducer.merge_contiguous;
    ])
  in
  Ok { tools
     ; cleanup = keeper_tool_bundle.cleanup
     ; hooks
     ; reducer
     ; memory
     ; acc
     ; initial_tool_surface
     ; initial_tool_surface_blocker
     ; all_tool_names
     ; tool_usage_before
     ; receipt_turn_count_ref
     ; receipt_model_used_ref
     ; receipt_stop_reason_ref
     ; receipt_cascade_observation_ref
     ; receipt_response_text_present_ref
     ; reported_tool_names_ref
     ; observed_tool_names_ref
     ; canonical_tool_names_ref
     ; unexpected_tool_names_ref
     ; actual_keeper_tool_names_ref
     }
