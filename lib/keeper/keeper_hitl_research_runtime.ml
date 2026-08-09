let make_runner
      ~(config : Workspace.config)
      ~publication_recovery_provider
      ~register
      ~clock
      ~net
      ~(entry : Keeper_approval_queue.pending_approval)
  =
  let open Result.Syntax in
  let* () =
    if String.equal config.base_path entry.audit_base_path
    then Ok ()
    else Error "HITL research config does not match the approval workspace"
  in
  let* resources =
    Keeper_publication_recovery_scope.resolve_turn_resources
      ~provider:publication_recovery_provider
      ~base_path:entry.audit_base_path
      ~keeper_name:entry.keeper_name
    |> Result.map_error (fun failure ->
      "HITL research context unavailable: "
      ^ Keeper_publication_recovery_scope.failure_to_string failure)
  in
  let frozen_input = Hitl_summary_worker.frozen_research_input ~entry in
  let ctx_snapshot =
    Keeper_context_runtime.create
      ~eio:true
      ~system_prompt:Hitl_summary_worker.research_system_prompt
    |> fun ctx ->
    Keeper_context_runtime.append
      ctx
      (Agent_sdk.Types.text_message
         Agent_sdk.Types.User
         (Yojson.Safe.to_string frozen_input))
  in
  let execution_id = Keeper_internal_research.Execution_id.generate () in
  let run_id = Keeper_internal_research.Execution_id.to_string execution_id in
  let registered = ref false in
  let register_once raw_trace_path =
    if not !registered
    then (
      register ~run_id ~raw_trace_path;
      registered := true)
  in
  let raw_trace =
    match
      Keeper_internal_research.create_raw_trace_sink
        ~before_create:(fun path -> register_once (Some path))
        ~config
        ~meta:resources.entry.meta
        ~execution_id
    with
    | Keeper_internal_research.Raw_trace_ready sink -> Some sink
    | Keeper_internal_research.Raw_trace_degraded error ->
      register_once None;
      Log.Keeper.warn
        ~keeper_name:entry.keeper_name
        "HITL research raw-trace sink degraded; dispatching untraced: %s"
        (Agent_sdk.Error.to_string error);
      None
  in
  register_once None;
  let receipt =
    Keeper_internal_research.run
      { owner = Keeper_internal_research.Hitl_auto_judge
      ; execution_id
      ; runtime_id =
          Keeper_meta_contract.runtime_id_of_meta resources.entry.meta
      ; frozen_system_prompt = Hitl_summary_worker.research_system_prompt
      ; frozen_prompt = Hitl_summary_worker.research_prompt frozen_input
      ; frozen_input
      ; evidence_budget_bytes = 16 * 1024
      ; config
      ; meta = resources.entry.meta
      ; publication_recovery = resources.publication_recovery
      ; ctx_snapshot
      ; clock
      ; net
      ; continuation_channel = Some entry.continuation_channel
      ; raw_trace
      }
  in
  Ok
    { Hitl_summary_worker.run_id = run_id
    ; receipt = Keeper_internal_research.receipt_to_yojson receipt
    ; finalizer_evidence =
        Keeper_internal_research.finalizer_evidence_to_yojson receipt
    }
;;
