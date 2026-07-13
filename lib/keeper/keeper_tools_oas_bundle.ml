(** Tool bundle assembly for keeper OAS execution.

    [make_tool_bundle] builds the full [tool_bundle] from each descriptor's
    single explicit Keeper-model projection, and [make_tools] is the
    convenience wrapper returning only [.tools].

    Extracted from [Keeper_tools_oas_handler] to keep that module
    focused on per-tool handler construction. *)

open Keeper_tools_oas

let task_state_hint ~(config : Workspace.config) ~(meta : Keeper_meta_contract.keeper_meta) : string =
  let meta = Keeper_current_task_reconcile.sync_current_task_id_from_backlog ~config meta in
  match meta.current_task_id with
  | None ->
    "No task currently assigned. Use keeper_task_claim or keeper_tasks_list to find one."
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
      ?clock
      ?continuation_channel
      ?gate_context
      ?hitl_resolution
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
  let gate_grant =
    Option.bind hitl_resolution Keeper_gate.cycle_grant_of_resolution
  in
  let gate_context_provider =
    Option.map
      (fun context () -> Keeper_gate_causal_context.snapshot context)
      gate_context
  in
  let record_gate_result =
    Option.map
      (fun context ~operation ~input result ->
         Keeper_gate_causal_context.record_tool_result
           context
           ~operation
           ~input
           result)
      gate_context
  in
  (* Every descriptor-declared model tool is materialized. The turn hook sends
     this exact list to OAS without per-Keeper or per-turn reduction. *)
  let model_visible_descriptors = Keeper_tool_descriptor.model_visible_descriptors () in
  (* The handler dispatches with
     [~name:descriptor.internal_name] so all telemetry SSOT remains internal;
     exactly one projected Tool.schema.name is model-visible.
     [descriptor.translate] reshapes the LLM's payload before dispatch;
     [descriptor.input_schema] provides the LLM-facing schema. *)
  let descriptor_tools =
    List.concat_map
      (fun (descriptor : Keeper_tool_descriptor.t) ->
         let internal = descriptor.internal_name in
         Keeper_tool_descriptor.keeper_model_names descriptor
         |> List.map (fun model_name ->
             let h =
               Keeper_tools_oas_handler.make_keeper_tool_handler
                 ~name:internal
                 ~input_schema:descriptor.input_schema
                 ~config
                   ~meta
                   ~ctx_snapshot
                   ?turn_sandbox_factory
                 ~exec_cache
                 ?search_fn
                 ?clock
                 ?continuation_channel
                 ?gate_context:gate_context_provider
                 ?gate_grant
                 ?record_gate_result
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
                 ()
             in
             let description =
               match descriptor.model_description_projection with
               | Keeper_tool_descriptor.Static_description -> descriptor.description
               | Keeper_tool_descriptor.Current_task_state ->
                 descriptor.description ^ "\n\n" ^ task_state_hint ~config ~meta
             in
             Tool_bridge.oas_tool_of_masc
               ~name:model_name
               ~description
               ~input_schema:descriptor.input_schema
               (fun input -> h input)))
      model_visible_descriptors
  in
  let bundle =
      { tools = descriptor_tools
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
      ?clock
      ()
  : Agent_sdk.Tool.t list
  =
  (make_tool_bundle ~config ~meta ~ctx_snapshot ?search_fn ?clock ())
    .tools
;;
