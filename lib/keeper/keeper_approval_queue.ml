(** Durable, nonblocking HITL requests for Keeper external effects. *)

open Keeper_approval_queue_rules_types
open Keeper_approval_queue_rules
open Keeper_approval_queue_projection
open Keeper_approval_queue_result
open Keeper_approval_queue_codec
open Keeper_approval_queue_state
include Keeper_approval_queue_registry
include Keeper_approval_queue_persist
include Keeper_approval_queue_load
include Keeper_approval_queue_grant

(* ── Persistent audit log ────────────────────────────────── *)

let generate_id () = make_generated_id "appr"

let default_continuation_channel () =
  Keeper_continuation_channel.unrouted "no originating connector"
;;

let create_entry
      ~id
      ~sequence
      ~keeper_name
      ~tool_name
      ~input
      ?turn_id
      ~origin
      ?request_context
      ?observation
      ?task_id
      ?goal_id
      ~continuation_channel
      ~audit_base_path
      ()
  =
  let input_hash = Keeper_approval_request_fingerprint.request_fingerprint input in
  { id
  ; keeper_name
  ; tool_name
  ; input_hash
  ; input
  ; sequence
  ; requested_at = Unix.gettimeofday ()
  ; turn_id
  ; origin
  ; request_context
  ; observation
  ; task_id
  ; goal_id
    ; continuation_channel
    ; audit_base_path
    ; summary_status = Summary_not_requested
    ; exact_attempt = Exact_unbound
    ; summary_attempt_disposition = Summary_attempt_ready
    }
;;

(* ── Durable summary-state transitions ───────────────────── *)

(** Read a pending entry by id. Returns [None] if already resolved. *)
let find_pending_entry_unchecked ~id : pending_approval option =
  SMap.find_opt id (Atomic.get pending)
;;

let summary_transition_rejection (entry : pending_approval) =
  match entry.exact_attempt with
  | Exact_unbound -> None
  | Exact_bound binding -> Some (Summary_exact_attempt_bound binding)
;;

let persist_pending_entry_unlocked ~map ~(entry : pending_approval) updated_entry =
  let updated = SMap.add entry.id updated_entry map in
  match
    persist_snapshot_unlocked
      ~base_path:entry.audit_base_path
      ~pending_map:updated
      ~delivery_map:(Atomic.get deliveries)
  with
  | Error _ as error -> error
  | Ok () ->
    Atomic.set pending updated;
    Ok true
;;

