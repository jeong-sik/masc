(** #9764/#9733/#9769: write_meta CAS retry semantics.

    Verifies that [Keeper_types.write_meta_with_retry]:
      - succeeds when no concurrent writer interferes
      - succeeds after N attempts when the disk version has advanced
      - distinguishes version conflicts from real I/O errors via
        [is_version_conflict_error] *)

open Alcotest
open Masc_mcp

let () = Server_startup_state.mark_state_ready ~backend_mode:"test"

let temp_dir () =
  let dir = Filename.temp_file "test_keeper_meta_cas_" "" in
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

let test_no_conflict_writes_first_attempt () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  let base_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_dir) (fun () ->
    let config = Coord.default_config base_dir in
    ignore (Coord.init config ~agent_name:(Some "operator"));
    let m0 = make_meta ~name:"alpha" in
    (* Initial write — no existing file. *)
    (match Keeper_types.write_meta_with_retry config m0 with
     | Ok () -> ()
     | Error e -> fail ("first write failed: " ^ e));
    (* Read what landed on disk and bump caller's version to match. *)
    let disk = match Keeper_types.read_meta config "alpha" with
      | Ok (Some m) -> m
      | _ -> fail "disk read failed"
    in
    let m1 = { disk with goal = "updated goal" } in
    match Keeper_types.write_meta_with_retry config m1 with
    | Ok () ->
      let after = match Keeper_types.read_meta config "alpha" with
        | Ok (Some m) -> m
        | _ -> fail "read after write failed"
      in
      check string "goal updated" "updated goal" after.goal
    | Error e -> fail ("second write failed: " ^ e))

let test_retry_succeeds_after_concurrent_bump () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  let base_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_dir) (fun () ->
    let config = Coord.default_config base_dir in
    ignore (Coord.init config ~agent_name:(Some "operator"));
    let m0 = make_meta ~name:"beta" in
    (match Keeper_types.write_meta ~force:true config m0 with
     | Ok () -> ()
     | Error e -> fail ("seed write failed: " ^ e));
    let caller_view = match Keeper_types.read_meta config "beta" with
      | Ok (Some m) -> m
      | _ -> fail "seed read failed"
    in
    (* Simulate a concurrent writer bumping the disk version while
       [caller_view] is held by the cycle-completion fiber. *)
    let racing = { caller_view with goal = "racing writer" } in
    (match Keeper_types.write_meta config racing with
     | Ok () -> ()
     | Error e -> fail ("racing write failed: " ^ e));
    (* Now the cycle attempts to write its own payload. CAS would fail
       once; write_meta_with_retry must lift the payload onto the new
       disk version and succeed. *)
    let cycle_payload = { caller_view with goal = "cycle payload" } in
    (match Keeper_types.write_meta_with_retry config cycle_payload with
     | Ok () -> ()
     | Error e -> fail ("retry write failed: " ^ e));
    let final = match Keeper_types.read_meta config "beta" with
      | Ok (Some m) -> m
      | _ -> fail "final read failed"
    in
    check string "cycle payload wins (last writer)" "cycle payload" final.goal;
    check bool "version moved past racing write" true
      (final.meta_version > racing.meta_version + 1))

let test_is_version_conflict_error_classifies () =
  let conflict_msg = "meta version conflict for foo: expected 3, disk has 4" in
  let other_msg = "failed to write meta /tmp/x: Permission denied" in
  check bool "classifies version conflict" true
    (Keeper_types.is_version_conflict_error conflict_msg);
  check bool "rejects unrelated error" false
    (Keeper_types.is_version_conflict_error other_msg)

let () =
  run "Keeper_types CAS retry (#9764/#9733/#9769)"
    [
      ( "write_meta_with_retry",
        [
          test_case "writes on first attempt when no conflict" `Quick
            test_no_conflict_writes_first_attempt;
          test_case "lifts payload onto disk version after concurrent bump" `Quick
            test_retry_succeeds_after_concurrent_bump;
        ] );
      ( "is_version_conflict_error",
        [
          test_case "classifies conflict vs I/O error" `Quick
            test_is_version_conflict_error_classifies;
        ] );
    ]
