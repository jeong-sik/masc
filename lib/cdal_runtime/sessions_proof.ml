(** Sessions proof assembly — worker-run construction and proof bundle.

    Transforms raw trace data and runtime participant metadata into
    structured worker_run records and assembles the complete proof_bundle
    used for conformance checking and evidence export. *)

open Sessions_types
open Sessions_store
open Result_syntax

let participant_by_name (session : Runtime.session) name =
  List.find_opt
    (fun (participant : Runtime.participant) -> String.equal participant.name name)
    session.participants
;;

let resolved_provider_of_participant
      (session : Runtime.session)
      (participant : Runtime.participant option)
  =
  match participant with
  | Some p ->
    (match p.resolved_provider with
     | Some _ as value -> value
     | None -> p.provider)
  | None -> session.provider
;;

let resolved_model_of_participant
      (session : Runtime.session)
      (participant : Runtime.participant option)
  =
  match participant with
  | Some p ->
    (match p.resolved_model with
     | Some _ as value -> value
     | None -> p.model)
  | None -> session.model
;;

let worker_status_of_participant (participant : Runtime.participant option) =
  match participant with
  | Some p ->
    (match p.state with
     | Runtime.Failed_participant -> Failed
     | Runtime.Done -> Completed
     | Runtime.Live | Runtime.Idle ->
       if p.last_progress_at <> None && p.last_progress_at <> p.started_at
       then Running
       else Ready
     | Runtime.Starting -> Accepted
     | Runtime.Planned | Runtime.Detached -> Planned)
  | None -> Completed
;;

let worker_order_ts (worker : worker_run) =
  match worker.finished_at with
  | Some _ as value -> value
  | None ->
    (match worker.last_progress_at with
     | Some _ as value -> value
     | None -> worker.started_at)
;;

let sort_worker_runs worker_runs =
  List.sort
    (fun a b ->
       match worker_order_ts a, worker_order_ts b with
       | Some x, Some y -> Float.compare x y
       | Some _, None -> -1
       | None, Some _ -> 1
       | None, None -> String.compare a.worker_run_id b.worker_run_id)
    worker_runs
;;

let latest_worker_by predicate worker_runs =
  worker_runs
  |> List.filter predicate
  |> sort_worker_runs
  |> List.rev
  |> function
  | worker :: _ -> Some worker
  | [] -> None
;;

let worker_run_of_raw
      (session : Runtime.session)
      (summary : raw_trace_summary)
      (validation : raw_trace_validation)
  =
  let participant = participant_by_name session summary.run_ref.agent_name in
  let provider = resolved_provider_of_participant session participant in
  let model = resolved_model_of_participant session participant in
  let final_text =
    match summary.final_text with
    | Some _ as value -> value
    | None -> Option.bind participant (fun p -> p.summary)
  in
  let error =
    match summary.error with
    | Some _ as value -> value
    | None -> Option.bind participant (fun p -> p.last_error)
  in
  let failure_reason =
    match validation.failure_reason with
    | Some _ as value -> value
    | None -> error
  in
  { worker_run_id = summary.run_ref.worker_run_id
  ; worker_id =
      first_some
        (Option.bind participant (fun p -> p.worker_id))
        (Some summary.run_ref.agent_name)
  ; agent_name = summary.run_ref.agent_name
  ; runtime_actor =
      first_some
        (Option.bind participant (fun p -> p.runtime_actor))
        (Some summary.run_ref.agent_name)
  ; role = Option.bind participant (fun p -> p.role)
  ; aliases =
      Option.bind participant (fun p -> Some p.aliases) |> Option.value ~default:[]
  ; primary_alias = Option.bind participant (fun p -> primary_alias p.aliases)
  ; provider
  ; model
  ; requested_provider = Option.bind participant (fun p -> p.requested_provider)
  ; requested_model = Option.bind participant (fun p -> p.requested_model)
  ; requested_policy =
      first_some
        (Option.bind participant (fun p -> p.requested_policy))
        session.permission_mode
  ; resolved_provider = provider
  ; resolved_model = model
  ; status = worker_status_of_participant participant
  ; trace_capability = Raw
  ; validated = validation.ok
  ; tool_names = validation.tool_names
  ; final_text
  ; stop_reason = validation.stop_reason
  ; error
  ; failure_reason
  ; accepted_at = Option.bind participant (fun p -> p.accepted_at)
  ; ready_at = Option.bind participant (fun p -> p.ready_at)
  ; first_progress_at = Option.bind participant (fun p -> p.first_progress_at)
  ; started_at =
      first_some (Option.bind participant (fun p -> p.started_at)) summary.started_at
  ; finished_at =
      first_some (Option.bind participant (fun p -> p.finished_at)) summary.finished_at
  ; last_progress_at = Option.bind participant (fun p -> p.last_progress_at)
  ; policy_snapshot = session.permission_mode
  ; paired_tool_result_count = validation.paired_tool_result_count
  ; has_file_write = validation.has_file_write
  ; verification_pass_after_file_write = validation.verification_pass_after_file_write
  }
