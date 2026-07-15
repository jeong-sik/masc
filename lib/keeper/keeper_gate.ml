type causal_context =
  { turn_id : int option
  ; snapshot : Yojson.Safe.t
  }

type request =
  { keeper_name : string
  ; operation : string
  ; input : Yojson.Safe.t
  ; base_path : string
  ; causal_context : causal_context option
  ; task_id : string option
  ; goal_ids : string list
  ; continuation_channel : Keeper_continuation_channel.t option
  }

type authorization_source =
  | One_shot_resolution of string
  | Exact_always_rule of string
  | Keeper_always_allow
  | Workspace_always_allow

type authorization = { source : authorization_source }

type deferred_reason =
  | Human_requested
  | Judge_requested
  | Auto_judge_unavailable of string
  | Mode_state_invalid of string

type unavailable_reason =
  | Queue_storage_unavailable of Keeper_approval_queue.storage_error
  | Approval_grant_unavailable of Keeper_approval_queue.grant_error
  | Approval_grant_consumption_in_progress of string

type decision =
  | Allow of authorization
  | Deferred of
      { approval_id : string
      ; reason : deferred_reason
      }
  | Unavailable of unavailable_reason

type auto_judge_resume_failure =
  { approval_id : string
  ; reason : string
  }

type auto_judge_resume_report =
  { requested : int
  ; started_ids : string list
  ; finalized_ids : string list
  ; skipped_ids : string list
  ; failures : auto_judge_resume_failure list
  }

type cycle_grant_entry =
  { approval_id : string }

type cycle_grant_state =
  | Cycle_grant_available of cycle_grant_entry
  | Cycle_grant_consuming of cycle_grant_entry
  | Cycle_grant_consumed

type cycle_grant = cycle_grant_state Atomic.t

type cycle_grant_take_result =
  | Cycle_grant_authorized of string
  | Cycle_grant_not_applicable
  | Cycle_grant_temporarily_unavailable of string * unavailable_reason

let cycle_grant_of_resolution (resolution : Keeper_event_queue.hitl_resolution) =
  match resolution.decision with
  | Keeper_event_queue.Hitl_approved ->
    Some
      (Atomic.make
         (Cycle_grant_available { approval_id = resolution.approval_id }))
  | Keeper_event_queue.Hitl_rejected _ | Keeper_event_queue.Hitl_edited _ -> None
;;

let rec take_matching_cycle_grant grant request =
  match Atomic.get grant with
  | Cycle_grant_consumed -> Cycle_grant_not_applicable
  | Cycle_grant_consuming entry ->
    Cycle_grant_temporarily_unavailable
      ( entry.approval_id
      , Approval_grant_consumption_in_progress entry.approval_id )
  | Cycle_grant_available entry as current ->
    let reserved = Cycle_grant_consuming entry in
    if Atomic.compare_and_set grant current reserved
    then (
      match
        Keeper_approval_queue.consume_approved_resolution
        ~base_path:request.base_path
        ~id:entry.approval_id
        ~keeper_name:request.keeper_name
        ~tool_name:request.operation
        ~input:request.input
      with
      | Error error ->
        Atomic.set grant current;
        Cycle_grant_temporarily_unavailable
          (entry.approval_id, Approval_grant_unavailable error)
      | Ok Keeper_approval_queue.Consumption_not_matching ->
        Atomic.set grant current;
        Cycle_grant_not_applicable
      | Ok Keeper_approval_queue.Consumption_already_committed ->
        Atomic.set grant Cycle_grant_consumed;
        Cycle_grant_not_applicable
      | Ok Keeper_approval_queue.Consumption_committed ->
        Atomic.set grant Cycle_grant_consumed;
        Cycle_grant_authorized entry.approval_id)
    else take_matching_cycle_grant grant request
;;

let authorization_source_to_string = function
  | One_shot_resolution _ -> "one_shot_resolution"
  | Exact_always_rule _ -> "exact_always_rule"
  | Keeper_always_allow -> "keeper_always_allow"
  | Workspace_always_allow -> "workspace_always_allow"
;;

let deferred_reason_to_string = function
  | Human_requested -> "human_requested"
  | Judge_requested -> "judge_requested"
  | Auto_judge_unavailable _ -> "auto_judge_unavailable"
  | Mode_state_invalid _ -> "mode_state_invalid"
;;

