(** Keeper_checkpoint_store — checkpoint file I/O.

    Handles saving, loading, listing, and pruning AGENT_CORE checkpoint JSON files
    within a session directory. Separated from [Keeper_working_context]
    so that file I/O concerns do not mix with context types and
    pure operations.

    The code lives in the [Keeper_checkpoint_store_*] modules included below.
    Each include uses only the ones above it, and [keeper_checkpoint_store.mli]
    is the interface callers see.

    @since keeper-ctx-split *)

include Keeper_checkpoint_store_history_files
include Keeper_checkpoint_store_decode
include Keeper_checkpoint_store_summary
include Keeper_checkpoint_store_lineage
include Keeper_checkpoint_store_load
include Keeper_checkpoint_store_session
include Keeper_checkpoint_store_canonical
include Keeper_checkpoint_store_ref_errors
include Keeper_checkpoint_store_installation
include Keeper_checkpoint_store_exact_snapshot
include Keeper_checkpoint_store_cas_save
include Keeper_checkpoint_store_retained
include Keeper_checkpoint_store_export
include Keeper_checkpoint_store_save

module For_testing = struct
  module Inode_set = Set.Make (struct
    type t = int * int

    let compare (d1, i1) (d2, i2) =
      let c = Int.compare d1 d2 in
      if c <> 0 then c else Int.compare i1 i2
  end)

  let retained_payload_bytes ~directory =
    let seen = ref Inode_set.empty in
    let rec count total path =
      let stat = Unix.lstat path in
      match stat.Unix.st_kind with
      | Unix.S_DIR ->
        Array.fold_left (fun total leaf -> count total (Filename.concat path leaf))
          total (Sys.readdir path)
      | Unix.S_REG ->
        let key = stat.Unix.st_dev, stat.Unix.st_ino in
        if Inode_set.mem key !seen then total
        else (
          seen := Inode_set.add key !seen;
          if stat.Unix.st_size > max_int - total then invalid_arg "retained payload byte count overflow";
          total + stat.Unix.st_size)
      | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK -> total
    in
    count 0 directory

  let save_agent_core_for_keeper_measured ~keeper_name ~session_dir ~history_retained ~boundary ckpt =
    let bytes = ref (Some 0) in
    let on_payload observation =
      bytes := (match !bytes, observation with
        | Some total, Some count when count <= max_int - total -> Some (total + count)
        | Some _, Some _ | None, Some _ | Some _, None | None, None -> None)
    in
    save_agent_core_classified_typed
      ~write_canonical:write_canonical_durably
      ~save_lineage:(Save_for_keeper keeper_name) ~payload_writer:(Checkpoint_payload_writer.Measured on_payload) ~session_dir ~history_retained ~boundary ckpt
    |> Result.map (fun outcome -> outcome, !bytes)
    |> Result.map_error save_agent_core_error_to_string

  let with_before_history_link hook f =
    let previous = Atomic.exchange before_history_link_hook (Some hook) in
    Fun.protect ~finally:(fun () -> Atomic.set before_history_link_hook previous) f

  let retain_exact_snapshot_with_writer = retain_exact_snapshot_with

  let save_agent_core_if_source_with_observer
      ~on_checkpoint_commit_observer
      ~session_dir
      ~expected_source_ref
      ~boundary
      candidate =
    save_agent_core_if_source_with
      ~with_checkpoint_cas_lock
      ~write_checkpoint_bytes
      ~on_checkpoint_commit_observer
      ~session_dir
      ~expected_source_ref
      ~boundary
      candidate
  ;;

  let save_agent_core_if_source_with_release_failure
      ~release_failure
      ~on_checkpoint_commit_observer
      ~session_dir
      ~expected_source_ref
      ~boundary
      candidate =
    let with_release_failure ~session_dir f =
      match canonical_session_location session_dir with
      | Error error ->
        not_installed
          (Source_unavailable
             (Ref_lock_failed (save_agent_core_error_to_string error)))
      | Ok session_dir ->
        let lock_path = session_dir ^ ".checkpoint.lock" in
        File_lock_eio.For_testing.with_durable_lock_observed_with_release_failure
          ~release_failure
          ~lock_path
          (fun () -> f session_dir)
        |> installation_of_lock_observation
    in
    save_agent_core_if_source_with
      ~with_checkpoint_cas_lock:with_release_failure
      ~write_checkpoint_bytes
      ~on_checkpoint_commit_observer
      ~session_dir
      ~expected_source_ref
      ~boundary
      candidate
  ;;

  let save_agent_core_if_source_with_acquire_failure
      ~acquire_failure
      ~on_checkpoint_commit_observer
      ~session_dir
      ~expected_source_ref
      ~boundary
      candidate =
    let with_acquire_failure ~session_dir:_ _f =
      installation_of_lock_observation
        (File_lock_eio.Lock_not_acquired acquire_failure)
    in
    save_agent_core_if_source_with
      ~with_checkpoint_cas_lock:with_acquire_failure
      ~write_checkpoint_bytes
      ~on_checkpoint_commit_observer
      ~session_dir
      ~expected_source_ref
      ~boundary
      candidate
  ;;

  let save_agent_core_if_source_with_writer
      ~write_checkpoint_bytes
      ~on_checkpoint_commit_observer
      ~session_dir
      ~expected_source_ref
      ~boundary
      candidate =
    save_agent_core_if_source_with
      ~with_checkpoint_cas_lock
      ~write_checkpoint_bytes
      ~on_checkpoint_commit_observer
      ~session_dir
      ~expected_source_ref
      ~boundary
      candidate
  ;;

  let save_agent_core_if_source_with_post_commit_unwind
      ~post_commit_unwind
      ~on_checkpoint_commit_observer
      ~session_dir
      ~expected_source_ref
      ~boundary
      candidate =
    let with_post_commit_unwind ~session_dir f =
      match with_checkpoint_cas_lock ~session_dir f with
      | Installed _ as installation ->
        post_commit_unwind ();
        installation
      | Not_installed _ as outcome -> outcome
    in
    save_agent_core_if_source_with
      ~with_checkpoint_cas_lock:with_post_commit_unwind
      ~write_checkpoint_bytes
      ~on_checkpoint_commit_observer
      ~session_dir
      ~expected_source_ref
      ~boundary
      candidate
  ;;

  let save_agent_core_for_keeper_with_before_stage
      ~before_stage ~keeper_name ~session_dir ~history_retained ~boundary ckpt
    =
    save_agent_core_classified_typed
      ~write_canonical:(fun ~ownership_root path encoded_source ->
        Keeper_fs.For_testing.save_encoded_durable_atomic_from
          ~before_stage ~ownership_root path encoded_source)
      ~save_lineage:(Save_for_keeper keeper_name) ~payload_writer:Checkpoint_payload_writer.Unmeasured ~session_dir ~history_retained ~boundary ckpt
    |> Result.map_error save_agent_core_error_to_string
  ;;
end