;;

let summary_only_worker_run
      (session : Runtime.session)
      index
      (participant : Runtime.participant)
  =
  let ts =
    match participant.started_at with
    | Some _ as value -> value
    | None -> participant.finished_at
  in
  let stamp =
    match ts with
    | Some ts -> Int64.of_float (ts *. 1000.)
    | None -> Int64.of_int index
  in
  { worker_run_id = Printf.sprintf "summary-only:%s:%Ld" participant.name stamp
  ; worker_id = first_some participant.worker_id (Some participant.name)
  ; agent_name = participant.name
  ; runtime_actor = first_some participant.runtime_actor (Some participant.name)
  ; role = participant.role
  ; aliases = participant.aliases
  ; primary_alias = primary_alias participant.aliases
  ; provider = resolved_provider_of_participant session (Some participant)
  ; model = resolved_model_of_participant session (Some participant)
  ; requested_provider = participant.requested_provider
  ; requested_model = participant.requested_model
  ; requested_policy = first_some participant.requested_policy session.permission_mode
  ; resolved_provider = resolved_provider_of_participant session (Some participant)
  ; resolved_model = resolved_model_of_participant session (Some participant)
  ; status = worker_status_of_participant (Some participant)
  ; trace_capability = Summary_only
  ; validated = false
  ; tool_names = []
  ; final_text = participant.summary
  ; stop_reason = None
  ; error = participant.last_error
  ; failure_reason = participant.last_error
  ; accepted_at = participant.accepted_at
  ; ready_at = participant.ready_at
  ; first_progress_at = participant.first_progress_at
  ; started_at = participant.started_at
  ; finished_at = participant.finished_at
  ; last_progress_at = participant.last_progress_at
  ; policy_snapshot = session.permission_mode
  ; paired_tool_result_count = 0
  ; has_file_write = false
  ; verification_pass_after_file_write = false
  }
;;

let unique_trace_capabilities worker_runs =
  worker_runs
  |> List.fold_left
       (fun acc (worker : worker_run) ->
          if List.exists (( = ) worker.trace_capability) acc
          then acc
          else acc @ [ worker.trace_capability ])
       []
;;

let evidence_capabilities_of_bundle
      ~raw_trace_runs
      ~raw_trace_summaries
      ~raw_trace_validations
  =
  { raw_trace = raw_trace_runs <> []
  ; validated_summary = raw_trace_summaries <> [] && raw_trace_validations <> []
  ; proof_bundle = true
  }
;;

let get_worker_runs ?session_root ~session_id () =
  let* session = get_session ?session_root session_id in
  let* summaries = get_raw_trace_summaries ?session_root ~session_id () in
  let* validations = get_raw_trace_validations ?session_root ~session_id () in
  let validation_by_run =
    validations
    |> List.map (fun (validation : raw_trace_validation) ->
      validation.run_ref.worker_run_id, validation)
  in
  let raw_worker_runs =
    summaries
    |> List.filter_map (fun (summary : raw_trace_summary) ->
      match List.assoc_opt summary.run_ref.worker_run_id validation_by_run with
      | Some validation -> Some (worker_run_of_raw session summary validation)
      | None -> None)
  in
  let raw_agent_names = raw_worker_runs |> List.map (fun worker -> worker.agent_name) in
  let summary_only_runs =
    session.participants
    |> List.mapi (fun index (participant : Runtime.participant) ->
      if List.exists (String.equal participant.name) raw_agent_names
      then None
      else Some (summary_only_worker_run session index participant))
    |> List.filter_map (fun value -> value)
  in
  Ok (sort_worker_runs (raw_worker_runs @ summary_only_runs))
;;

