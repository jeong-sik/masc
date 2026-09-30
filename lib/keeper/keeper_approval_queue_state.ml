(** Pure calculations over immutable pending approvals and persisted deliveries. *)
open Keeper_approval_queue_rules_types
open Keeper_approval_queue_result
open Keeper_approval_queue_codec

module SMap = Set_util.StringMap

let exact_attempt_identity_matches
      (left : exact_attempt_binding)
      (right : exact_attempt_binding)
  =
  String.equal left.approval_id right.approval_id
  && String.equal left.input_hash right.input_hash
  && Int.equal left.sequence right.sequence
  && String.equal left.slot_id right.slot_id
  && String.equal left.call_id right.call_id
  && String.equal left.plan_fingerprint right.plan_fingerprint
  && String.equal left.request_body_sha256 right.request_body_sha256
;;
let summary_attempt_allows_exact_bind = function
  | Summary_attempt_ready
  | Summary_attempt_pre_worker_unavailable
      { reason_code = Summary_pre_worker_start_reserved; _ } ->
    true
  | Summary_attempt_in_flight
  | Summary_attempt_identity_unbound
  | Summary_attempt_persistence_uncertain
  | Summary_attempt_pre_worker_unavailable _
  | Summary_attempt_settled ->
    false
;;

let entries_for_base ~base_path map project =
  SMap.filter (fun _id value -> String.equal (project value).audit_base_path base_path) map
;;

(* Rows for what differs between the last durable state and the maps being
   persisted. Physical equality: an entry a mutation did not touch is the
   same record in both maps. *)
let delta_rows ~before_pending ~before_deliveries ~after_pending ~after_deliveries =
  let pending_rows =
    SMap.merge
      (fun id before after ->
         match before, after with
         | Some before, Some after when before == after -> None
         | _, Some after -> Some (Pending_upsert after)
         | Some _, None -> Some (Pending_remove id)
         | None, None -> None)
      before_pending
      after_pending
  in
  let delivery_rows =
    SMap.merge
      (fun id before after ->
         match before, after with
         | Some before, Some after when before == after -> None
         | _, Some after -> Some (Delivery_upsert after)
         | Some _, None -> Some (Delivery_remove id)
         | None, None -> None)
      before_deliveries
      after_deliveries
  in
  List.map snd (SMap.bindings pending_rows) @ List.map snd (SMap.bindings delivery_rows)
;;

let classify_restarted_entry (entry : pending_approval) =
  match entry.exact_attempt, entry.summary_status with
  | Exact_bound
      ( { status =
            Exact_dispatch_uncertain
        ; _
        } as binding ),
    _ ->
    ( { entry with
        exact_attempt =
          Exact_bound
            (exact_attempt_binding_with_status
               binding
               Exact_restart_quarantined)
      ; summary_attempt_disposition =
          Summary_attempt_persistence_uncertain
      }
    , true )
  | Exact_bound
      ( { status =
            Exact_released_before_dispatch
        ; _
        } as binding ),
    Summary_pending ->
    ( { entry with
        exact_attempt =
          Exact_bound
            (exact_attempt_binding_with_status
               binding
               Exact_released_recovery_required)
      ; summary_attempt_disposition =
          Summary_attempt_persistence_uncertain
      }
    , true )
  | Exact_unbound, _
  | Exact_bound
      { status =
          ( Exact_released_before_dispatch
          | Exact_released_recovery_required
          | Exact_quarantined _
          | Exact_restart_quarantined
          | Exact_completed )
      ; _
      },
    _ ->
    entry, false
;;

let classify_restarted_pending map =
  SMap.fold
    (fun id entry (changed, classified) ->
       let entry, entry_changed = classify_restarted_entry entry in
       changed || entry_changed, SMap.add id entry classified)
    map
    (false, SMap.empty)
;;

let classify_restarted_deliveries map =
  SMap.fold
    (fun id delivery (changed, classified) ->
       let entry, entry_changed = classify_restarted_entry delivery.entry in
       ( changed || entry_changed
       , SMap.add id { delivery with entry } classified ))
    map
    (false, SMap.empty)
;;

