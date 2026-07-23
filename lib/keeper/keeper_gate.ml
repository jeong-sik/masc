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
  let detail = Keeper_approval_queue.summary_transition_error_to_string error in
  Log.Keeper.error
    ~keeper_name
    "auto judge summary transition rejected operation=%s approval=%s: %s"
    operation
    approval_id
    detail;
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string ApprovalQueueFailures)
    ~labels:[ "keeper", keeper_name; "site", "auto_judge_summary_transition" ]
    ()
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
         ~base_path:entry.audit_base_path
         ~id:approval_id
         ~decision
         ~source:Keeper_approval_queue.Auto_judge
         ~created_by:("auto_judge:" ^ summary.model_run_id)
         ()
     with
     | Ok _ -> Ok Judgment_finalized
     | Error (Keeper_approval_queue.Not_found _ | Keeper_approval_queue.Already_resolved _) ->
       Ok Judgment_skipped
     | Error error -> Error (Keeper_approval_queue.resolve_error_to_string error))
;;

type auto_judge_start_outcome =
  | Started
  | Skipped

type auto_judge_retry_outcome =
  | Retry_started
  | Retry_queued
  | Retry_skipped

module Auto_judge_owner = struct
  type t = string * string

  let compare (left_base, left_keeper) (right_base, right_keeper) =
    let by_base = String.compare left_base right_base in
    if by_base <> 0 then by_base else String.compare left_keeper right_keeper
  ;;
end

module Auto_judge_owners = Map.Make (Auto_judge_owner)
module Auto_judge_owner_set = Set.Make (Auto_judge_owner)

let auto_judge_owner (entry : Keeper_approval_queue.pending_approval) =
  entry.audit_base_path, entry.keeper_name
;;

(** Immutable process projection of the one active approval for each exact
    workspace/Keeper owner. The durable approval queue remains the work SSOT. *)
let active_auto_judges : string Auto_judge_owners.t Atomic.t =
  Atomic.make Auto_judge_owners.empty
;;

let rec claim_auto_judge (entry : Keeper_approval_queue.pending_approval) =
  let active = Atomic.get active_auto_judges in
  let owner = auto_judge_owner entry in
  match Auto_judge_owners.find_opt owner active with
  | Some _ -> false
  | None ->
    let claimed = Auto_judge_owners.add owner entry.id active in
    if Atomic.compare_and_set active_auto_judges active claimed
    then true
    else claim_auto_judge entry
;;

let rec release_auto_judge (entry : Keeper_approval_queue.pending_approval) =
  let active = Atomic.get active_auto_judges in
  let owner = auto_judge_owner entry in
  match Auto_judge_owners.find_opt owner active with
  | Some active_id when String.equal active_id entry.id ->
    let released = Auto_judge_owners.remove owner active in
    if not (Atomic.compare_and_set active_auto_judges active released)
    then release_auto_judge entry
  | Some _ | None -> ()
;;

let active_auto_judge_for_owner ~base_path ~keeper_name =
  Auto_judge_owners.find_opt
    (base_path, keeper_name)
    (Atomic.get active_auto_judges)
;;

type auto_judge_entry_class =
  | Auto_judge_not_requested
  | Auto_judge_pending_unbound
  | Auto_judge_finalizable of Keeper_approval_queue.hitl_context_summary
  | Auto_judge_ineligible

let classify_auto_judge_entry
      (entry : Keeper_approval_queue.pending_approval)
  =
  match entry.exact_attempt, entry.summary_status with
  | Keeper_approval_queue.Exact_unbound,
    Keeper_approval_queue.Summary_not_requested ->
    Auto_judge_not_requested
  | Keeper_approval_queue.Exact_unbound,
    Keeper_approval_queue.Summary_pending ->
    Auto_judge_pending_unbound
  | Keeper_approval_queue.Exact_unbound,
    Keeper_approval_queue.Summary_available summary ->
    Auto_judge_finalizable summary
  | Keeper_approval_queue.Exact_bound
      { status = Keeper_approval_queue.Exact_completed; _ },
    Keeper_approval_queue.Summary_available summary ->
    Auto_judge_finalizable summary
  | Keeper_approval_queue.Exact_unbound,
    Keeper_approval_queue.Summary_failed _
  | Keeper_approval_queue.Exact_bound _, _ ->
    Auto_judge_ineligible
;;

let auto_judge_entry_ready entry =
  match classify_auto_judge_entry entry with
  | Auto_judge_not_requested
  | Auto_judge_pending_unbound ->
    true
  | Auto_judge_finalizable _
  | Auto_judge_ineligible ->
    false
;;

