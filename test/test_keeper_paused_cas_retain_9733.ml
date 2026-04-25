(** #9733 follow-up to PR #10135: pin that the [paused] field
    survives a heartbeat-vs-overflow-pause race when the
    [Keeper_unified_turn] overflow-pause / pause-sync paths use
    [write_meta_with_merge ~merge:heartbeat_fields_from_disk].

    Without the migration, a bare [write_meta] in
    [pause_keeper_for_overflow] / [sync_keeper_paused_state] can
    silently lose the pause when a heartbeat fiber bumps
    [meta_version] between the overflow fiber's read and write.
    The dashboard then shows the keeper as unpaused while the
    caller's [Keeper_registry.update_meta] thinks the persist
    succeeded — a state corruption with no operator-visible
    signal.

    These tests exercise the merge contract directly so a future
    refactor of [heartbeat_fields_from_disk] cannot silently
    reintroduce the regression. *)

open Alcotest
open Masc_mcp

let () = Server_startup_state.mark_state_ready ~backend_mode:"test"

let temp_dir () =
  let dir = Filename.temp_file "test_keeper_paused_cas_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let ensure_fs env =
  if not (Fs_compat.has_fs ()) then
    Fs_compat.set_fs (Eio.Stdenv.fs env)

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path)
      else
        Unix.unlink path
  in
  try rm dir with _ -> ()

let make_meta ~name =
  match
    Keeper_types.meta_of_json
      (`Assoc
        [
          ("name", `String name);
          ("agent_name", `String ("keeper-" ^ name ^ "-agent"));
          ("trace_id", `String ("trace-" ^ name));
          ("goal", `String "test keeper");
          ("autoboot_enabled", `Bool false);
        ])
  with
  | Ok m -> m
  | Error e -> fail ("meta_of_json failed: " ^ e)

(* Race: overflow fiber observed unpaused at version N, decides
   to pause; heartbeat fiber bumps to version N+1 with new
   joined_room_ids; overflow fiber attempts write with stale
   version.  Merged CAS retry must:
   - persist [paused = true]      (caller wins on cycle field)
   - retain [joined_room_ids]      (disk wins on heartbeat field)
   - increment meta_version past the heartbeat write *)
let test_pause_caller_wins_heartbeat_disk_wins () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  let base_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_dir) (fun () ->
    let config = Coord.default_config base_dir in
    ignore (Coord.init config ~agent_name:(Some "operator"));
    let m0 =
      let m = make_meta ~name:"pause-race-9733" in
      { m with paused = false; joined_room_ids = ["r1"] }
    in
    (match Keeper_types.write_meta ~force:true config m0 with
     | Ok () -> ()
     | Error e -> fail ("seed failed: " ^ e));
    let overflow_view =
      match Keeper_types.read_meta config "pause-race-9733" with
      | Ok (Some m) -> m
      | _ -> fail "seed read failed"
    in
    (* Heartbeat fiber bumps version, joins another room. *)
    let heartbeat_payload =
      { overflow_view with joined_room_ids = ["r1"; "r2"] }
    in
    (match Keeper_types.write_meta config heartbeat_payload with
     | Ok () -> ()
     | Error e -> fail ("heartbeat write failed: " ^ e));
    (* Overflow fiber writes pause with a stale version (the one
       it read at [overflow_view]).  This is what
       [pause_keeper_for_overflow] does: it modifies [paused] on
       its captured snapshot then writes.  The merged-CAS retry
       inside [write_meta_with_merge] must lift [paused = true]
       onto the disk's latest version + retain
       [joined_room_ids = [r1; r2]]. *)
    let pause_payload = { overflow_view with paused = true } in
    (match
       Keeper_types.write_meta_with_merge
         ~merge:Keeper_meta_merge.heartbeat_fields_from_disk
         config pause_payload
     with
     | Ok () -> ()
     | Error e -> fail ("pause merged write failed: " ^ e));
    let final = match Keeper_types.read_meta config "pause-race-9733" with
      | Ok (Some m) -> m
      | _ -> fail "final read failed"
    in
    check bool "paused = true (caller wins on cycle field)"
      true final.paused;
    check (list string)
      "joined_room_ids = [r1; r2] (disk wins on heartbeat field)"
      ["r1"; "r2"] final.joined_room_ids;
    check bool "meta_version moved past heartbeat write"
      true (final.meta_version > heartbeat_payload.meta_version))

(* Resume side of the same migration.  [sync_keeper_paused_state
   ~paused:false] must also retain heartbeat fields and persist
   the resume even under race. *)
let test_resume_caller_wins_heartbeat_disk_wins () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  let base_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_dir) (fun () ->
    let config = Coord.default_config base_dir in
    ignore (Coord.init config ~agent_name:(Some "operator"));
    let m0 =
      let m = make_meta ~name:"resume-race-9733" in
      { m with paused = true; joined_room_ids = ["r1"] }
    in
    (match Keeper_types.write_meta ~force:true config m0 with
     | Ok () -> ()
     | Error e -> fail ("seed failed: " ^ e));
    let resume_view =
      match Keeper_types.read_meta config "resume-race-9733" with
      | Ok (Some m) -> m
      | _ -> fail "seed read failed"
    in
    let heartbeat_payload =
      { resume_view with joined_room_ids = ["r1"; "r3"] }
    in
    (match Keeper_types.write_meta config heartbeat_payload with
     | Ok () -> ()
     | Error e -> fail ("heartbeat failed: " ^ e));
    let resume_payload = { resume_view with paused = false } in
    (match
       Keeper_types.write_meta_with_merge
         ~merge:Keeper_meta_merge.heartbeat_fields_from_disk
         config resume_payload
     with
     | Ok () -> ()
     | Error e -> fail ("resume merged write failed: " ^ e));
    let final = match Keeper_types.read_meta config "resume-race-9733" with
      | Ok (Some m) -> m
      | _ -> fail "final read failed"
    in
    check bool "paused = false (caller wins on cycle field)"
      false final.paused;
    check (list string)
      "joined_room_ids = [r1; r3] (disk wins on heartbeat field)"
      ["r1"; "r3"] final.joined_room_ids)

let () =
  run "Keeper paused-field CAS retain (#9733)"
    [
      ( "pause-resume-merge",
        [
          test_case "pause: caller wins, heartbeat retained" `Quick
            test_pause_caller_wins_heartbeat_disk_wins;
          test_case "resume: caller wins, heartbeat retained" `Quick
            test_resume_caller_wins_heartbeat_disk_wins;
        ] );
    ]
