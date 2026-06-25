module Types = Masc_domain

(** Tests for Goal_store.delete_goal — Issue #7690 regression.

    Bug: the previous implementation used [{ st with goals = ...; updated_at }]
    which preserves [version], so successive deletes all landed at the same
    version. Replicas/snapshot consumers couldn't detect the change. This
    test asserts the version is bumped on every delete, matching
    [refresh_all] / [upsert_goal]. *)

open Alcotest
open Masc

let () = Mirage_crypto_rng_unix.use_default ()

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

let find_substring_from source needle start =
  let source_len = String.length source in
  let needle_len = String.length needle in
  let rec loop idx =
    if idx + needle_len > source_len
    then None
    else if String.sub source idx needle_len = needle
    then Some idx
    else loop (idx + 1)
  in
  loop start

let find_substring source needle = find_substring_from source needle 0

let contains_substring source needle =
  match find_substring source needle with
  | Some _ -> true
  | None -> false

let read_source_file rel =
  let source_root =
    match Sys.getenv_opt "DUNE_SOURCEROOT" with
    | Some root -> root
    | None -> Sys.getcwd ()
  in
  let path = Filename.concat source_root rel in
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> In_channel.input_all ic)

let write_file path content =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)

let read_file path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> In_channel.input_all ic)

let make_goal id title =
  let ts = iso_now () in
  {
    Goal_store.id; title;
    metric = None; target_value = None; due_date = None;
    priority = 3; status = Active; phase = Goal_phase.Executing;
    verifier_policy = None; require_completion_approval = false;
    active_verification_request_id = None; parent_goal_id = None;
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
   | Error (Goal_store.Store_unreadable msg) ->
     fail ("unexpected store unreadable error: " ^ msg)
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
  Workspace.write_json config (Goal_store.goals_path config)
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

let test_upsert_accepts_canonical_legacy_status_projection () =
  with_workspace @@ fun config ->
  let blocked, _kind =
    match
      Goal_store.upsert_goal
        config
        ~title:"Blocked with legacy status"
        ~phase:Goal_phase.Blocked
        ~status:Goal_store.Paused
        ()
    with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  check string "blocked phase accepted" "blocked"
    (Goal_phase.to_string blocked.phase);
  check string "blocked projects paused status" "paused"
    (match blocked.status with Paused -> "paused" | _ -> "other");
  let awaiting_approval, _kind =
    match
      Goal_store.upsert_goal
        config
        ~title:"Approval with legacy status"
        ~phase:Goal_phase.Awaiting_approval
        ~status:Goal_store.Active
        ()
    with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  check string "awaiting approval phase accepted" "awaiting_approval"
    (Goal_phase.to_string awaiting_approval.phase);
  check string "awaiting approval projects active status" "active"
    (match awaiting_approval.status with Active -> "active" | _ -> "other");
  match
    Goal_store.upsert_goal
      config
      ~title:"Contradictory status"
      ~phase:Goal_phase.Completed
      ~status:Goal_store.Active
      ()
  with
  | Error msg -> check string "incompatible pair rejected"
                   "phase and legacy status disagree" msg
  | Ok _ -> fail "incompatible phase/status pair should reject"

let test_persisted_status_phase_disagreement_surfaces_failure () =
  with_workspace @@ fun config ->
  let path = Goal_store.goals_path config in
  Workspace.write_json config path
    (`Assoc
      [
        ("version", `Int 1);
        ("updated_at", `String (iso_now ()));
        ( "goals",
          `List
            [
              `Assoc
                [
                  ("id", `String "bad-status-phase");
                  ("title", `String "Contradictory persisted goal");
                  ("metric", `Null);
                  ("target_value", `Null);
                  ("due_date", `Null);
                  ("priority", `Int 3);
                  ("status", `String "active");
                  ("phase", Goal_phase.to_yojson Goal_phase.Completed);
                  ("parent_goal_id", `Null);
                  ("last_review_note", `Null);
                  ("last_review_at", `Null);
                  ("created_at", `String (iso_now ()));
                  ("updated_at", `String (iso_now ()));
                ];
            ] );
      ]);
  let before = read_file path in
  (match Goal_store.read_state_result config with
   | Error msg ->
     check
       bool
       "result reader names status/phase disagreement"
       true
       (contains_substring msg "legacy status and phase disagree")
   | Ok _ -> fail "mismatched persisted status/phase must not parse as valid");
  let legacy_projection = Goal_store.read_state config in
  check int "legacy projection falls back empty" 0
    (List.length legacy_projection.goals);
  check string "contradictory primary preserved" before (read_file path)

let test_phase_only_row_derives_legacy_status () =
  with_workspace @@ fun config ->
  Workspace.write_json config (Goal_store.goals_path config)
    (`Assoc
      [
        ("version", `Int 1);
        ("updated_at", `String (iso_now ()));
        ( "goals",
          `List
            [
              `Assoc
                [
                  ("id", `String "phase-only");
                  ("title", `String "Phase-only persisted goal");
                  ("metric", `Null);
                  ("target_value", `Null);
                  ("due_date", `Null);
                  ("priority", `Int 3);
                  ("phase", Goal_phase.to_yojson Goal_phase.Completed);
                  ("parent_goal_id", `Null);
                  ("last_review_note", `Null);
                  ("last_review_at", `Null);
                  ("created_at", `String (iso_now ()));
                  ("updated_at", `String (iso_now ()));
                ];
            ] );
      ]);
  match Goal_store.read_state_result config with
  | Error msg -> fail msg
  | Ok state ->
    (match state.goals with
     | [ goal ] ->
       check string "phase-only row keeps phase" "completed"
         (Goal_phase.to_string goal.phase);
       check string "phase-only row derives status" "done"
         (match goal.status with Done -> "done" | _ -> "other")
     | _ -> fail "expected one phase-only goal")

let test_normalize_preserves_active_verification_request_only_in_verification_phase () =
  with_workspace @@ fun config ->
  let awaiting =
    {
      (make_goal "awaiting" "awaiting verification") with
      phase = Goal_phase.Awaiting_verification;
      status = Goal_store.Active;
      active_verification_request_id = Some "gvr-active";
    }
  in
  let executing =
    {
      (make_goal "executing" "executing") with
      active_verification_request_id = Some "gvr-stale";
    }
  in
  Goal_store.write_state config
    { version = 1; updated_at = iso_now (); goals = [ awaiting; executing ] };
  let state = Goal_store.read_state config in
  let find_goal id =
    match List.find_opt (fun goal -> String.equal goal.Goal_store.id id) state.goals with
    | Some goal -> goal
    | None -> fail ("missing goal " ^ id)
  in
  check (option string) "awaiting verification keeps active request"
    (Some "gvr-active")
    (find_goal "awaiting").active_verification_request_id;
  check (option string) "executing clears stale active request" None
    (find_goal "executing").active_verification_request_id

let test_normalize_goal_active_request_phase_guard () =
  let source = read_source_file "lib/goal/goal_store.ml" in
  let normalize_start =
    match find_substring source "and normalize_goal" with
    | Some idx -> idx
    | None -> fail "normalize_goal missing from source"
  in
  let normalize_end =
    match find_substring_from source "and goal_status_of_phase" normalize_start with
    | Some idx -> idx
    | None -> fail "goal_status_of_phase missing after normalize_goal"
  in
  let section =
    String.sub source normalize_start (normalize_end - normalize_start)
  in
  check bool "awaiting verification preserves request id" true
    (contains_substring
       section
       "Goal_phase.Awaiting_verification, request_id -> request_id");
  check bool "awaiting approval is explicitly enumerated" true
    (contains_substring section "Goal_phase.Awaiting_approval");
  check bool "normalize_goal has no active-request catch-all" false
    (contains_substring section "_, _ -> None")

let test_list_goals_filters_by_phase () =
  with_workspace @@ fun config ->
  let make title phase =
    match Goal_store.upsert_goal config ~title ~phase () with
    | Ok _ -> ()
    | Error msg -> fail msg
  in
  make "Executing goal" Goal_phase.Executing;
  make "Approval goal" Goal_phase.Awaiting_approval;
  make "Blocked goal" Goal_phase.Blocked;
  let goals =
    Goal_store.list_goals config ~phase:Goal_phase.Awaiting_approval ()
  in
  check int "one goal in awaiting approval" 1 (List.length goals);
  match goals with
  | [ goal ] ->
      check string "filtered phase preserved" "awaiting_approval"
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

let test_update_goal_checked_error_does_not_write () =
  with_workspace @@ fun config ->
  let goal = make_goal "exists" "one goal" in
  Goal_store.write_state config
    { version = 7; updated_at = iso_now (); goals = [ goal ] };
  let before = Goal_store.read_state config in
  (match
     Goal_store.update_goal_checked config ~goal_id:"exists" (fun current ->
       let _candidate = { current with title = "should not persist" } in
       Error "precondition failed")
   with
   | Error msg -> check string "precondition error returned" "precondition failed" msg
   | Ok _ -> fail "expected checked update to fail");
  let after = Goal_store.read_state config in
  check int "version unchanged on checked update error" before.version after.version;
  check string
    "updated_at unchanged on checked update error"
    before.updated_at
    after.updated_at;
  match after.goals with
  | [ saved ] -> check string "goal unchanged" goal.title saved.title
  | _ -> fail "expected one goal after checked update error"

let corrupt_goal_store_files config =
  let path = Goal_store.goals_path config in
  let recovery = path ^ ".last-good" in
  let corrupt_primary = "{primary-goals-corrupt" in
  let corrupt_recovery = "{recovery-goals-corrupt" in
  write_file path corrupt_primary;
  write_file recovery corrupt_recovery;
  path, recovery, corrupt_primary, corrupt_recovery

let check_corrupt_goal_files_preserved path recovery corrupt_primary corrupt_recovery =
  check string "primary corrupt goals file preserved" corrupt_primary (read_file path);
  check
    string
    "recovery corrupt goals file preserved"
    corrupt_recovery
    (read_file recovery)

let test_read_state_result_surfaces_corrupt_goal_store () =
  with_workspace @@ fun config ->
  let path, recovery, corrupt_primary, corrupt_recovery =
    corrupt_goal_store_files config
  in
  (match Goal_store.read_state_result config with
   | Error msg ->
     check
       bool
       "result reader names goal state failure"
       true
       (contains_substring msg "failed to read goal state")
   | Ok _ -> fail "result reader must not hide corrupt goal store");
  let legacy_projection = Goal_store.read_state config in
  check int "legacy read-only projection stays empty" 0
    (List.length legacy_projection.goals);
  check_corrupt_goal_files_preserved path recovery corrupt_primary corrupt_recovery

let test_goal_mutations_fail_closed_on_corrupt_goal_store () =
  with_workspace @@ fun config ->
  let path, recovery, corrupt_primary, corrupt_recovery =
    corrupt_goal_store_files config
  in
  (match Goal_store.upsert_goal config ~title:"must not overwrite corrupt goals" () with
   | Error msg ->
     check
       bool
       "upsert rejects corrupt goal store"
       true
       (contains_substring msg "failed to read goal state")
   | Ok _ -> fail "upsert must not overwrite corrupt goal store");
  check_corrupt_goal_files_preserved path recovery corrupt_primary corrupt_recovery;
  (match Goal_store.update_state_result config (fun state -> Ok state) with
   | Error msg ->
     check
       bool
       "result update rejects corrupt goal store"
       true
       (contains_substring msg "failed to read goal state")
   | Ok _ -> fail "result update must not overwrite corrupt goal store");
  check_corrupt_goal_files_preserved path recovery corrupt_primary corrupt_recovery;
  let legacy_update_error =
    try
      ignore
        (Goal_store.update_state config (fun state ->
           { state with version = state.version + 1 })
         : Goal_store.state);
      None
    with
    | Invalid_argument msg -> Some msg
    | exn ->
      fail
        (Printf.sprintf
           "legacy update raised unexpected exception: %s"
           (Printexc.to_string exn))
  in
  (match legacy_update_error with
   | Some msg ->
     check
       bool
       "legacy update rejects corrupt goal store"
       true
       (contains_substring msg "failed to read goal state")
   | None -> fail "legacy update must not overwrite corrupt goal store");
  check_corrupt_goal_files_preserved path recovery corrupt_primary corrupt_recovery;
  (match Goal_store.update_goal_checked config ~goal_id:"goal-a" (fun goal -> Ok goal) with
   | Error msg ->
     check
       bool
       "checked update rejects corrupt goal store"
       true
       (contains_substring msg "failed to read goal state")
   | Ok _ -> fail "checked update must not overwrite corrupt goal store");
  check_corrupt_goal_files_preserved path recovery corrupt_primary corrupt_recovery;
  (match Goal_store.delete_goal config ~goal_id:"goal-a" with
   | Error (Goal_store.Store_unreadable msg) ->
     check
       bool
       "delete rejects corrupt goal store"
       true
       (contains_substring msg "failed to read goal state")
   | Error (Goal_store.Unknown_goal msg) ->
     fail ("delete reported unknown goal instead of unreadable store: " ^ msg)
   | Ok _ -> fail "delete must not overwrite corrupt goal store");
  check_corrupt_goal_files_preserved path recovery corrupt_primary corrupt_recovery

let test_upsert_mints_random_goal_ids () =
  with_workspace @@ fun config ->
  let n = 256 in
  let seen = Hashtbl.create n in
  for idx = 1 to n do
    match Goal_store.upsert_goal config ~title:(Printf.sprintf "goal %d" idx) () with
    | Error msg -> fail msg
    | Ok (goal, `created) ->
      check bool "random goal id prefix" true
        (String.starts_with ~prefix:"goal-" goal.id);
      check int "random goal id length" 37 (String.length goal.id);
      check bool "goal id unique in burst" false (Hashtbl.mem seen goal.id);
      Hashtbl.add seen goal.id ()
    | Ok (_, `updated) -> fail "new goal unexpectedly updated existing row"
  done;
  check int "all burst goal ids unique" n (Hashtbl.length seen)

let test_upsert_parent_validation_runs_under_goal_lock_source_guard () =
  let source = read_source_file "lib/goal/goal_store.ml" in
  check bool
    "stale pre-lock parent validation comment absent"
    false
    (contains_substring source "Validate parent_goal_id before acquiring");
  let upsert_idx =
    match find_substring source "let upsert_goal" with
    | Some idx -> idx
    | None -> fail "upsert_goal missing from source"
  in
  let lock_idx =
    match
      find_substring_from
        source
        "Workspace_utils.with_file_lock config (goals_path config)"
        upsert_idx
    with
    | Some idx -> idx
    | None -> fail "upsert_goal missing goal-store file lock"
  in
  let validation_idx =
    match find_substring_from source "validate_parent_goal_id" upsert_idx with
    | Some idx -> idx
    | None -> fail "upsert_goal missing parent validation"
  in
  check bool
    "parent validation runs after goal-store lock"
    true
    (lock_idx < validation_idx)

let test_goal_id_source_uses_random_id () =
  let source = read_source_file "lib/goal/goal_store.ml" in
  check bool "goal id uses Random_id" true
    (contains_substring source "Random_id.prefixed ~prefix:\"goal-\" ~bytes:16");
  check bool "old millisecond goal id shape absent" false
    (contains_substring source "goal-%d-%04x")

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
          test_case "upsert accepts canonical legacy status projection" `Quick
            test_upsert_accepts_canonical_legacy_status_projection;
          test_case "persisted status/phase disagreement surfaces failure" `Quick
            test_persisted_status_phase_disagreement_surfaces_failure;
          test_case "phase-only row derives legacy status" `Quick
            test_phase_only_row_derives_legacy_status;
          test_case "active verification request normalized by phase" `Quick
            test_normalize_preserves_active_verification_request_only_in_verification_phase;
          test_case "normalize_goal active request phase guard" `Quick
            test_normalize_goal_active_request_phase_guard;
          test_case "list_goals filters by phase" `Quick
            test_list_goals_filters_by_phase;
          test_case "missing update: no bump" `Quick
            test_update_missing_goal_does_not_bump;
          test_case "checked update error: no write" `Quick
            test_update_goal_checked_error_does_not_write;
          test_case "corrupt goal store: result reader surfaces failure" `Quick
            test_read_state_result_surfaces_corrupt_goal_store;
          test_case "corrupt goal store: mutations fail closed" `Quick
            test_goal_mutations_fail_closed_on_corrupt_goal_store;
          test_case "upsert mints random goal ids" `Quick
            test_upsert_mints_random_goal_ids;
          test_case "upsert parent validation runs under goal lock" `Quick
            test_upsert_parent_validation_runs_under_goal_lock_source_guard;
          test_case "goal id source uses random id" `Quick
            test_goal_id_source_uses_random_id;
          test_case "write_state sanitizes invalid utf8" `Quick
            test_write_state_sanitizes_invalid_utf8_before_persisting ] ) ]
