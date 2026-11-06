open Keeper_approval_queue_rules
open Keeper_approval_queue_result
open Keeper_approval_queue_codec
open Keeper_approval_queue_registry
open Keeper_approval_queue_persist

type approved_delivery_lookup =
  | Approved_delivery_unconsumed of persisted_delivery
  | Approved_delivery_consumed of persisted_delivery

type grant_consumption_commit =
  | Consumption_without_audit of grant_consumption
  | Consumption_with_audit of persisted_delivery

let grant_workspace_mismatch ~base_path approval_id stored_base_path =
  Grant_workspace_mismatch
    { approval_id
    ; requested_base_path = base_path
    ; stored_base_path
    }
;;

let approved_delivery_unlocked ~base_path ~id =
  match SMap.find_opt base_path (Atomic.get unavailable_stores) with
  | Some error -> Error (Grant_store_unavailable error)
  | None ->
    (match SMap.find_opt id (Atomic.get deliveries) with
     | Some delivery ->
       let stored_base_path = delivery.entry.audit_base_path in
       if not (String.equal stored_base_path base_path)
       then Error (grant_workspace_mismatch ~base_path id stored_base_path)
       else
         (match delivery.decision with
          | Decision.Approve ->
            if delivery.grant_consumed
            then Ok (Approved_delivery_consumed delivery)
            else Ok (Approved_delivery_unconsumed delivery)
          | Decision.Reject _ ->
            Error (Grant_resolution_not_approved id))
     | None ->
       (match SMap.find_opt id (Atomic.get pending) with
        | Some entry ->
          if String.equal entry.audit_base_path base_path
          then Error (Grant_still_pending id)
          else
            Error
              (grant_workspace_mismatch
                 ~base_path
                 id
                 entry.audit_base_path)
        | None -> Error (Grant_resolution_missing id)))
;;

let approved_resolution_request ~base_path ~id =
  with_pending_store_lock (fun () ->
    match approved_delivery_unlocked ~base_path ~id with
    | Error _ as error -> error
    | Ok (Approved_delivery_consumed _) -> Ok None
    | Ok (Approved_delivery_unconsumed delivery) ->
      Ok
        (Some
           { keeper_name = delivery.entry.keeper_name
           ; tool_name = delivery.entry.tool_name
           ; input = delivery.entry.input
           }))
;;

let approved_resolution_state ~base_path ~id =
  with_pending_store_lock (fun () ->
    match approved_delivery_unlocked ~base_path ~id with
    | Error _ as error -> error
    | Ok (Approved_delivery_consumed _) -> Ok Resolution_consumed
    | Ok (Approved_delivery_unconsumed _) -> Ok Resolution_unconsumed)
;;

let approved_resolution_delivery ~base_path ~id =
  with_pending_store_lock (fun () ->
    match approved_delivery_unlocked ~base_path ~id with
    | Error _ as error -> error
    | Ok (Approved_delivery_unconsumed delivery) ->
      Ok
        { request =
            { keeper_name = delivery.entry.keeper_name
            ; tool_name = delivery.entry.tool_name
            ; input = delivery.entry.input
            }
        ; state = Resolution_unconsumed
        ; replay_outcome = delivery.replay_outcome
        }
    | Ok (Approved_delivery_consumed delivery) ->
      Ok
        { request =
            { keeper_name = delivery.entry.keeper_name
            ; tool_name = delivery.entry.tool_name
            ; input = delivery.entry.input
            }
        ; state = Resolution_consumed
        ; replay_outcome = delivery.replay_outcome
        })
;;

let resolution_replay_outcome_equal left right =
  match left, right with
  | Replay_applied left, Replay_applied right
  | Replay_applied_with_warning left, Replay_applied_with_warning right
  | Replay_failed left, Replay_failed right
  | Replay_indeterminate left, Replay_indeterminate right ->
    left = right
  | Replay_applied _, Replay_failed _
  | Replay_applied _, Replay_applied_with_warning _
  | Replay_applied _, Replay_indeterminate _
  | Replay_applied_with_warning _, Replay_applied _
  | Replay_applied_with_warning _, Replay_failed _
  | Replay_applied_with_warning _, Replay_indeterminate _
  | Replay_failed _, Replay_applied _
  | Replay_failed _, Replay_applied_with_warning _
  | Replay_failed _, Replay_indeterminate _
  | Replay_indeterminate _, Replay_applied _
  | Replay_indeterminate _, Replay_applied_with_warning _
  | Replay_indeterminate _, Replay_failed _ ->
    false