let compare_auto_judge_entries
      (left : Keeper_approval_queue.pending_approval)
      (right : Keeper_approval_queue.pending_approval)
  =
  Int.compare left.sequence right.sequence
;;

let earliest_auto_judge_for_owner ?exclude_id ~base_path ~keeper_name entries =
  entries
  |> List.filter (fun (entry : Keeper_approval_queue.pending_approval) ->
      String.equal entry.audit_base_path base_path
      && String.equal entry.keeper_name keeper_name
      && (match exclude_id with
          | Some id -> not (String.equal id entry.id)
          | None -> true))
  |> List.sort compare_auto_judge_entries
  |> List.hd_opt
;;

let ready_auto_judges_for_owner ?exclude_id ~base_path ~keeper_name entries =
  match
    earliest_auto_judge_for_owner
      ?exclude_id
      ~base_path
      ~keeper_name
      entries
  with
  | Some entry when auto_judge_entry_ready entry -> [ entry ]
  | Some _ | None -> []
;;

type auto_judge_drain_outcome =
  { started_id : string option
  ; failures : (string * string) list
  }

let rec spawn_claimed_auto_judge_entry
      (entry : Keeper_approval_queue.pending_approval)
  =
  let approval_id = entry.id in
  let on_summary summary =
    match resolve_judgment entry ~approval_id summary with
    | Ok (Judgment_finalized | Judgment_skipped) -> ()
    | Error reason ->
      log_auto_resolution_error
        ~keeper_name:entry.keeper_name
        ~approval_id
        reason
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
      ~finally:(fun () -> release_auto_judge entry)
      (fun () ->
         on_failure ~reason ~retryable;
         Error reason)
  in
  match Eio_context.get_root_switch_opt () with
  | Some sw ->
    (try
       match
         Hitl_summary_worker.spawn
           ~sw
           ~entry
           ~on_summary
           ~on_finish:(fun finish_outcome ->
             release_auto_judge entry;
             match finish_outcome with
             | Hitl_summary_worker.Conclusive_terminalization ->
               ignore
                 (drain_auto_judge_owner
                    ~base_path:entry.audit_base_path
                    ~keeper_name:entry.keeper_name
                    ())
             | Hitl_summary_worker.Terminalization_persistence_uncertain ->
               Log.Keeper.error
                 ~keeper_name:entry.keeper_name
                 "Auto Judge owner drain withheld after persistence uncertainty \
                  approval=%s"
                 entry.id)
           ()
       with
       | Ok () -> Ok Started
       | Error reason -> fail_before_worker ~reason ~retryable:false
     with
     | Eio.Cancel.Cancelled _ as exn ->
       release_auto_judge entry;
       raise exn
     | exn ->
       let reason =
         "Auto Judge worker start failed: " ^ Printexc.to_string exn
       in
       fail_before_worker ~reason ~retryable:true)
  | None ->
    fail_before_worker
      ~reason:"Auto Judge unavailable: server root switch is not installed"
      ~retryable:true

and spawn_auto_judge_entry (entry : Keeper_approval_queue.pending_approval) =
  if claim_auto_judge entry
  then spawn_claimed_auto_judge_entry entry
  else Ok Skipped

and retry_auto_judge_entry (entry : Keeper_approval_queue.pending_approval) =
  match Keeper_approval_queue.restart_failed_summary ~id:entry.id with
  | Error error ->
    Error (Keeper_approval_queue.summary_transition_error_to_string error)
  | Ok false -> Ok Retry_skipped
  | Ok true ->
    (match
       drain_auto_judge_owner
         ~base_path:entry.audit_base_path
         ~keeper_name:entry.keeper_name
         ()
     with
     | Error reason -> Error reason
     | Ok outcome ->
       (match List.assoc_opt entry.id outcome.failures, outcome.started_id with
        | Some reason, _ -> Error reason
        | None, Some id when String.equal id entry.id -> Ok Retry_started
        | None, (Some _ | None) -> Ok Retry_queued))

and start_auto_judge approval_id =
  match Keeper_approval_queue.get_pending_entry ~id:approval_id with
  | None -> Ok Skipped
  | Some entry ->
    if not (claim_auto_judge entry)
    then Ok Skipped
    else
        (match Keeper_approval_queue.mark_summary_pending ~id:approval_id with
         | Error error ->
           release_auto_judge entry;
           Error
             (Keeper_approval_queue.summary_transition_error_to_string error)
       | Ok false ->
         release_auto_judge entry;
         Ok Skipped
       | Ok true -> spawn_claimed_auto_judge_entry entry)