let notify_waiting_approval ~source (entry : pending_approval) =
  let report exn =
    Log.Keeper.warn "approval waiting inventory notification failed keeper=%s: %s"
      entry.keeper_name (Printexc.to_string exn) in
  match Keeper_waiting_inventory_broadcast.changed
          ~base_path:entry.audit_base_path ~keeper_name:entry.keeper_name ~source with
  | () -> ()
  | exception (Eio.Cancel.Cancelled _ as exn) ->
    (* The queue is already committed. A subscriber's own cancellation is
       observational; the calling fiber's actual cancellation still wins. *)
    (match Fs_compat.execution_context () with
     | Eio_fiber -> Eio.Fiber.check ()
     | Non_eio -> ());
    report exn
  | exception exn -> report exn
;;

let publish_summary_update ~id =
  let now = Time_compat.now () in
  match find_pending_entry_unchecked ~id with
  | Some updated ->
    notify_waiting_approval ~source:Approval_detail updated;
    record_summary_updated ~now updated
  | None -> ()
;;

let publish_summary_transition ~id = function
  | Ok true ->
    publish_summary_update ~id;
    Ok true
  | Ok false -> Ok false
  | Error error -> Error error
;;

let publish_exact_attempt_transition ~id = function
  | Ok ({ changed = true; _ } as transition) ->
    publish_summary_update ~id;
    Ok transition
  | Ok transition -> Ok transition
  | Error error -> Error error
;;

let exact_attempt_entry_unlocked map (candidate : exact_attempt_binding) =
  match SMap.find_opt candidate.approval_id map with
  | None ->
    Error
      (Exact_attempt_rejected
         (Exact_attempt_not_found candidate.approval_id))
  | Some entry
    when not
           (String.equal entry.input_hash candidate.input_hash
            && Int.equal entry.sequence candidate.sequence) ->
    Error
      (Exact_attempt_rejected
         (Exact_attempt_key_mismatch
            { approval_id = candidate.approval_id
            ; input_hash = candidate.input_hash
            ; sequence = candidate.sequence
            }))
  | Some entry -> Ok entry
;;

let persist_exact_attempt_entry_unlocked
      ~save_file_atomic_strict_staged
      ~write_mode
      ~changed
      ~map
      ~(entry : pending_approval)
      updated_entry
  =
  let updated = SMap.add entry.id updated_entry map in
  match
    persist_snapshot_exact_unlocked
      ~save_file_atomic_strict_staged
      ~write_mode
      ~base_path:entry.audit_base_path
      ~pending_map:updated
      ~delivery_map:(Atomic.get deliveries)
  with
  | Error error -> Error (Exact_attempt_storage_error error)
  | Ok write_outcome ->
    Atomic.set pending updated;
    Ok { changed; write_outcome }
;;

let bind_summary_exact_attempt_with
      ~write_mode
      ~save_file_atomic_strict_staged
      ~id
      ~input_hash
      ~sequence
      ~slot_id
      ~call_id
      ~plan_fingerprint
      ~request_body_sha256
  =
  let result =
    match
      validate_exact_attempt_candidate
        ~id
        ~input_hash
        ~sequence
        ~slot_id
        ~call_id
        ~plan_fingerprint
        ~request_body_sha256
    with
    | Error _ as error -> error
    | Ok candidate ->
      with_pending_store_lock (fun () ->
        let map = Atomic.get pending in
        match exact_attempt_entry_unlocked map candidate with
        | Error _ as error -> error
        | Ok entry ->
          (match Keeper_approval_queue_exact_transition.bind ~candidate entry with
           | Error _ as error -> error
           | Ok transition ->
             persist_exact_attempt_entry_unlocked
               ~save_file_atomic_strict_staged
               ~write_mode
               ~changed:transition.changed
               ~map
               ~entry
               transition.updated_entry))
  in
  publish_exact_attempt_transition ~id result
;;

let bind_summary_exact_attempt =
  bind_summary_exact_attempt_with
    ~write_mode:Append_rows
    ~save_file_atomic_strict_staged:Fs_compat.save_file_atomic_strict_staged
;;

let release_summary_exact_attempt_before_dispatch_with
      ~write_mode
      ~save_file_atomic_strict_staged
      ~id
      ~input_hash
      ~sequence
      ~slot_id
      ~call_id
      ~plan_fingerprint
      ~request_body_sha256
  =
  let result =
    match
      validate_exact_attempt_candidate
        ~id
        ~input_hash
        ~sequence
        ~slot_id
        ~call_id
        ~plan_fingerprint
        ~request_body_sha256
    with
    | Error _ as error -> error
    | Ok candidate ->
      with_pending_store_lock (fun () ->
        let map = Atomic.get pending in
        match exact_attempt_entry_unlocked map candidate with
        | Error _ as error -> error
        | Ok entry ->
          (match Keeper_approval_queue_exact_transition.release ~candidate entry with
           | Error _ as error -> error
           | Ok transition ->
             persist_exact_attempt_entry_unlocked
               ~save_file_atomic_strict_staged
               ~write_mode
               ~changed:transition.changed
               ~map
               ~entry
               transition.updated_entry))
  in
  publish_exact_attempt_transition ~id result
;;

let release_summary_exact_attempt_before_dispatch =
  release_summary_exact_attempt_before_dispatch_with
    ~write_mode:Append_rows
    ~save_file_atomic_strict_staged:Fs_compat.save_file_atomic_strict_staged
;;

let quarantine_summary_exact_attempt_with
      ~write_mode
      ~save_file_atomic_strict_staged
      ~id
      ~input_hash
      ~sequence
      ~slot_id
      ~call_id
      ~plan_fingerprint
      ~request_body_sha256
      ~cause
  =
  let result =
    match
      validate_exact_attempt_candidate
        ~id
        ~input_hash
        ~sequence
        ~slot_id
        ~call_id
        ~plan_fingerprint
        ~request_body_sha256
    with
    | Error _ as error -> error
    | Ok candidate ->
      with_pending_store_lock (fun () ->
        let map = Atomic.get pending in
        match exact_attempt_entry_unlocked map candidate with
        | Error _ as error -> error
        | Ok entry ->
          (match Keeper_approval_queue_exact_transition.quarantine ~candidate ~cause entry with
           | Error _ as error -> error
           | Ok transition ->
             persist_exact_attempt_entry_unlocked
               ~save_file_atomic_strict_staged
               ~write_mode
               ~changed:transition.changed
               ~map
               ~entry
               transition.updated_entry))
  in
  publish_exact_attempt_transition ~id result
;;

let quarantine_summary_exact_attempt =
  quarantine_summary_exact_attempt_with
    ~write_mode:Append_rows
    ~save_file_atomic_strict_staged:Fs_compat.save_file_atomic_strict_staged
;;

let complete_summary_exact_attempt_with
      ~write_mode
      ~save_file_atomic_strict_staged
      ~id
      ~input_hash
      ~sequence
      ~slot_id
      ~call_id
      ~plan_fingerprint
      ~request_body_sha256
      ~summary
  =
  let result =
    match
      validate_exact_attempt_candidate
        ~id
        ~input_hash
        ~sequence
        ~slot_id
        ~call_id
        ~plan_fingerprint
        ~request_body_sha256
    with
    | Error _ as error -> error
    | Ok candidate ->
      with_pending_store_lock (fun () ->
        let map = Atomic.get pending in
        match exact_attempt_entry_unlocked map candidate with
        | Error _ as error -> error
        | Ok entry ->
          (match Keeper_approval_queue_exact_transition.complete ~candidate ~summary entry with
           | Error _ as error -> error
           | Ok transition ->
             persist_exact_attempt_entry_unlocked
               ~save_file_atomic_strict_staged
               ~write_mode
               ~changed:transition.changed
               ~map
               ~entry
               transition.updated_entry))
  in
  publish_exact_attempt_transition ~id result
;;

let complete_summary_exact_attempt =
  complete_summary_exact_attempt_with
    ~write_mode:Append_rows
    ~save_file_atomic_strict_staged:Fs_compat.save_file_atomic_strict_staged
;;

let mark_summary_pending ~id =
  let result =
    with_pending_store_lock (fun () ->
      let map = Atomic.get pending in
      match SMap.find_opt id map with
      | None -> Ok false
      | Some entry ->
        (match summary_transition_rejection entry with
         | Some rejection -> Error (Summary_transition_rejected rejection)
         | None ->
           (match entry.summary_status with
            | Summary_not_requested ->
              persist_pending_entry_unlocked
                ~map
                ~entry
                { entry with summary_status = Summary_pending }
              |> Result.map_error (fun error ->
                Summary_transition_storage_error error)
            | Summary_pending
            | Summary_available _
            | Summary_failed _ ->
              Ok false)))
  in
  publish_summary_transition ~id result
;;

let publish_summary_attempt_transition ~id = function
  | Ok true ->
    publish_summary_update ~id;
    Ok true
  | Ok false -> Ok false
  | Error error -> Error error
;;

let transition_summary_attempt
      ~base_path
      ~id
      ~input_hash
      ~sequence
      update
  =
  let result =
    with_pending_store_lock (fun () ->
      let map = Atomic.get pending in
      match SMap.find_opt id map with
      | None ->
        Error (Exact_attempt_rejected (Exact_attempt_not_found id))
      | Some entry
        when not (String.equal entry.audit_base_path base_path) ->
        Error (Exact_attempt_rejected (Exact_attempt_not_found id))
      | Some entry
        when not
               (String.equal entry.input_hash input_hash
                && Int.equal entry.sequence sequence) ->
        Error
          (Exact_attempt_rejected
             (Exact_attempt_key_mismatch
                { approval_id = id; input_hash; sequence }))
      | Some entry ->
        (match update entry with
         | None -> Ok false
         | Some updated_entry ->
           persist_pending_entry_unlocked
             ~map
             ~entry
             updated_entry
           |> Result.map_error (fun error ->
             Exact_attempt_storage_error error)))
  in
  publish_summary_attempt_transition ~id result
;;

let mark_summary_attempt_identity_unbound
      ~base_path
      ~id
      ~input_hash
      ~sequence
  =
  transition_summary_attempt
    ~base_path
    ~id
    ~input_hash
    ~sequence
    (fun (entry : pending_approval) ->
       match
         entry.summary_status,
         entry.exact_attempt,
         entry.summary_attempt_disposition
       with
       | Summary_pending, Exact_unbound,
         ( Summary_attempt_ready
         | Summary_attempt_pre_worker_unavailable
             { reason_code = Summary_pre_worker_start_reserved; _ } ) ->
         Some
           { entry with
             summary_attempt_disposition =
               Summary_attempt_identity_unbound
           }
       | Summary_pending, Exact_unbound,
         Summary_attempt_identity_unbound ->
         Some entry
       | ( Summary_pending
         , Exact_unbound
         , Summary_attempt_pre_worker_unavailable
             { reason_code =
                 ( Summary_pre_worker_auto_judge_unavailable
                 | Summary_pre_worker_mode_state_invalid )
             ; _
             } )
       | ( Summary_pending
         , Exact_unbound
         , ( Summary_attempt_in_flight
           | Summary_attempt_persistence_uncertain
           | Summary_attempt_settled ) )
       | (Summary_pending, Exact_bound _, _)
       | ( ( Summary_not_requested
           | Summary_available _
           | Summary_failed _ )
         , _
         , _ ) -> None)
;;

let mark_summary_attempt_persistence_uncertain
      ~base_path
      ~id
      ~input_hash
      ~sequence
  =
  transition_summary_attempt
    ~base_path
    ~id
    ~input_hash
    ~sequence
    (fun (entry : pending_approval) ->
       match
         entry.summary_status,
         entry.summary_attempt_disposition
       with
       | Summary_not_requested, _
       | _, Summary_attempt_persistence_uncertain ->
         None
       | ( (Summary_pending | Summary_available _ | Summary_failed _)
         , ( Summary_attempt_ready
           | Summary_attempt_in_flight
           | Summary_attempt_identity_unbound
           | Summary_attempt_pre_worker_unavailable _
           | Summary_attempt_settled ) ) ->
         Some
           { entry with
             summary_attempt_disposition =
               Summary_attempt_persistence_uncertain
           })
;;

let mark_summary_attempt_pre_worker_unavailable
      ~base_path
      ~id
      ~input_hash
      ~sequence
      ~reason_code
      ~operator_detail
  =
  let trimmed_detail = String.trim operator_detail in
  if
    String.equal trimmed_detail ""
    || not (String.equal trimmed_detail operator_detail)
  then
    Error
      (Exact_attempt_rejected
         (Exact_attempt_invalid_identity "operator_detail"))
  else
    let blocked =
      Summary_attempt_pre_worker_unavailable
        { reason_code; operator_detail }
    in
    transition_summary_attempt
      ~base_path
      ~id
      ~input_hash
      ~sequence
      (fun (entry : pending_approval) ->
         match
           entry.summary_status,
           entry.exact_attempt,
           entry.summary_attempt_disposition
         with
         | (Summary_not_requested | Summary_pending), Exact_unbound,
           Summary_attempt_ready ->
           Some
             { entry with
               summary_attempt_disposition = blocked
             }
         | (Summary_not_requested | Summary_pending), Exact_unbound,
           Summary_attempt_pre_worker_unavailable
             { reason_code = Summary_pre_worker_start_reserved; _ } ->
           Some
             { entry with
               summary_attempt_disposition = blocked
             }
         | (Summary_not_requested | Summary_pending), Exact_unbound,
           current
           when current = blocked ->
           Some entry
         | ((Summary_not_requested | Summary_pending), Exact_bound _, _)
         | ((Summary_available _ | Summary_failed _), _, _)
         | (Summary_not_requested, Exact_unbound, Summary_attempt_pre_worker_unavailable {reason_code=(Summary_pre_worker_auto_judge_unavailable| Summary_pre_worker_mode_state_invalid); _ })
         | (Summary_not_requested, Exact_unbound, (Summary_attempt_in_flight|Summary_attempt_identity_unbound| Summary_attempt_persistence_uncertain|Summary_attempt_settled))
         | (Summary_pending, Exact_unbound, Summary_attempt_pre_worker_unavailable {reason_code=(Summary_pre_worker_auto_judge_unavailable| Summary_pre_worker_mode_state_invalid); _ })
         | (Summary_pending, Exact_unbound, (Summary_attempt_in_flight|Summary_attempt_identity_unbound| Summary_attempt_persistence_uncertain|Summary_attempt_settled)) -> None)
;;

let release_orphaned_start_reservation ~base_path ~id ~input_hash ~sequence =
  (* Boot-recovery reclaim of a start reservation that a hard process restart
     orphaned. [mark_summary_attempt_pre_worker_unavailable] writes the durable
     [Summary_pre_worker_start_reserved] row; the graceful in-memory settle to
     [Summary_attempt_identity_unbound] (worker terminates before binding) never
     runs when the whole process dies in the reserve->bind window, so the row is
     stranded. This is that arm's exact reverse: an unbound start reservation
     returns to [Summary_attempt_ready] so boot recovery re-activates a worker.
     Distinct from [reserve_summary_attempt_retry], the operator path that never
     reclaims a start reservation. Any other row shape is left untouched. *)
  transition_summary_attempt
    ~base_path
    ~id
    ~input_hash
    ~sequence
    (fun (entry : pending_approval) ->
       match
         entry.summary_status,
         entry.exact_attempt,
         entry.summary_attempt_disposition
       with
       | (Summary_not_requested | Summary_pending), Exact_unbound,
         Summary_attempt_pre_worker_unavailable
           { reason_code = Summary_pre_worker_start_reserved; _ } ->
         Some { entry with summary_attempt_disposition = Summary_attempt_ready }
       | ( (Summary_not_requested | Summary_pending)
         , Exact_unbound
         , Summary_attempt_pre_worker_unavailable
             { reason_code =
                 ( Summary_pre_worker_auto_judge_unavailable
                 | Summary_pre_worker_mode_state_invalid )
             ; _
             } )
       | ( (Summary_not_requested | Summary_pending)
         , Exact_unbound
         , ( Summary_attempt_ready
           | Summary_attempt_in_flight
           | Summary_attempt_identity_unbound
           | Summary_attempt_persistence_uncertain
           | Summary_attempt_settled ) )
       | ((Summary_not_requested | Summary_pending), Exact_bound _, _)
       | ((Summary_available _ | Summary_failed _), _, _) -> None)
;;

let reserve_summary_attempt_retry
      ~base_path
      ~id
      ~input_hash
      ~sequence
      ~expected_exact_attempt
      ~expected_disposition
      ~requested_by
  =
  let exact_attempt_state_equal left right =
    match left, right with
    | Exact_unbound, Exact_unbound -> true
    | Exact_bound left, Exact_bound right ->
      exact_attempt_identity_matches left right
      && left.status = right.status
    | Exact_unbound, Exact_bound _
    | Exact_bound _, Exact_unbound ->
      false
  in
  if String.trim requested_by = ""
  then
    Error
      (Exact_attempt_rejected
         (Exact_attempt_invalid_identity "requested_by"))
  else
    let reserved =
      Summary_attempt_pre_worker_unavailable
        { reason_code = Summary_pre_worker_start_reserved
        ; operator_detail = summary_attempt_start_reserved_operator_detail
        }
    in
    transition_summary_attempt
      ~base_path
      ~id
      ~input_hash
      ~sequence
      (fun (entry : pending_approval) ->
         if
           entry.summary_attempt_disposition <> expected_disposition
           || not
                (exact_attempt_state_equal
                   entry.exact_attempt
                   expected_exact_attempt)
         then None
         else
           match
             entry.summary_attempt_disposition,
             entry.exact_attempt,
             entry.summary_status
           with
           | Summary_attempt_identity_unbound, Exact_unbound,
             Summary_pending
           | Summary_attempt_persistence_uncertain, Exact_unbound,
             Summary_pending ->
             Some
               { entry with
                 summary_status = Summary_pending
               ; summary_attempt_disposition = reserved
               }
           | Summary_attempt_pre_worker_unavailable
               { reason_code =
                   ( Summary_pre_worker_auto_judge_unavailable
                   | Summary_pre_worker_mode_state_invalid )
               ; _
               },
             Exact_unbound,
             (Summary_not_requested | Summary_pending) ->
             Some
               { entry with
                 summary_status = Summary_pending
               ; summary_attempt_disposition = reserved
               }
           | Summary_attempt_persistence_uncertain,
             Exact_bound
               { status = Exact_released_recovery_required; _ },
             Summary_pending ->
             Some
               { entry with
                 exact_attempt = Exact_unbound
               ; summary_status = Summary_pending
               ; summary_attempt_disposition = reserved
               }
           | ( Summary_attempt_persistence_uncertain
             , Exact_bound { status = Exact_released_recovery_required; _ }
             , (Summary_not_requested | Summary_available _ | Summary_failed _) )
           | ( Summary_attempt_persistence_uncertain
             , Exact_bound
                 { status =
                     ( Exact_dispatch_uncertain
                     | Exact_released_before_dispatch
                     | Exact_restart_quarantined
                     | Exact_completed
                     | Exact_quarantined _ )
                 ; _
                 }
             , _ )
           | ( Summary_attempt_persistence_uncertain
             , Exact_unbound
             , (Summary_not_requested | Summary_available _ | Summary_failed _) )
           | ( Summary_attempt_pre_worker_unavailable
                 { reason_code =
                     ( Summary_pre_worker_auto_judge_unavailable
                     | Summary_pre_worker_mode_state_invalid )
                 ; _
                 }
             , Exact_unbound
             , (Summary_available _ | Summary_failed _) )
           | ( Summary_attempt_pre_worker_unavailable
                 { reason_code =
                     ( Summary_pre_worker_auto_judge_unavailable
                     | Summary_pre_worker_mode_state_invalid )
                 ; _
                 }
             , Exact_bound _
             , _ )
           | ( Summary_attempt_pre_worker_unavailable
                 { reason_code = Summary_pre_worker_start_reserved; _ }
             , _
             , _ )
           | ( Summary_attempt_identity_unbound
             , Exact_unbound
             , (Summary_not_requested | Summary_available _ | Summary_failed _) )
           | (Summary_attempt_identity_unbound, Exact_bound _, _)
           | ( ( Summary_attempt_ready
               | Summary_attempt_in_flight
               | Summary_attempt_settled )
             , _
             , _ ) -> None)
;;

let record_resolution_delivery_failure ~keeper_name ~approval_id reason =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string ApprovalQueueFailures)
    ~labels:
      [ "keeper", keeper_name
      ; ( "site"
        , Keeper_approval_queue_failure_site.(to_label Resolution_delivery) )
      ]
    ();
  Log.Keeper.error
    ~keeper_name
    "hitl resolution delivery failed approval=%s: %s"
    approval_id
    reason