let unavailable_reason_to_string = function
  | Queue_storage_unavailable error ->
    Keeper_approval_queue.storage_error_to_string error
  | Approval_grant_unavailable error ->
    Keeper_approval_queue.grant_error_to_string error
  | Approval_grant_consumption_in_progress approval_id ->
    Printf.sprintf "approval %s is being consumed" approval_id
;;

let source_fields = function
  | One_shot_resolution approval_id ->
    [ "authorization_source", `String "one_shot_resolution"
    ; "approval_id", `String approval_id
    ]
  | Exact_always_rule rule_id ->
    [ "authorization_source", `String "exact_always_rule"
    ; "rule_id", `String rule_id
    ]
  | Keeper_always_allow ->
    [ "authorization_source", `String "keeper_always_allow" ]
  | Workspace_always_allow ->
    [ "authorization_source", `String "workspace_always_allow" ]
;;

let request_turn_id request =
  Option.bind request.causal_context (fun context -> context.turn_id)
;;

let decision_to_yojson = function
  | Allow authorization ->
    `Assoc ([ "decision", `String "allow" ] @ source_fields authorization.source)
  | Deferred { approval_id; reason } ->
    let detail =
      match reason with
      | Mode_state_invalid detail -> [ "mode_read_error", `String detail ]
      | Auto_judge_unavailable detail ->
        [ "auto_judge_error", `String detail ]
      | Human_requested | Judge_requested -> []
    in
    `Assoc
      ([ "decision", `String "deferred"
       ; "approval_id", `String approval_id
       ; "reason", `String (deferred_reason_to_string reason)
       ]
       @ detail)
  | Unavailable reason ->
    `Assoc
      [ "decision", `String "unavailable"
      ; "reason", `String (unavailable_reason_to_string reason)
      ]
;;

let audit_allow request ?rule_match ?source_approval_id ?decision_source source =
  Keeper_approval_queue.audit_approval_event
    ~base_path:request.base_path
    ~event_type:"gate_allowed"
    ~id:
      (match source with
       | One_shot_resolution approval_id -> approval_id
       | Exact_always_rule rule_id -> rule_id
       | Keeper_always_allow | Workspace_always_allow ->
         Keeper_approval_queue.generate_id ())
    ~keeper_name:request.keeper_name
    ~tool_name:request.operation
    ?turn_id:(request_turn_id request)
    ?task_id:request.task_id
    ~goal_ids:request.goal_ids
    ?rule_match
    ?source_approval_id
    ?decision_source
    ()
;;

let submit request =
  Keeper_approval_queue.submit_pending
    ~keeper_name:request.keeper_name
    ~tool_name:request.operation
    ~input:request.input
    ~base_path:request.base_path
    ?turn_id:(request_turn_id request)
    ?request_context:(Option.map (fun context -> context.snapshot) request.causal_context)
    ?task_id:request.task_id
    ~goal_ids:request.goal_ids
    ?continuation_channel:request.continuation_channel
    ()
;;

let log_auto_resolution_error ~keeper_name ~approval_id reason =
  Log.Keeper.warn
    ~keeper_name
    "auto judge resolution failed approval=%s: %s"
    approval_id
    reason
;;

let log_summary_state_error ~keeper_name ~approval_id ~operation error =
  Log.Keeper.warn
    ~keeper_name
    "auto judge summary state failed operation=%s approval=%s: %s"
    operation
    approval_id
    (Keeper_approval_queue.storage_error_to_string error)
;;

let log_summary_transition_miss ~keeper_name ~approval_id ~operation =
  Log.Keeper.warn
    ~keeper_name
    "auto judge summary state not changed operation=%s approval=%s"
    operation
    approval_id
;;

type judgment_finalize_outcome =
  | Judgment_finalized
  | Judgment_skipped

let resolve_judgment (entry : Keeper_approval_queue.pending_approval) ~approval_id
      (summary : Keeper_approval_queue.hitl_context_summary) =
  let decision =
    match summary.Keeper_approval_queue.judgment with
    | Keeper_approval_queue.Approve -> Some Keeper_approval_queue.Decision.Approve
    | Keeper_approval_queue.Deny ->
      Some (Keeper_approval_queue.Decision.Reject summary.rationale)
    | Keeper_approval_queue.Require_human -> None
  in
  match decision with
  | None -> Ok Judgment_skipped
  | Some decision ->
    (match
       Keeper_approval_queue.resolve_with_policy
         ~id:approval_id
         ~decision
         ~source:Keeper_approval_queue.Auto_judge
         ~created_by:("auto_judge:" ^ summary.model_run_id)
         ()
     with
     | Ok _ -> Ok Judgment_finalized
     | Error (Keeper_approval_queue.Not_found _ | Keeper_approval_queue.Already_resolved _) ->
       Ok Judgment_skipped
     | Error (Keeper_approval_queue.Delivery_failed _ as delivery_error) ->
       (match Keeper_approval_queue.requeue_failed_auto_judge_delivery ~id:approval_id with
        | Ok () -> Error (Keeper_approval_queue.resolve_error_to_string delivery_error)
        | Error requeue_error ->
          Error
            (Printf.sprintf
               "%s; durable Auto Judge requeue failed: %s"
               (Keeper_approval_queue.resolve_error_to_string delivery_error)
               (Keeper_approval_queue.auto_judge_delivery_requeue_error_to_string
                  requeue_error)))
     | Error error -> Error (Keeper_approval_queue.resolve_error_to_string error))
;;

type auto_judge_start_outcome =
  | Started
  | Skipped

module Auto_judge_ids = Set_util.StringSet

let active_auto_judges : Auto_judge_ids.t Atomic.t =
  Atomic.make Auto_judge_ids.empty
;;

let rec claim_auto_judge id =
  let active = Atomic.get active_auto_judges in
  if Auto_judge_ids.mem id active
  then false
  else
    let claimed = Auto_judge_ids.add id active in
    if Atomic.compare_and_set active_auto_judges active claimed
    then true
    else claim_auto_judge id
;;

let rec release_auto_judge id =
  let active = Atomic.get active_auto_judges in
  let released = Auto_judge_ids.remove id active in
  if not (Atomic.compare_and_set active_auto_judges active released)
  then release_auto_judge id
;;

let spawn_claimed_auto_judge_entry
      (entry : Keeper_approval_queue.pending_approval)
  =
  let approval_id = entry.id in
  let on_summary summary =
    match Keeper_approval_queue.attach_summary ~id:approval_id summary with
    | Ok true ->
      (match resolve_judgment entry ~approval_id summary with
       | Ok (Judgment_finalized | Judgment_skipped) -> ()
       | Error reason ->
         log_auto_resolution_error
           ~keeper_name:entry.keeper_name
           ~approval_id
           reason)
    | Ok false ->
      log_summary_transition_miss
        ~keeper_name:entry.keeper_name
        ~approval_id
        ~operation:"attach"
    | Error error ->
      log_summary_state_error
        ~keeper_name:entry.keeper_name
        ~approval_id
        ~operation:"attach"
        error
  in
  let on_failure ~reason ~retryable =
    match
      Keeper_approval_queue.mark_summary_failed
        ~id:approval_id
        ~reason
        ~retryable
    with
    | Ok true -> ()
    | Ok false ->
      log_summary_transition_miss
        ~keeper_name:entry.keeper_name
        ~approval_id
        ~operation:"fail"
    | Error error ->
      log_summary_state_error
        ~keeper_name:entry.keeper_name
        ~approval_id
        ~operation:"fail"
        error
  in
  let fail_before_worker ~reason ~retryable =
    Fun.protect
      ~finally:(fun () -> release_auto_judge approval_id)
      (fun () ->
         on_failure ~reason ~retryable;
         Error reason)
  in
  let provider_selection =
    try
      Ok
        (Hitl_summary_worker.provider_config_for_summary
           ~keeper_name:entry.keeper_name)
    with
    | Eio.Cancel.Cancelled _ as exn ->
      release_auto_judge approval_id;
      raise exn
    | exn ->
      Error
        ("Auto Judge provider selection failed: " ^ Printexc.to_string exn)
  in
  match Eio_context.get_root_switch_opt (), provider_selection with
  | Some sw, Ok (Some selected) ->
    (try
       Hitl_summary_worker.spawn
         ~sw
         ~runtime_id:selected.runtime_id
         ~entry
         ~provider_config:selected.provider_config
         ~on_summary
         ~on_failure
         ~on_finish:(fun () -> release_auto_judge approval_id)
         ();
       Ok Started
     with
     | Eio.Cancel.Cancelled _ as exn ->
       release_auto_judge approval_id;
       raise exn
     | exn ->
       let reason =
         "Auto Judge worker start failed: " ^ Printexc.to_string exn
       in
       fail_before_worker ~reason ~retryable:true)
  | None, _ ->
    fail_before_worker
      ~reason:"Auto Judge unavailable: server root switch is not installed"
      ~retryable:true
  | Some _, Ok None ->
    fail_before_worker
      ~reason:"Auto Judge unavailable: no runtime provider is configured"
      ~retryable:true
  | Some _, Error reason -> fail_before_worker ~reason ~retryable:true
;;

let spawn_auto_judge_entry (entry : Keeper_approval_queue.pending_approval) =
  if claim_auto_judge entry.id
  then spawn_claimed_auto_judge_entry entry
  else Ok Skipped
;;

let retry_auto_judge_entry (entry : Keeper_approval_queue.pending_approval) =
  if not (claim_auto_judge entry.id)
  then Ok Skipped
  else
    match Keeper_approval_queue.restart_retryable_summary ~id:entry.id with
    | Error error ->
      release_auto_judge entry.id;
      Error (Keeper_approval_queue.storage_error_to_string error)
    | Ok false ->
      release_auto_judge entry.id;
      Ok Skipped
    | Ok true -> spawn_claimed_auto_judge_entry entry
;;

let start_auto_judge approval_id =
  match Keeper_approval_queue.get_pending_entry ~id:approval_id with
  | None -> Ok Skipped
  | Some entry ->
    if not (claim_auto_judge approval_id)
    then Ok Skipped
    else
      (match Keeper_approval_queue.mark_summary_pending ~id:approval_id with
       | Error error ->
         release_auto_judge approval_id;
         Error (Keeper_approval_queue.storage_error_to_string error)
       | Ok false ->
         release_auto_judge approval_id;
         Ok Skipped
       | Ok true -> spawn_claimed_auto_judge_entry entry)
;;

type recovered_work =
  | Restart_worker of Keeper_approval_queue.pending_approval
  | Finalize_judgment of
      Keeper_approval_queue.pending_approval
      * Keeper_approval_queue.hitl_context_summary
  | Retry_worker of Keeper_approval_queue.pending_approval

let recovered_work_for_base_path ~base_path =
  Keeper_approval_queue.list_pending_entries ()
  |> List.filter_map (fun (entry : Keeper_approval_queue.pending_approval) ->
    if not (String.equal entry.audit_base_path base_path)
    then None
    else
      match entry.summary_status with
      | Keeper_approval_queue.Summary_pending -> Some (Restart_worker entry)
      | Keeper_approval_queue.Summary_available
          ({ judgment = (Keeper_approval_queue.Approve | Keeper_approval_queue.Deny); _ }
           as summary) ->
        Some (Finalize_judgment (entry, summary))
      | Keeper_approval_queue.Summary_failed { retryable = true; _ } ->
        Some (Retry_worker entry)
      | Keeper_approval_queue.Summary_not_requested
      | Keeper_approval_queue.Summary_available
          { judgment = Keeper_approval_queue.Require_human; _ }
      | Keeper_approval_queue.Summary_failed { retryable = false; _ } ->
        None)
;;

let observe_recovered_work kind (entry : Keeper_approval_queue.pending_approval) =
  let event_type, outcome =
    match kind with
    | `Restart_worker ->
      "auto_judge_restart_worker_recovered", "restart_worker_recovered"
    | `Finalize_judgment ->
      "auto_judge_restart_judgment_recovered", "restart_judgment_recovered"
    | `Retry_worker ->
      "auto_judge_restart_retryable_recovered", "restart_retryable_recovered"
    | `Lane_activity_retry ->
      "auto_judge_lane_activity_retry", "lane_activity_retry"
    | `Lane_activity_finalize ->
      "auto_judge_lane_activity_judgment_recovered", "lane_activity_judgment_recovered"
  in
  Log.Keeper.warn
    ~keeper_name:entry.keeper_name
    "auto judge durable work recovered kind=%s approval=%s operation=%s"
    outcome
    entry.id
    entry.tool_name;
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string HitlSummaryOutcomes)
    ~labels:[ "outcome", outcome ]
    ();
  Keeper_approval_queue.audit_approval_event
    ~base_path:entry.audit_base_path
    ~event_type
    ~id:entry.id
    ~keeper_name:entry.keeper_name
    ~tool_name:entry.tool_name
    ?turn_id:entry.turn_id
    ?task_id:entry.task_id
    ?goal_id:entry.goal_id
    ~goal_ids:entry.goal_ids
    ()