and start_auto_judge_entry (entry : Keeper_approval_queue.pending_approval) =
  match Keeper_approval_queue.get_pending_entry ~id:entry.id with
    | None -> Ok Skipped
    | Some current ->
      (match classify_auto_judge_entry current with
       | Auto_judge_not_requested -> start_auto_judge current.id
       | Auto_judge_pending_unbound -> spawn_auto_judge_entry current
       | Auto_judge_finalizable _
       | Auto_judge_ineligible ->
         Ok Skipped)

and drain_auto_judge_owner_queue ?exclude_id ~base_path ~keeper_name () =
  let rec loop failures = function
    | [] -> { started_id = None; failures = List.rev failures }
    | entry :: rest ->
      (match start_auto_judge_entry entry with
       | Ok Started ->
         { started_id = Some entry.id; failures = List.rev failures }
       | Ok Skipped ->
         (match active_auto_judge_for_owner ~base_path ~keeper_name with
          | Some _ -> { started_id = None; failures = List.rev failures }
          | None -> loop failures rest)
       | Error reason ->
         Log.Keeper.error
           ~keeper_name
           "Auto Judge owner drain failed approval=%s: %s"
           entry.id
           reason;
         loop ((entry.id, reason) :: failures) rest)
  in
  Keeper_approval_queue.list_pending_entries ()
  |> ready_auto_judges_for_owner ?exclude_id ~base_path ~keeper_name
  |> loop []

and drain_auto_judge_owner ?exclude_id ~base_path ~keeper_name () =
  match Keeper_gate_mode.read ~base_path with
  | Ok Keeper_gate_mode.Auto_judge ->
    Ok (drain_auto_judge_owner_queue ?exclude_id ~base_path ~keeper_name ())
  | Ok (Keeper_gate_mode.Manual | Keeper_gate_mode.Always_allow) ->
    Ok { started_id = None; failures = [] }
  | Error detail ->
    Log.Keeper.error
      ~keeper_name
      "Auto Judge owner drain unavailable workspace=%s: %s"
      base_path
      detail;
    Error detail

and drain_auto_judges ~base_path =
  match Keeper_gate_mode.read ~base_path with
  | Error detail ->
    Log.Keeper.error
      "Auto Judge workspace drain unavailable workspace=%s: %s"
      base_path
      detail;
    []
  | Ok (Keeper_gate_mode.Manual | Keeper_gate_mode.Always_allow) -> []
  | Ok Keeper_gate_mode.Auto_judge ->
    let owners =
      Keeper_approval_queue.list_pending_entries ()
      |> List.fold_left
           (fun owners (entry : Keeper_approval_queue.pending_approval) ->
              if String.equal entry.audit_base_path base_path
                 && auto_judge_entry_ready entry
              then Auto_judge_owner_set.add (auto_judge_owner entry) owners
              else owners)
           Auto_judge_owner_set.empty
    in
    Auto_judge_owner_set.fold
      (fun (_, keeper_name) started_ids ->
         let outcome =
           drain_auto_judge_owner_queue ~base_path ~keeper_name ()
         in
         match outcome.started_id with
         | Some id -> id :: started_ids
         | None -> started_ids)
      owners
      []
    |> List.rev
;;

type recovered_work =
  | Activate_worker of Keeper_approval_queue.pending_approval
  | Finalize_judgment of
      Keeper_approval_queue.pending_approval
      * Keeper_approval_queue.hitl_context_summary

let recovered_work_for_base_path ~base_path =
  let enabled =
    match Keeper_gate_mode.read ~base_path with
    | Ok Keeper_gate_mode.Auto_judge -> true
    | Ok (Keeper_gate_mode.Manual | Keeper_gate_mode.Always_allow) -> false
    | Error detail ->
      Log.Keeper.error
        "Auto Judge recovery unavailable workspace=%s: %s"
        base_path
        detail;
      false
  in
  if not enabled
  then []
  else (
    let entries = Keeper_approval_queue.list_pending_entries () in
    let owners =
      List.fold_left
        (fun owners (entry : Keeper_approval_queue.pending_approval) ->
           if String.equal entry.audit_base_path base_path
           then Auto_judge_owner_set.add (auto_judge_owner entry) owners
           else owners)
        Auto_judge_owner_set.empty
        entries
    in
    owners
    |> Auto_judge_owner_set.elements
    |> List.filter_map (fun (_, keeper_name) ->
      earliest_auto_judge_for_owner
        ~base_path
        ~keeper_name
        entries)
    |> List.sort compare_auto_judge_entries
    |> List.filter_map (fun entry ->
        match classify_auto_judge_entry entry with
        | Auto_judge_not_requested
        | Auto_judge_pending_unbound ->
          Some (Activate_worker entry)
        | Auto_judge_finalizable
            ({ judgment = (Keeper_approval_queue.Approve | Keeper_approval_queue.Deny); _ }
             as summary) ->
          Some (Finalize_judgment (entry, summary))
        | Auto_judge_finalizable
            { judgment = Keeper_approval_queue.Require_human; _ }
        | Auto_judge_ineligible ->
          None))
