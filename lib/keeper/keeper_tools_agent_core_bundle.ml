(** Tool bundle assembly for keeper AGENT_CORE execution.

    [make_tool_bundle] builds the full [tool_bundle] from each descriptor's
    single explicit Keeper-model projection, and [make_tools] is the
    convenience wrapper returning only [.tools].

    Extracted from [Keeper_tools_agent_core_handler] to keep that module
    focused on per-tool handler construction. *)

open Keeper_tools_agent_core

let terminal_externalization_failure
      state
      ({ kind; message } : Tool_bridge.externalization_error)
  =
  match state with
  | Keeper_tools_agent_core.Terminal_effect_completed _ ->
    let detail =
      match kind with
      | Tool_bridge.Artifact_storage_failure ->
        Keeper_terminal_effect_detail.Output_artifact_unstored { message }
      | Tool_bridge.Inline_budget_exceeded ->
        Keeper_terminal_effect_detail.Output_over_inline_budget { message }
    in
    Some
      { Keeper_tools_agent_core.failure_class = Tool_result.Runtime_failure
      ; effect_disposition = Tool_result.Proven_post_effect
      ; detail
      }
  | ( Keeper_tools_agent_core.Terminal_effect_open
    | Keeper_tools_agent_core.Deferred_tool_result
    | Keeper_tools_agent_core.External_effect_deferred
    | Keeper_tools_agent_core.Terminal_effect_failed _ ) ->
    None
;;

let initial_terminal_effect_state = function
  | Some
      { Keeper_tools_agent_core.outcome =
          ( Keeper_gate_replay.Applied _
          | Keeper_gate_replay.Applied_with_warning _ )
      ; terminal_effect_receipt = Some receipt
      ; _
      } ->
    Keeper_tools_agent_core.Terminal_effect_completed receipt
  | None
  | Some
      { Keeper_tools_agent_core.outcome =
          ( Keeper_gate_replay.Applied _
          | Keeper_gate_replay.Applied_with_warning _ )
      ; terminal_effect_receipt = None
      ; _
      }
  | Some
      { Keeper_tools_agent_core.outcome =
          ( Keeper_gate_replay.Not_applicable
          | Keeper_gate_replay.Failed _
          | Keeper_gate_replay.Indeterminate _
          | Keeper_gate_replay.Repair_required _
          | Keeper_gate_replay.Resolution_absent _ )
      ; _
      } -> Keeper_tools_agent_core.Terminal_effect_open
;;

(* The failure callback every ordinary descriptor's handler receives. The
   handler calls it only for a post-effect or unknown failure; whether that
   ends the turn is Keeper_tool_failure_boundary's decision, the same one a
   skill composition reads for its failed nodes. *)
let ordinary_on_failed
      ~mark_terminal_effect_failed
      handler
      (failure : Keeper_tools_agent_core.terminal_effect_failure)
  =
  if Keeper_tool_failure_boundary.ends_turn handler failure.effect_disposition
  then mark_terminal_effect_failed failure
;;

