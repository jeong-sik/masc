(** Durable, nonblocking HITL requests for Keeper external effects.

    The code lives in the [Keeper_approval_queue_*] modules included below, in
    dependency order: a module reads the ones above it and none below it.
    [For_testing] holds the seams that tests use. *)

open Keeper_approval_queue_rules
open Keeper_approval_queue_result
open Keeper_approval_queue_codec
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
include Keeper_approval_queue_query

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

