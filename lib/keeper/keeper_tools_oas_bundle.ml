(** Tool bundle assembly for keeper OAS execution.

    [make_tool_bundle] builds the full [tool_bundle] (internal tools +
    alias-registered public names) and [make_tools] is the convenience
    wrapper returning only [.tools].

    Extracted from [Keeper_tools_oas_handler] to keep that module
    focused on per-tool handler construction. *)

open Keeper_tools_oas

let task_state_hint ~(config : Workspace.config) ~(meta : Keeper_meta_contract.keeper_meta) : string =
  let meta = Keeper_current_task_reconcile.sync_current_task_id_from_backlog ~config meta in
  match meta.current_task_id with
  | None -> "No task currently assigned. Use keeper_task_claim or masc_tasks to find one."
  | Some tid ->
    let task_id = Keeper_id.Task_id.to_string tid in
    (match Workspace_backlog.read_backlog_r config with
     | Error _ -> Printf.sprintf "Current task: %s (status unavailable)" task_id
     | Ok backlog ->
       (match List.find_opt (fun (t : Masc_domain.task) -> t.id = task_id) backlog.tasks with
        | None -> Printf.sprintf "Current task: %s (not found in backlog)" task_id
        | Some task ->
          let status = Masc_domain.task_status_to_string task.task_status in
          let hint = Workspace_task_classify.next_actions_hint task.task_status in
          Printf.sprintf "Current task: %s, status=%s%s" task_id status hint))
;;

let make_tool_bundle
      ~(config : Workspace.config)
      ~(meta : Keeper_meta_contract.keeper_meta)
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
     each tool call site that already knows its [cwd]. *)
  let turn_sandbox_factory = Some (Keeper_sandbox_factory.create ~config ~meta ()) in
  let exec_cache = Some (Masc_exec.Exec_cache.create ()) in
  (* Build Tool.t for the full universe so BM25 and Tool_op can
     discover tools beyond the current turn-allowed schema.  Progressive disclosure
     (AllowList filter in before_turn_hook) controls LLM visibility;
     execute_keeper_tool_call uses can_execute for the execution gate. *)
  let universe_names = Keeper_tool_dispatch_runtime.keeper_universe_tool_names meta in
  let tool_defs = Keeper_tool_dispatch_runtime.keeper_universe_model_tools meta in
  (* Descriptor projection owns the sole active model name for each semantic
     capability. Its internal route is materialized only by Pass B, so Pass A
     cannot reintroduce a second model-visible name. Dispatch-only descriptors
     are absent from [model_visible_descriptors]. *)
  let model_visible_descriptors = Keeper_tool_descriptor.model_visible_descriptors () in
  let descriptor_pass_b_owned_names =
    model_visible_descriptors
    |> List.concat_map (fun descriptor ->
      Keeper_tool_descriptor.keeper_model_names descriptor
      @ Keeper_tool_descriptor.internal_names descriptor)
  in
  let failure_counts = create_failure_counts () in
  (* Pass A: schemas without a descriptor-owned model projection. *)
  let internal_tools =
    List.filter_map
      (fun (td : Masc_domain.tool_schema) ->
         if
           List.mem td.name universe_names
           && not (List.mem td.name descriptor_pass_b_owned_names)
         then (
           let h =
             Keeper_tools_oas_handler.make_keeper_tool_handler
               ~name:td.name
               ~input_schema:td.input_schema
               ~config
                 ~meta
                 ~ctx_snapshot
                 ?turn_sandbox_factory
                 ~exec_cache
               ?search_fn
               ?on_tool_called
               ?clock
               ~failure_counts
               ()
           in
           let description =
             if String.equal td.name "masc_transition"
             then td.description ^ "\n\n" ^ task_state_hint ~config ~meta
             else td.description
           in
           Some
             (Tool_bridge.oas_tool_of_masc
                ~name:td.name
                ~description
                ~input_schema:td.input_schema
                (fun input -> h input)))
         else None)
      tool_defs
  in
  (* Pass B: register the descriptor-owned model projection. The handler dispatches with
     [~name:descriptor.internal_name] so all telemetry SSOT remains internal;
     only the Tool.schema.name is model-visible.
     [descriptor.translate] reshapes the LLM's payload before dispatch;
     [descriptor.input_schema] provides the LLM-facing schema. *)
  let alias_tools =
    List.concat_map
      (fun (descriptor : Keeper_tool_descriptor.t) ->
         let internal = descriptor.internal_name in
         if not (List.mem internal universe_names)
         then []
         else (
           (* Descriptor-backed aliases own their public schema.  Some aliases
              (notably WebSearch/WebFetch) can be present in the descriptor
              universe before the injected masc_* schema snapshot is populated. *)
           let handler_input_schema =
             Keeper_tool_policy.descriptor_handler_input_schema descriptor
           in
           Keeper_tool_descriptor.keeper_model_names descriptor
           |> List.map (fun model_name ->
             let h =
               Keeper_tools_oas_handler.make_keeper_tool_handler
                 ~name:internal
                 ~input_schema:handler_input_schema
                 ~config
                   ~meta
                   ~ctx_snapshot
                   ?turn_sandbox_factory
                   ~exec_cache
                 ?search_fn
                 ?on_tool_called
                 ?clock
                 ~pre_validate_input:(fun input ->
                   match
                     Keeper_tool_descriptor_resolution.validate_public_input_for_tool_call
                       ~tool_name:model_name
                       ~input
                   with
                 | Some result -> result
                 | None -> Ok input)
                 ~translate_input:descriptor.translate
                 ~validate_translated_input:descriptor.validate_translated_input
                 ~failure_counts
                 ()
             in
             (* Public aliases (e.g. WebSearch) are not present in
                [Tool_catalog] metadata, so derive the descriptor from the
                internal name and pass it explicitly. *)
             let oas_descriptor = Tool_bridge.oas_descriptor_of_masc_tool internal in
             Tool_bridge.oas_tool_of_masc
               ?descriptor:oas_descriptor
               ~name:model_name
               ~description:descriptor.description
               ~input_schema:descriptor.input_schema
               (fun input -> h input))))
      model_visible_descriptors
  in
  let bundle =
      { tools = internal_tools @ alias_tools
      ; cleanup =
          (fun () ->
            Option.iter Keeper_sandbox_factory.cleanup turn_sandbox_factory)
      }
  in
  Otel_metric_hotpath.observe
    ~metric:Otel_metric_hotpath.metric_oas_make_tool_bundle_sec
    ~start:__t0;
  bundle
;;

let make_tools
      ~(config : Workspace.config)
      ~(meta : Keeper_meta_contract.keeper_meta)
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