let make_tool_bundle_for_descriptors_with_policy
      ~(config : Workspace.config)
      ~(meta : Keeper_meta_contract.keeper_meta)
      ~(publication_recovery :
          Keeper_publication_recovery_availability.turn_context)
      ~(ctx_snapshot : Keeper_types.working_context)
      ?clock
      ?continuation_channel
      ?gate_context
      ?hitl_resolution
      ?on_gate_deferred
      ?(skill_catalog = Keeper_skill_catalog.empty)
      ?(identity_surface : Keeper_tools_agent_core.attached_surface option)
      ?composition_plan_index
      ?skill_activation_context
      ?composition_result_delivery
      ?(allow_unrecorded_skill_surface = false)
      ?turn_ctx_cell
      ?capability_surface
      ?(checkpoint_owner = fun () -> None)
      ?(tool_result_inline_ceiling_bytes = fun () -> Common.max_tool_result_wire_bytes)
      ~(descriptors : Keeper_tool_descriptor.t list)
      ()
  : tool_bundle
  =
  (* Which lane will execute this call. The bundle is built before the turn
     resolves a runtime, so this is asked per call rather than read now.

     [Store_above] is constructed in exactly one place —
     [Tool_output.default_model_projection] — so matching it here is matching
     "the descriptor did not choose a projection". A descriptor that did
     choose one ([keeper.artifact.read] is the only one today) keeps it: its
     page size answers a different question than the wire ceiling. *)
  let artifact_draft_scope = Keeper_artifact_draft_scope.create ~base_path:config.base_path ~keeper:meta.name in
  let model_projection_for_call (descriptor : Keeper_tool_descriptor.t) () =
    match checkpoint_owner (), descriptor.model_output_projection with
    | Some Runtime_execution.Masc_agent_core, Tool_output.Store_above _ ->
      Tool_output.agent_core_model_projection
    | Some Runtime_execution.Official_client, Tool_output.Store_above _ ->
      Tool_output.Store_above
        { threshold_bytes = tool_result_inline_ceiling_bytes () }
    | (Some Runtime_execution.Official_client | None), projection
    | Some Runtime_execution.Masc_agent_core, (Tool_output.Inline_up_to _ as projection) ->
      projection
  in
  (* The per-run carrier is filled after bundle construction. Each handler
     freezes this context at invocation entry before input preparation. *)
  let source_context () =
    Option.map
      (fun cell -> Keeper_tool_call_log_context.get_turn_context_record ~cell ())
      turn_ctx_cell
  in
  let keeper_turn_id () =
    Option.bind (source_context ()) (fun context ->
      context.Keeper_tool_call_log_context.keeper_turn_id)
  in
  let descriptors =
    List.map
      (fun (descriptor : Keeper_tool_descriptor.t) ->
         let canonical = match capability_surface with
           | Some surface -> Keeper_capability_surface.find_descriptor_by_id surface descriptor.id
           | None -> Keeper_tool_descriptor.find_id descriptor.id in
         match canonical with
         | Some canonical when canonical == descriptor -> canonical
         | Some _ | None ->
           invalid_arg
             (Printf.sprintf
                "Keeper tool bundle received unknown descriptor id %S"
                descriptor.id))
      descriptors
  in
  Option.iter (fun index ->
    Keeper_tool_composition_plan_index.bind_descriptors index descriptors)
    composition_plan_index;
  let skill_surface_present =
    Keeper_skill_catalog.skills skill_catalog <> []
  in
  (match skill_surface_present, skill_activation_context with
   | true, None when not allow_unrecorded_skill_surface ->
     invalid_arg
       "Skill-bearing Keeper bundle requires a frozen activation context"
   | true, None
   | true, Some _ | false, Some _ | false, None -> ());
  (* PR-3b (#11611 part 1): replace eager [Keeper_turn_sandbox_runtime]
     instances with a factory. in_playground and the runtime cache key need
     the call site's [cwd], which is unknown at turn start, so the factory
     defers creating the runtime until a call site supplies it.

     The profile itself is not deferred in any meaningful sense:
     [Keeper_sandbox_runner.effective_sandbox_profile] takes only [~meta] and
     projects [meta.sandbox_profile], so every call in this turn gets the same
     answer from the [meta] captured here. *)
  let turn_sandbox_factory = Some (Keeper_sandbox_factory.create ~config ~meta ()) in
  let gate_grant =
    Option.bind hitl_resolution Keeper_gate.cycle_grant_of_resolution
  in
  let gate_context_provider =
    Option.map
      (fun context () -> Keeper_gate_causal_context.snapshot context)
      gate_context
  in
  (* RFC-0356: the approval owns its effect. Spend the one-shot grant on the
     payload the Gate approved instead of waiting for the model to re-emit a
     byte-identical call, which it cannot do for large write payloads
     (#25947). Consumption is the durable grant, so a second bundle build in
     the same cycle replays nothing.

     Replay carries the same causal context the model-issued path carries: a
     replay whose re-derived input no longer matches its approval follows the
     producer's ordinary Gate behavior instead of inventing another replay
     constraint. *)
  let gate_replay_delivery =
    match hitl_resolution, gate_grant with
    | ( Some
          { Keeper_event_queue.approval_id
          ; decision = Keeper_event_queue.Hitl_approved
          ; _
          }
      , Some grant ) ->
      let replay_execution =
        Keeper_gate_replay.replay_approved_effect_with_receipt
           ~config
           ~meta
           ~publication_recovery
           ~turn_sandbox_factory
           ?continuation_channel
           ?gate_context:gate_context_provider
           ~grant
           ~approval_id
           ()
      in
      let outcome = replay_execution.Keeper_gate_replay.outcome in
      (match outcome with
       | Keeper_gate_replay.Not_applicable -> ()
       | Keeper_gate_replay.Applied _ as outcome ->
         Log.Keeper.info
           "gate replay approval=%s %s"
           approval_id
           (Keeper_gate_replay.outcome_to_string outcome)
       | Keeper_gate_replay.Applied_with_warning _ as outcome ->
         Log.Keeper.error
           "gate replay approval=%s %s"
           approval_id
           (Keeper_gate_replay.outcome_to_string outcome)
       | Keeper_gate_replay.Failed _ as outcome ->
         Log.Keeper.error
           "gate replay approval=%s %s"
           approval_id
           (Keeper_gate_replay.outcome_to_string outcome)
       | Keeper_gate_replay.Indeterminate _ as outcome ->
         Log.Keeper.error
           "gate replay approval=%s %s"
           approval_id
           (Keeper_gate_replay.outcome_to_string outcome)
       | Keeper_gate_replay.Repair_required _ as outcome ->
         Log.Keeper.error
           "gate replay approval=%s %s"
           approval_id
           (Keeper_gate_replay.outcome_to_string outcome)
       | Keeper_gate_replay.Resolution_absent _ as outcome ->
         Log.Keeper.warn
           "gate replay approval=%s %s"
           approval_id
           (Keeper_gate_replay.outcome_to_string outcome));
      Some
        Keeper_tools_agent_core.
          { approval_id
          ; outcome
          ; terminal_effect_receipt = replay_execution.terminal_effect_receipt
          }
    | None, _
    | Some { Keeper_event_queue.decision = Keeper_event_queue.Hitl_rejected _; _ }, _
    | Some { Keeper_event_queue.decision = Keeper_event_queue.Hitl_approved; _ }, None ->
      None
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
  (* Every descriptor authorized by this caller is materialized through the
     canonical Keeper handler. A Keeper turn supplies its frozen Tool Group
     surface; bounded internal roles supply their own closed typed subset. *)
  (* The bundle lives for exactly one Agent run. Its typed tool-boundary
     state is request-scoped and observed by the AGENT_CORE tool-boundary probe only
     after the whole tool batch and checkpoint sink have completed. A generic
     deferred tool transition retains the existing durable-stimulus checkpoint;
     only a typed external-effect defer stops the provider loop until Gate's
     durable resolution wakes a later turn. An already-applied connector replay
     seeds this same state from its producer-owned receipt, so finalization does
     not mistake the post-effect continuation for another visible reply. A
     terminal completion supersedes a defer in the same batch; a proven terminal
     failure dominates every state regardless of callback order. Failure is
     sticky so its first detail remains authoritative. *)
  let terminal_effect_state =
    Atomic.make (initial_terminal_effect_state gate_replay_delivery)
  in
  let mark_deferred_tool_result () =
    ignore
      (Atomic.compare_and_set
         terminal_effect_state
         Terminal_effect_open
         Deferred_tool_result)
  in
  let mark_external_effect_deferred ~approval_id =
    Option.iter (fun id -> Option.iter (fun record -> record id) on_gate_deferred) approval_id;
    (* A generic deferred transition may precede the Gate result in one AGENT_CORE
       batch. The external effect owns the user-facing terminal projection, so
       it must promote that generic state rather than being hidden by it. *)
    let rec transition () =
      match Atomic.get terminal_effect_state with
      | External_effect_deferred
      | Terminal_effect_completed _
      | Terminal_effect_failed _ ->
        ()
      | (Terminal_effect_open | Deferred_tool_result) as current ->
        if
          not
            (Atomic.compare_and_set
               terminal_effect_state
               current
               External_effect_deferred)
        then transition ()
    in
    transition ()
  in
  let mark_terminal_effect_completed receipt =
    let rec transition () =
      match Atomic.get terminal_effect_state with
      | Terminal_effect_completed _ | Terminal_effect_failed _ -> ()
      | ( Terminal_effect_open
        | Deferred_tool_result
        | External_effect_deferred ) as current ->
        if
          not
            (Atomic.compare_and_set
               terminal_effect_state
               current
               (Terminal_effect_completed receipt))
        then transition ()
    in
    transition ()
  in
  let mark_terminal_effect_failed failure =
    let rec transition () =
      match Atomic.get terminal_effect_state with
      | Terminal_effect_failed _ -> ()
      | ( Terminal_effect_open
        | Deferred_tool_result
        | External_effect_deferred
        | Terminal_effect_completed _ ) as current ->
        if
          not
            (Atomic.compare_and_set
               terminal_effect_state
               current
               (Terminal_effect_failed failure))
        then transition ()
    in
    transition ()
  in
  let mark_completed_terminal_externalization_failed
      error
    =
    terminal_externalization_failure
      (Atomic.get terminal_effect_state)
      error
    |> Option.iter mark_terminal_effect_failed
  in
  (* The handler dispatches with
     [~name:descriptor.internal_name] so all telemetry SSOT remains internal;
     exactly one projected Tool.schema.name is model-visible.
     the descriptor-owned typed translation reshapes the LLM's payload before dispatch;
     [descriptor.input_schema] provides the LLM-facing schema. *)
  let descriptor_tools_with_loading =
    List.concat_map
      (fun (descriptor : Keeper_tool_descriptor.t) ->
         let internal = descriptor.internal_name in
         (* A static declaration holds even when a hook normalizes the input.
            Input-dependent or missing declarations remain effect-possible. *)
         let call_effect _ =
           match Keeper_tool_descriptor.readonly_static_hint descriptor with
           | Some true -> Agent_core.Tool.Read_only
           | Some false | None -> Agent_core.Tool.Effect_possible
         in
         let agent_core_descriptor =
           match descriptor.execution with
           | Keeper_tool_descriptor.Ordinary Keeper_tool_descriptor.Serial ->
             Some
               (Agent_core.Tool.ordinary_descriptor ~call_effect Agent_core.Tool_contract.Serial)
           | Keeper_tool_descriptor.Ordinary Keeper_tool_descriptor.Concurrent ->
             Some
               (Agent_core.Tool.ordinary_descriptor ~call_effect
                  Agent_core.Tool_contract.Concurrent)
           | Keeper_tool_descriptor.Terminal ->
             Some
               (Agent_core.Tool.terminal_descriptor
                  Agent_core.Tool_contract.Effect_outcome_unknown)
         in
         let on_completed, on_failed, on_externalization_error =
           match descriptor.execution with
           | Keeper_tool_descriptor.Terminal ->
             ( Some
                 (function
                   | Some receipt -> mark_terminal_effect_completed receipt
                   | None ->
                     mark_terminal_effect_failed
                       { failure_class = Tool_result.Runtime_failure
                       ; effect_disposition = Tool_result.Effect_outcome_unknown
                       ; detail =
                           Keeper_terminal_effect_detail.Terminal_tool_receipt_missing
                             { internal_tool_name = internal }
                       })
             , Some mark_terminal_effect_failed
             , Some mark_completed_terminal_externalization_failed )
           | Keeper_tool_descriptor.Ordinary
               (Keeper_tool_descriptor.Serial | Keeper_tool_descriptor.Concurrent) ->
             ( None
             , Some
                 (ordinary_on_failed
                    ~mark_terminal_effect_failed
                    descriptor.runtime_handler)
             , None )
         in
         Keeper_tool_descriptor.keeper_model_names descriptor
         |> List.map (fun model_name ->
             let make_h ?prepared_edit
                 ?(call_source_context = source_context)
                 ?(call_gate_context = gate_context_provider)
                 ?(call_record_gate_result = record_gate_result) () =
               match capability_surface with
               | Some capability_surface ->
                 Keeper_tools_agent_core_handler.make_keeper_tool_handler
                   ~capability_surface
                   ~name:internal
                   ~descriptor
                   ~model_name
                   ~input_schema:descriptor.input_schema
                   ~config
                   ~meta
                   ~publication_recovery
                   ~ctx_snapshot
                   ~keeper_turn_id
                   ~artifact_draft_scope
                   ~source_context:call_source_context
                   ?prepared_edit
                   ?turn_sandbox_factory
                   ?clock
                   ?continuation_channel
                   ?gate_context:call_gate_context
                   ?gate_grant
                   ?record_gate_result:call_record_gate_result
                   ?on_completed
                   ~on_deferred:mark_deferred_tool_result
                   ~on_external_effect_deferred:mark_external_effect_deferred
                   ?on_failed
                   ()
               | None ->
                 Keeper_tools_agent_core_handler.make_keeper_tool_handler_from_meta
                   ~name:internal
                   ~input_schema:descriptor.input_schema
                   ~config
                   ~meta
                   ~publication_recovery
                   ~ctx_snapshot
                   ~keeper_turn_id
                   ~artifact_draft_scope
                   ~source_context:call_source_context
                   ?prepared_edit
                   ?turn_sandbox_factory
                   ?clock
                   ?continuation_channel
                   ?gate_context:call_gate_context
                   ?gate_grant
                   ?record_gate_result:call_record_gate_result
                   ?on_completed
                   ~on_deferred:mark_deferred_tool_result
                   ~on_external_effect_deferred:mark_external_effect_deferred
                   ?on_failed
                   ~prepare_input:(fun input ->
                     Keeper_tool_descriptor_resolution.prepare_model_input_for_descriptor
                       ~tool_name:model_name
                       descriptor
                       ~input)
                   ()
             in
             let bridge h =
               Keeper_schema_observation.with_definition descriptor @@ fun () ->
               let schema =
                 match Keeper_descriptor_schema.for_descriptor descriptor with
                 | Ok schema -> schema
                 | Error detail ->
                   invalid_arg (Printf.sprintf "tool %S schema invalid: %s" model_name detail)
               in
               Tool_bridge.agent_core_tool_of_schema_with_execution_env
               ~base_path:config.base_path
               ~answer_reader:(fun output_text ->
                 Keeper_tool_answer.answer ~tool_name:model_name ~output_text)
               ~model_projection:(model_projection_for_call descriptor)
               ?on_externalization_error
               ~schema
               (fun execution_env input ->
                 (* The handler is told the projection its result will cross,
                    asked the same way the bridge asks, so a handler that
                    pages its output fills what this lane carries inline. *)
                 h
                   ?agent_core_invocation:
                     (Agent_core.Tool.Execution_env.invocation execution_env)
                   ?result_projection:(Some (model_projection_for_call descriptor ()))
                   input)
             in
             let ordinary = bridge (make_h ()) in
             let agent_core_descriptor =
               if Option.is_some capability_surface
                  && descriptor.runtime_handler = Keeper_tool_descriptor.Tool_edit_file then
                 let prepare ~sw input =
                   let original_source = source_context () in
                   let source_matches = match original_source with
                     | None -> false
                     | Some source ->
                       source.agent_name = Some meta.name
                       && source.trace_id = Some (Keeper_id.Trace_id.to_string meta.runtime.trace_id)
                       && source.task_id = Option.map Keeper_id.Task_id.to_string meta.current_task_id
                       && Option.is_some source.keeper_turn_id in
                   if not source_matches then Ok None
                   else
                     match Keeper_tool_descriptor_resolution.prepare_model_input_for_descriptor
                         ~tool_name:model_name descriptor ~input with
                     | Error _ -> Ok None
                     | Ok args ->
                       (match Keeper_tool_filesystem_runtime.prepare_edit ~sw ~config ~meta ~args with
                        (* The ordinary Serial path retains real validation/path
                           failure telemetry and load receipt consumption. *)
                        | Error _ | Ok None -> Ok None
                        | Ok (Some prepared_edit) ->
                          let handler execution input =
                            let causal = Option.map Keeper_gate_causal_context.fork gate_context in
                            let call_gate_context = Option.map
                                (fun context () -> Keeper_gate_causal_context.snapshot context) causal in
                            let call_record_gate_result = Option.map (fun context ~operation ~input result ->
                              Keeper_gate_causal_context.record_tool_result context ~operation ~input result;
                              Option.iter (fun record -> record ~operation ~input result) record_gate_result) causal in
                            let h = make_h ~prepared_edit
                                ~call_source_context:(fun () -> original_source)
                                ~call_gate_context ~call_record_gate_result () in
                            let adapted = bridge h in
                            adapted.Agent_core.Tool.handler execution input
                          in
                          match Keeper_tool_filesystem_runtime.prepared_edit_scopes prepared_edit with
                          | scope :: additional_scopes ->
                            Ok (Some (Agent_core.Tool.scoped_call ~scope ~additional_scopes handler))
                          | [] -> invalid_arg "prepared Edit producer returned no file footprint")
                 in
                 Some (Agent_core.Tool.ordinary_descriptor_scoped
                   ~call_effect:(Agent_core.Tool.call_effect ordinary) ~prepare)
               else agent_core_descriptor
             in
             ( Agent_core.Tool.of_schema ?descriptor:agent_core_descriptor
                 ordinary.schema ordinary.handler
             (* A descriptor's [defer_loading] lives in the TOML named for its
                internal name, while the model may know the tool by a public
                name ([BrowserRead] for [masc_browser_read]). Taken here, where
                the descriptor is in hand, rather than looked up again by the
                model name, which answered Always_loaded for every such tool. *)
             , Keeper_tool_descriptor.declared_loading descriptor )))
      descriptors
  in
  let descriptor_tools = List.map fst descriptor_tools_with_loading in
  let composition_tools_with_loading, task_required_tool_names =
    let instruction_skills =
      Keeper_tool_composition_surface.instruction_skills_of_catalog skill_catalog
    in
    let composition_skills =
      Keeper_skill_catalog.skills skill_catalog
      |> List.filter_map (fun (skill : Keeper_skill_catalog.skill) ->
           match skill.reference, skill.surface with
           | Some reference, Keeper_skill_catalog.Composition entry ->
             Some Keeper_tool_composition_surface.{ reference; entry }
           | None, _ | Some _, Keeper_skill_catalog.Instruction ->
             None)
    in
    let task_references = match skill_activation_context, meta.current_task_id with
      | Some context, Some task_id ->
        Keeper_skill_activation_recorder.task_references ~task_id context
      | None, _ | Some _, None -> [] in
    let task_required_tool_names = List.concat_map
        (fun (skill : Keeper_tool_composition_surface.composition_skill) ->
          if List.exists (Skill_reference.equal skill.reference) task_references then
            Keeper_composition_draft.run_tool_name ::
            Keeper_tool_composition_catalog.tool_name skill.entry ::
              List.filter_map (fun (node : Keeper_tool_plan.node) ->
                match Keeper_tool_plan.descriptor skill.entry.plan node.id with
                | Some _ -> Some node.tool_name
                | None -> None) (Keeper_tool_plan.nodes skill.entry.plan)
          else []) composition_skills
        |> List.sort_uniq String.compare in
    let record_instruction_activation =
      Option.map
        (fun context ~invocation ~content reference ->
           Keeper_skill_activation_recorder.record_instruction
             ~config
             context
             ~invocation
             ~content
             reference)
        skill_activation_context
    in
    let record_composition_activation =
      Option.map
        (fun context ~invocation ~tool_name ~reference ->
           Keeper_skill_activation_recorder.record_composition
             ~config
             context
             ~invocation
             ~tool_name
             reference)
        skill_activation_context
    in
    let make_composition_tools =
      let record_nested_composition_activation = Option.map
          (fun context ~invocation ~tool_name ~scope ~reference ->
             Keeper_skill_activation_recorder.record_nested_composition
               ~config context ~invocation ~tool_name ~scope reference)
          skill_activation_context in
      match capability_surface with
      | Some capability_surface ->
        Keeper_tool_composition_surface.make_tools ~capability_surface ?record_nested_composition_activation
          ?nested_activation_context:skill_activation_context
      | None ->
        Keeper_tool_composition_surface.Compatibility.make_tools ~descriptors ?record_nested_composition_activation
          ?nested_activation_context:skill_activation_context
    in
    let tools = make_composition_tools
        ?result_delivery:composition_result_delivery
        ~instruction_skills
        ~skill_compositions:composition_skills
        ?composition_plan_index
        ~config
        ~meta
        ~publication_recovery
        ~ctx_snapshot
        ?record_instruction_activation
        ?record_composition_activation
        ?turn_sandbox_factory
        ?turn_ctx_cell
        ?clock
        ?continuation_channel
        ?gate_context:gate_context_provider
        ?gate_causal_context:gate_context
        ?gate_grant
        ?record_gate_result
        ~on_completed:(fun ~composition_tool -> function
          | Some receipt -> mark_terminal_effect_completed receipt
          | None ->
            mark_terminal_effect_failed
              { failure_class = Tool_result.Runtime_failure
              ; effect_disposition = Tool_result.Effect_outcome_unknown
              ; detail =
                  Keeper_terminal_effect_detail.Terminal_composition_receipt_missing
                    { composition_tool }
              })
        ~on_deferred:mark_deferred_tool_result
        ~on_external_effect_deferred:mark_external_effect_deferred
        ~on_failed:mark_terminal_effect_failed
        ~on_externalization_error:mark_completed_terminal_externalization_failed
        ()
    in
    tools, task_required_tool_names
  in
  let composition_tools =
    List.map (fun (tool, _, _) -> tool) composition_tools_with_loading
  in
  (* Identity tools are external effects by definition; they join the turn
     only behind the durable Gate, irrespective of provider annotations. The
     cycle's one-shot grant threads through so an approved exact call can be
     spent in the woken cycle.

     They reach the model through the listing rather than directly: an
     attached service offers more tools than a request can carry, and the
     Gate wrapper is the same either way. *)
  let gate_wrapped offered =
    Keeper_identity_gate.agent_tool
      ?clock
      ~config
      ~meta
      ?continuation_channel
      ?gate_context:gate_context_provider
      ?gate_grant
      offered
  in
  (* Attached tools, as schemas. What the lanes that cannot widen a running
     turn are given: they pin their tool set at process spawn or thread start,
     and that set is part of a resumable session's identity, so a listing
     would name tools they can never make callable. *)
  let identity_agent_tools =
    List.map
      gate_wrapped
      (match identity_surface with
       | None -> []
       | Some surface -> surface.Keeper_tools_agent_core.offered)
  in
  (* What the model is shown by name instead of by schema.

     Two sources, one answer. An attached tool is held back by default: a
     Keeper is handed its services' entire lists, 145 tools and 142,257 bytes
     on the Keeper the RFC measured. A built-in is held back when it declares
     [defer_loading = true]: a descriptor or the Skill reader in its own
     [config/tools/<name>.toml], a Skill composition in its composition
     block -- of 89 built-ins on one Keeper, 33 went a whole day uncalled,
     21,601 bytes charged to every request of every turn.

     The listing does not record which source a tool came from, and the model
     is not told. Holding a tool back is a property of the tool. *)
  let deferrable = function
    | Tool_definition_toml.Deferrable -> true
    | Tool_definition_toml.Always_loaded -> false
  in
  let deferred_builtin_tools, always_loaded_builtin_tools =
    (* Both families, each paired with its declaration where it was built:
       a descriptor's from [config/tools/<internal name>.toml], a Skill
       composition's from its composition block, and the Skill reader and
       request controls beside the compositions from their own tool files.
       Splitting only the descriptors would leave a [defer_loading = true]
       that nothing honours and nothing reports -- a declaration is either
       read wherever it can be written or it is a trap. Exact current-Task
       composition selection already names the schemas needed for the work:
       its callable and ordinary leaves are provided now, without a model
       loader roundtrip. This changes delivery, not the stored declaration,
       source authority, or activation. Unrelated tools remain deferrable. *)
    let split tools_with_loading =
      let deferred, loaded =
        List.partition (fun ((tool : Agent_core.Tool.t), loading) ->
          deferrable loading
          && not (List.exists (String.equal tool.schema.name) task_required_tool_names)) tools_with_loading
      in
      List.map fst deferred, List.map fst loaded
    in
    let deferred_descriptors, loaded_descriptors = split descriptor_tools_with_loading in
    let deferred_compositions, loaded_compositions =
      split
        (List.map
           (fun (tool, loading, _) -> tool, loading)
           composition_tools_with_loading)
    in
    deferred_descriptors @ deferred_compositions, loaded_descriptors @ loaded_compositions
  in
  let deferred_of source tool =
    ( { Keeper_identity_tool_search.tool
      ; summary =
          Keeper_identity_tool_search.summary_of
            tool.Agent_core.Tool.schema.description
      }
    , { Keeper_tool_load_receipts.source; schema = tool.Agent_core.Tool.schema } )
  in
  let identity_listing =
    match identity_surface with
    | None -> None
    | Some surface ->
      let deferred, receipt_surface =
        List.split
          (List.map
             (fun (offered : Keeper_identity_tools.offered_tool) ->
               deferred_of
                 (Keeper_tool_load_receipts.Attached
                    { provider_id = offered.provider.id
                    ; endpoint = offered.provider.mcp_url
                    ; remote_name = offered.remote_name
                    })
                 (gate_wrapped offered))
             surface.Keeper_tools_agent_core.offered
           @ List.map (deferred_of Keeper_tool_load_receipts.Builtin) deferred_builtin_tools)
      in
      let receipts =
        Keeper_tool_load_receipts.create
          ~restored:surface.load_receipts
          ~trace_id:meta.runtime.trace_id
          ~task_id:meta.current_task_id
          ~keeper_turn:surface.keeper_turn_id
          ~current_task_id:(fun () ->
            match
              Keeper_owner_registry.get
                ~base_path:config.base_path ~keeper_name:meta.name
            with
            | Error error ->
              Error (Keeper_owner_registry.lookup_error_to_string error)
            | Ok owner ->
              (match (Keeper_owner.projection owner).meta with
               | None -> Error "Keeper metadata is absent"
               | Some current -> Ok current.current_task_id))
          ~surface:receipt_surface
      in
      Keeper_identity_tool_search.make
        ~keeper_name:meta.Keeper_meta_contract.name
        { Keeper_identity_tool_search.deferred
        ; agent_cell = surface.Keeper_tools_agent_core.agent_cell
        ; history = surface.Keeper_tools_agent_core.history
        ; carry_window = Keeper_config.keeper_tool_carry_window ()
        ; receipts
        }
  in
  (* The lanes that cannot widen a turn get every tool as a schema: holding
     one back there would name a tool nothing can load. *)
  let always_loaded = always_loaded_builtin_tools in
  let tools = descriptor_tools @ composition_tools @ identity_agent_tools in
  let offered_names =
    List.map (fun (tool : Agent_core.Tool.t) -> tool.schema.name) tools
    @ (match identity_listing with
       | None -> []
       | Some listing -> [listing.Keeper_identity_tool_search.tool.schema.name]) in
  (* Runtime admission reserves static host tools. Skill compositions and
     attached-service tools are known only here, so finish collision admission
     before publishing either lane's bundle. A policy and a callable must never
     resolve the same name to different owners. *)
  List.iter (fun (descriptor : Keeper_tool_descriptor.t) ->
    match descriptor.runtime_handler with
    | Tool_lane_addon _ ->
        let name = descriptor.public_name in
        if List.length (List.filter (String.equal name) offered_names) <> 1 then
          invalid_arg ("Lane Add-on tool collides with the assembled Keeper surface: " ^ name)
    | Keeper_tool_descriptor.Tool_execute | Keeper_tool_descriptor.Tool_search_files
    | Keeper_tool_descriptor.Tool_read_file | Keeper_tool_descriptor.Tool_edit_file
    | Keeper_tool_descriptor.Tool_write_file | Keeper_tool_descriptor.Tool_lane_status
    | Keeper_tool_descriptor.Tool_tools_list | Keeper_tool_descriptor.Tool_capability_search
    | Keeper_tool_descriptor.Tool_context_status | Keeper_tool_descriptor.Tool_peer_artifact
    | Keeper_tool_descriptor.Tool_artifact_read | Keeper_tool_descriptor.Tool_skill_validate
    | Keeper_tool_descriptor.Tool_artifact_draft | Keeper_tool_descriptor.Tool_artifact_publish | Keeper_tool_descriptor.Tool_skill_publish | Keeper_tool_descriptor.Tool_workspace_memory_read
    | Keeper_tool_descriptor.Tool_memory_search | Keeper_tool_descriptor.Tool_memory_select
    | Keeper_tool_descriptor.Tool_memory_retract | Keeper_tool_descriptor.Tool_memory_write
    | Keeper_tool_descriptor.Tool_constitution_write | Keeper_tool_descriptor.Tool_constitution_read
    | Keeper_tool_descriptor.Tool_constitution_remove | Keeper_tool_descriptor.Tool_wiki_search
    | Keeper_tool_descriptor.Tool_wiki_read | Keeper_tool_descriptor.Tool_surface_read
    | Keeper_tool_descriptor.Tool_surface_post | Keeper_tool_descriptor.Tool_person_note_set
    | Keeper_tool_descriptor.Tool_ide_annotate | Keeper_tool_descriptor.Tool_voice_dispatch
    | Keeper_tool_descriptor.Tool_task_dispatch | Keeper_tool_descriptor.Tool_board_dispatch
    | Keeper_tool_descriptor.Tool_masc_task_dispatch
    | Keeper_tool_descriptor.Tool_masc_plan_dispatch | Keeper_tool_descriptor.Tool_masc_run_dispatch
    | Keeper_tool_descriptor.Tool_masc_agent_dispatch
    | Keeper_tool_descriptor.Tool_masc_workspace_dispatch
    | Keeper_tool_descriptor.Tool_masc_misc_dispatch | Keeper_tool_descriptor.Tool_web_search
    | Keeper_tool_descriptor.Tool_web_fetch | Keeper_tool_descriptor.Tool_browser_tabs
    | Keeper_tool_descriptor.Tool_browser_read | Keeper_tool_descriptor.Tool_browser_session
    | Keeper_tool_descriptor.Tool_browser_goto | Keeper_tool_descriptor.Tool_browser_act
    | Keeper_tool_descriptor.Tool_browser_instruct | Keeper_tool_descriptor.Tool_browser_interact
    | Keeper_tool_descriptor.Tool_masc_control_dispatch
    | Keeper_tool_descriptor.Tool_masc_agent_timeline_dispatch
    | Keeper_tool_descriptor.Tool_masc_schedule_dispatch
    | Keeper_tool_descriptor.Tool_keeper_spawn_dispatch
    | Keeper_tool_descriptor.Tool_keeper_composition_result_dispatch
    | Keeper_tool_descriptor.Tool_keeper_code_query_dispatch
    | Keeper_tool_descriptor.Tool_keeper_webmcp_dispatch
    | Keeper_tool_descriptor.Tool_keeper_job_dispatch
    | Keeper_tool_descriptor.Tool_masc_keeper_dispatch
    | Keeper_tool_descriptor.Tool_masc_fusion_dispatch
    | Keeper_tool_descriptor.Tool_masc_fusion_status
    | Keeper_tool_descriptor.Tool_masc_fusion_decision
    | Keeper_tool_descriptor.Tool_masc_file_dispatch
    | Keeper_tool_descriptor.Tool_masc_wiki_dispatch
    | Keeper_tool_descriptor.Tool_masc_local_runtime_dispatch
    | Keeper_tool_descriptor.Tool_analyze_image | Keeper_tool_descriptor.Tool_read_image -> ()) descriptors;
  { tools
  ; agent_core_tools =
      always_loaded
      @ (match identity_listing with
         | None ->
           (* Without a live agent cell there is no callable loader. Keep
              these schemas available instead of advertising a search whose
              extension can never be installed. *)
           deferred_builtin_tools
         | Some listing ->
           (* Pending successful loads and recently used tools belong on the
              first request of the next turn, before the agent exists. *)
           listing.Keeper_identity_tool_search.tool
           :: listing.Keeper_identity_tool_search.already_used)
  ; on_demand_tool_names =
      (* What an official client holds back: the same built-ins the Agent
         Core lane puts behind its listing, and every attached-service tool. *)
      List.map
        (fun (tool : Agent_core.Tool.t) -> tool.Agent_core.Tool.schema.name)
        (deferred_builtin_tools @ identity_agent_tools)
  ; result_bounds =
      (* The bound each built-in result is held to on an official-client lane,
         read off the projection the bridge applies there: the descriptor's
         own (see [model_projection_for_call]). Every model name a descriptor
         answers to crosses the same projection. Composition tools carry the
         projection chosen by their surface. Attached-service results have no
         MASC bound and declare nothing. *)
      List.concat_map
        (fun (descriptor : Keeper_tool_descriptor.t) ->
           let bound =
             match descriptor.model_output_projection with
             | Tool_output.Store_above _ ->
               Runtime_execution.claude_code_inline_result_bytes
             | Tool_output.Inline_up_to _ as projection ->
               Tool_output.inline_ceiling_bytes projection
           in
           List.map
             (fun model_name -> model_name, bound)
             (Keeper_tool_descriptor.keeper_model_names descriptor))
        descriptors
      @ List.map
          (fun (tool, _, projection) ->
             ( tool.Agent_core.Tool.schema.name
             , Tool_output.inline_ceiling_bytes projection ))
          composition_tools_with_loading
  ; listing =
      (match identity_listing with
       | None -> Keeper_tools_agent_core.No_listing
       | Some listing ->
         (* What is missing from the surface, not what declared itself. A tool
            this conversation has run is placed with its schema again, so a
            declared tool can be present after all -- and reporting the
            declaration would have the projection check expect it gone. *)
         let carried =
           List.map
             (fun (tool : Agent_core.Tool.t) -> tool.Agent_core.Tool.schema.name)
             listing.Keeper_identity_tool_search.already_used
         in
         Keeper_tools_agent_core.Listing
           { deferred_builtin_names =
               List.filter_map
                 (fun (tool : Agent_core.Tool.t) ->
                    let name = tool.Agent_core.Tool.schema.name in
                    if List.exists (String.equal name) carried then None else Some name)
                 deferred_builtin_tools
           })
  ; cleanup =
      (fun () ->
        Keeper_artifact_draft_scope.close artifact_draft_scope;
        (* Turn end on both the ordinary and the raised path -- this thunk is
           what [run_with_setup_cleanup] guarantees -- which is the only point
           where "the listing found nothing usable" is still answerable.
           Before the sandbox release rather than after: this reads two lists
           and writes a log line, and releasing a runtime can raise, which
           would take the reading with it. *)
        Option.iter
          (fun (listing : Keeper_identity_tool_search.placement) ->
             let (_ : Keeper_identity_tool_search.turn_discovery) =
               listing.Keeper_identity_tool_search.observe_turn ()
             in
             ())
          identity_listing;
        Option.iter Keeper_sandbox_factory.cleanup turn_sandbox_factory)
  ; terminal_effect_state = (fun () -> Atomic.get terminal_effect_state)
  ; gate_replay_delivery
  ; turn_sandbox_factory
  }
;;

let make_tool_bundle_for_capability_surface
      ~config
      ~meta
      ~publication_recovery
      ~ctx_snapshot
      ?clock
      ?continuation_channel
      ?gate_context
      ?hitl_resolution
      ?on_gate_deferred
      ?identity_surface
      ?composition_plan_index
      ?skill_activation_context
      ?composition_result_delivery
      ?turn_ctx_cell
      ?checkpoint_owner
      ?tool_result_inline_ceiling_bytes
      ~capability_surface
      ()
  =
  make_tool_bundle_for_descriptors_with_policy
    ~config
    ~meta
    ~publication_recovery
    ~ctx_snapshot
    ?clock
    ?continuation_channel
    ?gate_context
    ?hitl_resolution
      ?on_gate_deferred
    ~skill_catalog:(Keeper_capability_surface.skill_catalog capability_surface)
    ?identity_surface
    ?composition_plan_index
    ?skill_activation_context
    ?composition_result_delivery
    ~allow_unrecorded_skill_surface:false
    ?turn_ctx_cell
    ?checkpoint_owner
    ?tool_result_inline_ceiling_bytes
    ~descriptors:(Keeper_capability_surface.descriptors capability_surface)
    ~capability_surface
    ()
;;

module For_testing = struct
  let make_tool_bundle
        ~config
        ~meta
        ~publication_recovery
        ~ctx_snapshot
        ?clock
        ?continuation_channel
        ?gate_context
        ?hitl_resolution
      ?on_gate_deferred
        ?capability_surface
        ?skill_catalog
        ?turn_ctx_cell
        ()
    =
    let descriptors = match capability_surface with
      | Some surface -> Keeper_capability_surface.descriptors surface
      | None -> Keeper_tool_descriptor.model_visible_descriptors () in
    make_tool_bundle_for_descriptors_with_policy
      ?capability_surface ~descriptors
      ~config
      ~meta
      ~publication_recovery
      ~ctx_snapshot
      ?clock
      ?continuation_channel
      ?gate_context
      ?hitl_resolution
      ?on_gate_deferred
      ?skill_catalog
      ~allow_unrecorded_skill_surface:true
      ?turn_ctx_cell
      ()
  ;;

  let make_tools
        ~config
        ~meta
        ~publication_recovery
        ~ctx_snapshot
        ?clock
        ?skill_catalog
        ?turn_ctx_cell
        ()
    =
    (make_tool_bundle
       ~config
       ~meta
       ~publication_recovery
       ~ctx_snapshot
       ?clock
       ?skill_catalog
       ?turn_ctx_cell
       ())
      .tools
  ;;

  let make_tools_for_descriptors
        ~config
        ~meta
        ~publication_recovery
        ~ctx_snapshot
        ~descriptors
        ?skill_catalog
        ()
    =
    (make_tool_bundle_for_descriptors_with_policy
       ~config
       ~meta
       ~publication_recovery
       ~ctx_snapshot
       ~descriptors
       ?skill_catalog
       ~allow_unrecorded_skill_surface:true
       ())
      .tools
  ;;

  let initial_terminal_effect_state = initial_terminal_effect_state
  let ordinary_on_failed = ordinary_on_failed

  let terminal_externalization_failure =
    terminal_externalization_failure
  ;;
end