;;

let signal_resolution_after_commit ~base_path ~keeper_name ~approval_id =
  try
    let outcome =
      Keeper_registry.wakeup_running
        ~intent:Keeper_registry.Hitl_resolution
        ~base_path
        keeper_name
    in
    let outcome_label, detail =
      match outcome with
      | Keeper_registry.Signaled -> "signaled", "running"
      | Keeper_registry.Deferred_unregistered ->
        "deferred_unregistered", "unregistered"
      | Keeper_registry.Deferred_not_running phase ->
        "deferred_not_running", Keeper_state_machine.phase_to_string phase
      | Keeper_registry.Deferred_lifecycle denial ->
        ( "deferred_lifecycle"
        , Keeper_lifecycle_admission.autonomous_denial_to_wire denial )
    in
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ApprovalResolutionSignal)
      ~labels:[ "keeper", keeper_name; "outcome", outcome_label ]
      ();
    Log.Keeper.info
      ~keeper_name
      "hitl resolution committed approval=%s signal=%s phase=%s"
      approval_id
      outcome_label
      detail
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ApprovalQueueFailures)
      ~labels:
        [ "keeper", keeper_name
        ; "site", Keeper_approval_queue_failure_site.(to_label Resolution_signal)
        ]
      ();
    Log.Keeper.error
      ~keeper_name
      "hitl resolution signal failed after durable commit approval=%s: %s"
      approval_id
      (Printexc.to_string exn)
;;

let commit_keeper_approval_resolution
    ~base_path ~keeper_name ~approval_id ~decision
    ~(channel : Keeper_continuation_channel.t) =
  match
    try
      Keeper_registry_event_queue.enqueue_hitl_resolution_durable_result
        ~base_path
        ~keeper_name
        ~approval_id
        ~decision
        ~channel
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn ->
      Error
        (Keeper_registry_event_queue.Hitl_enqueue_failed
           (Printexc.to_string exn))
  with
  | Ok () -> Ok ()
  | Error Keeper_registry_event_queue.Hitl_recipient_absent as error ->
    (* No Keeper exists with the addressed name. That is a terminal
       disposition the caller settles, not a delivery failure, so it gets
       neither the failure counter nor an ERROR log here. *)
    error
  | Error (Keeper_registry_event_queue.Hitl_enqueue_failed reason) as error ->
    record_resolution_delivery_failure ~keeper_name ~approval_id reason;
    error
;;

let hitl_resolution_decision_of_approval_decision = function
  | Decision.Approve -> Keeper_event_queue.Hitl_approved
  | Decision.Reject rationale -> Keeper_event_queue.Hitl_rejected rationale
;;

let deliver_resolution ~base_path (entry : pending_approval) decision =
  commit_keeper_approval_resolution
    ~base_path
    ~keeper_name:entry.keeper_name
    ~approval_id:entry.id
    ~decision:(hitl_resolution_decision_of_approval_decision decision)
    ~channel:entry.continuation_channel
;;