;;

let observe_recovered_work kind (entry : Keeper_approval_queue.pending_approval) =
  let event_type, outcome =
    match kind with
    | `Activate_worker ->
      "auto_judge_restart_worker_recovered", "restart_worker_recovered"
    | `Finalize_judgment ->
      "auto_judge_restart_judgment_recovered", "restart_judgment_recovered"
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

let retry_failed_auto_judge ~base_path ~requested_by approval_id =
  match Keeper_approval_queue.get_pending_entry ~id:approval_id with
  | None -> Error ("pending approval not found: " ^ approval_id)
  | Some entry when not (String.equal entry.audit_base_path base_path) ->
    Error ("pending approval not found: " ^ approval_id)
  | Some entry ->
    (match retry_auto_judge_entry entry with
     | Error reason -> Error reason
     | Ok Retry_skipped ->
       Error ("approval summary is not failed or is already active: " ^ approval_id)
     | Ok Retry_queued ->
       Log.Keeper.info
         ~keeper_name:entry.keeper_name
         "auto judge operator retry queued approval=%s operation=%s actor=%s"
         entry.id
         entry.tool_name
         requested_by;
       Ok ()
     | Ok Retry_started ->
       Log.Keeper.info
         ~keeper_name:entry.keeper_name
         "auto judge operator retry started approval=%s operation=%s actor=%s"
         entry.id
         entry.tool_name
         requested_by;
       Otel_metric_store.inc_counter
         Keeper_metrics.(to_string HitlSummaryOutcomes)
         ~labels:[ "outcome", "operator_retry_started" ]
         ();
       Keeper_approval_queue.audit_approval_event
         ~base_path:entry.audit_base_path
         ~event_type:"auto_judge_operator_retry_started"
         ~id:entry.id
         ~keeper_name:entry.keeper_name
         ~tool_name:entry.tool_name
         ?turn_id:entry.turn_id
         ?task_id:entry.task_id
         ?goal_id:entry.goal_id
         ~goal_ids:entry.goal_ids
         ~actor:requested_by
         ();
       Ok ())
;;

let finalize_recovered_judgment
      ~complete_summary_exact_attempt
      (entry : Keeper_approval_queue.pending_approval)
      summary
  =
  match entry.exact_attempt with
  | Keeper_approval_queue.Exact_unbound ->
    resolve_judgment entry ~approval_id:entry.id summary
  | Keeper_approval_queue.Exact_bound
      ({ status = Keeper_approval_queue.Exact_completed; _ } as binding) ->
    (match
       complete_summary_exact_attempt
         ~id:entry.id
         ~input_hash:entry.input_hash
         ~sequence:entry.sequence
         ~slot_id:binding.slot_id
         ~call_id:binding.call_id
         ~plan_fingerprint:binding.plan_fingerprint
         ~request_body_sha256:binding.request_body_sha256
         ~summary
     with
     | Ok
         { Keeper_approval_queue.write_outcome =
             Keeper_approval_queue.Fsync_completed
         ; _
         } ->
       resolve_judgment entry ~approval_id:entry.id summary
     | Ok
         { write_outcome =
             Keeper_approval_queue.Visible_sync_unconfirmed detail
         ; _
         } ->
       Error
         ("exact completion is visible but fsync remains unconfirmed; Gate \
           finalization withheld: "
          ^ detail)
     | Error error ->
       Error
         ("exact completion durability confirmation failed; Gate finalization \
           withheld: "
          ^ Keeper_approval_queue.exact_attempt_error_to_string error))
  | Keeper_approval_queue.Exact_bound _ ->
    Error
      "recovered Auto Judge entry is not an unbound or completed exact judgment"
;;

let resume_persisted_auto_judges_with
      ~complete_summary_exact_attempt
      ~base_path
  =
  let recovered = recovered_work_for_base_path ~base_path in
  let requested = List.length recovered in
  let started_ids, finalized_ids, skipped_ids, failures =
    List.fold_left
      (fun (started_ids, finalized_ids, skipped_ids, failures) work ->
         let entry, result =
           match work with
           | Activate_worker entry ->
             observe_recovered_work `Activate_worker entry;
             entry, `Start (start_auto_judge_entry entry)
             | Finalize_judgment (entry, summary) ->
               observe_recovered_work `Finalize_judgment entry;
               ( entry
               , `Finalize
                   (finalize_recovered_judgment
                      ~complete_summary_exact_attempt
                      entry
                      summary) )
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

