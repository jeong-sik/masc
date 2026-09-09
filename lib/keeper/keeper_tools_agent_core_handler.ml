(** Keeper_tools_agent_core_handler — Tool handler factory for Agent.run().

    Skeleton module: validation and dispatch. The heavy execution body lives
    in [Keeper_tools_agent_core_handler_exec]; telemetry helpers live in
    [Keeper_tools_agent_core_handler_telemetry].

    @since P1 extraction *)

open Keeper_tools_agent_core_handler_telemetry

let make_keeper_tool_handler_with_authority
      ~capability_authority
      ~(name : string)
      ?descriptor
      ?model_name
      ~(input_schema : Yojson.Safe.t)
      ~(config : Workspace.config)
      ~(meta : Keeper_meta_contract.keeper_meta)
      ~(publication_recovery :
          Keeper_publication_recovery_availability.turn_context)
      ~(ctx_snapshot : Keeper_types.working_context)
      ?turn_sandbox_factory
      ?clock
      ?continuation_channel
      ?gate_context
      ?gate_grant
      ?record_gate_result
      ?observe_execution_evidence
      ?on_completed
      ?on_deferred
      ?on_external_effect_deferred
      ?on_failed
      ?prepare_input
      ()
  : ?agent_core_invocation:Agent_core.Tool_contract.Invocation.t -> Yojson.Safe.t -> Tool_result.result
  =
  let input_schema =
    match descriptor with
    | None -> input_schema
    | Some supplied ->
      (match Keeper_tool_descriptor.find_id supplied.Keeper_tool_descriptor.id with
       | Some canonical
         when canonical == supplied
              && String.equal name canonical.Keeper_tool_descriptor.internal_name ->
         canonical.input_schema
       | Some _ | None ->
         invalid_arg
           "make_keeper_tool_handler: exact descriptor dispatch requires process-owned canonical authority")
  in
  let prepare_input =
    match descriptor, model_name, prepare_input with
    | Some canonical, Some model_name, _ ->
      fun input ->
        Keeper_tool_descriptor_resolution.prepare_model_input_for_descriptor
          ~tool_name:model_name
          canonical
          ~input
    | Some _, None, _ ->
      invalid_arg
        "make_keeper_tool_handler: exact descriptor dispatch requires its model-visible name"
    | None, Some _, _ ->
      invalid_arg
        "make_keeper_tool_handler: model-visible name requires exact descriptor authority"
    | None, None, Some prepare -> prepare
    | None, None, None ->
      fun input ->
        Tool_input_validation.validate_args
          ~schema:input_schema
          ~name
          ~args:input
          ()
  in
  let record_result ~input result =
    Option.iter
      (fun record -> record ~operation:name ~input result)
      record_gate_result;
    result
  in
  let observe_terminal_execution_result
        ~failure_effect_disposition
        ~deferred_kind
        (execution : Keeper_tools_agent_core_handler_exec.execution_result)
        (result : Tool_result.result)
    =
    (match result with
     | Tool_result.Completed _ ->
       Option.iter
         (fun completed -> completed execution.terminal_effect_receipt)
         on_completed
     | Tool_result.Deferred _ ->
       (match deferred_kind with
        | Some Keeper_tool_execution.External_effect_deferred ->
          Option.iter
            (fun deferred -> deferred ())
            on_external_effect_deferred
        | None | Some Keeper_tool_execution.Generic_deferred ->
          Option.iter (fun deferred -> deferred ()) on_deferred)
     | Tool_result.Failed { class_; message; _ } ->
       let effect_disposition =
         Option.value
           ~default:Tool_result.Effect_outcome_unknown
           failure_effect_disposition
       in
       (match effect_disposition with
        | Tool_result.Proven_pre_effect -> ()
        | Tool_result.Proven_post_effect | Tool_result.Effect_outcome_unknown ->
          Option.iter
            (fun failed ->
               failed
                 { Keeper_tools_agent_core.failure_class = class_
                 ; effect_disposition
                 ; diagnostic = message
                 })
            on_failed)
    );
    result
  in
  fun ?agent_core_invocation raw_input ->
    let invocation_fields = agent_core_invocation_fields agent_core_invocation in
    let handle_validation_error ~input validation_result =
      let validation_result =
        match validation_result with
        | Tool_result.Failed
            ({ Tool_result.metadata = None; data; _ } as failure) ->
          (* The descriptor validator owns a typed failure before the runtime
             handler starts. Agent Core's bridge carries failure metadata, so
             mirror that already-typed object instead of degrading every
             schema rejection to its prose message. *)
          Tool_result.Failed { failure with metadata = Some data }
        | Tool_result.Failed { metadata = Some _; _ }
        | Tool_result.Completed _
        | Tool_result.Deferred _ ->
          validation_result
      in
      Option.iter
        (fun observe ->
           observe
             ~failure_effect_disposition:(Some Tool_result.Proven_pre_effect)
             ~deferred_kind:None)
        observe_execution_evidence;
      let output_text = Tool_result.message validation_result in
      let duration_ms = 0 in
      let disposition = Tool_result.string_of_disposition validation_result in
      let ts = Time_compat.now () in
      let error_text = Tool_result.message validation_result in
      Keeper_registry.record_tool_use
        ~base_path:config.base_path
        meta.name
        ~tool_name:name
        ~disposition:validation_result;
      (* AGENT_CORE input validation runs outside guarded_dispatch, so emit the
         shared dispatch observers explicitly with the same shape as the
         exec error path ([Handled] with the error result).  The rejection
         class (Policy_rejection) rides in [validation_result] so observers
         that inspect [Tool_result.failure_class] can still distinguish it.
         Using [Handled (Some ...)] keeps the failure in the unified observer
         view; the earlier [Handler_error] arm was dropped by every observer
         (all three match only [Handled, Some _]). *)
      Tool_dispatch.run_dispatch_observers
        Dispatch_outcome.Handled
        (Some validation_result);
      broadcast_keeper_tool_call_event
        ~keeper_name:meta.name
        ~tool_name:name
        ~duration_ms
        ~disposition:validation_result
        ~error_text
        ~extra_fields:
          (tool_io_preview_fields ~tool_name:name ~input ~output:output_text ()
           @ invocation_fields)
        ~site:"input_validation"
        ~ts
        ();
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string ToolsAgent_coreFailures)
        ~labels:[ "tool", name; "site", "input_validation" ]
        ();
      append_tool_exec_decision_log
        ~config
        ~keeper_name:meta.name
        ~site:"input_validation"
        (`Assoc
            ([ "ts_unix", `Float ts
            ; "event", `String "tool_exec"
            ; "keeper_name", `String meta.name
            ; "tool", `String name
            ; "duration_ms", `Int duration_ms
            ; "result_bytes", `Int (String.length output_text)
            ; "disposition", `String disposition
            ; "error", `String error_text
            ]
             @ invocation_fields));
      (* Input rejection is proven pre-effect. Keep it in dispatch telemetry,
         but do not poison the request-scoped terminal-effect state. *)
      validation_result |> record_result ~input
    in
    match prepare_input raw_input with
    | Error validation_result ->
      handle_validation_error ~input:raw_input validation_result
    | Ok input ->
          let current_clock =
            match clock with
            | Some clock -> Some clock
            | None -> Eio_context.get_clock_opt ()
          in
          let run_with_current_eio_context ?clock () =
            let sw = Eio_context.get_switch_opt () in
            let net = Eio_context.get_net_opt () in
            let proc_mgr =
              match Process_eio.get_proc_mgr () with
              | Ok proc_mgr -> Some proc_mgr
              | Error _ -> None
            in
            let execution =
              let execute =
                match capability_authority with
                | Keeper_tool_runtime.Frozen_surface capability_surface ->
                  Keeper_tools_agent_core_handler_exec.execute_with_observers
                    ~capability_surface
                | Keeper_tool_runtime.Compatibility_meta ->
                  Keeper_tools_agent_core_handler_exec.execute_with_observers_from_meta
              in
              execute
                ~name
                ?descriptor
                ~config
                ~meta
                ~publication_recovery
                ~ctx_snapshot
                ?turn_sandbox_factory
                ?sw
                ?clock
                ?proc_mgr
                ?net
                ?continuation_channel
                ?gate_context
                ?gate_grant
                ?agent_core_invocation
                ~input
                ()
            in
            Option.iter
              (fun observe ->
                 observe
                   ~failure_effect_disposition:
                     execution.failure_effect_disposition
                   ~deferred_kind:execution.deferred_kind)
              observe_execution_evidence;
            execution.tool_result
            |> record_result ~input
            |> observe_terminal_execution_result
                 ~failure_effect_disposition:
                   execution.failure_effect_disposition
                 ~deferred_kind:execution.deferred_kind
                 execution
          in
          (* Named per call so a run on the main domain inside a tool reads
             as [tool <name>] in the trace. *)
          Eio_guard.with_named_switch ("tool " ^ name) (fun () ->
            run_with_current_eio_context ?clock:current_clock ())
;;

let make_keeper_tool_handler ~capability_surface =
  make_keeper_tool_handler_with_authority
    ~capability_authority:
      (Keeper_tool_runtime.Frozen_surface capability_surface)
;;

let make_keeper_tool_handler_from_meta =
  make_keeper_tool_handler_with_authority
    ~capability_authority:Keeper_tool_runtime.Compatibility_meta
;;