;;

let record_consumed_resolution_replay ~base_path ~id ~outcome =
  with_pending_store_lock (fun () ->
    match SMap.find_opt base_path (Atomic.get replay_projection_errors) with
    | Some error -> Error (Grant_replay_projection_unavailable error)
    | None ->
      (match approved_delivery_unlocked ~base_path ~id with
       | Error _ as error -> error
       | Ok (Approved_delivery_unconsumed _) ->
         Error (Grant_replay_not_consumed id)
       | Ok (Approved_delivery_consumed delivery) ->
         (match delivery.replay_outcome with
          | Some existing when resolution_replay_outcome_equal existing outcome ->
            Ok Replay_already_recorded
          | Some _ -> Error (Grant_replay_outcome_conflict id)
          | None ->
            let updated_delivery =
              { delivery with replay_outcome = Some outcome }
            in
            let updated_deliveries =
              SMap.add id updated_delivery (Atomic.get deliveries)
            in
            (match
               save_replay_results_file_unlocked
                 ~base_path
                 ~delivery_map:updated_deliveries
             with
             | Error error ->
               Error (Grant_replay_projection_unavailable error)
             | Ok Fsync_completed ->
               Atomic.set deliveries updated_deliveries;
               (match durable_state_for ~base_path with
                | None -> ()
                | Some durable when SMap.mem id durable.durable_deliveries ->
                  set_durable_state
                    ~base_path
                    { durable with
                      durable_deliveries =
                        SMap.add id updated_delivery durable.durable_deliveries
                    }
                | Some _ -> ());
               Ok Replay_recorded
             | Ok (Visible_sync_unconfirmed reason) ->
               let error =
                 { path = replay_results_store_path ~base_path
                 ; reason
                 }
               in
               Error (Grant_replay_projection_unavailable error)))))
;;

let consume_approved_resolution
      ~base_path
      ~id
      ~keeper_name
      ~tool_name
      ~input
  =
  let result =
    with_pending_store_lock (fun () ->
      match approved_delivery_unlocked ~base_path ~id with
      | Error error -> Error error
      | Ok (Approved_delivery_consumed _) ->
        Ok (Consumption_without_audit Consumption_already_committed)
      | Ok (Approved_delivery_unconsumed delivery) ->
        let entry = delivery.entry in
        if
          not
            (String.equal entry.keeper_name keeper_name
             && String.equal entry.tool_name tool_name
             && String.equal
                  entry.input_hash
                  (Keeper_approval_request_fingerprint.request_fingerprint input))
        then Ok (Consumption_without_audit Consumption_not_matching)
        else
          let consumed_delivery = { delivery with grant_consumed = true } in
          let updated_deliveries =
            SMap.add id consumed_delivery (Atomic.get deliveries)
          in
          (match
             persist_snapshot_unlocked
               ~base_path
               ~pending_map:(Atomic.get pending)
               ~delivery_map:updated_deliveries
           with
           | Error error -> Error (Grant_store_unavailable error)
           | Ok () ->
             Atomic.set deliveries updated_deliveries;
             Ok (Consumption_with_audit delivery)))
  in
  match result with
  | Error _ as error -> error
  | Ok (Consumption_without_audit consumption) -> Ok consumption
  | Ok (Consumption_with_audit delivery) ->
    let entry = delivery.entry in
    let audit_receipt =
      Keeper_approval.Audit.record
        ~base_path
        ~event_type:Keeper_approval.Audit.Grant_consumed
        ~id
        ~keeper_name:entry.keeper_name
        ~tool_name:entry.tool_name
        ?turn_id:entry.turn_id
        ?task_id:entry.task_id
        ?goal_id:entry.goal_id
        ~source_approval_id:id
        ~decision_source:delivery.source
        ~decision:Decision.Approve
        ()
    in
    Ok (Consumption_committed audit_receipt)
;;
