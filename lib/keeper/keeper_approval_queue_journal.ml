open Keeper_approval_queue_rules
open Keeper_approval_queue_result
open Keeper_approval_queue_codec
open Keeper_approval_queue_registry
open Keeper_approval_queue_persist

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
