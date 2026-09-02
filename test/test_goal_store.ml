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
    priority = 3; phase = Goal_phase.Executing;
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

let test_status_field_no_longer_decodes () =
  with_workspace @@ fun config ->
  (* Hard cut: "status" is not an accepted Goal field. A row still carrying the
     retired duplicate is a decode error, so read_state applies the corrupt-store
     policy rather than accepting a row with two lifecycle representations. *)
  let row ~id ~phase ~status =
    `Assoc
      [
        ("id", `String id);
        ("title", `String ("Goal " ^ id));
        ("metric", `Null);
        ("target_value", `Null);
        ("due_date", `Null);
        ("priority", `Int 3);
        ("status", `String status);
        ("phase", `String phase);
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
              row ~id:"dual-active" ~phase:"executing" ~status:"active";
              row ~id:"dual-conflict" ~phase:"paused" ~status:"done";
            ] );
      ]);
  let on_disk_before = In_channel.with_open_bin (Goal_store.goals_path config)
    In_channel.input_all
  in
  let state = Goal_store.read_state config in
  check int "read of a store carrying the retired status field is empty" 0
    (List.length state.goals);
  (* Fail-closed: the lenient empty read must not license a write.  Without this
     the next upsert would overwrite goals.json AND its .last-good mirror with the
     empty state, turning one undecodable row into permanent loss. *)
  (match
     Goal_store.upsert_goal config ~title:"phase only" ~metric:"m"
       ~target_value:"1" ~phase:Goal_phase.Dropped ()
   with
   | Ok _ -> fail "upsert_goal wrote over an undecodable store"
   | Error msg ->
       check bool "refusal names the store path" true
         (String_util.contains_substring msg (Goal_store.goals_path config)));
  let on_disk_after = In_channel.with_open_bin (Goal_store.goals_path config)
    In_channel.input_all
  in
  check string "undecodable store is left byte-identical on disk" on_disk_before
    on_disk_after;
  check bool "no recovery mirror was written over it" false
    (Sys.file_exists (goals_recovery_path config))

let test_serializer_omits_status () =
  with_workspace @@ fun config ->
  match
    Goal_store.upsert_goal config ~title:"phase only" ~metric:"m"
      ~target_value:"1" ~phase:Goal_phase.Dropped ()
  with
  | Error msg -> fail msg
  | Ok (goal, _) -> (
      match Goal_store.goal_to_yojson goal with
      | `Assoc fields ->
          check bool "serializer omits status" false (List.mem_assoc "status" fields)
      | _ -> fail "goal_to_yojson: expected object")

