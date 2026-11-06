open Keeper_approval_queue_rules
open Keeper_approval_queue_projection
open Keeper_approval_queue_result
open Keeper_approval_queue_codec
open Keeper_approval_queue_registry
open Keeper_approval_queue_persist
open Keeper_approval_queue_entry_update
open Keeper_approval_queue_delivery
open Keeper_approval_queue_journal

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
