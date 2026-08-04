(** Every load path must reject a nonempty legacy transition WAL (v4/v5): it is
    committed evidence the v6 binary cannot replay, so loading the current
    snapshot over it could resurrect already-disposed work. Empty legacy WALs
    carry no evidence and stay tolerated, matching
    scripts/check-keeper-event-queue-v15-cutover.sh. *)

module Persistence = Keeper_event_queue_persistence

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Unix.unlink path

let write_file path contents =
  Out_channel.with_open_bin path (fun oc -> Out_channel.output_string oc contents)

let contains_legacy_rejection message =
  let needle = "legacy transition WAL" in
  let needle_len = String.length needle in
  let message_len = String.length message in
  let rec go i =
    i + needle_len <= message_len
    && (String.equal (String.sub message i needle_len) needle || go (i + 1))
  in
  go 0

let expect_legacy_error label = function
  | Ok _ -> failwith (label ^ ": expected legacy transition WAL rejection")
  | Error message ->
    if not (contains_legacy_rejection message)
    then failwith (label ^ ": failed for another reason: " ^ message)

let expect_ok label = function
  | Ok _ -> ()
  | Error message -> failwith (label ^ ": expected Ok, got: " ^ message)

let () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let mono_clock = Eio.Stdenv.mono_clock env in
  let net = Eio.Stdenv.net env in
  Eio.Switch.run @@ fun sw ->
  Eio_context.with_test_env ~net ~clock ~mono_clock ~sw @@ fun () ->
  let base_path = Filename.temp_file "kq_legacy_wal" "" in
  Sys.remove base_path;
  Unix.mkdir base_path 0o755;
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists base_path then rm_rf base_path)
    (fun () ->
      let keeper_name = "legacy_probe" in
      Persistence.persist ~base_path ~keeper_name Keeper_event_queue.empty;
      let runtime_dir =
        Filename.concat (Common.keepers_runtime_dir_of_base ~base_path) keeper_name
      in
      let snapshot_path = Filename.concat runtime_dir "event-queue-v15.json" in
      let v4_path = Filename.concat runtime_dir "event-queue-transitions-v4.jsonl" in
      let v5_path = Filename.concat runtime_dir "event-queue-transitions-v5.jsonl" in
      assert (Sys.file_exists snapshot_path);

      (* An empty legacy WAL carries no evidence: loads stay Ok. *)
      write_file v5_path "";
      expect_ok
        "empty v5 beside snapshot"
        (Persistence.load_state_result ~base_path ~keeper_name);

      (* Nonempty legacy WAL beside the current snapshot: every load fails. *)
      write_file v5_path "{\"schema\":\"masc.keeper_event_queue.transition.v5\"}\n";
      expect_legacy_error
        "load_state_result with nonempty v5"
        (Persistence.load_state_result ~base_path ~keeper_name);
      expect_legacy_error
        "validate_state_read_only_result with nonempty v5"
        (Persistence.validate_state_read_only_result ~base_path ~keeper_name);

      (* The reviewer scenario: crash after appending the legacy transition but
         before checkpointing leaves the WAL as the only evidence. *)
      Sys.remove snapshot_path;
      expect_legacy_error
        "load_existing_state_result with WAL-only nonempty v5"
        (Persistence.load_existing_state_result ~base_path ~keeper_name);

      (* v4 sits in the same rejection set. *)
      Sys.remove v5_path;
      write_file v4_path "{\"schema\":\"masc.keeper_event_queue.transition.v4\"}\n";
      expect_legacy_error
        "load_state_result with nonempty v4"
        (Persistence.load_state_result ~base_path ~keeper_name);

      (* Removing the legacy evidence restores normal loads. *)
      Sys.remove v4_path;
      expect_ok
        "load after legacy WALs removed"
        (Persistence.load_state_result ~base_path ~keeper_name));

  print_endline "test_keeper_event_queue_legacy_wal_reject: OK"
