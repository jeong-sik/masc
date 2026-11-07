open Keeper_approval_queue_rules
open Keeper_approval_queue_result
open Keeper_approval_queue_state
open Keeper_approval_queue_registry
open Keeper_approval_queue_persist
open Keeper_approval_queue_entry_update

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

(* The four exact-attempt transitions below share this body; [apply] is the
   transition of Keeper_approval_queue_exact_transition they differ in. *)
let transition_exact_attempt
      (apply :
         candidate:exact_attempt_binding
         -> pending_approval
         -> (Keeper_approval_queue_exact_transition.t, exact_attempt_error) result)
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
          (match apply ~candidate entry with
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

let bind_summary_exact_attempt_with =
  transition_exact_attempt Keeper_approval_queue_exact_transition.bind
;;

let bind_summary_exact_attempt =
  bind_summary_exact_attempt_with
    ~write_mode:Append_rows
    ~save_file_atomic_strict_staged:Fs_compat.save_file_atomic_strict_staged
;;

let release_summary_exact_attempt_before_dispatch_with =
  transition_exact_attempt Keeper_approval_queue_exact_transition.release
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
  transition_exact_attempt
    (Keeper_approval_queue_exact_transition.quarantine ~cause)
    ~write_mode
    ~save_file_atomic_strict_staged
    ~id
    ~input_hash
    ~sequence
    ~slot_id
    ~call_id
    ~plan_fingerprint
    ~request_body_sha256
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
  transition_exact_attempt
    (Keeper_approval_queue_exact_transition.complete ~summary)
    ~write_mode
    ~save_file_atomic_strict_staged
    ~id
    ~input_hash
    ~sequence
    ~slot_id
    ~call_id
    ~plan_fingerprint
    ~request_body_sha256
;;

let complete_summary_exact_attempt =
  complete_summary_exact_attempt_with
    ~write_mode:Append_rows
    ~save_file_atomic_strict_staged:Fs_compat.save_file_atomic_strict_staged
;;
