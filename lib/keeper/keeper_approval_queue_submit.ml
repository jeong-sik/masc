open Keeper_approval_queue_rules
open Keeper_approval_queue_projection
open Keeper_approval_queue_result
open Keeper_approval_queue_state
open Keeper_approval_queue_registry
open Keeper_approval_queue_persist
open Keeper_approval_queue_entry_update

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