let validate_exact_attempt_candidate
      ~id
      ~input_hash
      ~sequence
      ~slot_id
      ~call_id
      ~plan_fingerprint
      ~request_body_sha256
  =
  let invalid field value =
    if String.trim value = ""
    then Error (Exact_attempt_rejected (Exact_attempt_invalid_identity field))
    else Ok ()
  in
  let ( let* ) = Result.bind in
  let* () = invalid "approval_id" id in
  let* () = invalid "input_hash" input_hash in
  let* () =
    if sequence > 0
    then Ok ()
    else Error (Exact_attempt_rejected (Exact_attempt_invalid_identity "sequence"))
  in
  let* () = invalid "slot_id" slot_id in
  let* () = invalid "call_id" call_id in
  let* () = invalid "plan_fingerprint" plan_fingerprint in
  let* () =
    if is_lowercase_sha256 request_body_sha256
    then Ok ()
    else
      Error
        (Exact_attempt_rejected
           (Exact_attempt_invalid_identity "request_body_sha256"))
  in
  Ok
    (make_exact_attempt_binding
       ~approval_id:id
       ~input_hash
       ~sequence
       ~slot_id
       ~call_id
       ~plan_fingerprint
       ~request_body_sha256
       ())
;;

(* The effect request's identity. [turn_id] is deliberately absent: it names
   the turn that asked, not the effect being asked for. Keeping it in this
   comparison made every next-turn retry of the same call a fresh approval —
   measured 2026-08-16: one identical web_search deferred in turns
   28959/28960/28961 produced three approvals, three auto-judge approvals,
   and three replays of the same 17,712-byte output into the same context
   (#28866). The turn that asked is still recorded on the entry for audit. *)
let pending_entry_matches
      (entry : pending_approval)
      ~base_path
      ~keeper_name
      ~tool_name
      ~input_hash
      ~task_id
      ~goal_id
      ~continuation_channel
  =
  String.equal entry.audit_base_path base_path
  && String.equal entry.keeper_name keeper_name
  && String.equal entry.tool_name tool_name
  && String.equal entry.input_hash input_hash
  && entry.task_id = task_id
  && entry.goal_id = goal_id
  && Yojson.Safe.equal
       (Keeper_continuation_channel.to_yojson entry.continuation_channel)
       (Keeper_continuation_channel.to_yojson continuation_channel)
;;

let find_pending_id_in_map
      (map : pending_approval SMap.t)
      ~base_path
      ~keeper_name
      ~tool_name
      ~input_hash
      ~task_id
      ~goal_id
      ~continuation_channel
  =
  SMap.fold
    (fun id (entry : pending_approval) acc ->
       match acc with
       | Some _ -> acc
       | None ->
         if
           pending_entry_matches
             entry
             ~base_path
             ~keeper_name
             ~tool_name
             ~input_hash
             ~task_id
             ~goal_id
             ~continuation_channel
         then Some id
         else None)
    map
    None
;;

(* An approved resolution whose one-shot grant is still unconsumed is the
   same effect request one step further along: the host owes the Keeper a
   replay of exactly this call. A resubmission folds onto it instead of
   opening a second approval — "an approval owns its effect" (RFC-0356)
   implies its dual, an effect has one approval. Rejected and
   grant-consumed deliveries never match: a retry after rejection is a new
   approval cycle, and a retry after the effect ran is a new effect. *)
let find_unconsumed_grant_id_in_deliveries
      (map : persisted_delivery SMap.t)
      ~base_path
      ~keeper_name
      ~tool_name
      ~input_hash
      ~task_id
      ~goal_id
      ~continuation_channel
  =
  SMap.fold
    (fun id (delivery : persisted_delivery) acc ->
       match acc with
       | Some _ -> acc
       | None ->
         (match delivery.decision with
          | Decision.Reject _ -> None
          | Decision.Approve ->
            if
              (not delivery.grant_consumed)
              && pending_entry_matches
                   delivery.entry
                   ~base_path
                   ~keeper_name
                   ~tool_name
                   ~input_hash
                   ~task_id
                   ~goal_id
                   ~continuation_channel
            then Some id
            else None))
    map
    None
;;

let compare_pending_order left right =
  match String.compare left.audit_base_path right.audit_base_path with
  | 0 ->
    let sequence_order = Int.compare left.sequence right.sequence in
    if sequence_order = 0 then String.compare left.id right.id else sequence_order
  | workspace_order -> workspace_order
;;