let get_latest_worker_run ?session_root ~session_id () =
  let* workers = get_worker_runs ?session_root ~session_id () in
  Ok (latest_worker_by (fun _ -> true) workers)
;;

let get_latest_accepted_worker_run ?session_root ~session_id () =
  let* workers = get_worker_runs ?session_root ~session_id () in
  Ok (latest_worker_by (fun worker -> worker.status = Accepted) workers)
;;

let get_latest_ready_worker_run ?session_root ~session_id () =
  let* workers = get_worker_runs ?session_root ~session_id () in
  Ok (latest_worker_by (fun worker -> worker.status = Ready) workers)
;;

let get_latest_running_worker_run ?session_root ~session_id () =
  let* workers = get_worker_runs ?session_root ~session_id () in
  Ok (latest_worker_by (fun worker -> worker.status = Running) workers)
;;

let get_latest_completed_worker_run ?session_root ~session_id () =
  let* workers = get_worker_runs ?session_root ~session_id () in
  Ok (latest_worker_by (fun worker -> worker.status = Completed) workers)
;;

let get_latest_failed_worker_run ?session_root ~session_id () =
  let* workers = get_worker_runs ?session_root ~session_id () in
  Ok (latest_worker_by (fun worker -> worker.status = Failed) workers)
;;

let get_latest_validated_worker_run ?session_root ~session_id () =
  let* workers = get_worker_runs ?session_root ~session_id () in
  Ok (latest_worker_by (fun worker -> worker.validated) workers)
;;

let get_proof_bundle ?session_root ~session_id () =
  let* session = get_session ?session_root session_id in
  let* report = get_report ?session_root ~session_id () in
  let* proof = get_proof ?session_root ~session_id () in
  let* telemetry = get_telemetry ?session_root ~session_id () in
  let* structured_telemetry = get_telemetry_structured ?session_root ~session_id () in
  let* evidence = get_evidence ?session_root ~session_id () in
  let* hook_summary = get_hook_summary ?session_root ~session_id () in
  let* tool_catalog = get_tool_catalog ?session_root ~session_id () in
  let* latest_raw_trace_run = get_latest_raw_trace_run ?session_root ~session_id () in
  let* raw_trace_runs = get_raw_trace_runs ?session_root ~session_id () in
  let* raw_trace_summaries = summarize_runs raw_trace_runs in
  let* raw_trace_validations = validate_runs raw_trace_runs in
  let* worker_runs = get_worker_runs ?session_root ~session_id () in
  let latest_worker_run = latest_worker_by (fun _ -> true) worker_runs in
  let latest_accepted_worker_run =
    latest_worker_by (fun worker -> worker.status = Accepted) worker_runs
  in
  let latest_ready_worker_run =
    latest_worker_by (fun worker -> worker.status = Ready) worker_runs
  in
  let latest_running_worker_run =
    latest_worker_by (fun worker -> worker.status = Running) worker_runs
  in
  let latest_completed_worker_run =
    latest_worker_by (fun worker -> worker.status = Completed) worker_runs
  in
  let latest_validated_worker_run =
    latest_worker_by (fun worker -> worker.validated) worker_runs
  in
  let latest_failed_worker_run =
    latest_worker_by (fun worker -> worker.status = Failed) worker_runs
  in
  let validated_worker_runs =
    worker_runs |> List.filter (fun worker -> worker.validated)
  in
  let raw_trace_run_count = List.length raw_trace_runs in
  let validated_worker_run_count = List.length validated_worker_runs in
  let trace_capabilities = unique_trace_capabilities worker_runs in
  let capabilities =
    evidence_capabilities_of_bundle
      ~raw_trace_runs
      ~raw_trace_summaries
      ~raw_trace_validations
  in
  Ok
    { session
    ; report
    ; proof
    ; telemetry
    ; structured_telemetry
    ; evidence
    ; hook_summary
    ; tool_catalog
    ; latest_raw_trace_run
    ; raw_trace_runs
    ; raw_trace_summaries
    ; raw_trace_validations
    ; worker_runs
    ; latest_accepted_worker_run
    ; latest_ready_worker_run
    ; latest_running_worker_run
    ; latest_worker_run
    ; latest_completed_worker_run
    ; latest_validated_worker_run
    ; latest_failed_worker_run
    ; validated_worker_runs
    ; raw_trace_run_count
    ; validated_worker_run_count
    ; trace_capabilities
    ; capabilities
    }
;;