let add_goal_field config key value =
  match Yojson.Safe.from_file (Goal_store.goals_path config) with
  | `Assoc state_fields ->
    let goals =
      match List.assoc_opt "goals" state_fields with
      | Some (`List [ `Assoc goal_fields ]) ->
        `List [ `Assoc ((key, value) :: goal_fields) ]
      | _ -> fail "expected one persisted goal"
    in
    Workspace.write_json
      config
      (Goal_store.goals_path config)
      (`Assoc (("goals", goals) :: List.remove_assoc "goals" state_fields));
    Workspace.write_json
      config
      (goals_recovery_path config)
      (`Assoc (("goals", goals) :: List.remove_assoc "goals" state_fields))
  | _ -> fail "expected persisted goal state object"

let test_other_unknown_goal_field_still_fails () =
  with_workspace @@ fun config ->
  let goal = make_goal "unknown-field" "unknown field fails" in
  Goal_store.write_state config
    { version = 1; updated_at = iso_now (); goals = [ goal ] };
  add_goal_field config "unexpected_assignment" (`String "still-closed");
  check int
    "unrelated unknown field keeps store undecodable"
    0
    (List.length (Goal_store.read_state config).goals);
  match
    Goal_store.update_goal_if_phase config ~goal_id:goal.id
      ~expected_phase:goal.phase Fun.id
  with
  | Ok _ -> fail "unknown field licensed a write"
  | Error detail ->
    check bool
      "unknown field write remains fail-closed"
      true
      (String_util.contains_substring detail "refusing to write")

let test_phaseless_row_no_longer_decodes () =
  with_workspace @@ fun config ->
  (* Counterfactual for the removed status->phase inference: a status-only
     row is now a decode error, and read_state falls back to the
     pre-existing corrupt-store policy (recovery mirror, else empty +
     warn) instead of silently defaulting the phase.  The live store was
     measured at zero such rows before this landed. *)
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
                  ("id", `String "legacy-only");
                  ("title", `String "Status-only row");
                  ("metric", `Null);
                  ("target_value", `Null);
                  ("due_date", `Null);
                  ("priority", `Int 3);
                  ("status", `String "paused");
                          ("last_review_note", `Null);
                  ("last_review_at", `Null);
                  ("created_at", `String (iso_now ()));
                  ("updated_at", `String (iso_now ()));
                ];
            ] );
      ]);
  let state = Goal_store.read_state config in
  check int "phase-less store rejected as corrupt" 0 (List.length state.goals)

let test_priorityless_row_no_longer_decodes () =
  with_workspace @@ fun config ->
  (* Same contract as phase (#23901): a row without an int [priority] is a
     decode error, not a silent 3 — a silent default would dress a corrupt
     row up as a plausible medium-priority goal. The live store was
     measured at zero such rows (2026-09-02, 79 goals). *)
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
                  ("id", `String "no-priority");
                  ("title", `String "Priority-less row");
                  ("metric", `Null);
                  ("target_value", `Null);
                  ("due_date", `Null);
                  ("phase", `String "Executing");
                  ("last_review_note", `Null);
                  ("last_review_at", `Null);
                  ("created_at", `String (iso_now ()));
                  ("updated_at", `String (iso_now ()));
                ];
            ] );
      ]);
  let state = Goal_store.read_state config in
  check int "priority-less store rejected as corrupt" 0 (List.length state.goals)

let test_dropped_phase_serializes_without_status () =
  with_workspace @@ fun config ->
  let goal, _kind =
    match Goal_store.upsert_goal config ~title:"Dropped goal"
            ~metric:"m" ~target_value:"1" ~phase:Goal_phase.Dropped ()
    with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  check string "dropped phase stored" "dropped" (Goal_phase.to_string goal.phase);
  match Goal_store.goal_to_yojson goal with
  | `Assoc fields ->
      check bool "no status field persisted" false (List.mem_assoc "status" fields)
  | _ -> fail "goal_to_yojson: expected object"

let test_list_goals_filters_by_phase () =
  with_workspace @@ fun config ->
  let make title phase =
    match Goal_store.upsert_goal config ~title ~metric:"m" ~target_value:"1"
            ~phase () with
    | Ok _ -> ()
    | Error msg -> fail msg
  in
  make "Executing goal" Goal_phase.Executing;
  make "Completed goal" Goal_phase.Completed;
  make "Dropped goal" Goal_phase.Dropped;
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
  (match
     Goal_store.update_goal_if_phase config ~goal_id:"ghost"
       ~expected_phase:goal.phase Fun.id
   with
   | Error _ -> ()
   | Ok _ -> fail "expected missing goal error");
  let after = Goal_store.read_state config in
  check int "version unchanged on missing update" before.version after.version;
  check string "updated_at unchanged on missing update" before.updated_at after.updated_at

let test_update_goal_if_phase_refuses_stale_phase () =
  with_workspace @@ fun config ->
  let goal = make_goal "cas" "concurrent transition refusal" in
  Goal_store.write_state config
    { version = 1; updated_at = iso_now (); goals = [ goal ] };
  let before = Goal_store.read_state config in
  (* A concurrent transition lands first: the goal leaves Executing. *)
  (match
     Goal_store.update_goal_if_phase config ~goal_id:goal.id
       ~expected_phase:Goal_phase.Executing
       (fun current -> { current with phase = Goal_phase.Dropped })
   with
   | Error detail -> fail ("first transition failed: " ^ detail)
   | Ok (Goal_store.Goal_phase_mismatch _) ->
     fail "first transition unexpectedly mismatched"
   | Ok (Goal_store.Goal_updated _) -> (
     (* The stale writer still believes the goal is Executing; its write must
        refuse without touching the stored phase or bumping the version. *)
     match
       Goal_store.update_goal_if_phase config ~goal_id:goal.id
         ~expected_phase:Goal_phase.Executing
         (fun current -> { current with phase = Goal_phase.Completed })
     with
     | Ok (Goal_store.Goal_phase_mismatch actual) ->
       check bool "stale write reports the actual phase" true
         (actual = Goal_phase.Dropped);
       let after = Goal_store.read_state config in
       check int "version not bumped by refused write"
         (before.version + 1) after.version;
       (match Goal_store.get_goal config ~goal_id:goal.id with
        | Some stored ->
          check bool "stored phase untouched by refused write" true
            (stored.phase = Goal_phase.Dropped)
        | None -> fail "goal vanished after refused write")
     | Ok (Goal_store.Goal_updated _) -> fail "stale-phase write licensed a transition"
     | Error detail -> fail ("stale write errored instead of refusing: " ^ detail)))

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
          test_case "status field no longer decodes" `Quick
            test_status_field_no_longer_decodes;
          test_case "serializer omits status" `Quick
            test_serializer_omits_status;
          test_case "other unknown goal field still fails" `Quick
            test_other_unknown_goal_field_still_fails;
          test_case "phase-less row no longer decodes" `Quick
            test_phaseless_row_no_longer_decodes;
          test_case "priority-less row no longer decodes" `Quick
            test_priorityless_row_no_longer_decodes;
          test_case "dropped phase serializes without status" `Quick
            test_dropped_phase_serializes_without_status;
          test_case "list_goals filters by phase" `Quick
            test_list_goals_filters_by_phase;
          test_case "missing update: no bump" `Quick
            test_update_missing_goal_does_not_bump;
          test_case "stale expected_phase refuses to write" `Quick
            test_update_goal_if_phase_refuses_stale_phase;
          test_case "write_state sanitizes invalid utf8" `Quick
            test_write_state_sanitizes_invalid_utf8_before_persisting;
          test_case "recovery mirror write failure preserves primary" `Quick
            test_write_state_result_keeps_primary_commit_when_recovery_write_fails ] ) ]
