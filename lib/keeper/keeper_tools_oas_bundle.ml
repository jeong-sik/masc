(** Tool bundle assembly for keeper OAS execution.

    [make_tool_bundle] builds the full [tool_bundle] (internal tools +
    alias-registered public names) and [make_tools] is the convenience
    wrapper returning only [.tools].

    Extracted from [Keeper_tools_oas_handler] to keep that module
    focused on per-tool handler construction. *)

open Keeper_tools_oas

let make_tool_bundle
      ~(config : Coord.config)
      ~(meta : Keeper_types.keeper_meta)
      ~(ctx_snapshot : Keeper_types.working_context)
      ?search_fn
      ?on_tool_called
      ?clock
      ()
  : tool_bundle
  =
  (* Phase B baseline (wise-nibbling-lerdorf plan): timestamp before the
     bundle assembly work begins; observed at function exit. *)
  let __t0 = Mtime_clock.now () in
  (* PR-3b (#11611 part 1): replace eager [Keeper_turn_sandbox_runtime]
     instances with a factory.  in_playground/cwd are unknown at
     turn-start, so the factory defers
     [Keeper_sandbox_runner.effective_sandbox_profile] resolution until
     each tool call site that already knows its [cwd].  The git variant
     carries a [default_network_override] so resolved runtimes always
     inherit the host network. *)
  let turn_sandbox_factory = Some (Keeper_sandbox_factory.create ~config ~meta ()) in
  let turn_sandbox_factory_git =
    Some
      (Keeper_sandbox_factory.create
         ~default_network_override:Network_inherit
         ~config
         ~meta
         ())
  in
  let exec_cache = Some (Masc_exec.Exec_cache.create ()) in
  (* Build Tool.t for the full universe so BM25 and Tool_op can
     discover tools beyond the active preset.  Progressive disclosure
     (AllowList filter in before_turn_hook) controls LLM visibility;
     execute_keeper_tool_call uses can_execute for the execution gate. *)
  let universe_names = Keeper_exec_tools.keeper_universe_tool_names meta in
  let tool_defs = Keeper_exec_tools.keeper_universe_model_tools meta in
  (* RFC-0064 Phase 2 (Copilot review #14662 threads 5/6): aliased internal
     names backing public aliases must NOT appear on
     the LLM-visible surface alongside their public alias.  Mirrors the
     pattern already established in [keeper_run_tools.ml] PRs #14574/#14596. *)
  let aliased_internal_names =
    List.filter_map
      (fun public ->
         match Keeper_tool_alias.route public with
         | Some r -> Some (Agent_tool_descriptor.internal_names r.descriptor)
         | None -> None)
      (Keeper_tool_alias.public_names ())
    |> List.concat
  in
  let alias_public_names_in_surface =
    List.filter
      (fun public ->
         match Keeper_tool_alias.route public with
         | Some r ->
           List.exists
             (fun internal_name -> List.mem internal_name universe_names)
             (Agent_tool_descriptor.internal_names r.descriptor)
         | None -> false)
      (Keeper_tool_alias.public_names ())
  in
  let assembled_surface_names =
    List.filter (fun n -> not (List.mem n aliased_internal_names)) universe_names
    @ alias_public_names_in_surface
  in
  (* Record tool assignment telemetry for causal tracing.
     assignment_id links Assigned -> Called -> Completed events.
     [tool_list] matches the actual LLM-visible surface (internal names
     minus aliased counterparts, plus public alias names), so downstream
     Assigned/Called/Completed pairing has no missing entries. *)
  let (_assignment_id : Tool_assignment_telemetry.assignment_id) =
    let lookup = Keeper_tool_policy.tool_access_lookup_of_meta meta in
    let preset =
      match meta.tool_access with
      | Preset { preset; _ } ->
        Some (Keeper_tool_policy.preset_name_of_tool_preset preset)
      | Custom _ -> None
    in
    Tool_assignment_telemetry.emit_assigned
      ~agent_id:meta.agent_name
      ~profile:"keeper"
      ?preset
      ~tool_list:assembled_surface_names
      ~allow_set:(Keeper_tool_policy.StringSet.elements lookup.allow_set)
      ~deny_set:(Keeper_tool_policy.StringSet.elements lookup.deny_set)
      ~reason:"keeper tool bundle assembly"
      ()
  in
  let failure_counts = create_failure_counts () in
  (* Pass A: internal tools that have no public alias.  Aliased internals
     are registered only via Pass B under their public name so the LLM
     surface holds at most one entry per logical tool. *)
  let internal_tools =
    List.filter_map
      (fun (td : Masc_domain.tool_schema) ->
         if
           List.mem td.name universe_names
           && not (List.mem td.name aliased_internal_names)
         then (
           let h =
             Keeper_tools_oas_handler.make_keeper_tool_handler
               ~name:td.name
               ~input_schema:td.input_schema
               ~config
               ~meta
               ~ctx_snapshot
               ?turn_sandbox_factory
               ?turn_sandbox_factory_git
               ~exec_cache
               ?search_fn
               ?on_tool_called
               ?clock
               ~failure_counts
               ()
           in
           Some
             (Tool_bridge.oas_tool_of_masc
                ~name:td.name
                ~description:td.description
                ~input_schema:td.input_schema
                (fun input -> h input)))
         else None)
      tool_defs
  in
  (* Pass B: register LLM-native capability names (Execute/ReadFile/etc)
     via the flat routing table. The handler dispatches with
     [~name:r.internal_name] so all telemetry SSOT remains internal;
     only the Tool.schema.name (LLM-visible) is the public name.
     [r.translate] reshapes the LLM's payload before dispatch;
     [r.public_schema] provides the LLM-facing schema. *)
  let alias_tools =
    List.filter_map
      (fun public ->
         match Keeper_tool_alias.route public with
         | None -> None (* routing miss — should not happen for public_names *)
         | Some r ->
           let internal = r.internal_name in
           if not (List.mem internal universe_names)
           then None
           else (
             match
               List.find_opt
                 (fun (td : Masc_domain.tool_schema) -> String.equal td.name internal)
                 tool_defs
             with
             | None -> None
             | Some internal_def ->
               let input_schema =
                 match r.public_schema with
                 | Some s -> s
                 | None -> internal_def.input_schema
               in
              let description = r.descriptor.description in
               let h =
                 Keeper_tools_oas_handler.make_keeper_tool_handler
                   ~name:internal
                   ~input_schema:internal_def.input_schema
                   ~config
                   ~meta
                   ~ctx_snapshot
                   ?turn_sandbox_factory
                   ?turn_sandbox_factory_git
                   ~exec_cache
                   ?search_fn
                   ?on_tool_called
                   ?clock
                   ~translate_input:r.translate
                   ~failure_counts
                   ()
               in
               Some
                 (Tool_bridge.oas_tool_of_masc
                    ~name:public
                    ~description
                    ~input_schema
                    (fun input -> h input))))
      (Keeper_tool_alias.public_names ())
  in
  let bundle =
    { tools = internal_tools @ alias_tools
    ; cleanup =
        (fun () ->
          Option.iter Keeper_sandbox_factory.cleanup turn_sandbox_factory;
          Option.iter Keeper_sandbox_factory.cleanup turn_sandbox_factory_git)
    }
  in
  Prometheus_hotpath.observe
    ~metric:Prometheus_hotpath.metric_oas_make_tool_bundle_sec
    ~start:__t0;
  bundle
;;

let make_tools
      ~(config : Coord.config)
      ~(meta : Keeper_types.keeper_meta)
      ~(ctx_snapshot : Keeper_types.working_context)
      ?search_fn
      ?on_tool_called
      ?clock
      ()
  : Agent_sdk.Tool.t list
  =
  (make_tool_bundle ~config ~meta ~ctx_snapshot ?search_fn ?on_tool_called ?clock ())
    .tools
;;
