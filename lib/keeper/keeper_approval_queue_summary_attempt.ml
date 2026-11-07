open Keeper_approval_queue_rules
open Keeper_approval_queue_result
open Keeper_approval_queue_state
open Keeper_approval_queue_registry
open Keeper_approval_queue_persist
open Keeper_approval_queue_entry_update

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
  publish_summary_transition ~id result
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