let ensure_resolution_chat_projection =
  Keeper_approval_queue_projection.ensure_resolution_chat_projection
let ensure_replay_chat_projection =
  Keeper_approval_queue_projection.ensure_replay_chat_projection
let continuation_settled_chat_projection_present =
  Keeper_approval_queue_projection.continuation_settled_chat_projection_present

type continuation_projection_result =
  Keeper_approval_queue_result.continuation_projection_result =
  | Continuation_projection_recorded
  | Continuation_projection_not_ready

let settled_continuation_readiness
      ~base_path ~(resolution : Keeper_event_queue.hitl_resolution) =
  match resolution.decision with
  | Keeper_event_queue.Hitl_rejected _ -> Ok (Continuation_ready None)
  | Keeper_event_queue.Hitl_approved ->
    (match approved_resolution_delivery ~base_path ~id:resolution.approval_id with
     | Ok delivery -> Ok (continuation_readiness_of_delivery delivery)
     | Error error -> Error (grant_error_to_string error))
;;

let ensure_settled_continuation_chat_projection
      ~base_path ~keeper_name ~(resolution : Keeper_event_queue.hitl_resolution) =
  Result.bind (settled_continuation_readiness ~base_path ~resolution)
    (fun readiness ->
      Keeper_approval_queue_projection.record_settled_continuation
        ~base_path ~keeper_name ~approval_id:resolution.approval_id ~readiness)
;;

let record_native_continuation_delivery ~base_path ~keeper_name
    ~(resolution : Keeper_event_queue.hitl_resolution) =
  let tool_name = match resolution.decision with
    | Keeper_event_queue.Hitl_rejected _ -> Ok None
    | Keeper_event_queue.Hitl_approved ->
      (match approved_resolution_delivery ~base_path ~id:resolution.approval_id with
       | Ok {request; _} when request.keeper_name = keeper_name -> Ok (Some request.tool_name)
       | Ok _ -> Error "native continuation belongs to another Keeper"
       | Error error -> Error (grant_error_to_string error)) in
  Result.bind tool_name (fun tool_name ->
    Keeper_approval_queue_projection.record_settled_continuation
      ~base_path ~keeper_name ~approval_id:resolution.approval_id
      ~readiness:(Continuation_ready tool_name))
;;

let ensure_failed_continuation_chat_projection
      ~base_path ~keeper_name ~(resolution : Keeper_event_queue.hitl_resolution)
      ~(route : Keeper_runtime_failure_route.route) =
  Result.bind (settled_continuation_readiness ~base_path ~resolution)
    (fun readiness ->
      Keeper_approval_queue_projection.record_failed_continuation
        ~base_path ~keeper_name ~approval_id:resolution.approval_id ~readiness ~route)
;;

(* ── Nonblocking submission ───────────────────────────────── *)