;;

let resume_persisted_auto_judges ~base_path =
  let recovered = recovered_work_for_base_path ~base_path in
  let requested = List.length recovered in
  let started_ids, finalized_ids, skipped_ids, failures =
    List.fold_left
      (fun (started_ids, finalized_ids, skipped_ids, failures) work ->
         let entry, result =
           match work with
           | Restart_worker entry ->
             observe_recovered_work `Restart_worker entry;
             entry, `Start (spawn_auto_judge_entry entry)
           | Finalize_judgment (entry, summary) ->
             observe_recovered_work `Finalize_judgment entry;
             entry, `Finalize (resolve_judgment entry ~approval_id:entry.id summary)
           | Retry_worker entry ->
             observe_recovered_work `Retry_worker entry;
             entry, `Start (retry_auto_judge_entry entry)
         in
         match result with
         | `Start (Ok Started) ->
           entry.id :: started_ids, finalized_ids, skipped_ids, failures
         | `Finalize (Ok Judgment_finalized) ->
           started_ids, entry.id :: finalized_ids, skipped_ids, failures
         | `Start (Ok Skipped) | `Finalize (Ok Judgment_skipped) ->
           started_ids, finalized_ids, entry.id :: skipped_ids, failures
         | `Start (Error reason) | `Finalize (Error reason) ->
           ( started_ids
           , finalized_ids
           , skipped_ids
           , { approval_id = entry.id; reason } :: failures ))
      ([], [], [], [])
      recovered
  in
  { requested
  ; started_ids = List.rev started_ids
  ; finalized_ids = List.rev finalized_ids
  ; skipped_ids = List.rev skipped_ids
  ; failures = List.rev failures
  }