let resume_persisted_auto_judges =
  resume_persisted_auto_judges_with
    ~complete_summary_exact_attempt:
      Keeper_approval_queue.complete_summary_exact_attempt
;;

type operator_recovery_report =
  { reopened_ids : string list
  ; started_ids : string list
  ; queued : int
  }

let request_operator_auto_judge_recovery ~base_path =
  match Keeper_gate_mode.read ~base_path with
  | Error detail -> Error detail
  | Ok (Keeper_gate_mode.Manual | Keeper_gate_mode.Always_allow) ->
    Error "operator Auto Judge recovery requires auto_judge mode"
  | Ok Keeper_gate_mode.Auto_judge ->
    (match Hitl_summary_worker.readiness () with
     | Error detail -> Error detail
     | Ok () ->
      (match Keeper_approval_queue.restart_failed_summaries ~base_path with
       | Error error ->
         Error (Keeper_approval_queue.summary_transition_error_to_string error)
       | Ok reopened_ids ->
       let started_ids = drain_auto_judges ~base_path in
       let queued =
         Keeper_approval_queue.list_pending_entries ()
         |> List.fold_left
                (fun count (entry : Keeper_approval_queue.pending_approval) ->
                   if String.equal entry.audit_base_path base_path
                      && auto_judge_entry_ready entry
                   then count + 1
                   else count)
              0
       in
       Ok { reopened_ids; started_ids; queued }))
;;

let defer request reason =
  match submit request with
  | Error error -> Unavailable (Queue_storage_unavailable error)
  | Ok approval_id ->
    let reason =
      match reason with
      | Judge_requested ->
        let drained =
          try
            drain_auto_judge_owner
              ~base_path:request.base_path
              ~keeper_name:request.keeper_name
              ()
          with
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | exn ->
            Error
              ("Auto Judge start failed before worker launch: "
               ^ Printexc.to_string exn)
        in
        (match drained with
         | Error detail -> Auto_judge_unavailable detail
         | Ok outcome ->
           (match List.assoc_opt approval_id outcome.failures with
            | Some detail -> Auto_judge_unavailable detail
            | None -> Judge_requested))
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

let observe_exact_rule_expired request (rule_match : Keeper_approval_queue.rule_match) =
  Log.Keeper.warn
    ~keeper_name:request.keeper_name
    "exact Always Allowed rule %s expired operation=%s; continuing configured Gate mode"
    rule_match.rule_id
    request.operation;
  Keeper_approval_queue.audit_approval_event
    ~base_path:request.base_path
    ~event_type:"gate_exact_rule_expired"
    ~id:(Keeper_approval_queue.generate_id ())
    ~keeper_name:request.keeper_name
    ~tool_name:request.operation
    ?turn_id:(request_turn_id request)
    ?task_id:request.task_id
    ~goal_ids:request.goal_ids
    ~rule_match
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
        | Ok (Keeper_approval_queue.Rule_match_active rule_match) ->
          let source = Exact_always_rule rule_match.rule_id in
          audit_allow
            request
            ~rule_match
            ~decision_source:Keeper_approval_queue.Always_allowed
            source;
          Allow { source }
        | Ok (Keeper_approval_queue.Rule_match_expired rule_match) ->
          observe_exact_rule_expired request rule_match;
          decide_from_selected_mode request mode
        | Ok Keeper_approval_queue.Rule_match_absent ->
          decide_from_selected_mode request mode))
;;

let decide ?cycle_grant ~keeper_always_allow request =
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

module For_testing = struct
  type exact_completion =
    id:string ->
    input_hash:string ->
    sequence:int ->
    slot_id:string ->
    call_id:string ->
    plan_fingerprint:string ->
    request_body_sha256:string ->
    summary:Keeper_approval_queue.hitl_context_summary ->
    ( Keeper_approval_queue.exact_attempt_transition
    , Keeper_approval_queue.exact_attempt_error )
      result

  let auto_judge_entry_ready = auto_judge_entry_ready

  let ready_auto_judges_for_owner ~base_path ~keeper_name entries =
    ready_auto_judges_for_owner ~base_path ~keeper_name entries
  ;;

  let claim_auto_judge = claim_auto_judge
  let release_auto_judge = release_auto_judge

  let resume_persisted_auto_judges_with_exact_completion =
    resume_persisted_auto_judges_with
  ;;
end
