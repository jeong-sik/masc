open Result.Syntax

module Catalog = Keeper_tool_composition_catalog
module Executor = Keeper_tool_plan_executor
module Journal = Keeper_tool_execution_journal
module Activation_ledger = Keeper_skill_activation_ledger
open Keeper_tool_composition_projection
open Keeper_tool_composition_surface_schema
open Keeper_tool_composition_surface_observation
open Keeper_tool_composition_surface_execution
open Keeper_tool_composition_surface_request_control
open Keeper_tool_composition_surface_instruction_skill
open Keeper_tool_composition_surface_outcome
open Keeper_tool_composition_surface_async

let make_tools_with_authority
      ?(instruction_skills : instruction_skill list = [])
      ?(skill_compositions : composition_skill list = [])
      ?composition_plan_index
      ?record_instruction_activation
      ?record_composition_activation
      ?record_nested_composition_activation
      ?nested_activation_context
      ?result_delivery
      ?on_inline_receipt_committed
      ~(config : Workspace.config)
      ~meta
      ~capability_authority
      ~publication_recovery
      ~ctx_snapshot
      ?turn_sandbox_factory
      ?turn_ctx_cell
      ?clock
      ?continuation_channel
      ?gate_context
      ?gate_causal_context
      ?gate_grant
      ?record_gate_result
      ?on_completed
      ?on_deferred
      ?on_external_effect_deferred
      ?on_failed
      ?on_externalization_error
      ~descriptors
      ()
  =
  (* Skill-declared entries went through the same [Catalog.parse] as the
     TOML catalog, so materialization cannot tell them apart — one closure
     serves both. Name collisions across the two sources are refused where
     both catalogs are loaded, before this point. *)
  let composition_tools =
    skill_compositions
    |> List.map (fun (skill : composition_skill) ->
    let entry = skill.entry in
    let tool_name = Catalog.tool_name entry in
    (* The approval policy cannot look this tool up: it is an Agent-Core tool,
       not a keeper descriptor, so a descriptor lookup finds nothing and the
       policy asks. Declaring the plan's node tools here lets it judge the
       composition by what the composition runs. Written once per turn, at the
       one point that already holds the plan. *)
    Option.iter
      (fun index ->
        Keeper_tool_composition_plan_index.record
          index
          ~composition:tool_name
          ~node_tools:
            (List.map
               (fun (node : Keeper_tool_plan.node) ->
                  node.Keeper_tool_plan.tool_name)
               (Keeper_tool_plan.nodes entry.plan)))
      composition_plan_index;
    let completion = Executor.outer_completion entry.plan in
    (* A template is not the input a node will execute. Only static read-only
       contracts for every node prove the whole inline composition read-only.
       Async admission writes a durable request even when its nodes only read. *)
    let read_only =
      List.for_all (fun (node : Keeper_tool_plan.node) ->
        match Keeper_tool_plan.descriptor entry.plan node.id with
        | None -> false
        | Some descriptor ->
          Keeper_tool_descriptor.readonly_static_hint descriptor = Some true)
        (Keeper_tool_plan.nodes entry.plan)
    in
    (* A read-only leaf can still own a serial resource, such as a browser
       session. Only leaves whose own contract permits concurrent execution
       can prove that separate invocations of this whole plan may overlap. *)
    let causal_context_isolatable = match gate_causal_context, gate_context with
      | Some _, _ | None, None -> true
      | None, Some _ -> false
    in
    let concurrent = read_only && causal_context_isolatable
      && List.for_all (fun (node : Keeper_tool_plan.node) ->
        match Keeper_tool_plan.descriptor entry.plan node.id with
        | Some { Keeper_tool_descriptor.execution =
                   Keeper_tool_descriptor.Ordinary Keeper_tool_descriptor.Concurrent; _ } -> true
        | Some { Keeper_tool_descriptor.execution =
                   ( Keeper_tool_descriptor.Ordinary Keeper_tool_descriptor.Serial
                   | Keeper_tool_descriptor.Terminal ); _ }
        | None -> false) (Keeper_tool_plan.nodes entry.plan)
    in
    let call_effect _ =
      match entry.execution with
      | Catalog.Async -> Agent_core.Tool.Effect_possible
      | Catalog.Inline ->
        if read_only
        then Agent_core.Tool.Read_only
        else Agent_core.Tool.Effect_possible
    in
    let descriptor =
      match entry.execution, completion with
      | Catalog.Async, Agent_core.Tool_contract.Continue_after_success ->
        Agent_core.Tool.ordinary_descriptor ~call_effect Agent_core.Tool_contract.Serial
      | Catalog.Inline, Agent_core.Tool_contract.Continue_after_success ->
        Agent_core.Tool.ordinary_descriptor ~call_effect
          (if concurrent then Agent_core.Tool_contract.Concurrent else Agent_core.Tool_contract.Serial)
      | Catalog.Inline, Agent_core.Tool_contract.Terminal_after_success disposition ->
        Agent_core.Tool.terminal_descriptor disposition
      | Catalog.Async, Agent_core.Tool_contract.Terminal_after_success _ ->
        invalid_arg "validated async composition retained a terminal completion"
    in
    let tool_externalization_error =
      match entry.execution with
      | Catalog.Async -> None
      | Catalog.Inline -> on_externalization_error
    in
    (* Paired here, where the entry is in hand: a composition declares
       [defer_loading] in its Skill block, and nothing downstream should have
       to find that block again by the generated tool name. *)
    let model_projection = Tool_output.default_model_projection in
    let make_tool ?prepared_files () = Tool_bridge.agent_core_tool_of_masc_with_execution_env
      ~descriptor
      ~base_path:config.base_path
      ~model_projection:(fun () -> model_projection)
      ?on_externalization_error:tool_externalization_error
      ~name:tool_name
      ~description:(entry_description entry)
      ~input_schema:(Catalog.input_schema_of_params entry.params)
      (fun execution_env input ->
        let dispatch_result =
          let start_time = Tool_timing.start () in
        match
          Tool_input_validation.validate_args
            ~schema:(Catalog.input_schema_of_params entry.params)
            ~name:tool_name
            ~args:input
            ()
        with
        | Error rejection -> rejection
        | Ok _ ->
          (match Agent_core.Tool.Execution_env.invocation execution_env with
           | None ->
             Tool_result.runtime_err
               ~tool_name
               ~start_time
               "composition execution requires Agent-Core invocation identity"
           | Some parent_invocation ->
             let gate_context, record_gate_result =
               if (concurrent || Option.is_some prepared_files) && entry.execution = Catalog.Inline
               then isolate_gate_context ~gate_causal_context ~gate_context ~record_gate_result
               else gate_context, record_gate_result
             in
             let turn_context =
               match prepared_files with
               | Some prepared -> Some (Keeper_prepared_inline_files.source prepared)
               | None -> Option.map
                 (fun cell ->
                    Keeper_tool_call_log_context.get_turn_context_record
                      ~cell
                      ())
                 turn_ctx_cell
             in
             (match entry.execution with
              | Catalog.Async ->
                (match
                   Catalog.instantiate
                     ~descriptors
                     ~args:input
                     entry
                 with
                 | Error error ->
                   let message = Catalog.instantiation_error_to_string error in
                   let class_ =
                     match error with
                     | Catalog.Missing_argument _
                     | Catalog.Instantiated_plan_rejected _ ->
                       Tool_result.Policy_rejection
                   in
                   let data =
                     `Assoc
                       [ "composition_tool", `String tool_name
                       ; tool_kind_field (Catalog.tool_kind entry)
                       ; "error", Catalog.instantiation_error_to_json error
                       ]
                   in
                   Tool_result.make_err
                     ~tool_name
                     ~class_
                     ~start_time
                     ~data
                     ~metadata:data
                     message
                 | Ok plan ->
                   named_async_submission_result
                     ~admission:(Fresh_named nested_activation_context)
                     ~skill_reference:skill.reference ~plan ~tool_name
                     ~tool_kind:(Catalog.tool_kind entry) ~parent_invocation
                     ~config ~meta ~capability_authority ~publication_recovery
                     ~ctx_snapshot ~turn_context ?clock ())
              | Catalog.Inline ->
                (match
                   (match prepared_files with
                    | Some prepared -> Ok (Keeper_prepared_inline_files.plan prepared)
                    | None -> Catalog.instantiate ~descriptors ~args:input entry)
                 with
                 | Error error ->
                   (* Unreachable through the validated schema — required
                      params are enforced there — but total: a rejected
                      binding names the argument instead of executing a
                      half-bound plan. *)
                   let message = Catalog.instantiation_error_to_string error in
                   let class_ =
                     match error with
                     | Catalog.Missing_argument _
                     | Catalog.Instantiated_plan_rejected _ ->
                       Tool_result.Policy_rejection
                   in
                   let data =
                     `Assoc
                       [ "composition_tool", `String tool_name
                       ; tool_kind_field (Catalog.tool_kind entry)
                       ; "error", Catalog.instantiation_error_to_json error
                       ]
                   in
                   Tool_result.make_err
                     ~tool_name
                     ~class_
                     ~start_time
                     ~data
                     ~metadata:data
                     message
                 | Ok plan ->
             let activation =
               match record_composition_activation with
               | None -> Ok ()
               | Some record ->
                 (match
                    record
                      ~invocation:parent_invocation
                      ~tool_name
                      ~reference:skill.reference
                  with
                  | Error error -> Error error
                  | Ok
                      ( Activation_ledger.Recorded _
                      | Activation_ledger.Already_recorded _ ) ->
                    Ok ())
             in
             (match activation with
              | Error error -> activation_failure ~tool_name ~start_time error
              | Ok () ->
             let run_id = Keeper_tool_plan.Run_id.fresh () in
             let composition_run_id = Keeper_tool_plan.Composition_run_id.fresh () in
             let committed_receipts = ref [] in
             let execution =
               with_ready_inline_files ~config ~meta ~source:turn_context ~plan
                 ~prepared_files ~gate_causal_context ~gate_context ~record_gate_result
                 (fun ready_files gate_context record_gate_result ->
               execute_keeper_plan
                 ~capability_authority
                 ~plan
                 ~run_id
                 ~composition_run_id
                 ~parent_invocation
                 ~config
                 ~meta
                 ~publication_recovery
                 ~ctx_snapshot
                 ~keeper_turn_id:(keeper_turn_id_of turn_context)
                 ?source_context:turn_context
                 ?prepared_files
                 ?ready_files
                 ?turn_sandbox_factory
                 ?clock
                 ?continuation_channel
                 ?gate_context
                 ?gate_grant
                 ?record_gate_result
                 ?on_completed:
                   (Option.map
                      (fun completed -> completed ~composition_tool:tool_name)
                      on_completed)
                 ?on_deferred
                 ?on_external_effect_deferred
                 ?on_failed
                 ?observe_node_result:
                   (Option.map
                      (fun turn_context ->
                         observe_node_result
                           ~on_receipt_committed:(fun execution_id ->
                             committed_receipts := execution_id :: !committed_receipts;
                             Option.iter (fun record ->
                               record ~keeper_name:meta.name ~turn_context execution_id)
                               on_inline_receipt_committed)
                           ~composition_tool:tool_name
                           ~composition_execution:entry.execution
                           ~composition_tool_kind:(Catalog.tool_kind entry)
                           ~composition_run_id
                           ~parent_invocation
                           ~meta
                           ~turn_context)
                      turn_context)
                 ())
             in
             (match execution with
              | Error
                  ({ Executor.effect_disposition =
                       ( Tool_result.Proven_post_effect
                       | Tool_result.Effect_outcome_unknown )
                   ; _
                   } as failure) ->
                (* The aggregate is computed from every settled sibling and all
                   earlier batches, so a selected Deferred cause cannot hide an
                   earlier committed write or a sibling's unknown/post-effect
                   failure.  It fences the turn unless every failed node's own
                   boundary sends the failure back to the model
                   ([failure_returns_to_model]).  Composition execution has no
                   persisted cursor, so only an entirely proven-pre-effect
                   defer may remain resumable. *)
                if not (failure_returns_to_model ~plan ~committed:!committed_receipts failure) then
                (match composition_cause failure with
                 | Pre_effect_only { expected; actual } ->
                   (* This branch is post-effect or unknown, and a completion
                      mismatch is settled [Proven_pre_effect] before any node
                      runs, so the two cannot meet. If they ever do, an effect
                      may have happened and there is no cause to terminalize
                      it with; stop loudly rather than let the turn continue
                      past an unfenced effect. *)
                   invalid_arg
                     (Printf.sprintf
                        "composition %s settled a completion mismatch (plan %s, call \
                         %s) with effect_disposition=%s"
                        tool_name
                        (Yojson.Safe.to_string
                           (Agent_core.Tool_contract.completion_to_yojson expected))
                        (Yojson.Safe.to_string
                           (Agent_core.Tool_contract.completion_to_yojson actual))
                        (Tool_result.failure_effect_disposition_to_string
                           failure.effect_disposition))
                 | Terminal_cause cause ->
                   Option.iter
                     (fun mark_failed ->
                        mark_failed
                          { Keeper_tools_agent_core.failure_class =
                              failure_class failure
                          ; effect_disposition = failure.effect_disposition
                          ; detail =
                              Keeper_terminal_effect_detail.Composition_failed
                                { composition_tool = tool_name
                                ; cause
                                ; payload =
                                    failure_data
                                      ~tool_name
                                      ~tool_kind:(Catalog.tool_kind entry)
                                      failure
                                }
                          })
                     on_failed)
              | Ok _
              | Error
                  { Executor.effect_disposition = Tool_result.Proven_pre_effect
                  ; _
                  } ->
                ());
             let executor_result =
               result_of_execution
                 ~tool_name
                 ~tool_kind:(Catalog.tool_kind entry)
                 ~start_time
                 execution
             in
             let result =
               match
                 project_execution_result
                   ~base_path:config.base_path ~plan ~execution executor_result
               with
               | Ok result -> result
               | Error { message; _ } ->
                 Option.iter
                   (fun mark_failed ->
                      mark_failed
                        { Keeper_tools_agent_core.failure_class =
                            Tool_result.Runtime_failure
                        ; effect_disposition = Tool_result.Effect_outcome_unknown
                        ; detail =
                            Keeper_terminal_effect_detail.Composition_result_manifest_unpersisted
                              { composition_tool = tool_name; detail = message }
                        })
                   on_failed;
                 Tool_result.make_err
                   ~tool_name
                   ~class_:Tool_result.Runtime_failure
                   ~start_time
                   message
             in
             record_skill_composition_evidence
               ~on_publication_failure:(fun detail ->
                 match execution with
                 | Error failure when failure_returns_to_model ~plan ~committed:!committed_receipts failure ->
                   (* Unpublished evidence fences the turn because the record of
                      what already took effect is what lets the turn go on. A
                      refusal that took no effect has nothing to record, and the
                      native loop ends the turn on any terminal-effect failure
                      (Keeper_tool_terminal_boundary), so fencing here would end
                      a turn over a file that describes nothing. *)
                   (match failure.effect_disposition with
                    | Tool_result.Proven_pre_effect -> ()
                    | Tool_result.Proven_post_effect | Tool_result.Effect_outcome_unknown ->
                      Option.iter (fun mark_failed -> mark_failed
                        { Keeper_tools_agent_core.failure_class = Tool_result.Runtime_failure;
                          effect_disposition = failure.effect_disposition;
                          detail =
                            Keeper_terminal_effect_detail.Composition_evidence_unpublished
                              { composition_tool = tool_name; detail } }) on_failed)
                 | Ok _ | Error _ -> ())
               ~config
               ~reference:skill.reference
               ~composition_run_id
               ~request_id:None
               ~parent_invocation
               ~meta
               ~composition_tool:tool_name
               ~composition_execution:Catalog.Inline
               ~execution
               ~result;
             observe_composition_run_summary
               ~composition_tool:tool_name
               ~skill_reference:skill.reference
               ~composition_execution:Catalog.Inline
               ~composition_tool_kind:(Catalog.tool_kind entry)
               ~composition_run_id
               ~parent_invocation
               ~meta
               ~turn_context
               ~input
               ~output_text:(Tool_result.message result)
               ~success:(Tool_result.is_success result)
               ~duration_ms:(Tool_result.duration_ms result)
               ~typed_result:result
               ();
             result))))
        in
        (* task-3268: compositions bypass the exec handler, so emit the shared
           dispatch observers here with the honest typed result — Deferred
           included — or tool_metric_events keeps zero keeper_compose_* rows
           (#38824). *)
        Tool_dispatch.run_dispatch_observers Dispatch_outcome.Handled (Some dispatch_result);
        dispatch_result)
    in
    let* ordinary = make_tool () in
    let resource_candidate =
      match capability_authority, entry.execution, completion with
      | Keeper_tool_runtime.Frozen_surface _, Catalog.Inline,
        Agent_core.Tool_contract.Continue_after_success ->
        causal_context_isolatable && Keeper_prepared_inline_files.eligible entry.plan
      | Keeper_tool_runtime.Compatibility_meta, _, _
      | _, Catalog.Async, _
      | _, _, Agent_core.Tool_contract.Terminal_after_success _ -> false
    in
    let tool = if not resource_candidate then ordinary else
      let prepare ~sw input =
        let source = Option.map (fun cell ->
          Keeper_tool_call_log_context.get_turn_context_record ~cell ()) turn_ctx_cell in
        match Catalog.instantiate ~descriptors ~args:input entry with
        | Error _ -> Ok None
        | Ok plan ->
          match Keeper_prepared_inline_files.prepare ~sw ~config ~meta ~source plan with
          | None -> Ok None
          | Some prepared_files ->
            match Keeper_prepared_inline_files.scopes prepared_files with
            | [] -> invalid_arg "prepared Inline file plan has no file footprint"
            | scope :: additional_scopes ->
              (match make_tool ~prepared_files () with
               | Ok prepared ->
                 Ok (Some (Agent_core.Tool.scoped_call ~scope ~additional_scopes prepared.handler))
               | Error error ->
                 Error { Agent_core.Types.message = Tool_bridge.schema_error_to_string error
                       ; recoverable = false
                       ; error_class = Some Agent_core.Types.Deterministic })
      in
      Agent_core.Tool.of_schema
        ~descriptor:(Agent_core.Tool.ordinary_descriptor_scoped
          ~call_effect:(Agent_core.Tool.call_effect ordinary) ~prepare)
        ordinary.schema ordinary.handler
    in
    Ok ( tool
       , entry.Catalog.loading
       , model_projection ))
  in
  let draft_tools =
    match capability_authority with
    | Keeper_tool_runtime.Compatibility_meta -> []
    | Keeper_tool_runtime.Frozen_surface capability_surface ->
      let module Draft = Keeper_composition_draft in
      let rejection ~tool_name ~start_time error =
        let class_ = Draft.failure_class error in
        let data = Draft.error_to_json error in
        Tool_result.make_err ~tool_name ~class_ ~effect_disposition:Tool_result.Proven_pre_effect
          ~start_time ~data (Yojson.Safe.to_string data)
      in
      let journal_rejection ~start_time error =
        Tool_result.make_err ~tool_name:Draft.run_tool_name
          ~class_:(Journal.failure_class error)
          ~effect_disposition:Tool_result.Effect_outcome_unknown
          ~start_time ~data:(Journal.error_to_json error)
          (Journal.error_to_string error)
      in
      let make (schema : Masc_domain.tool_schema) ~artifact_projection ~call_effect handle =
        let model_projection = Tool_output.default_model_projection in
        let+ tool = Tool_bridge.agent_core_tool_of_masc_with_execution_env
           ~descriptor:(Agent_core.Tool.ordinary_descriptor ~call_effect Agent_core.Tool_contract.Serial)
           ~base_path:config.base_path ~model_projection:(fun () -> model_projection)
           ?on_externalization_error ~name:schema.name ~description:schema.description
           ~input_schema:schema.input_schema
           (fun execution_env input ->
              let dispatch_result =
                let start_time = Tool_timing.start () in
              match Tool_input_validation.validate_args ~schema:schema.input_schema
                      ~name:schema.name ~args:input () with
              | Error rejected -> rejected
              | Ok _ ->
                let result = handle ~start_time execution_env input in
                match Tool_bridge.attach_artifact_manifest
                        ~projection:artifact_projection ~base_path:config.base_path result with
                | Ok result -> result
                | Error { message; _ } ->
                  Tool_result.make_err ~tool_name:schema.name ~class_:Tool_result.Runtime_failure
                    ~effect_disposition:Tool_result.Effect_outcome_unknown ~start_time message
              in
              (* task-3268: the transient run tool bypasses the exec handler,
                 so emit the shared dispatch observers here (#38824). *)
              Tool_dispatch.run_dispatch_observers Dispatch_outcome.Handled (Some dispatch_result);
              dispatch_result)
        in
        (tool, Tool_loading_declarations.required schema.name, model_projection)
      in
      let run = make Draft.run_schema ~artifact_projection:Tool_output.Inline_with_structured_diagnostic
        ~call_effect:(fun _ -> Agent_core.Tool.Effect_possible)
        (fun ~start_time execution_env input ->
          match Agent_core.Tool.Execution_env.invocation execution_env with
          | None -> Tool_result.runtime_err ~tool_name:Draft.run_tool_name ~start_time
              "composition run requires Agent-Core invocation identity"
          | Some parent_invocation ->
            match Draft.resolve_run_request ~base_path:config.base_path ~capability_surface ~keeper_name:meta.name input with
            | Error error -> rejection ~tool_name:Draft.run_tool_name ~start_time error
            | Ok draft ->
              let plan = Draft.plan draft in
              let turn_context = Option.map (fun cell ->
                Keeper_tool_call_log_context.get_turn_context_record ~cell ()) turn_ctx_cell in
              let bind_result ~composition_run_id ~run_reference result =
                bind_prepared_result ~composition_run_id ~run_reference
                  ~draft_reference:(Draft.reference draft) result in
              let execute_run ?journal ?continuation ~nested_activation ~composition_run_id ~run_reference ~parent_invocation ~turn_context () =
                let result = match Draft.execution draft with
                  | Catalog.Async ->
                    async_submission_result ?journal ?continuation ~draft_reference:(Draft.reference draft) ~run_reference ~composition_run_id
                      ~nested_calls:(Draft.nested_calls draft) ?nested_activation
                      ~plan ~tool_name:Draft.run_tool_name ~tool_kind:Keeper_tool_descriptor.Async_composition_tool
                      ~parent_invocation ~config ~meta ~capability_authority ~publication_recovery
                      ~ctx_snapshot ~turn_context ?clock ()
                  | Catalog.Inline ->
                    with_ready_inline_files ~config ~meta ~source:turn_context ~plan
                      ~prepared_files:None ~gate_causal_context ~gate_context ~record_gate_result
                      (fun ready_files gate_context record_gate_result ->
                    let nested_run = Keeper_composition_nested_run.create
                        ~calls:(Draft.nested_calls draft) ~composition_run_id ~parent_invocation
                        ~tool_name:Draft.run_tool_name ~record_activation:record_nested_composition_activation () in
                    let execution = execute_keeper_plan ~capability_authority ~plan ~composition_run_id
                        ~run_id:(Keeper_tool_plan.Run_id.fresh ()) ~parent_invocation ~config ~meta
                        ~publication_recovery ~ctx_snapshot ~keeper_turn_id:(keeper_turn_id_of turn_context)
                        ?source_context:turn_context ?ready_files
                        ?turn_sandbox_factory ?clock ?continuation_channel ?gate_context ?gate_grant ?record_gate_result
                        ?on_deferred ?on_external_effect_deferred
                        ~admit_node:(Keeper_composition_nested_run.admit_node nested_run)
                        ?observe_node_result:(Option.map (fun turn_context ->
                          observe_node_result
                            ?on_receipt_committed:(Option.map (fun record execution_id ->
                              record ~keeper_name:meta.name ~turn_context execution_id)
                              on_inline_receipt_committed)
                            ~composition_tool:Draft.run_tool_name ~composition_execution:Catalog.Inline
                            ~composition_tool_kind:Keeper_tool_descriptor.Composition_tool ~composition_run_id
                            ~parent_invocation ~meta ~turn_context) turn_context) () in
                    let result = result_of_execution ~tool_name:Draft.run_tool_name
                        ~tool_kind:Keeper_tool_descriptor.Composition_tool ~start_time execution in
                    let nested_scopes = match Draft.nested_calls draft with [] -> None | _ :: _ ->
                      Some (Keeper_composition_nested_run.evidence_to_json nested_run ~plan ~execution) in
                    let result = match Keeper_composition_result.project ?nested_scopes ~base_path:config.base_path ~plan ~execution result with
                      | Ok result -> result
                      | Error { message; _ } -> Tool_result.make_err ~tool_name:Draft.run_tool_name
                          ~class_:Tool_result.Runtime_failure ~effect_disposition:Tool_result.Effect_outcome_unknown
                          ~start_time message in
                    observe_composition_run_summary
                      ~composition_tool:Draft.run_tool_name ~composition_execution:Catalog.Inline
                      ~composition_tool_kind:Keeper_tool_descriptor.Composition_tool ~composition_run_id
                      ~parent_invocation ~meta ~turn_context ~input ~output_text:(Tool_result.message result)
                      ~success:(Tool_result.is_success result) ~duration_ms:(Tool_result.duration_ms result)
                      ~typed_result:result ();
                    result)
                in
                bind_result ~composition_run_id ~run_reference result
              in
              let resume_run_id = match input with
                | `Assoc fields -> List.assoc_opt "resume_run_id" fields
                | _ -> None in
              match resume_run_id, Draft.execution draft with
              | Some _, Catalog.Inline ->
                rejection ~tool_name:Draft.run_tool_name ~start_time
                  (Draft.Malformed_draft "resume_run_id requires a prepared async draft")
              | Some (`String identity), Catalog.Async ->
                (match Keeper_tool_plan.Composition_run_id.of_string identity with
                 | Error _ -> rejection ~tool_name:Draft.run_tool_name ~start_time
                     (Draft.Malformed_draft "resume_run_id must be a composition run UUIDv7")
                 | Ok composition_run_id ->
                   match Journal.load ~base_path:config.base_path ~keeper_name:meta.name ~composition_run_id with
                   | Error error -> journal_rejection ~start_time error
                   | Ok journal ->
                     let source = Journal.source journal in
                     if (match source.producer with Journal.Named _ -> true | Prepared -> false) then
                       journal_rejection ~start_time Journal.Source_conflict
                     else if not (Yojson.Safe.equal
                       (Tool_output.normalized_artifact_ref_to_json source.draft_reference)
                       (Tool_output.normalized_artifact_ref_to_json (Draft.reference draft))) then
                       journal_rejection ~start_time Journal.Source_conflict
                     else
                       let parent_invocation = Agent_core.Tool_contract.Invocation.create
                         ~tool_use_id:source.parent_tool_use_id ~turn:source.source_turn
                         ~schedule:(Agent_core.Tool_contract.Invocation.schedule parent_invocation)
                         ~completion:Agent_core.Tool_contract.Continue_after_success in
                       (* The new physical turn keeps its own trace/session identity,
                          while work and completion belong to the original task. *)
                       let context = match turn_context with
                         | Some context -> context
                         | None -> Keeper_tool_call_log_context.get_turn_context_record
                             ~cell:(Keeper_tool_call_log_context.create_cell ()) () in
                       let turn_context = Some { context with task_id = source.source_task_id } in
                       match Journal.waiting_continuation journal with
                       | Error error -> journal_rejection ~start_time error
                       | Ok continuation ->
                         (match Draft.load_nested_activation ~base_path:config.base_path source with
                          | Error error -> rejection ~tool_name:Draft.run_tool_name ~start_time error
                          | Ok nested_activation ->
                            let original_nested = Keeper_composition_nested_run.create ~calls:(Draft.nested_calls draft)
                                ~composition_run_id ~parent_invocation
                                ~delivery_parent_tool_use_id:(Keeper_composition_nested_run.async_result_parent composition_run_id)
                                ~tool_name:Draft.run_tool_name ~record_activation:None () in
                            Option.iter (fun bound -> Keeper_composition_nested_run.restore_admissions original_nested
                              ~find_activation:(fun ~invocation ~tool_name ~scope ~reference ->
                                Keeper_skill_activation_recorder.find_bound_nested ~config bound ~invocation ~tool_name ~scope ~reference)) nested_activation;
                            match Keeper_composition_nested_run.check_original_admissions original_nested
                                ~child_history:(Journal.child_admission journal) with
                            | Keeper_composition_nested_run.Original_authority_held error -> Tool_result.make_err ~tool_name:Draft.run_tool_name ~start_time
                                ~class_:Tool_result.Runtime_failure ~effect_disposition:Tool_result.Proven_pre_effect
                                ~data:error.data error.detail
                            | Keeper_composition_nested_run.Original_admitted -> execute_run ~journal ?continuation ~nested_activation ~composition_run_id ~run_reference:source.run_reference
                                ~parent_invocation ~turn_context ()))
              | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _), Catalog.Async ->
                rejection ~tool_name:Draft.run_tool_name ~start_time
                  (Draft.Malformed_draft "resume_run_id must be a string")
              | None, (Catalog.Inline | Catalog.Async) ->
                let nested_activation = match Draft.execution draft,Draft.nested_calls draft with
                  | Catalog.Inline,_ | Catalog.Async,[] -> Ok None
                  | Catalog.Async,_::_ ->
                    (match nested_activation_context with
                     | None -> Error Keeper_skill_activation_recorder.Runtime_attempt_missing
                     | Some context -> Keeper_skill_activation_recorder.bind_async context |> Result.map Option.some) in
                (match nested_activation with
                 | Error error -> Tool_result.make_err ~tool_name:Draft.run_tool_name
                     ~class_:Tool_result.Runtime_failure ~effect_disposition:Tool_result.Proven_pre_effect ~start_time
                     ~data:(Keeper_skill_activation_recorder.error_to_yojson error)
                     (Keeper_skill_activation_recorder.error_to_string error)
                 | Ok nested_activation ->
                let composition_run_id = Keeper_tool_plan.Composition_run_id.fresh () in
                match Draft.record_invocation ~base_path:config.base_path ?nested_activation ~composition_run_id
                        ~invocation:parent_invocation draft with
                | Error error -> rejection ~tool_name:Draft.run_tool_name ~start_time error
                | Ok run_reference ->
                  match Draft.execution draft with
                  | Catalog.Inline -> execute_run ~nested_activation ~composition_run_id ~run_reference ~parent_invocation ~turn_context ()
                  | Catalog.Async ->
                    let source : Journal.source =
                      { keeper_name = meta.name; composition_run_id
                      ; draft_reference = Draft.reference draft; run_reference
                      ; parent_tool_use_id = Agent_core.Tool_contract.Invocation.tool_use_id parent_invocation
                      ; source_turn = Agent_core.Tool_contract.Invocation.turn parent_invocation
                      ; source_task_id = Option.bind turn_context (fun context -> context.Keeper_tool_call_log_context.task_id); producer=Journal.Prepared } in
                    match Journal.prepare ?observation:(source_observation_of_context turn_context)
                        ~base_path:config.base_path source with
                    | Error error -> bind_result ~composition_run_id ~run_reference (journal_rejection ~start_time error)
                    | Ok journal -> execute_run ~journal ~nested_activation ~composition_run_id ~run_reference ~parent_invocation ~turn_context ()))
      in
      [ run ]
  in
  let composition_tools = composition_tools @ draft_tools in
  (* A keeper with no instruction skills gets no tool: an empty [Available]
     list would ask the model to reach for something that answers nothing. *)
  let composition_tools =
    match instruction_skills with
    | [] -> composition_tools
    | skills ->
      composition_tools
      @ [ (let+ tool = make_instruction_skill_tool
            ~config
            ?record_activation:record_instruction_activation
            ~assess_applicability:(fun ~reference ~body ->
              let context = Option.map (fun capture -> (capture ()).Keeper_gate.snapshot) gate_context in
              Typesafeai_skill_applicability.assess ?clock ~keeper_id:meta.name
                ~context ~reference ~body ())
            ~instruction_skills:skills
            () in
          (tool, Tool_loading_declarations.required Catalog.skill_tool_name,
           Tool_output.bounded_inline_model_projection))
        ]
  in
  (* Built only where they can address something: an async entry on this
     surface is the one thing that mints the request id they take. *)
  let async_controls =
    draft_tools <> [] || Catalog.requires_async_controls
      (List.map (fun (skill : composition_skill) -> skill.entry) skill_compositions)
  in
  let status_tool =
      make_request_control_tool
        ~config
        ~name:Catalog.status_tool_name
        ~description:Tool_schemas_composition_control.status_schema.description
        ~input_schema:Tool_schemas_composition_control.status_schema.input_schema
        ~descriptor:
          (Agent_core.Tool.ordinary_descriptor Agent_core.Tool_contract.Concurrent)
        ~on_rejected:(fun execution_env -> discard_status_binding ~delivery_registry:result_delivery
          ~invocation:(Agent_core.Tool.Execution_env.invocation execution_env))
        ~handle:(fun execution_env request_id ->
          status_result_for_invocation ?delivery_registry:result_delivery
            ?invocation:(Agent_core.Tool.Execution_env.invocation execution_env)
            ~config ~meta ~request_id ())
  in
  let cancel_tool =
      make_request_control_tool
        ~config
        ~name:Catalog.cancel_tool_name
        ~description:Tool_schemas_composition_control.cancel_schema.description
        ~input_schema:Tool_schemas_composition_control.cancel_schema.input_schema
        ~descriptor:(Agent_core.Tool.ordinary_descriptor Agent_core.Tool_contract.Serial)
        ~on_rejected:(fun _execution_env -> ())
        ~handle:(fun _execution_env request_id -> cancel_result ~config ~meta ~request_id)
  in
  (* The Skill reader and the two request controls are not Skill
     compositions; each is declared in its own [config/tools/<name>.toml]. *)
  let rows =
    if async_controls then
      composition_tools
      @ [ Result.map (fun tool ->
            tool, Tool_loading_declarations.required Catalog.status_tool_name,
            Tool_output.default_model_projection) status_tool
        ; Result.map (fun tool ->
            tool, Tool_loading_declarations.required Catalog.cancel_tool_name,
            Tool_output.default_model_projection) cancel_tool ]
    else composition_tools
  in
  let rec collect = function
    | [] -> Ok []
    | row :: rest ->
      let* row = row in
      let+ rest = collect rest in
      row :: rest
  in
  collect rows
;;
