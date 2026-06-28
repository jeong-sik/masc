(** Regression: durable event-queue persistence must not poison its shared,
    process-global Eio mutex on a disk write failure (audit 2026-06-29).

    Before the fix, [save_json_atomic] called [Fs_compat.mkdir_p] — which raises
    (Sys_error / Unix_error) on ENOTDIR/ENOSPC/EROFS — inside the
    [Eio.Mutex.use_rw] critical section. [use_rw] poisons the mutex permanently
    on a raised exception, so a single disk error blocked durable snapshots for
    EVERY keeper for the lifetime of the process.

    This test drives the Eio path (so [Eio_context.get_switch_opt] returns
    [Some], selecting the poison-prone [eio_write_mu]) and asserts that a failed
    persist leaves the mutex usable for a subsequent valid persist. On the
    unfixed code the second persist's [with_write_lock] raises
    [Eio.Mutex.Poisoned], [persist] swallows it, the snapshot file is never
    written, and the [Sys.file_exists] assertion fails (RED). *)

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
  (* Exercise the Eio mutex (poison-prone path), not the Stdlib fallback. *)
  assert (Eio_context.get_switch_opt () <> None);

  let keeper_name = "poison_probe" in
  let queue = Keeper_event_queue.empty in

  (* 1) Force mkdir_p to raise inside the critical section: a base path whose
        ancestor is a regular file yields ENOTDIR. [persist] logs the failure as
        a warning and returns; pre-fix it ALSO poisoned the shared mutex. *)
  let blocker_file = Filename.temp_file "kqp_poison_blocker" "" in
  let bad_base = Filename.concat blocker_file "base" in
  Keeper_event_queue_persistence.persist ~base_path:bad_base ~keeper_name queue;

  (* 2) A valid persist on a real directory. If step 1 poisoned the mutex,
        [with_write_lock] raises [Eio.Mutex.Poisoned], [persist] swallows it, and
        the snapshot is never written -> the assertion below fails. *)
  let good_base = Filename.temp_dir "kqp_poison_ok" "" in
  Keeper_event_queue_persistence.persist ~base_path:good_base ~keeper_name queue;
  let path = snapshot_path ~base_path:good_base ~keeper_name in
  assert (Sys.file_exists path);

  (* 3) The lock still serializes correctly after recovery: load round-trips the
        persisted (empty) queue without raising. *)
  let restored =
    Keeper_event_queue_persistence.load ~base_path:good_base ~keeper_name
  in
  assert (Keeper_event_queue.is_empty restored);

  rm_rf good_base;
  (try Sys.remove blocker_file with _ -> ());
  print_endline "test_keeper_event_queue_persist_poison: OK"
