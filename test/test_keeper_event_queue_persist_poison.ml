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
    "event-queue.json"

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
      assert (Keeper_event_queue.is_empty restored));

  print_endline "test_keeper_event_queue_persist_poison: OK"
