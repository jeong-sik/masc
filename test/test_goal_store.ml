module Types = Masc_domain

(** Tests for Goal_store.delete_goal — Issue #7690 regression.

    Bug: the previous implementation used [{ st with goals = ...; updated_at }]
    which preserves [version], so successive deletes all landed at the same
    version. Replicas/snapshot consumers couldn't detect the change. This
    test asserts the version is bumped on every delete, matching
    [refresh_all] / [upsert_goal]. *)

open Alcotest
open Masc

let temp_dir () =
  Filename.temp_dir "goal_store_test" ""

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

let with_workspace f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = temp_dir () in
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () ->
    let config = Workspace.default_config dir in
    ignore (Workspace.init config ~agent_name:(Some "test"));
    f config)

let iso_now () = Masc_domain.now_iso ()

let goals_recovery_path config =
  Goal_store.goals_path config ^ ".last-good"

let make_goal id title =
  let ts = iso_now () in
  {
    Goal_store.id; title;
    metric = None; target_value = None; due_date = None;
    priority = 3; status = Active; phase = Goal_phase.Executing;
    parent_goal_id = None;
    last_review_note = None; last_review_at = None;
    created_at = ts; updated_at = ts;
  }

let test_delete_goal_bumps_version () =
  with_workspace @@ fun config ->
  let g = make_goal "g-1" "to delete" in
  Goal_store.write_state config
    { version = 10; updated_at = iso_now (); goals = [g] };
  let v_before = (Goal_store.read_state config).version in
  check int "initial version" 10 v_before;
  (match Goal_store.delete_goal config ~goal_id:"g-1" with
   | Ok Goal_store.Deleted -> ()
   | Ok (Goal_store.Deleted_with_orphaned_links msg) ->
     fail ("unexpected partial cleanup failure: " ^ msg)
   | Error e -> fail ("delete_goal failed: " ^ Goal_store.delete_goal_error_to_string e));
  let v_after = (Goal_store.read_state config).version in
  check int "version bumped by 1" (v_before + 1) v_after

let test_multiple_deletes_each_bump () =
  with_workspace @@ fun config ->
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
  with_workspace @@ fun config ->
  let g = make_goal "exists" "one goal" in
  Goal_store.write_state config
    { version = 42; updated_at = iso_now (); goals = [g] };
  let v_before = (Goal_store.read_state config).version in
  (match Goal_store.delete_goal config ~goal_id:"ghost" with
   | Error (Goal_store.Unknown_goal _) -> ()
   | Error err ->
     fail ("expected Unknown_goal, got: " ^ Goal_store.delete_goal_error_to_string err)
   | Ok _ -> fail "expected error for missing goal");
  let v_after = (Goal_store.read_state config).version in
  check int "version unchanged on error" v_before v_after

let test_updated_at_also_refreshed () =
  with_workspace @@ fun config ->
  let g = make_goal "g-1" "x" in
  let stale_ts = "2020-01-01T00:00:00Z" in
  Goal_store.write_state config
    { version = 1; updated_at = stale_ts; goals = [g] };
  let _ = Goal_store.delete_goal config ~goal_id:"g-1" in
  let after = Goal_store.read_state config in
  check bool "updated_at refreshed" true (after.updated_at <> stale_ts)

let test_delete_goal_prunes_goal_task_links () =
  with_workspace
  @@ fun config ->
  let deleted = make_goal "g-1" "deleted goal" in
  let preserved = make_goal "g-2" "preserved goal" in
  Goal_store.write_state
    config
    { version = 1; updated_at = iso_now (); goals = [ deleted; preserved ] };
  Workspace_goal_index.write_goal_task_links
    config
    [ "g-1", [ "task-a"; "task-b" ]; "g-2", [ "task-c" ] ];
  (match Goal_store.delete_goal config ~goal_id:"g-1" with
   | Ok Goal_store.Deleted -> ()
   | Ok (Goal_store.Deleted_with_orphaned_links msg) ->
     fail ("unexpected partial cleanup failure: " ^ msg)
   | Error msg -> fail (Goal_store.delete_goal_error_to_string msg));
  let links = Workspace_goal_index.read_goal_task_links config in
  check bool
    "deleted goal links removed"
    false
    (List.exists (fun (goal_id, _) -> String.equal goal_id "g-1") links);
  check bool
    "other goal links preserved"
    true
    (List.exists
       (fun (goal_id, task_ids) ->
          String.equal goal_id "g-2" && List.mem "task-c" task_ids)
       links)

