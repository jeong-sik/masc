(** Regression: durable event-queue persistence must not poison an owner's Eio
    gate on a disk write failure (audit 2026-06-29, owner isolation 2026-07-11).

    Before the fix, [save_json_atomic] called [Fs_compat.mkdir_p] — which raises
    (Sys_error / Unix_error) on ENOTDIR/ENOSPC/EROFS — inside the
    [Eio.Mutex.use_rw] critical section. [use_rw] poisons the mutex permanently
    on a raised exception, so the old process-global lock could block durable
    snapshots for every keeper for the lifetime of the process.

    This test drives the Eio path and repairs the failing filesystem ancestor
    before retrying the exact same canonical owner. The retry therefore proves
    that the owner's cooperative gate remains usable; a different BasePath
    cannot accidentally make the assertion pass through lock isolation. *)

module Event_queue_persistence_source = Keeper_event_queue_persistence
module Keeper_event_queue_persistence = struct
  include Event_queue_persistence_source

  let load ~base_path ~keeper_name =
    match load_result ~base_path ~keeper_name with
    | Ok queue -> queue
    | Error detail -> Alcotest.fail detail
  ;;
end

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Unix.unlink path

let snapshot_path ~base_path ~keeper_name =
  Filename.concat
    (Filename.concat (Common.keepers_runtime_dir_of_base ~base_path) keeper_name)
    "event-queue-v19.json"

let () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let mono_clock = Eio.Stdenv.mono_clock env in
  let net = Eio.Stdenv.net env in
  Eio.Switch.run @@ fun sw ->
  Eio_context.with_test_env ~net ~clock ~mono_clock ~sw @@ fun () ->
  (* [Eio_main.run] makes this an Eio fiber; [with_test_env] supplies the
     existing filesystem/network test context but does not select the lock. *)
  assert (Eio_context.get_switch_opt () <> None);

  let keeper_name = "poison_probe" in
  let queue = Keeper_event_queue.empty in

  (* 1) Force mkdir_p to raise inside the critical section: a base path whose
        ancestor is a regular file yields ENOTDIR. [persist] logs the failure as
        a warning and returns; pre-fix it ALSO poisoned the shared mutex. *)
  let blocker_path = Filename.temp_file "kqp_poison_blocker" "" in
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists blocker_path then rm_rf blocker_path)
    (fun () ->
      let base_path = Filename.concat blocker_path "base" in
      Keeper_event_queue_persistence.persist ~base_path ~keeper_name queue;

      (* 2) Replace the invalid ancestor and retry the same owner identity. *)
      Sys.remove blocker_path;
      Unix.mkdir blocker_path 0o755;
      Keeper_event_queue_persistence.persist ~base_path ~keeper_name queue;
      let path = snapshot_path ~base_path ~keeper_name in
      assert (Sys.file_exists path);

      (* 3) The lock still serializes correctly after recovery: load round-trips
         the persisted (empty) queue without raising. *)
      let restored =
        Keeper_event_queue_persistence.load ~base_path ~keeper_name
      in
      assert (Keeper_event_queue.is_empty restored);

      (* 4) With the process pool installed, the snapshot is rendered in a
         pool job. The bytes on disk are still the printed, sanitized JSON of
         the state the owner reads back. *)
      let pool = Domain_pool.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env) in
      Domain_pool_ref.set pool;
      let revision_on_disk () =
        match
          Keeper_event_queue_persistence.load_state_result ~base_path ~keeper_name
        with
        | Error detail -> failwith detail
        | Ok state -> state, Keeper_event_queue_state.revision state
      in
      Fun.protect ~finally:Domain_pool_ref.clear_for_tests (fun () ->
        let _, before = revision_on_disk () in
        Keeper_event_queue_persistence.persist ~base_path ~keeper_name queue;
        match revision_on_disk () with
        | _, after when Int64.compare after before <= 0 ->
          failwith "the pooled persist did not write a new snapshot"
        | state, _ ->
          let expected =
            Keeper_event_queue_state.to_yojson state
            |> Safe_ops.sanitize_json_utf8
            |> Yojson.Safe.pretty_to_string
          in
          assert (String.equal expected (In_channel.with_open_bin path In_channel.input_all))));

  print_endline "test_keeper_event_queue_persist_poison: OK"