;;

let defer request reason =
  match submit request with
  | Error error -> Unavailable (Queue_storage_unavailable error)
  | Ok approval_id ->
    let reason =
      match reason with
      | Judge_requested ->
        let started =
          try start_auto_judge approval_id with
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | exn ->
            Error
              ("Auto Judge start failed before worker launch: "
               ^ Printexc.to_string exn)
        in
        (match started with
         | Ok (Started | Skipped) -> Judge_requested
         | Error detail -> Auto_judge_unavailable detail)
      | Human_requested | Auto_judge_unavailable _ | Mode_state_invalid _ -> reason
    in
    Deferred { approval_id; reason }
;;

let observe_exact_rule_store_degraded request error =
  let detail = Keeper_approval_queue.rule_store_error_to_string error in
  Log.Keeper.error
    ~keeper_name:request.keeper_name
    "exact Always Allowed rule lookup unavailable operation=%s: %s; continuing configured Gate mode"
    request.operation
    detail;
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string ApprovalQueueFailures)
    ~labels:[ "keeper", request.keeper_name; "site", "exact_rule_lookup" ]
    ();
  Keeper_approval_queue.audit_approval_event
    ~base_path:request.base_path
    ~event_type:"gate_exact_rule_store_degraded"
    ~id:(Keeper_approval_queue.generate_id ())
    ~keeper_name:request.keeper_name
    ~tool_name:request.operation
    ?turn_id:(request_turn_id request)
    ?task_id:request.task_id
    ~goal_ids:request.goal_ids
    ()
