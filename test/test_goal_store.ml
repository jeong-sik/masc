(** Tests for Goal_store.delete_goal — Issue #7690 regression.

    Bug: the previous implementation used [{ st with goals = ...; updated_at }]
    which preserves [version], so successive deletes all landed at the same
    version. Replicas/snapshot consumers couldn't detect the change. This
    test asserts the version is bumped on every delete, matching
    [refresh_all] / [review_goal]. *)

open Alcotest
open Masc_mcp

let temp_dir () =
  let path = Filename.temp_file "goal_store_test" "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path

let rm_rf dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Sys.readdir path
        |> Array.iter (fun entry -> rm (Filename.concat path entry));
        Unix.rmdir path
      end else
        Sys.remove path
  in
  try rm dir with _ -> ()

let with_room f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = temp_dir () in
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () ->
    let config = Coord.default_config dir in
    ignore (Coord.init config ~agent_name:(Some "test"));
    f config)

let iso_now () = Types.now_iso ()

let make_goal id title =
  let ts = iso_now () in
  {
    Goal_store.id; horizon = Short; title;
    metric = None; target_value = None; due_date = None;
    priority = 3; status = Active; phase = Goal_phase.Executing;
    verifier_policy = None; require_completion_approval = false;
    active_verification_request_id = None; parent_goal_id = None;
    last_review_note = None; last_review_at = None;
    created_at = ts; updated_at = ts;
  }

let test_delete_goal_bumps_version () =
  with_room @@ fun config ->
  let g = make_goal "g-1" "to delete" in
  Goal_store.write_state config
    { version = 10; updated_at = iso_now (); goals = [g] };
  let v_before = (Goal_store.read_state config).version in
  check int "initial version" 10 v_before;
  (match Goal_store.delete_goal config ~goal_id:"g-1" with
   | Ok () -> ()
   | Error e -> fail ("delete_goal failed: " ^ e));
  let v_after = (Goal_store.read_state config).version in
  check int "version bumped by 1" (v_before + 1) v_after

let test_multiple_deletes_each_bump () =
  with_room @@ fun config ->
  let goals = List.init 3 (fun i ->
    make_goal (Printf.sprintf "g-%d" i) (Printf.sprintf "goal %d" i)) in
  Goal_store.write_state config
    { version = 5; updated_at = iso_now (); goals };
  let v0 = (Goal_store.read_state config).version in
  List.iter (fun i ->
    let _ = Goal_store.delete_goal config
              ~goal_id:(Printf.sprintf "g-%d" i) in ()) [0; 1; 2];
  let v_final = (Goal_store.read_state config).version in
  check int "three deletes = +3 versions" (v0 + 3) v_final;
  check int "all goals removed" 0
    (List.length (Goal_store.read_state config).goals)

let test_delete_nonexistent_does_not_bump () =
  with_room @@ fun config ->
  let g = make_goal "exists" "one goal" in
  Goal_store.write_state config
    { version = 42; updated_at = iso_now (); goals = [g] };
  let v_before = (Goal_store.read_state config).version in
  (match Goal_store.delete_goal config ~goal_id:"ghost" with
   | Error _ -> ()
   | Ok () -> fail "expected error for missing goal");
  let v_after = (Goal_store.read_state config).version in
  check int "version unchanged on error" v_before v_after

let test_updated_at_also_refreshed () =
  with_room @@ fun config ->
  let g = make_goal "g-1" "x" in
  let stale_ts = "2020-01-01T00:00:00Z" in
  Goal_store.write_state config
    { version = 1; updated_at = stale_ts; goals = [g] };
  let _ = Goal_store.delete_goal config ~goal_id:"g-1" in
  let after = Goal_store.read_state config in
  check bool "updated_at refreshed" true (after.updated_at <> stale_ts)

let test_legacy_status_defaults_phase () =
  with_room @@ fun config ->
  Coord.write_json config (Goal_store.goals_path config)
    (`Assoc
      [
        ("version", `Int 1);
        ("updated_at", `String (iso_now ()));
        ( "goals",
          `List
            [
              `Assoc
                [
                  ("id", `String "legacy-1");
                  ("horizon", `String "short");
                  ("title", `String "Legacy Goal");
                  ("metric", `Null);
                  ("target_value", `Null);
                  ("due_date", `Null);
                  ("priority", `Int 3);
                  ("status", `String "active");
                  ("parent_goal_id", `Null);
                  ("last_review_note", `Null);
                  ("last_review_at", `Null);
                  ("created_at", `String (iso_now ()));
                  ("updated_at", `String (iso_now ()));
                ];
            ] );
      ]);
  let state = Goal_store.read_state config in
  match state.goals with
  | [ goal ] ->
      check string "legacy active becomes executing" "executing"
        (Goal_phase.to_string goal.phase);
      check string "legacy active status preserved" "active"
        (match goal.status with Active -> "active" | _ -> "other")
  | _ -> fail "expected one legacy goal"

let test_blocked_phase_projects_legacy_status () =
  with_room @@ fun config ->
  let goal, _kind =
    match Goal_store.upsert_goal config ~title:"Blocked goal"
            ~phase:Goal_phase.Blocked ()
    with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  check string "blocked phase stored" "blocked" (Goal_phase.to_string goal.phase);
  check string "blocked phase projects to paused status" "paused"
    (match goal.status with Paused -> "paused" | _ -> "other")

let () =
  run "Goal_store.delete_goal"
    [ ( "regression-7690",
        [ test_case "version bumps +1" `Quick test_delete_goal_bumps_version;
          test_case "three deletes = +3" `Quick
            test_multiple_deletes_each_bump;
          test_case "missing goal: no bump" `Quick
            test_delete_nonexistent_does_not_bump;
          test_case "updated_at also refreshed" `Quick
            test_updated_at_also_refreshed;
          test_case "legacy status defaults phase" `Quick
            test_legacy_status_defaults_phase;
          test_case "blocked phase projects legacy status" `Quick
            test_blocked_phase_projects_legacy_status ] ) ]