let submit_pending
      ~keeper_name
      ~tool_name
      ~input
      ~call_summary
      ~base_path
      ?turn_id
      ~origin
      ?request_context
      ?observation
      ?task_id
      ?goal_id
      ?continuation_channel
      ()
  : (pending_submission, storage_error) result
  =
  let input_hash = Keeper_approval_request_fingerprint.request_fingerprint input in
  let continuation_channel =
    Option.value continuation_channel ~default:(default_continuation_channel ())
  in
  let stored =
    with_pending_store_lock (fun () ->
      let map = Atomic.get pending in
      match next_sequence_lifecycle ~base_path with
      | Uninstalled ->
        Error
          { path = pending_store_path ~base_path
          ; reason =
              "gate_pending store is not installed; submit requires a completed install"
          }
      | Unavailable error -> Error error
      | Ready sequence ->
        (match
           find_pending_id_in_map
             map
             ~base_path
             ~keeper_name
             ~tool_name
             ~input_hash
             ~origin
             ~task_id
             ~goal_id
             ~continuation_channel
         with
         | Some id -> Ok (`Deduplicated id)
         | None ->
           (match
              find_unconsumed_grant_id_in_deliveries
                (Atomic.get deliveries)
                ~base_path
                ~keeper_name
                ~tool_name
                ~input_hash
                ~origin
                ~task_id
                ~goal_id
                ~continuation_channel
            with
            | Some id -> Ok (`Folded_onto_unconsumed_grant id)
            | None ->
           let id = generate_id () in
           if sequence = max_int
           then
             Error
               { path = pending_store_path ~base_path
               ; reason = "approval sequence exhausted its integer representation"
               }
           else
             let entry =
               create_entry
                 ~id
                 ~sequence
                 ~keeper_name
                 ~tool_name
                 ~input
                 ?turn_id
                 ~origin
                 ?request_context
                 ?observation
                 ?task_id
                 ?goal_id
                 ~continuation_channel
                 ~audit_base_path:base_path
                 ()
          in
          let updated = SMap.add id entry map in
          let following_sequence = sequence + 1 in
          (match
             persist_snapshot_with_sequence_unlocked
               ~base_path
               ~next_sequence:following_sequence
               ~pending_map:updated
               ~delivery_map:(Atomic.get deliveries)
           with
           | Error error -> Error error
           | Ok () ->
             Atomic.set pending updated;
             Atomic.set
               next_sequences
               (SMap.add base_path following_sequence (Atomic.get next_sequences));
             Ok (`Created entry)))))
  in
  match stored with
  | Error _ as error -> error
  | Ok (`Deduplicated approval_id) ->
    Ok { approval_id; disposition = Pending_deduplicated }
  | Ok (`Folded_onto_unconsumed_grant approval_id) ->
    Ok { approval_id; disposition = Folded_onto_unconsumed_grant }
  | Ok (`Created entry) ->
    notify_waiting_approval ~source:Approval_count entry;
    let audit_receipt = record_pending ~call_summary entry in
    Ok
      { approval_id = entry.id
      ; disposition = Pending_created audit_receipt
      }
;;

(* ── Resolve (operator action) ────────────────────────────── *)

type resolve_error =
  | Not_found of string
  | Already_resolved of string
  | Delivery_failed of
      { approval_id : string
      ; reason : string
      }
  | Persistence_failed of
      { approval_id : string
      ; storage_error : storage_error
      }

let resolve_error_to_string = function
  | Not_found id -> Printf.sprintf "approval %s not found" id
  | Already_resolved id -> Printf.sprintf "approval %s already resolved" id
  | Delivery_failed { approval_id; reason } ->
    Printf.sprintf "approval %s resolution delivery failed: %s" approval_id reason
  | Persistence_failed { approval_id; storage_error } ->
    Printf.sprintf
      "approval %s queue persistence failed: %s"
      approval_id
      (storage_error_to_string storage_error)
;;

module Resolution_claims = Set_util.StringSet

let resolution_claims : Resolution_claims.t Atomic.t =
  Atomic.make Resolution_claims.empty
;;

let rec claim_resolution id =
  let claims = Atomic.get resolution_claims in
  if Resolution_claims.mem id claims
  then false
  else
    let claimed = Resolution_claims.add id claims in
    if Atomic.compare_and_set resolution_claims claims claimed
    then true
    else claim_resolution id
;;

let release_resolution_claim id =
  atomic_update resolution_claims (fun claims -> Resolution_claims.remove id claims)
;;

let resolve_store_readiness_error ~base_path ~approval_id =
  match next_sequence_lifecycle ~base_path with
  | Ready _ -> Ok ()
  | Unavailable storage_error ->
    Error (Persistence_failed { approval_id; storage_error })
  | Uninstalled ->
    let storage_error =
      { path = pending_store_path ~base_path
      ; reason =
          "gate_pending store is not installed; resolution requires a completed install"
      }
    in
    Error (Persistence_failed { approval_id; storage_error })
;;

type resolution_target =
  | Pending_resolution of pending_approval
  | Journaled_resolution of persisted_delivery

(* Both maps and store readiness are one observation. Callers hold the queue
   authority lock; no callback, audit append or delivery runs in this region. *)
let resolution_target_unlocked ~base_path ~id =
  match resolve_store_readiness_error ~base_path ~approval_id:id with
  | Error _ as error -> error
  | Ok () ->
    (match SMap.find_opt id (Atomic.get pending) with
     | Some entry when String.equal entry.audit_base_path base_path ->
       Ok (Pending_resolution entry)
     | Some _ -> Error (Not_found id)
     | None ->
       (match SMap.find_opt id (Atomic.get deliveries) with
        | Some delivery when String.equal delivery.entry.audit_base_path base_path ->
          Ok (Journaled_resolution delivery)
        | Some _ | None -> Error (Not_found id)))
;;

type prepared_resolution =
  | Newly_journaled of persisted_delivery
  | Previously_journaled of persisted_delivery

let journal_resolution ~base_path ~id ~decision ~source ~remember_rule ~rule_expires_at ~created_by =
  with_pending_store_lock (fun () ->
    match resolution_target_unlocked ~base_path ~id with
    | Error _ as error -> error
    | Ok (Journaled_resolution delivery) -> Ok (Previously_journaled delivery)
    | Ok (Pending_resolution entry) ->
      let open Result.Syntax in
      let* resolution_sequence =
        match next_sequence_lifecycle ~base_path with
        | Ready sequence when sequence < max_int -> Ok sequence
        | Ready _ -> Error (Persistence_failed { approval_id = id; storage_error =
            { path = pending_store_path ~base_path
            ; reason = "approval sequence exhausted its integer representation" } })
        | Unavailable storage_error -> Error (Persistence_failed { approval_id = id; storage_error })
        | Uninstalled -> Error (Persistence_failed { approval_id = id; storage_error =
            { path = pending_store_path ~base_path; reason = "approval store is not installed" } })
      in
      let remember_rule =
        match decision with
        | Decision.Approve -> remember_rule
        | Decision.Reject _ -> false
      in
      let rule_expires_at = if remember_rule then rule_expires_at else None in
      let delivery =
        { entry
        ; resolution_sequence
        ; decision
        ; source
        ; remember_rule
        ; rule_expires_at
        ; created_by
        ; grant_consumed = false
        ; replay_outcome = None
        }
      in
      let updated_pending = SMap.remove id (Atomic.get pending) in
      let updated_deliveries = SMap.add id delivery (Atomic.get deliveries) in
      (match
         persist_snapshot_with_sequence_unlocked
           ~base_path
           ~next_sequence:(resolution_sequence + 1)
           ~pending_map:updated_pending
           ~delivery_map:updated_deliveries
       with
       | Error storage_error ->
         Error (Persistence_failed { approval_id = id; storage_error })
       | Ok () ->
         Atomic.set next_sequences
           (SMap.add base_path (resolution_sequence + 1) (Atomic.get next_sequences));
         Atomic.set pending updated_pending;
         Atomic.set deliveries updated_deliveries;
         Ok (Newly_journaled delivery)))
;;

let remove_delivery_from_store delivery =
  with_pending_store_lock (fun () ->
    let delivery_map = Atomic.get deliveries in
    let updated_deliveries = SMap.remove delivery.entry.id delivery_map in
    match
      persist_snapshot_unlocked
        ~base_path:delivery.entry.audit_base_path
        ~pending_map:(Atomic.get pending)
        ~delivery_map:updated_deliveries
    with
    | Error _ as error -> error
    | Ok () ->
      Atomic.set deliveries updated_deliveries;
      Ok ())
;;

let approval_decision_equal left right =
  match left, right with
  | Decision.Approve, Decision.Approve -> true
  | Decision.Reject left, Decision.Reject right -> String.equal left right
  | (Decision.Approve | Decision.Reject _),
    (Decision.Approve | Decision.Reject _) ->
    false
;;

let remember_rule_for_entry ~base_path ~resolution_sequence ?created_by ?rule_expires_at
      (entry : pending_approval) =
  try
    match
      Keeper_approval_queue_rules.upsert_rule
        ~base_path
        ~keeper_name:entry.keeper_name
        ~tool_name:entry.tool_name
        ~input:entry.input
        ?created_by
        ~source_approval_id:entry.id
        ~resolution_sequence
        ~expires_at:rule_expires_at
        ()
    with
    | Ok (Keeper_approval_queue_rules.Already_applied rule
         | Keeper_approval_queue_rules.Superseded rule) -> Ok (rule, [])
    | Ok (Keeper_approval_queue_rules.Applied { rule; disposition }) ->
      let audit_receipts =
        match disposition with
        | Keeper_approval_queue_rules.Created ->
          [ Keeper_approval.Audit.record_rule_created ~base_path rule ]
        | Keeper_approval_queue_rules.Existing -> []
        | Keeper_approval_queue_rules.Renewed { previous_expires_at } ->
          [ Keeper_approval.Audit.record_rule_renewed
              ~base_path
              ?renewed_by:created_by
              ~source_approval_id:entry.id
              ~previous_expires_at
              rule ]
      in
      Ok (Some rule, audit_receipts)
    | Error reason -> Error reason
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    let reason = Printexc.to_string exn in
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ApprovalQueueFailures)
      ~labels:
        [ "keeper", entry.keeper_name
        ; "site", Keeper_approval_queue_failure_site.(to_label Remember_rule)
        ]
      ();
    Log.Keeper.warn
      "approval_queue: remember rule failed id=%s err=%s"
      entry.id
      reason;
    Error
      ({ path = rules_path ~base_path ()
       ; reason
       }
       : rule_store_error)
;;

let remember_rule_for_delivery delivery =
  match delivery.decision, delivery.remember_rule with
  | Decision.Approve, true ->
    (match
       remember_rule_for_entry
         ~base_path:delivery.entry.audit_base_path
         ~resolution_sequence:delivery.resolution_sequence
         ?created_by:delivery.created_by
         ?rule_expires_at:delivery.rule_expires_at
         delivery.entry
     with
     | Ok (rule, audit_receipts) -> Ok (rule, audit_receipts)
     | Error rule_error ->
       Error
         { path = rule_error.path
         ; reason = rule_error.reason
         })
  | (Decision.Approve | Decision.Reject _),
    false ->
    Ok (None, [])
  | Decision.Reject _, true -> Ok (None, [])
;;

(* Why a delivery is being completed. The operator's decision reaches the
   audit ledger as [Resolved] once, when [journal_resolution] has made it
   durable (see [record_journaled_resolution]); no completion writes that row.
   The occasion only says why the wake is being sent, and a boot replay or a
   same-request resubmission logs it as a redelivery.

   Writing the row on every completion counted one click as many decisions --
   nineteen rows for one approval on 2026-09-22 while its keeper was offline
   across twenty-one boots (#37964). Writing it on the first completion, after
   the wake, lost the decision whenever that wake failed: the operator's second
   press and every boot replay found no pending entry and never wrote it. *)
type delivery_occasion =
  | First_commit
  | Boot_replay
  | Same_request_resubmitted

let delivery_occasion_to_string = function
  | First_commit -> "first_commit"
  | Boot_replay -> "boot_replay"
  | Same_request_resubmitted -> "same_request_resubmitted"
;;

(* The ledger row and SSE [resolved] for a decision [journal_resolution] has
   just made durable. It runs once per journal, before any wake is attempted,
   so a failed delivery cannot leave the decision off the ledger.

   A failed append does not undo the journal. [Keeper_approval.Audit.record]
   is an observation boundary: its failure is counted and logged there and
   comes back in the receipt, and it must not erase or re-open the
   authoritative decision. The operator's approval stays in force and the
   missing row is visible as an audit append failure, not as a pending
   approval the operator must answer again.

   The chat row is not written here. A delivery whose keeper no longer exists
   is retired without one, and whether the keeper exists is known only when
   the wake is enqueued; [project_resolution_chat] writes it then. *)
let record_journaled_resolution delivery =
  let actor =
    match delivery.created_by with
    | Some actor when String.trim actor <> "" -> Some actor
    | Some _ | None -> None
  in
  resolve_entry
    ~base_path:delivery.entry.audit_base_path
    delivery.entry
    ~source:delivery.source
    ?actor
    delivery.decision
;;

(* The chat row for the decision. [append_approval_lifecycle_once] writes it
   at most once, so every completion that reaches a live keeper may ask for it:
   the one that follows a failed first delivery is the one that writes it. *)
let project_resolution_chat delivery =
  match
    ensure_resolution_chat_projection
      ~base_path:delivery.entry.audit_base_path
      ~keeper_name:delivery.entry.keeper_name
      ~approval_id:delivery.entry.id
      ~tool_name:(Some delivery.entry.tool_name)
      ~decision:delivery.decision
  with
  | Ok () -> ()
  | Error reason ->
    record_resolution_delivery_failure
      ~keeper_name:delivery.entry.keeper_name
      ~approval_id:delivery.entry.id
      ("chat projection: " ^ reason)
;;

let complete_delivery ~(occasion : delivery_occasion) delivery =
  let id = delivery.entry.id in
  let base_path = delivery.entry.audit_base_path in
  (match occasion with
   | First_commit -> ()
   | Boot_replay | Same_request_resubmitted ->
     Log.Keeper.info
       ~keeper_name:delivery.entry.keeper_name
       "hitl resolution redelivered approval=%s occasion=%s"
       id
       (delivery_occasion_to_string occasion));
  match resolve_store_readiness_error ~base_path ~approval_id:id with
  | Error _ as error -> error
  | Ok () ->
    if delivery.grant_consumed
    then (
      (* The keeper already used the grant, so no wake is sent. *)
      project_resolution_chat delivery;
      Ok { remembered_rule = None; audit_receipts = [] })
    else
      (match deliver_resolution ~base_path delivery.entry delivery.decision with
       | Error Keeper_registry_event_queue.Hitl_recipient_absent ->
         (* No Keeper exists with the addressed name, so this resolution has
            no consumer — ever. The decision is already on the ledger; retire
            the durable delivery, since keeping it would replay the same
            permanent failure at every boot. No always-allow rule and no chat
            row are written: the operator approved a grant for a Keeper that
            is gone. *)
         (match remove_delivery_from_store delivery with
          | Error storage_error ->
            Error (Persistence_failed { approval_id = id; storage_error })
          | Ok () ->
            Log.Keeper.info
              ~keeper_name:delivery.entry.keeper_name
              "hitl delivery retired: no such keeper approval=%s"
              id;
            Ok { remembered_rule = None; audit_receipts = [] })
       | Error (Keeper_registry_event_queue.Hitl_enqueue_failed reason) ->
         Error (Delivery_failed { approval_id = id; reason })
       | Ok () ->
         (match remember_rule_for_delivery delivery with
          | Error storage_error ->
            Error (Persistence_failed { approval_id = id; storage_error })
          | Ok (remembered_rule, rule_audit_receipts) ->
            (* Both decisions remain authoritative after their wake is sent.
               A waiting direct operation must re-read the exact rejection as
               well as an approval; the wake alone is not the request store.
               A retained rejection is never a consumable approval grant. *)
            project_resolution_chat delivery;
            signal_resolution_after_commit
              ~base_path
              ~keeper_name:delivery.entry.keeper_name
              ~approval_id:id;
            Ok { remembered_rule; audit_receipts = rule_audit_receipts }))
;;

let delivery_wake_was_observed delivery =
  let resolution : Keeper_event_queue.hitl_resolution =
    { approval_id = delivery.entry.id
    ; decision =
        hitl_resolution_decision_of_approval_decision delivery.decision
    ; channel = delivery.entry.continuation_channel
    }
  in
  let post_id = Keeper_event_queue.hitl_resolution_post_id resolution in
  match
    Keeper_reaction_ledger.event_queue_delivery_seen_for_source_result
      ~base_path:delivery.entry.audit_base_path
      ~keeper_name:delivery.entry.keeper_name
      ~post_id
      ~stimulus_kind:Keeper_reaction_ledger.Hitl_resolved
  with
  | Ok observed -> observed
  | Error error ->
    Log.Keeper.warn
      ~keeper_name:delivery.entry.keeper_name
      "approval_queue: could not verify prior HITL wake delivery approval=%s; replaying safely: %s"
      delivery.entry.id
      (Keeper_reaction_ledger.event_queue_reaction_evidence_error_to_string
         error);
    false
;;

(* ── Spent deliveries leave the store at install

   A delivery stays after its wake is sent so the wake's readers can re-read
   the decision. Those readers are: the intake, which reconciles a queued
   [Hitl_resolved] against it; host replay, which records its outcome on it;
   and a direct operation, which observes it while it waits on, binds, or
   resumes from that approval and until it discharges the evidence. Boot
   replay re-sends only a wake that was never delivered, and never for a
   consumed grant. So a delivery is spent when
   - its wake was delivered ([delivery_wake_was_observed], the rule boot
     replay already uses) and is no longer in the Keeper's queue: a delivered
     wake can still be queued, because a turn records its start before the
     queue acknowledges it;
   - no unsettled execution of the Keeper names the approval; and
   - an approval's one-shot grant is consumed (an unconsumed one can still be
     spent by the Keeper; a rejection grants nothing).
   A delivery addressed to a Keeper whose meta is gone is spent too: that is
   the rule [Hitl_recipient_absent] already applies, since nobody can read it.
   The operator's decision and the consumption stay on the audit ledger.
   Without this every approval left a permanent row (2,131 consumed approvals,
   7.8 MB, on 2026-09-23).

   The check runs once per install, the one place that already walks every
   delivery, and before any Keeper starts. Anything that cannot be read -- the
   meta, the queue, the operation store, a Keeper whose queue does not exist
   although its meta does -- keeps the row. *)
type keeper_delivery_readers =
  | Keeper_gone
  | Keeper_readers of
      { queued_wakes : string list
      ; gate_references : string list
      }
  | Keeper_readers_unknown of string

let queued_hitl_wake_ids ~base_path ~keeper_name =
  match
    Keeper_event_queue_persistence.durable_state_exists_result ~base_path ~keeper_name
  with
  | Error reason -> Error reason
  | Ok false -> Error "event queue has no durable state"
  | Ok true ->
    (match Keeper_registry_event_queue.snapshot_result ~base_path keeper_name with
     | Error reason -> Error reason
     | Ok queue ->
       Ok
         (Keeper_event_queue.to_list queue
          |> List.filter_map (fun (stimulus : Keeper_event_queue.stimulus) ->
            match stimulus.payload with
            | Keeper_event_queue.Hitl_resolved resolution -> Some resolution.approval_id
            | Keeper_event_queue.Board_signal _
            | Keeper_event_queue.Board_attention _
            | Keeper_event_queue.Bootstrap
            | Keeper_event_queue.Fusion_completed _
            | Keeper_event_queue.Schedule_due _
            | Keeper_event_queue.Connector_attention _
            | Keeper_event_queue.Ask_answered _
            | Keeper_event_queue.Completion_authority_rejected _
            | Keeper_event_queue.Task_cancelled _
            | Keeper_event_queue.Workspace_message _
            | Keeper_event_queue.Delegate_completed _
            | Keeper_event_queue.Composition_completed _
            | Keeper_event_queue.Tool_result_ready _ | Keeper_event_queue.Owned_job_completed _
            | Keeper_event_queue.Task_outcome _ -> None)))
;;

let gate_references_of_operations ~config ~keeper_name =
  let path =
    Keeper_chat_operation_store.path_for_keeper
      ~keepers_runtime_dir:(Workspace.keepers_runtime_dir config)
      ~keeper_name
  in
  match
    Eio_guard.run_in_systhread ~label:"approval-queue-read" (fun () ->
      Keeper_chat_operation_store.inspect_outstanding ~path)
  with
  | Error error -> Error (Keeper_chat_operation_store.error_to_string error)
  | Ok Keeper_chat_operation_store.Missing_store -> Ok []
  | Ok (Keeper_chat_operation_store.Stored_operations { semantic_executions; chat_operations = _; input_checkpoints = _; input_history = _ }) ->
    Ok (List.concat_map Keeper_semantic_execution.gate_approval_ids semantic_executions)
;;

(* Only a missing meta file is a gone Keeper. A file this binary does not
   decode as the current schema ([Meta_not_current]) still names a Keeper: the
   boot path re-materialises it from its declaration after this install, and a
   schema change that makes every live meta not current (a retired key, as in
   #39025) would otherwise retire every Keeper's deliveries at once. *)
let keeper_delivery_readers ~base_path ~keeper_name =
  let config = Workspace.default_config base_path in
  match Keeper_meta_store.read_meta_presence config keeper_name with
  | Error reason -> Keeper_readers_unknown ("keeper meta: " ^ reason)
  | Ok (Keeper_meta_store.Meta_not_current detail) ->
    Keeper_readers_unknown ("keeper meta not current: " ^ detail)
  | Ok Keeper_meta_store.Meta_absent -> Keeper_gone
  | Ok (Keeper_meta_store.Meta_present _) ->
    (match
       ( queued_hitl_wake_ids ~base_path ~keeper_name
       , gate_references_of_operations ~config ~keeper_name )
     with
     | Error reason, _ -> Keeper_readers_unknown ("event queue: " ^ reason)
     | _, Error reason -> Keeper_readers_unknown ("operation store: " ^ reason)
     | Ok queued_wakes, Ok gate_references ->
       Keeper_readers { queued_wakes; gate_references })
;;

let delivery_is_spent readers delivery =
  match readers with
  | Keeper_readers_unknown _ -> false
  | Keeper_gone -> true
  | Keeper_readers { queued_wakes; gate_references } ->
    let id = delivery.entry.id in
    let grant_settled =
      match delivery.decision with
      | Decision.Approve -> delivery.grant_consumed
      | Decision.Reject _ -> true
    in
    grant_settled
    && (not (List.mem id queued_wakes))
    && (not (List.mem id gate_references))
    && delivery_wake_was_observed delivery
;;

let spent_delivery_ids ~base_path loaded_deliveries =
  let readers_by_keeper = Hashtbl.create 8 in
  let readers_of keeper_name =
    match Hashtbl.find_opt readers_by_keeper keeper_name with
    | Some readers -> readers
    | None ->
      let readers = keeper_delivery_readers ~base_path ~keeper_name in
      (match readers with
       | Keeper_gone | Keeper_readers _ -> ()
       | Keeper_readers_unknown reason ->
         Log.Keeper.warn
           ~keeper_name
           "approval_queue: delivery readers unknown; spent deliveries kept: %s"
           reason);
      Hashtbl.add readers_by_keeper keeper_name readers;
      readers
  in
  List.filter_map
    (fun delivery ->
       if delivery_is_spent (readers_of delivery.entry.keeper_name) delivery
       then Some delivery.entry.id
       else None)
    loaded_deliveries
;;

(* The sidecar is written before the snapshot. A crash between the two leaves
   a consumed delivery without its outcome, which the next install retires
   the same way; the other order would leave an outcome whose delivery is
   gone, and that fails the sidecar load. An unreadable sidecar is left
   alone: rewriting it from memory would drop the outcomes it still holds. *)
let retire_spent_deliveries ~base_path ids =
  with_pending_store_lock (fun () ->
    if
      SMap.mem base_path (Atomic.get unavailable_stores)
      || SMap.mem base_path (Atomic.get replay_projection_errors)
    then Ok 0
    else (
      let current = Atomic.get deliveries in
      let retired =
        List.filter
          (fun id ->
             match SMap.find_opt id current with
             | Some delivery -> String.equal delivery.entry.audit_base_path base_path
             | None -> false)
          ids
      in
      match retired with
      | [] -> Ok 0
      | _ :: _ ->
        let updated_deliveries =
          List.fold_left (fun map id -> SMap.remove id map) current retired
        in
        (match save_replay_results_file_unlocked ~base_path ~delivery_map:updated_deliveries with
         | Error error -> Error error
         | Ok (Visible_sync_unconfirmed reason) ->
           Error { path = replay_results_store_path ~base_path; reason }
         | Ok Fsync_completed ->
           (match
              persist_snapshot_unlocked
                ~base_path
                ~pending_map:(Atomic.get pending)
                ~delivery_map:updated_deliveries
            with
            | Error error -> Error error
            | Ok () ->
              Atomic.set deliveries updated_deliveries;
              Ok (List.length retired)))))
;;

let install_persistence_internal ~after_load ~after_pending_publish ~base_path =
  (* Snapshot read and installation are one transition. The hybrid pending
     store lock serializes Eio and non-Eio callers, cooperatively gates Eio
     waiters, and protects cancellation across the durable transition. Keeping
     the load inside this boundary prevents a same-workspace mutation from
     being published between the read and the replacement below. *)
  let installed =
    with_pending_store_lock (fun () ->
      Atomic.set
        pending_read_errors
        (SMap.remove base_path (Atomic.get pending_read_errors));
      let loaded_snapshot =
        match load_snapshot_unlocked ~base_path with
        | Error _ as error -> error
        | Ok
            { loaded_pending
            ; loaded_deliveries
            ; loaded_next_sequence
            ; loaded_read_errors = pending_read_errors
            ; loaded_durable
            } ->
          let loaded_deliveries, replay_projection_error =
            load_replay_results_unlocked
              ~base_path
              ~delivery_map:loaded_deliveries
          in
          let loaded_durable =
            Option.map
              (fun durable -> { durable with durable_deliveries = loaded_deliveries })
              loaded_durable
          in
          Ok
            ( loaded_pending
            , loaded_deliveries
            , loaded_next_sequence
            , replay_projection_error
            , pending_read_errors
            , loaded_durable )
      in
      after_load ();
      match loaded_snapshot with
      | Error storage_error ->
        mark_store_unavailable_unlocked ~base_path storage_error;
        Error storage_error
      | Ok
          ( loaded_pending
          , loaded_deliveries
          , loaded_next_sequence
          , replay_projection_error
          , pending_entry_read_errors
          , loaded_durable ) ->
        let current_pending =
          remove_base_entries ~base_path (Atomic.get pending) Fun.id
        in
        let current_deliveries =
          remove_base_entries
            ~base_path
            (Atomic.get deliveries)
            (fun delivery -> delivery.entry)
        in
        (match
           merge_loaded_map
             ~surface:"gate_pending.pending"
             ~existing:current_pending
             ~loaded:loaded_pending,
           merge_loaded_map
             ~surface:"gate_pending.deliveries"
             ~existing:current_deliveries
             ~loaded:loaded_deliveries
         with
         | Error reason, _ | _, Error reason ->
           let path = pending_store_path ~base_path in
           report_pending_read_drop
             ~reason:Read_drop_reason.Invalid_payload
             ~path
             ~detail:reason;
           let error = { path; reason } in
           mark_store_unavailable_unlocked ~base_path error;
           Error error
         | Ok pending_map, Ok delivery_map ->
           (match first_shared_id pending_map delivery_map with
            | Some id ->
              let path = pending_store_path ~base_path in
              let reason =
                Printf.sprintf
                  "gate_pending id %s collides across pending and delivery states"
                  id
              in
              report_pending_read_drop
                ~reason:Read_drop_reason.Invalid_payload
                ~path
                ~detail:reason;
              let error = { path; reason } in
              mark_store_unavailable_unlocked ~base_path error;
              Error error
            | None ->
              (match loaded_durable with
               | Some durable -> set_durable_state ~base_path durable
               | None -> drop_durable_state ~base_path);
              (match pending_entry_read_errors with
               | [] -> clear_store_unavailable_unlocked ~base_path
               | first :: _ -> mark_store_unavailable_unlocked ~base_path first);
              Atomic.set
                pending_read_errors
                (match pending_entry_read_errors with
                 | [] -> SMap.remove base_path (Atomic.get pending_read_errors)
                 | errors -> SMap.add base_path errors (Atomic.get pending_read_errors));
              Atomic.set
                replay_projection_errors
                (match replay_projection_error with
                 | None ->
                   SMap.remove
                     base_path
                     (Atomic.get replay_projection_errors)
                 | Some error ->
                   SMap.add
                     base_path
                     error
                     (Atomic.get replay_projection_errors));
              Atomic.set pending pending_map;
              after_pending_publish ();
              Atomic.set deliveries delivery_map;
              Atomic.set
                next_sequences
                (SMap.add
                   base_path
                   loaded_next_sequence
                   (Atomic.get next_sequences));
              Ok
                ( SMap.cardinal loaded_pending
                , SMap.bindings loaded_deliveries
                  |> List.map snd
                  |> List.sort (fun left right ->
                    compare_pending_order left.entry right.entry)
                , replay_projection_error ))))
  in
  match installed with
  | Error storage_error -> Error (Install_storage_failed storage_error)
  | Ok (loaded_pending, loaded_deliveries, replay_projection_error) ->
    let spent_ids = spent_delivery_ids ~base_path loaded_deliveries in
    let retired_deliveries, delivery_retirement_error, loaded_deliveries =
      match retire_spent_deliveries ~base_path spent_ids with
      | Ok 0 -> 0, None, loaded_deliveries
      | Ok count ->
        ( count
        , None
        , List.filter
            (fun delivery -> not (List.mem delivery.entry.id spent_ids))
            loaded_deliveries )
      | Error error -> 0, Some error, loaded_deliveries
    in
    let rec replay count failures = function
      | [] ->
        Ok
          { loaded_pending
          ; replayed_deliveries = count
          ; delivery_replay_failures = List.rev failures
          ; replay_projection_error
          ; retired_deliveries
          ; delivery_retirement_error
          }
      | delivery :: rest ->
        if delivery.grant_consumed
        then replay count failures rest
        else if delivery_wake_was_observed delivery
        then replay count failures rest
        else
          (match complete_delivery ~occasion:Boot_replay delivery with
           | Ok _ -> replay (count + 1) failures rest
           | Error error ->
             let failure =
               { approval_id = delivery.entry.id
               ; reason = resolve_error_to_string error
               }
             in
             replay count (failure :: failures) rest)
    in
    replay 0 [] loaded_deliveries
;;

let install_persistence ~base_path =
  install_persistence_internal
    ~after_load:(fun () -> ()) ~after_pending_publish:(fun () -> ()) ~base_path
;;

module For_testing = struct
  type strict_snapshot_writer =
    string -> string -> (unit, Fs_compat.atomic_replace_failure) result

  let with_pending_store_lock = with_pending_store_lock
  let get_pending_entry_unchecked = find_pending_entry_unchecked

  let with_unavailable_workspace ~base_path f =
    let previous = with_pending_store_lock (fun () ->
      let stores = Atomic.get unavailable_stores in
      let previous = SMap.find_opt base_path stores in
      Atomic.set unavailable_stores (SMap.add base_path
        {path=base_path; reason="injected unavailable Gate authority"} stores);
      previous) in
    Fun.protect ~finally:(fun () -> with_pending_store_lock (fun () ->
      let stores = Atomic.get unavailable_stores in
      Atomic.set unavailable_stores (match previous with
        | None -> SMap.remove base_path stores
        | Some error -> SMap.add base_path error stores))) f

  let reset_runtime_state () =
    with_pending_store_lock (fun () ->
      Atomic.set pending SMap.empty;
      Atomic.set deliveries SMap.empty;
      Atomic.set unavailable_stores SMap.empty;
      Atomic.set pending_read_errors SMap.empty;
      Atomic.set replay_projection_errors SMap.empty;
      Atomic.set store_revisions SMap.empty;
      Atomic.set next_sequences SMap.empty;
      Atomic.set durable_states SMap.empty)
  ;;

  let install_persistence_with_after_load_hook ~base_path ~after_load =
    install_persistence_internal ~after_load ~after_pending_publish:(fun () -> ()) ~base_path
  ;;

  let install_persistence_with_after_pending_publish_hook ~base_path ~after_pending_publish =
    install_persistence_internal ~after_load:(fun () -> ()) ~after_pending_publish ~base_path
  ;;

  let pending_store_path = pending_store_path
  let replay_results_store_path = replay_results_store_path
  let always_allowed_store_path ~base_path = rules_path ~base_path ()

  (* The injected writer stands in for the snapshot write, so these seams
     rewrite the snapshot on every write instead of appending rows. *)
  let bind_summary_exact_attempt_with_writer =
    bind_summary_exact_attempt_with ~write_mode:Rewrite_snapshot
  ;;

  let release_summary_exact_attempt_before_dispatch_with_writer =
    release_summary_exact_attempt_before_dispatch_with ~write_mode:Rewrite_snapshot
  ;;

  let quarantine_summary_exact_attempt_with_writer =
    quarantine_summary_exact_attempt_with ~write_mode:Rewrite_snapshot
  ;;

  let complete_summary_exact_attempt_with_writer =
    complete_summary_exact_attempt_with ~write_mode:Rewrite_snapshot
  ;;

  let pending_log_path = pending_log_path

  let durable_snapshot_json ~base_path =
    with_pending_store_lock (fun () ->
      match read_durable_unlocked ~base_path with
      | Error error -> Error (storage_error_to_string error)
      | Ok (pending_map, delivery_map, next_sequence, generation, _errors, _log) ->
        Ok
          (snapshot_to_yojson
             ~base_path
             ~next_sequence
             ~generation
             ~pending_map
             ~delivery_map))
  ;;
end

let resolve_with_policy
      ~base_path
      ~id
      ~(decision : decision)
      ~(source : decision_source)
      ?(remember_rule = false)
      ?rule_expires_at
      ?created_by
      ()
  : (resolution_result, resolve_error) result
  =
  let claim =
    with_pending_store_lock (fun () ->
      match resolution_target_unlocked ~base_path ~id with
      | Error _ as error -> error
      | Ok (Pending_resolution _ | Journaled_resolution _) ->
        if claim_resolution id then Ok () else Error (Already_resolved id))
  in
  match claim with
  | Error _ as error -> error
  | Ok () ->
    Fun.protect
      ~finally:(fun () -> release_resolution_claim id)
      (fun () ->
         match journal_resolution ~base_path ~id ~decision ~source ~remember_rule
                 ~rule_expires_at ~created_by with
         | Error _ as error -> error
         | Ok (Newly_journaled delivery) ->
           notify_waiting_approval ~source:Approval_count delivery.entry;
           let resolution_receipt = record_journaled_resolution delivery in
           (match complete_delivery ~occasion:First_commit delivery with
            | Error _ as error -> error
            | Ok result ->
              Ok
                { result with
                  audit_receipts = result.audit_receipts @ [ resolution_receipt ]
                })
         | Ok (Previously_journaled delivery) ->
           let same_request =
             approval_decision_equal decision delivery.decision
             && source = delivery.source
             && remember_rule = delivery.remember_rule
             && rule_expires_at = delivery.rule_expires_at
             && created_by = delivery.created_by
           in
           if same_request
           then complete_delivery ~occasion:Same_request_resubmitted delivery
           else Error (Already_resolved id))
;;

(* ── Query ────────────────────────────────────────────────── *)

let retire_summary_owner ~base_path ~keeper_name ~reason =
  let result =
    with_pending_store_lock (fun () ->
      let current = Atomic.get pending in
      let ids, next, bound =
        SMap.fold
          (fun id (entry : pending_approval) (ids, map, bound) ->
             if
               String.equal entry.audit_base_path base_path
               && String.equal entry.keeper_name keeper_name
             then
               match entry.summary_status, entry.exact_attempt with
               | Summary_pending, Exact_bound attempt ->
                 ids, map, Some attempt
               | Summary_pending, Exact_unbound ->
                 ( id :: ids
                 , SMap.add
                     id
                     { entry with
                       summary_status = Summary_failed { reason }
                     }
                     map
                 , bound )
               | ( Summary_not_requested
                 | Summary_available _
                 | Summary_failed _ ),
                 _ ->
                 ids, map, bound
             else ids, map, bound)
          current
          ([], current, None)
      in
      match bound, ids with
      | Some attempt, _ ->
        Error (Summary_owner_retirement_exact_attempt_unsettled attempt)
      | None, [] -> Ok []
      | None, _ ->
        (match
           persist_snapshot_unlocked
             ~base_path
             ~pending_map:next
             ~delivery_map:(Atomic.get deliveries)
         with
         | Error error ->
           Error (Summary_owner_retirement_storage_error error)
         | Ok () ->
           Atomic.set pending next;
           Ok (List.rev ids)))
  in
  match result with
  | Error _ as error -> error
  | Ok ids ->
    List.iter (fun id -> publish_summary_update ~id) ids;
    Ok ids
;;

let pending_entries_in_sequence_order () =
  SMap.fold (fun _id entry acc -> entry :: acc) (Atomic.get pending) []
  |> List.sort compare_pending_order
;;

type pending_entries_snapshot =
  { revision : int
  ; entries : pending_approval list
  ; read_errors : storage_error list
  }

let pending_entries_snapshot_unlocked ~base_path =
  let entries =
    pending_entries_in_sequence_order ()
    |> List.filter (fun (entry : pending_approval) ->
      String.equal entry.audit_base_path base_path)
  in
  let revision = store_revision_unlocked ~base_path in
  match SMap.find_opt base_path (Atomic.get unavailable_stores) with
  | Some _ when SMap.mem base_path (Atomic.get pending_read_errors) ->
    Ok
      { revision
      ; entries
      ; read_errors =
          Option.value
            (SMap.find_opt base_path (Atomic.get pending_read_errors))
            ~default:[]
      }
  | Some error -> Error error
  | None -> Ok { revision; entries; read_errors = [] }
;;

let pending_entries_snapshot_for_workspace ~base_path =
  with_pending_store_lock (fun () ->
    pending_entries_snapshot_unlocked ~base_path)
;;

let list_pending_entries_with_read_errors_for_workspace ~base_path =
  pending_entries_snapshot_for_workspace ~base_path
  |> Result.map (fun snapshot -> snapshot.entries, snapshot.read_errors)
;;

let list_pending_entries_for_workspace ~base_path =
  list_pending_entries_with_read_errors_for_workspace ~base_path
  |> Result.map fst
;;

let get_pending_entry_for_workspace ~base_path ~id =
  with_pending_store_lock (fun () ->
    match SMap.find_opt base_path (Atomic.get unavailable_stores) with
    | Some error -> Error error
    | None ->
      (match SMap.find_opt id (Atomic.get pending) with
       | Some entry when String.equal entry.audit_base_path base_path ->
         Ok (Some entry)
       | Some _ | None -> Ok None))
;;

let list_pending_dashboard_json_for_workspace ~base_path =
  list_pending_entries_for_workspace ~base_path
  |> Result.map (fun entries ->
    entries
    |> List.map (fun entry ->
      `Assoc (pending_entry_json_fields ~include_input:true entry)))
;;

let pending_count_for_keeper_in_workspace ~base_path ~keeper_name =
  list_pending_entries_for_workspace ~base_path
  |> Result.map (fun entries ->
    List.fold_left
      (fun count (entry : pending_approval) ->
        if String.equal entry.keeper_name keeper_name then count + 1 else count)
      0
      entries)
;;

type waiting_observation =
  { waiting_request : pending_approval; waiting_decision : decision option }
let observe_waiting_request ~base_path ~id =
  with_pending_store_lock (fun () ->
    match SMap.find_opt base_path (Atomic.get unavailable_stores) with
    | Some error -> Error error
    | None ->
      match SMap.find_opt id (Atomic.get deliveries), SMap.find_opt id (Atomic.get pending) with
      | Some delivery, _ when delivery.entry.audit_base_path = base_path ->
        Ok (Some {waiting_request=delivery.entry; waiting_decision=Some delivery.decision})
      | None, Some entry when entry.audit_base_path = base_path ->
        Ok (Some {waiting_request=entry; waiting_decision=None})
      | Some _, _ | None, Some _ | None, None -> Ok None)