let test_delete_goal_wraps_prune_failure_after_goal_delete () =
  with_workspace
  @@ fun config ->
  let deleted = make_goal "g-1" "deleted goal" in
  Goal_store.write_state config
    { version = 1; updated_at = iso_now (); goals = [ deleted ] };
  Workspace_goal_index.write_goal_task_links config [ "g-1", [ "task-a" ] ];
  let links_path = Workspace_goal_index.goal_task_links_path config in
  Sys.remove links_path;
  Unix.mkdir links_path 0o755;
  (match Goal_store.delete_goal config ~goal_id:"g-1" with
   | Ok Goal_store.Deleted -> fail "expected prune failure to return partial cleanup"
   | Ok (Goal_store.Deleted_with_orphaned_links msg) ->
     check bool
       "partial cleanup carries detail"
       true
       (String.length msg > 0)
   | Error msg -> fail (Goal_store.delete_goal_error_to_string msg));
  let goals = (Goal_store.read_state config).goals in
  check bool
    "goal deletion already committed"
    false
    (List.exists (fun goal -> String.equal goal.Goal_store.id "g-1") goals)

let test_legacy_status_defaults_phase () =
  with_workspace @@ fun config ->
  let legacy_goal ~id ~title ~status =
    `Assoc
      [
        ("id", `String id);
        ("title", `String title);
        ("metric", `Null);
        ("target_value", `Null);
        ("due_date", `Null);
        ("priority", `Int 3);
        ("status", `String status);
        ("parent_goal_id", `Null);
        ("last_review_note", `Null);
        ("last_review_at", `Null);
        ("created_at", `String (iso_now ()));
        ("updated_at", `String (iso_now ()));
      ]
  in
  Workspace.write_json config (Goal_store.goals_path config)
    (`Assoc
      [
        ("version", `Int 1);
        ("updated_at", `String (iso_now ()));
        ( "goals",
          `List
            [
              legacy_goal ~id:"legacy-active" ~title:"Legacy Active" ~status:"active";
              legacy_goal ~id:"legacy-paused" ~title:"Legacy Paused" ~status:"paused";
              legacy_goal ~id:"legacy-done" ~title:"Legacy Done" ~status:"done";
              legacy_goal ~id:"legacy-dropped" ~title:"Legacy Dropped" ~status:"dropped";
            ] );
      ]);
  let state = Goal_store.read_state config in
  let by_id id =
    List.find_opt
      (fun (goal : Goal_store.goal) -> String.equal goal.id id)
      state.goals
  in
  let check_legacy id expected_phase expected_status =
    match by_id id with
    | None -> fail ("missing legacy goal " ^ id)
    | Some goal ->
        check string (id ^ " phase") expected_phase
          (Goal_phase.to_string goal.phase);
        check string (id ^ " status") expected_status
          (match goal.status with
          | Active -> "active"
          | Paused -> "paused"
          | Done -> "done"
          | Dropped -> "dropped")
  in
  check int "legacy goal count" 4 (List.length state.goals);
  check_legacy "legacy-active" "executing" "active";
  check_legacy "legacy-paused" "paused" "paused";
  check_legacy "legacy-done" "completed" "done";
  check_legacy "legacy-dropped" "dropped" "dropped"

let test_blocked_phase_projects_legacy_status () =
  with_workspace @@ fun config ->
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

let test_list_goals_filters_by_phase () =
  with_workspace @@ fun config ->
  let make title phase =
    match Goal_store.upsert_goal config ~title ~phase () with
    | Ok _ -> ()
    | Error msg -> fail msg
  in
  make "Executing goal" Goal_phase.Executing;
  make "Completed goal" Goal_phase.Completed;
  make "Blocked goal" Goal_phase.Blocked;
  let goals =
    Goal_store.list_goals config ~phase:Goal_phase.Completed ()
  in
  check int "one completed goal" 1 (List.length goals);
  match goals with
  | [ goal ] ->
      check string "filtered phase preserved" "completed"
        (Goal_phase.to_string goal.phase)
  | _ -> fail "expected one filtered goal"

let test_update_missing_goal_does_not_bump () =
  with_workspace @@ fun config ->
  let goal = make_goal "exists" "one goal" in
  Goal_store.write_state config
    { version = 9; updated_at = iso_now (); goals = [ goal ] };
  let before = Goal_store.read_state config in
  (match Goal_store.update_goal config ~goal_id:"ghost" Fun.id with
   | Error _ -> ()
   | Ok _ -> fail "expected missing goal error");
  let after = Goal_store.read_state config in
  check int "version unchanged on missing update" before.version after.version;
  check string "updated_at unchanged on missing update" before.updated_at after.updated_at

let test_write_state_sanitizes_invalid_utf8_before_persisting () =
  with_workspace @@ fun config ->
  Safe_ops.reset_persistence_utf8_repair_stats_for_tests ();
  let replacement = "\xEF\xBF\xBD" in
  let goal =
    {
      (make_goal "utf8-goal" "bad\xffgoal") with
      metric = Some "metric\xffvalue";
      target_value = Some "target\xffvalue";
    }
  in
  Goal_store.write_state config
    { version = 1; updated_at = iso_now (); goals = [ goal ] };
  let raw = Fs_compat.load_file (Goal_store.goals_path config) in
  check bool "raw file has no original invalid byte" false
    (String.contains raw '\255');
  let state = Goal_store.read_state config in
  let saved_goal =
    match state.goals with
    | [ goal ] -> goal
    | _ -> fail "expected one goal"
  in
  check string "title repaired on write" ("bad" ^ replacement ^ "goal")
    saved_goal.title;
  check (option string) "metric repaired on write"
    (Some ("metric" ^ replacement ^ "value"))
    saved_goal.metric;
  let stats = Safe_ops.persistence_utf8_repair_stats () in
  check int "read path did not repair goal store" 0 stats.repaired_reads

let test_write_state_result_keeps_primary_commit_when_recovery_write_fails () =
  with_workspace @@ fun config ->
  Unix.mkdir (goals_recovery_path config) 0o755;
  let goal = make_goal "recovery-mirror-fail" "recovery mirror fail" in
  let state = { Goal_store.version = 3; updated_at = iso_now (); goals = [ goal ] } in
  (match Goal_store.write_state_result config state with
   | Ok () -> ()
   | Error msg ->
     fail ("recovery mirror failure should not fail committed primary write: " ^ msg));
  match Goal_store.get_goal config ~goal_id:goal.Goal_store.id with
  | Some stored -> check string "primary has goal" goal.title stored.title
  | None -> fail "primary goal missing after recovery mirror failure"

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
          test_case "delete prunes goal_task_links" `Quick
            test_delete_goal_prunes_goal_task_links;
          test_case "prune failure reports partial delete" `Quick
            test_delete_goal_wraps_prune_failure_after_goal_delete;
          test_case "legacy status defaults phase" `Quick
            test_legacy_status_defaults_phase;
          test_case "blocked phase projects legacy status" `Quick
            test_blocked_phase_projects_legacy_status;
          test_case "list_goals filters by phase" `Quick
            test_list_goals_filters_by_phase;
          test_case "missing update: no bump" `Quick
            test_update_missing_goal_does_not_bump;
          test_case "write_state sanitizes invalid utf8" `Quick
            test_write_state_sanitizes_invalid_utf8_before_persisting;
          test_case "recovery mirror write failure preserves primary" `Quick
            test_write_state_result_keeps_primary_commit_when_recovery_write_fails ] ) ]