;;

let decide_from_selected_mode request = function
  | Error detail -> defer request (Mode_state_invalid detail)
  | Ok Keeper_gate_mode.Manual -> defer request Human_requested
  | Ok Keeper_gate_mode.Auto_judge -> defer request Judge_requested
  | Ok Keeper_gate_mode.Always_allow ->
    let source = Workspace_always_allow in
    audit_allow
      request
      ~decision_source:Keeper_approval_queue.Always_allowed
      source;
    Allow { source }
;;

let decide_without_cycle_grant ~keeper_always_allow request =
  if keeper_always_allow
  then (
    let source = Keeper_always_allow in
    audit_allow
      request
      ~decision_source:Keeper_approval_queue.Always_allowed
      source;
    Allow { source })
  else
    let mode = Keeper_gate_mode.read ~base_path:request.base_path in
    (match mode with
     | Ok Keeper_gate_mode.Always_allow ->
       let source = Workspace_always_allow in
       audit_allow
         request
         ~decision_source:Keeper_approval_queue.Always_allowed
         source;
       Allow { source }
     | Error _ | Ok (Keeper_gate_mode.Manual | Keeper_gate_mode.Auto_judge) ->
       (match
          Keeper_approval_queue.find_matching_rule
            ~base_path:request.base_path
            ~keeper_name:request.keeper_name
            ~tool_name:request.operation
            ~input:request.input
            ()
        with
        | Error error ->
          observe_exact_rule_store_degraded request error;
          decide_from_selected_mode request mode
        | Ok (Some rule_match) ->
          let source = Exact_always_rule rule_match.rule_id in
          audit_allow
            request
            ~rule_match
            ~decision_source:Keeper_approval_queue.Always_allowed
            source;
          Allow { source }
        | Ok None -> decide_from_selected_mode request mode))
