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
include Keeper_approval_queue_entry_update
include Keeper_approval_queue_summary_exact
include Keeper_approval_queue_summary_attempt
include Keeper_approval_queue_delivery
include Keeper_approval_queue_submit
include Keeper_approval_queue_journal
include Keeper_approval_queue_resolve
include Keeper_approval_queue_install

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