;;

let decide ?cycle_grant ~keeper_always_allow request =
  let recover_lane_auto_judges () =
    Keeper_approval_queue.list_pending_entries ()
    |> List.iter (fun (entry : Keeper_approval_queue.pending_approval) ->
      if String.equal entry.audit_base_path request.base_path
         && String.equal entry.keeper_name request.keeper_name
      then
        match entry.summary_status with
        | Keeper_approval_queue.Summary_failed { retryable = true; _ } ->
          observe_recovered_work `Lane_activity_retry entry;
          (match retry_auto_judge_entry entry with
           | Ok (Started | Skipped) -> ()
           | Error reason ->
             Log.Keeper.error
               ~keeper_name:request.keeper_name
               "lane-local Auto Judge state recovery failed approval=%s: %s"
               entry.id
               reason)
        | Keeper_approval_queue.Summary_available
            ({ judgment = (Keeper_approval_queue.Approve | Keeper_approval_queue.Deny); _ }
             as summary) ->
          observe_recovered_work `Lane_activity_finalize entry;
          (match resolve_judgment entry ~approval_id:entry.id summary with
           | Ok (Judgment_finalized | Judgment_skipped) -> ()
           | Error reason ->
             Log.Keeper.error
               ~keeper_name:request.keeper_name
               "lane-local Auto Judge delivery recovery failed approval=%s: %s"
               entry.id
               reason)
        | Keeper_approval_queue.Summary_not_requested
        | Keeper_approval_queue.Summary_pending
        | Keeper_approval_queue.Summary_available
            { judgment = Keeper_approval_queue.Require_human; _ }
        | Keeper_approval_queue.Summary_failed { retryable = false; _ } -> ())
  in
  (try recover_lane_auto_judges () with
   | Eio.Cancel.Cancelled _ as exn -> raise exn
   | exn ->
     Log.Keeper.error
       ~keeper_name:request.keeper_name
       "lane-local Auto Judge recovery boundary failed: %s"
       (Printexc.to_string exn));
  let grant_result =
    match cycle_grant with
    | None -> Cycle_grant_not_applicable
    | Some grant -> take_matching_cycle_grant grant request
  in
  match grant_result with
  | Cycle_grant_authorized approval_id ->
    let source = One_shot_resolution approval_id in
    audit_allow request ~source_approval_id:approval_id source;
    Allow { source }
  | Cycle_grant_not_applicable ->
    decide_without_cycle_grant ~keeper_always_allow request
  | Cycle_grant_temporarily_unavailable (approval_id, reason) ->
    Log.Keeper.warn
      ~keeper_name:request.keeper_name
      "one-shot Gate grant unavailable; preserving the unconsumed grant operation=%s reason=%s"
      request.operation
      (unavailable_reason_to_string reason);
    Keeper_approval_queue.audit_approval_event
      ~base_path:request.base_path
      ~event_type:"gate_grant_unavailable"
      ~id:approval_id
      ~keeper_name:request.keeper_name
      ~tool_name:request.operation
      ?turn_id:(request_turn_id request)
      ?task_id:request.task_id
      ~goal_ids:request.goal_ids
      ~source_approval_id:approval_id
      ();
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ApprovalQueueFailures)
      ~labels:[ "keeper", request.keeper_name; "site", "cycle_grant_lookup" ]
      ();
    Unavailable reason
;;
