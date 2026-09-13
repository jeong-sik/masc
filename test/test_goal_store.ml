module Types = Masc_domain

(** Tests for Goal_store.

    - Issue #7690 regression: the previous delete used
      [{ st with goals = ...; updated_at }] which preserves [version], so
      successive deletes all landed at the same version.
    - RFC-0444 PR-1: the store is read through the closed sum
      [Goal_store.source]; a store this build cannot read is [Unavailable]
      with its reason, mirror state and reset step, never an empty state, and
      every writer refuses it without touching either file. *)

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
    Goal_store.id; criterion_revision = "fixture-criterion-" ^ id; title;
    metric = None; target_value = None; due_date = None;
    priority = 3; phase = Goal_phase.Executing;
    last_review_note = None; last_review_at = None;
    created_at = ts; updated_at = ts;
  }

(* The state an [Available] store holds; any other source fails the test. *)
let available config =
  match Goal_store.load_source config with
  | Goal_store.Available state -> state
  | Goal_store.Uninitialized -> fail "expected an Available store, read Uninitialized"
  | Goal_store.Unavailable u ->
    fail ("expected an Available store, read " ^ Goal_store.unavailable_to_string u)

let unavailable config =
  match Goal_store.load_source config with
  | Goal_store.Unavailable u -> u
  | Goal_store.Available _ -> fail "expected an Unavailable store, read Available"
  | Goal_store.Uninitialized -> fail "expected an Unavailable store, read Uninitialized"

let write_error_msg = Goal_store.write_error_to_string

let file_digest path = Digest.to_hex (Digest.file path)

let write_raw path bytes =
  Out_channel.with_open_bin path (fun channel -> output_string channel bytes)

let test_delete_goal_bumps_version () =
  with_workspace @@ fun config ->
  let g = make_goal "g-1" "to delete" in
  Goal_store.write_state config
    { version = 10; updated_at = iso_now (); goals = [g] };
  let v_before = (available config).version in
  check int "initial version" 10 v_before;
  (match Goal_store.delete_goal config ~goal_id:"g-1" with
   | Ok Goal_store.Deleted -> ()
   | Ok (Goal_store.Deleted_with_orphaned_links msg) ->
     fail ("unexpected partial cleanup failure: " ^ msg)
   | Error e -> fail ("delete_goal failed: " ^ Goal_store.delete_goal_error_to_string e));
  let v_after = (available config).version in
  check int "version bumped by 1" (v_before + 1) v_after

let test_multiple_deletes_each_bump () =
  with_workspace @@ fun config ->
  let goals = List.init 3 (fun i ->
    make_goal (Printf.sprintf "g-%d" i) (Printf.sprintf "goal %d" i)) in
  Goal_store.write_state config
    { version = 5; updated_at = iso_now (); goals };
  let v0 = (available config).version in
  List.iter (fun i ->
    let _ = Goal_store.delete_goal config
              ~goal_id:(Printf.sprintf "g-%d" i) in ()) [0; 1; 2];
  let v_final = (available config).version in
  check int "three deletes = +3 versions" (v0 + 3) v_final;
  check int "all goals removed" 0
    (List.length (available config).goals)

let test_delete_nonexistent_does_not_bump () =
  with_workspace @@ fun config ->
  let g = make_goal "exists" "one goal" in
  Goal_store.write_state config
    { version = 42; updated_at = iso_now (); goals = [g] };
  let v_before = (available config).version in
  (match Goal_store.delete_goal config ~goal_id:"ghost" with
   | Error (Goal_store.Unknown_goal _) -> ()
   | Error err ->
     fail ("expected Unknown_goal, got: " ^ Goal_store.delete_goal_error_to_string err)
   | Ok _ -> fail "expected error for missing goal");
  let v_after = (available config).version in
  check int "version unchanged on error" v_before v_after

let test_updated_at_also_refreshed () =
  with_workspace @@ fun config ->
  let g = make_goal "g-1" "x" in
  let stale_ts = "2020-01-01T00:00:00Z" in
  Goal_store.write_state config
    { version = 1; updated_at = stale_ts; goals = [g] };
  let _ = Goal_store.delete_goal config ~goal_id:"g-1" in
  let after = available config in
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
  let goals = (available config).goals in
  check bool
    "goal deletion already committed"
    false
    (List.exists (fun goal -> String.equal goal.Goal_store.id "g-1") goals)

let test_status_field_no_longer_decodes () =
  with_workspace @@ fun config ->
  (* Hard cut: "status" is not an accepted Goal field. A row still carrying the
     retired duplicate is a decode error, so the source is [Unavailable] naming
     that field rather than a row with two lifecycle representations. *)
  let row ~id ~phase ~status =
    `Assoc
      [
        ("id", `String id);
        ("criterion_revision", `String "fixture-revision");
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
  (match (unavailable config).reason with
   | Goal_store.Schema_rejected { field; _ } ->
     check string "the retired status field is the rejected member" "status" field
   | Goal_store.Missing_after_init | Goal_store.Unreadable _ | Goal_store.Not_json _ ->
     fail "a row with the retired status field must be a schema rejection");
  (* Fail-closed: an unreadable store must not license a write.  Without this
     the next upsert would overwrite goals.json AND its .last-good mirror with an
     empty state, turning one undecodable row into permanent loss. *)
  (match
     Goal_store.upsert_goal config ~title:"phase only" ~metric:"m"
       ~target_value:"1" ~phase:Goal_phase.Dropped ()
   with
   | Ok _ -> fail "upsert_goal wrote over an undecodable store"
   | Error (Goal_store.Store_unavailable u) ->
       check string "refusal names the store path" (Goal_store.goals_path config) u.file
   | Error (Goal_store.Goal_not_found _ | Goal_store.Rejected _
           | Goal_store.Persist_failed _ as other) ->
       fail ("refusal was not Store_unavailable: " ^ write_error_msg other));
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
  | Error error -> fail (write_error_msg error)
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
  (match unavailable config with
   | { reason = Goal_store.Schema_rejected { field; _ };
       mirror = Goal_store.Mirror_rejected (Goal_store.Schema_rejected { field = mirror_field; _ });
       _ } ->
     check string "unrelated unknown field keeps store undecodable"
       "unexpected_assignment" field;
     check string "the mirror carries the same rejected member"
       "unexpected_assignment" mirror_field
   | u -> fail ("expected a schema rejection on both files: " ^ Goal_store.unavailable_to_string u));
  match
    Goal_store.update_goal_if_phase config ~goal_id:goal.id
      ~expected_phase:goal.phase Fun.id
  with
  | Ok _ -> fail "unknown field licensed a write"
  | Error (Goal_store.Store_unavailable
             { reason = Goal_store.Schema_rejected { field = "unexpected_assignment"; _ }; _ }) -> ()
  | Error other -> fail ("unknown field write was not Store_unavailable: " ^ write_error_msg other)

let test_undecodable_store_read_error_names_path () =
  with_workspace @@ fun config ->
  let goal = make_goal "read-error" "read error names the store path" in
  Goal_store.write_state config
    { version = 1; updated_at = iso_now (); goals = [ goal ] };
  add_goal_field config "unexpected_assignment" (`String "still-closed");
  match Goal_store.list_goals_result config () with
  | Ok _ -> fail "undecodable store listed goals"
  | Error { file; reason = Goal_store.Schema_rejected { field; detail }; reset_step; _ } ->
    check string "read error names the store path" (Goal_store.goals_path config) file;
    check string "read error names the rejected member" "unexpected_assignment" field;
    check bool "read error keeps the decode detail" true
      (String_util.contains_substring detail "unexpected_assignment");
    check bool "the reset step is to repair that member" true
      (reset_step = Goal_store.Repair_field "unexpected_assignment")
  | Error u -> fail ("expected a schema rejection: " ^ Goal_store.unavailable_to_string u)

let test_phaseless_row_no_longer_decodes () =
  with_workspace @@ fun config ->
  (* Counterfactual for the removed status->phase inference: a row without
     [phase] is a decode error naming that member instead of a silently
     defaulted phase. The live store was measured at zero such rows before
     this landed. *)
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
                  ("id", `String "phase-less");
                  ("criterion_revision", `String "fixture-revision");
                  ("title", `String "Phase-less row");
                  ("metric", `Null);
                  ("target_value", `Null);
                  ("due_date", `Null);
                  ("priority", `Int 3);
                  ("last_review_note", `Null);
                  ("last_review_at", `Null);
                  ("created_at", `String (iso_now ()));
                  ("updated_at", `String (iso_now ()));
                ];
            ] );
      ]);
  match (unavailable config).reason with
  | Goal_store.Schema_rejected { field; _ } ->
    check string "phase-less store rejected on the phase member" "phase" field
  | Goal_store.Missing_after_init | Goal_store.Unreadable _ | Goal_store.Not_json _ ->
    fail "a phase-less row must be a schema rejection"

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
                  ("criterion_revision", `String "fixture-revision");
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
  match (unavailable config).reason with
  | Goal_store.Schema_rejected { field; _ } ->
    check string "priority-less store rejected on the priority member" "priority" field
  | Goal_store.Missing_after_init | Goal_store.Unreadable _ | Goal_store.Not_json _ ->
    fail "a priority-less row must be a schema rejection"

let test_dropped_phase_serializes_without_status () =
  with_workspace @@ fun config ->
  let goal, _kind =
    match Goal_store.upsert_goal config ~title:"Dropped goal"
            ~metric:"m" ~target_value:"1" ~phase:Goal_phase.Dropped ()
    with
    | Ok payload -> payload
    | Error error -> fail (write_error_msg error)
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
    | Error error -> fail (write_error_msg error)
  in
  make "Executing goal" Goal_phase.Executing;
  make "Completed goal" Goal_phase.Completed;
  make "Dropped goal" Goal_phase.Dropped;
  let goals =
    match Goal_store.list_goals_result config ~phase:Goal_phase.Completed () with
    | Ok goals -> goals
    | Error u -> fail (Goal_store.unavailable_to_string u)
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
  let before = available config in
  (match
     Goal_store.update_goal_if_phase config ~goal_id:"ghost"
       ~expected_phase:goal.phase Fun.id
   with
   | Error (Goal_store.Goal_not_found "ghost") -> ()
   | Error other -> fail ("expected Goal_not_found: " ^ write_error_msg other)
   | Ok _ -> fail "expected missing goal error");
  let after = available config in
  check int "version unchanged on missing update" before.version after.version;
  check string "updated_at unchanged on missing update" before.updated_at after.updated_at

let test_update_goal_if_phase_refuses_stale_phase () =
  with_workspace @@ fun config ->
  let goal = make_goal "cas" "concurrent transition refusal" in
  Goal_store.write_state config
    { version = 1; updated_at = iso_now (); goals = [ goal ] };
  let before = available config in
  (* A concurrent transition lands first: the goal leaves Executing. *)
  (match
     Goal_store.update_goal_if_phase config ~goal_id:goal.id
       ~expected_phase:Goal_phase.Executing
       (fun current -> { current with phase = Goal_phase.Dropped })
   with
   | Error error -> fail ("first transition failed: " ^ write_error_msg error)
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
       let after = available config in
       check int "version not bumped by refused write"
         (before.version + 1) after.version;
       (match Goal_store.find_goal config ~goal_id:goal.id with
        | Goal_store.Goal_found stored ->
          check bool "stored phase untouched by refused write" true
            (stored.phase = Goal_phase.Dropped)
        | Goal_store.Goal_absent -> fail "goal vanished after refused write"
        | Goal_store.Store_unavailable u ->
          fail ("store unreadable after refused write: " ^ Goal_store.unavailable_to_string u))
     | Ok (Goal_store.Goal_updated _) -> fail "stale-phase write licensed a transition"
     | Error error ->
       fail ("stale write errored instead of refusing: " ^ write_error_msg error)))

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
  let state = available config in
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
  (* A primary that decodes is Available without the mirror being opened, so
     a directory at the mirror path does not reach the lookup. *)
  match Goal_store.find_goal config ~goal_id:goal.Goal_store.id with
  | Goal_store.Goal_found stored -> check string "primary has goal" goal.title stored.title
  | Goal_store.Goal_absent -> fail "primary goal missing after recovery mirror failure"
  | Goal_store.Store_unavailable u ->
    fail ("mirror failure made the primary unreadable: " ^ Goal_store.unavailable_to_string u)

let upsert_exn config ?id ?title ?metric ?target_value ?due_date ?priority () =
  match Goal_store.upsert_goal config ?id ?title ?metric ?target_value ?due_date ?priority () with
  | Ok (goal, _) -> goal
  | Error error -> fail (write_error_msg error)

let test_criterion_edits_invalidate_proof_phase () =
  with_workspace @@ fun config ->
  let original = upsert_exn config ~title:"Measured service" ~metric:"p99" ~target_value:"400ms" () in
  check bool "creation has revision" true (original.criterion_revision <> "");
  let completed = { original with phase = Goal_phase.Completed;
    last_review_note = Some "proved"; last_review_at = Some (iso_now ()) } in
  Goal_store.write_state config { version = 1; updated_at = iso_now (); goals = [completed] };
  let same = upsert_exn config ~id:original.id ~title:original.title ~metric:"p99"
      ~target_value:"400ms" ~priority:1 ~due_date:"tomorrow" () in
  check string "priority, due date and no-op criterion preserve revision" original.criterion_revision same.criterion_revision;
  check bool "unrelated edit preserves completion" true (same.phase = Goal_phase.Completed);
  let changed = upsert_exn config ~id:original.id ~target_value:"200ms" () in
  check bool "criterion edit reopens" true (changed.phase = Goal_phase.Executing);
  check bool "criterion edit rotates revision" true (changed.criterion_revision <> original.criterion_revision);
  check (option string) "old note no longer current" None changed.last_review_note;
  check (option string) "old review time no longer current" None changed.last_review_at;
  let restored = upsert_exn config ~id:original.id ~target_value:"400ms" () in
  check bool "ABA cannot restore old proof identity" false
    (Goal_store.criterion_equal (Goal_store.criterion_of_goal original) (Goal_store.criterion_of_goal restored));
  let verifying = { restored with phase = Goal_phase.Verifying } in
  Goal_store.write_state config { version = 4; updated_at = iso_now (); goals = [verifying] };
  let renamed = upsert_exn config ~id:original.id ~title:"Another measurement" () in
  check bool "title edit supersedes active review" true (renamed.phase = Goal_phase.Executing);
  let dropped = { renamed with phase = Goal_phase.Dropped } in
  Goal_store.write_state config { version = 6; updated_at = iso_now (); goals = [dropped] };
  let updated = upsert_exn config ~id:original.id ~metric:"p95" () in
  check bool "criterion edit does not reopen dropped Goal" true (updated.phase = Goal_phase.Dropped)

let test_transact_goal_authoritative_and_noop () =
  with_workspace @@ fun config ->
  let goal = upsert_exn config ~title:"Atomic Goal" ~metric:"count" ~target_value:"10" () in
  let path = Goal_store.goals_path config in
  let bytes () = In_channel.with_open_bin path In_channel.input_all in
  let before = bytes () in
  (match Goal_store.transact_goal config ~goal_id:goal.id (fun current -> Ok (current, "observed")) with
   | Ok (_, value) -> check string "callback result returned" "observed" value
   | Error error -> fail (write_error_msg error));
  check string "no-op preserves exact bytes" before (bytes ());
  (match Goal_store.transact_goal config ~goal_id:goal.id (fun _ -> Error "ledger refused") with
   | Error (Goal_store.Rejected message) -> check string "callback error preserved" "ledger refused" message
   | Error other -> fail ("callback error was not Rejected: " ^ write_error_msg other)
   | Ok _ -> fail "transaction accepted rejected ledger");
  check string "refusal preserves exact bytes" before (bytes ());
  (match Goal_store.transact_goal config ~goal_id:goal.id
      (fun current -> Ok ({ current with phase = Goal_phase.Verifying }, current.criterion_revision)) with
   | Ok (updated, revision) ->
       check string "callback read authoritative revision" goal.criterion_revision revision;
       check bool "phase persisted" true (updated.phase = Goal_phase.Verifying)
   | Error error -> fail (write_error_msg error));
  let mirror = In_channel.with_open_bin (goals_recovery_path config) In_channel.input_all in
  write_raw path "{broken";
  let called = ref false in
  (* The mirror still decodes; it is reported as evidence, never served. *)
  (match Goal_store.transact_goal config ~goal_id:goal.id
      (fun current -> called := true; Ok (current, ())) with
   | Error (Goal_store.Store_unavailable
              { reason = Goal_store.Not_json _;
                mirror = Goal_store.Mirror_decodes { goal_count = 1; _ }; _ }) -> ()
   | Error other -> fail ("corrupt primary was not Store_unavailable: " ^ write_error_msg other)
   | Ok _ -> fail "recovery snapshot authorized proof mutation");
  check bool "callback not entered on corrupt primary" false !called;
  check string "primary untouched" "{broken" (bytes ());
  check string "recovery evidence untouched" mirror
    (In_channel.with_open_bin (goals_recovery_path config) In_channel.input_all)

let test_missing_criterion_revision_refuses_bound_mutation () =
  with_workspace @@ fun config ->
  let goal = make_goal "revision-required" "Old-looking goal" in
  let row = match Goal_store.goal_to_yojson goal with
    | `Assoc fields -> `Assoc (List.remove_assoc "criterion_revision" fields)
    | _ -> fail "Goal serializer returned non-object" in
  let json = `Assoc [ "version", `Int 1; "updated_at", `String (iso_now ()); "goals", `List [row] ] in
  let path = Goal_store.goals_path config in
  write_raw path (Yojson.Safe.to_string json);
  match Goal_store.transact_goal config ~goal_id:goal.id (fun current -> Ok (current, ())) with
  | Error (Goal_store.Store_unavailable
             { reason = Goal_store.Schema_rejected { field = "criterion_revision"; _ }; _ }) -> ()
  | Error other -> fail ("missing revision was not Store_unavailable: " ^ write_error_msg other)
  | Ok _ -> fail "missing revision was silently accepted"

(* {1 RFC-0444 PR-1: the closed source sum}

   Six read conditions (RFC §2.1), the four mirror states inside
   [Unavailable], writer refusal with byte identity (criterion 5), and reads
   that move nothing. *)

let mirror_path = goals_recovery_path

let phase_fixture_goals () =
  List.mapi
    (fun index phase ->
      { (make_goal (Printf.sprintf "goal-%d" index) ("Goal in " ^ Goal_phase.to_string phase))
        with phase })
    [ Goal_phase.Executing; Goal_phase.Verifying; Goal_phase.Awaiting_confirmation;
      Goal_phase.Completed; Goal_phase.Dropped ]

(* The #34459 shape: every phase, no [criterion_revision]. Written raw so
   no writer of this module is involved in planting it. *)
let bytes_without_criterion_revision goals =
  let row goal =
    match Goal_store.goal_to_yojson goal with
    | `Assoc fields -> `Assoc (List.remove_assoc "criterion_revision" fields)
    | _ -> fail "goal serializer returned non-object"
  in
  Yojson.Safe.to_string
    (`Assoc [ "version", `Int 1; "updated_at", `String (iso_now ());
              "goals", `List (List.map row goals) ])

let seed_schema_rejected config =
  let bytes = bytes_without_criterion_revision (phase_fixture_goals ()) in
  write_raw (Goal_store.goals_path config) bytes;
  write_raw (mirror_path config) bytes

let reason_name = function
  | Goal_store.Missing_after_init -> "missing_after_init"
  | Goal_store.Unreadable _ -> "unreadable"
  | Goal_store.Not_json _ -> "not_json"
  | Goal_store.Schema_rejected _ -> "schema_rejected"

let test_source_uninitialized_only_when_both_files_absent () =
  with_workspace @@ fun config ->
  check bool "fresh workspace has no goals.json" false
    (Sys.file_exists (Goal_store.goals_path config));
  check bool "fresh workspace has no mirror" false (Sys.file_exists (mirror_path config));
  (match Goal_store.load_source config with
   | Goal_store.Uninitialized -> ()
   | Goal_store.Available _ -> fail "two absent files read as Available"
   | Goal_store.Unavailable u -> fail (Goal_store.unavailable_to_string u));
  (match Goal_store.find_goal config ~goal_id:"anything" with
   | Goal_store.Goal_absent -> ()
   | Goal_store.Goal_found _ -> fail "an uninitialized store found a goal"
   | Goal_store.Store_unavailable u -> fail (Goal_store.unavailable_to_string u));
  (match Goal_store.list_goals_result config () with
   | Ok [] -> ()
   | Ok _ -> fail "an uninitialized store listed goals"
   | Error u -> fail (Goal_store.unavailable_to_string u));
  check bool "reading did not create goals.json" false
    (Sys.file_exists (Goal_store.goals_path config))

let test_source_missing_after_init () =
  with_workspace @@ fun config ->
  let stamp = "2026-09-08T16:20:13Z" in
  Goal_store.write_state config
    { version = 7; updated_at = stamp; goals = [ make_goal "g-1" "survivor" ] };
  Sys.remove (Goal_store.goals_path config);
  (match unavailable config with
   | { file; reason = Goal_store.Missing_after_init;
       mirror = Goal_store.Mirror_decodes { goal_count; updated_at };
       reset_step = Goal_store.Reset_goal_store } ->
     check string "names goals.json" (Goal_store.goals_path config) file;
     check int "mirror goal count is evidence" 1 goal_count;
     check string "mirror stamp is evidence" stamp updated_at
   | u -> fail ("expected Missing_after_init with a decoding mirror: "
                ^ Goal_store.unavailable_to_string u));
  check bool "read did not recreate goals.json" false
    (Sys.file_exists (Goal_store.goals_path config))

let test_source_not_json () =
  with_workspace @@ fun config ->
  write_raw (Goal_store.goals_path config) "{broken";
  match unavailable config with
  | { reason = Goal_store.Not_json _; mirror = Goal_store.Mirror_absent;
      reset_step = Goal_store.Reset_goal_store; _ } -> ()
  | u -> fail ("expected Not_json with no mirror: " ^ Goal_store.unavailable_to_string u)

let test_source_schema_rejected_names_criterion_revision () =
  with_workspace @@ fun config ->
  seed_schema_rejected config;
  match unavailable config with
  | { reason = Goal_store.Schema_rejected { field = "criterion_revision"; detail };
      mirror = Goal_store.Mirror_rejected
                 (Goal_store.Schema_rejected { field = "criterion_revision"; _ });
      reset_step = Goal_store.Repair_field "criterion_revision"; _ } ->
    check bool "detail names the first refused row" true
      (String_util.contains_substring detail "goal-0")
  | u -> fail ("expected Schema_rejected on criterion_revision for both files: "
               ^ Goal_store.unavailable_to_string u)

(* A directory at the path opens read-only and fails on the first read, so
   the errno that survives is EISDIR; it needs no permission change and
   holds as root. *)
let test_source_unreadable_eisdir () =
  with_workspace @@ fun config ->
  Unix.mkdir (Goal_store.goals_path config) 0o755;
  match unavailable config with
  | { reason = Goal_store.Unreadable Unix.EISDIR; mirror = Goal_store.Mirror_absent;
      reset_step = Goal_store.Reset_goal_store; _ } -> ()
  | u -> fail ("expected Unreadable EISDIR: " ^ Goal_store.unavailable_to_string u)

let test_source_unreadable_eacces () =
  if Unix.geteuid () = 0 then begin
    print_endline "skipped: running as root, chmod 000 does not deny the read";
    Alcotest.skip ()
  end;
  with_workspace @@ fun config ->
  Goal_store.write_state config
    { version = 1; updated_at = iso_now (); goals = [ make_goal "g-1" "locked out" ] };
  let path = Goal_store.goals_path config in
  Unix.chmod path 0o000;
  Fun.protect ~finally:(fun () -> Unix.chmod path 0o644) (fun () ->
    match unavailable config with
    | { reason = Goal_store.Unreadable Unix.EACCES;
        mirror = Goal_store.Mirror_decodes { goal_count = 1; _ };
        reset_step = Goal_store.Restore_permission; _ } -> ()
    | u -> fail ("expected Unreadable EACCES with a decoding mirror: "
                 ^ Goal_store.unavailable_to_string u))

let test_source_available_never_consults_the_mirror () =
  with_workspace @@ fun config ->
  Goal_store.write_state config
    { version = 2; updated_at = iso_now ();
      goals = [ make_goal "g-1" "first"; make_goal "g-2" "second" ] };
  write_raw (mirror_path config) "{broken";
  let state = available config in
  check int "primary is served as is" 2 (List.length state.goals);
  check int "primary version is served" 2 state.version;
  check string "mirror bytes untouched" "{broken"
    (In_channel.with_open_bin (mirror_path config) In_channel.input_all)

let test_mirror_four_states_are_evidence () =
  with_workspace @@ fun config ->
  let primary = Goal_store.goals_path config in
  let mirror = mirror_path config in
  let expect label pattern =
    let u = unavailable config in
    check string (label ^ ": primary reason") "not_json" (reason_name u.reason);
    if not (pattern u.mirror) then
      fail (label ^ ": unexpected mirror status: " ^ Goal_store.unavailable_to_string u)
  in
  write_raw primary "{broken";
  expect "absent" (function Goal_store.Mirror_absent -> true
    | Goal_store.Mirror_unreadable _ | Goal_store.Mirror_decodes _
    | Goal_store.Mirror_rejected _ -> false);
  Unix.mkdir mirror 0o755;
  expect "unreadable" (function Goal_store.Mirror_unreadable Unix.EISDIR -> true
    | Goal_store.Mirror_unreadable _ | Goal_store.Mirror_absent
    | Goal_store.Mirror_decodes _ | Goal_store.Mirror_rejected _ -> false);
  Unix.rmdir mirror;
  let stamp = "2026-09-09T00:10:29Z" in
  Goal_store.write_state config
    { version = 3; updated_at = stamp; goals = phase_fixture_goals () };
  write_raw primary "{broken";
  expect "decodes" (function
    | Goal_store.Mirror_decodes { goal_count = 5; updated_at } -> String.equal updated_at stamp
    | Goal_store.Mirror_decodes _ | Goal_store.Mirror_unreadable _
    | Goal_store.Mirror_absent | Goal_store.Mirror_rejected _ -> false);
  write_raw mirror (bytes_without_criterion_revision (phase_fixture_goals ()));
  expect "rejected" (function
    | Goal_store.Mirror_rejected
        (Goal_store.Schema_rejected { field = "criterion_revision"; _ }) -> true
    | Goal_store.Mirror_rejected _ | Goal_store.Mirror_unreadable _
    | Goal_store.Mirror_absent | Goal_store.Mirror_decodes _ -> false)

(* Criterion 5: every writer refuses a Schema_rejected store and neither
   file changes a byte across the call. *)
let test_writers_refuse_unavailable_and_keep_bytes () =
  with_workspace @@ fun config ->
  seed_schema_rejected config;
  let primary = Goal_store.goals_path config in
  let mirror = mirror_path config in
  let digests () = file_digest primary, file_digest mirror in
  let before = digests () in
  let unchanged label =
    let after = digests () in
    check string (label ^ ": goals.json digest unchanged") (fst before) (fst after);
    check string (label ^ ": .last-good digest unchanged") (snd before) (snd after)
  in
  (* Annotated: three result types share a [Store_unavailable] constructor. *)
  let refused label (error : Goal_store.write_error) =
    match error with
    | Goal_store.Store_unavailable
        { reason = Goal_store.Schema_rejected { field = "criterion_revision"; _ }; _ } -> ()
    | other -> fail (label ^ ": refusal was not Store_unavailable: " ^ write_error_msg other)
  in
  (match Goal_store.upsert_goal config ~title:"new" ~metric:"m" ~target_value:"1" () with
   | Ok _ -> fail "upsert wrote over an unavailable store"
   | Error error -> refused "upsert_goal" error);
  unchanged "upsert_goal";
  let entered = ref false in
  (match Goal_store.transact_goal config ~goal_id:"goal-0"
           (fun goal -> entered := true; Ok (goal, ())) with
   | Ok _ -> fail "transact_goal wrote over an unavailable store"
   | Error error -> refused "transact_goal" error);
  check bool "transact_goal callback not entered" false !entered;
  unchanged "transact_goal";
  (match Goal_store.update_goal_if_phase config ~goal_id:"goal-0"
           ~expected_phase:Goal_phase.Executing Fun.id with
   | Ok _ -> fail "update_goal_if_phase wrote over an unavailable store"
   | Error error -> refused "update_goal_if_phase" error);
  unchanged "update_goal_if_phase";
  (match Goal_store.delete_goal config ~goal_id:"goal-0" with
   | Ok _ -> fail "delete_goal wrote over an unavailable store"
   | Error (Goal_store.Store_unavailable
              { reason = Goal_store.Schema_rejected { field = "criterion_revision"; _ }; _ }) -> ()
   | Error other ->
     fail ("delete_goal refusal was not Store_unavailable: "
           ^ Goal_store.delete_goal_error_to_string other));
  unchanged "delete_goal";
  (match Goal_store.with_existing_goals config ~goal_ids:[ "goal-0" ]
           (fun () -> entered := true) with
   | Ok () -> fail "with_existing_goals ran its callback on an unavailable store"
   | Error (Goal_store.Goal_source_unavailable
              { reason = Goal_store.Schema_rejected { field = "criterion_revision"; _ }; _ }) -> ()
   | Error (Goal_store.Goal_source_unavailable u) ->
     fail ("with_existing_goals refusal carried another reason: "
           ^ Goal_store.unavailable_to_string u)
   | Error (Goal_store.Goal_lock_failed error) ->
     fail ("with_existing_goals could not take the lock: "
           ^ Masc_domain.masc_error_to_string error)
   | Error (Goal_store.Goal_missing id) ->
     fail ("with_existing_goals read an unavailable store as missing " ^ id));
  check bool "with_existing_goals callback not entered" false !entered;
  unchanged "with_existing_goals"

let test_find_goal_three_arms () =
  with_workspace @@ fun config ->
  Goal_store.write_state config
    { version = 1; updated_at = iso_now (); goals = [ make_goal "known" "found" ] };
  (match Goal_store.find_goal config ~goal_id:"known" with
   | Goal_store.Goal_found goal -> check string "found the row" "found" goal.title
   | Goal_store.Goal_absent -> fail "known id read as absent"
   | Goal_store.Store_unavailable u -> fail (Goal_store.unavailable_to_string u));
  (match Goal_store.find_goal config ~goal_id:"unknown" with
   | Goal_store.Goal_absent -> ()
   | Goal_store.Goal_found _ -> fail "unknown id was found"
   | Goal_store.Store_unavailable u -> fail (Goal_store.unavailable_to_string u));
  seed_schema_rejected config;
  match Goal_store.find_goal config ~goal_id:"goal-0" with
  | Goal_store.Store_unavailable
      { reason = Goal_store.Schema_rejected { field = "criterion_revision"; _ }; _ } -> ()
  | Goal_store.Store_unavailable u ->
    fail ("lookup carried another reason: " ^ Goal_store.unavailable_to_string u)
  | Goal_store.Goal_found _ -> fail "an unavailable store found a goal"
  | Goal_store.Goal_absent -> fail "an unavailable store read as absent (RFC-0444 S5)"

let test_load_source_twice_moves_nothing () =
  with_workspace @@ fun config ->
  seed_schema_rejected config;
  let primary = Goal_store.goals_path config in
  let mirror = mirror_path config in
  let before = file_digest primary, file_digest mirror in
  let first = unavailable config in
  let second = unavailable config in
  check string "same reason both reads" (reason_name first.reason) (reason_name second.reason);
  check string "goals.json digest unchanged after two reads" (fst before) (file_digest primary);
  check string ".last-good digest unchanged after two reads" (snd before) (file_digest mirror);
  check bool "no rejected-* file appeared beside the store" false
    (Sys.readdir (Filename.dirname primary)
     |> Array.exists (fun name -> String_util.contains_substring name "rejected"))

let test_first_write_creates_the_store () =
  with_workspace @@ fun config ->
  let primary = Goal_store.goals_path config in
  (* A refused create hands the state back untouched: no empty store is
     pre-written, so the source stays Uninitialized. *)
  (match Goal_store.upsert_goal config ~title:"no condition" () with
   | Error (Goal_store.Rejected _) -> ()
   | Error other -> fail ("B1 refusal was not Rejected: " ^ write_error_msg other)
   | Ok _ -> fail "a goal without a success condition was created");
  check bool "refused create wrote no goals.json" false (Sys.file_exists primary);
  (match Goal_store.transact_goal config ~goal_id:"ghost" (fun goal -> Ok (goal, ())) with
   | Error (Goal_store.Goal_not_found "ghost") -> ()
   | Error other -> fail ("uninitialized transact was not Goal_not_found: " ^ write_error_msg other)
   | Ok _ -> fail "uninitialized store transacted a goal");
  (match Goal_store.delete_goal config ~goal_id:"ghost" with
   | Error (Goal_store.Unknown_goal _) -> ()
   | Error other -> fail (Goal_store.delete_goal_error_to_string other)
   | Ok _ -> fail "uninitialized store deleted a goal");
  (match Goal_store.with_existing_goals config ~goal_ids:[ "ghost" ] (fun () -> ()) with
   | Error (Goal_store.Goal_missing "ghost") -> ()
   | Error (Goal_store.Goal_missing id) -> fail ("missing id misnamed: " ^ id)
   | Error (Goal_store.Goal_source_unavailable u) -> fail (Goal_store.unavailable_to_string u)
   | Error (Goal_store.Goal_lock_failed error) -> fail (Masc_domain.masc_error_to_string error)
   | Ok () -> fail "uninitialized store admitted a goal reference");
  check bool "refused writers created no goals.json" false (Sys.file_exists primary);
  (match Goal_store.upsert_goal config ~title:"first" ~metric:"m" ~target_value:"1" () with
   | Ok (_, `created) -> ()
   | Ok (_, `updated) -> fail "first write reported an update"
   | Error error -> fail (write_error_msg error));
  let state = available config in
  check int "first write holds one goal" 1 (List.length state.goals);
  check int "first write starts the version counter" 2 state.version

let () =
  run "Goal_store"
    [ ( "proof identity",
        [ test_case "criterion edits invalidate proof phase" `Quick test_criterion_edits_invalidate_proof_phase;
          test_case "transaction uses primary and preserves no-op" `Quick test_transact_goal_authoritative_and_noop;
          test_case "missing revision refuses bound mutation" `Quick test_missing_criterion_revision_refuses_bound_mutation ] );
      ( "regression-7690",
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
          test_case "undecodable store read error names the path" `Quick
            test_undecodable_store_read_error_names_path;
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
            test_write_state_result_keeps_primary_commit_when_recovery_write_fails ] );
      ( "rfc-0444 source",
        [ test_case "uninitialized only when both files are absent" `Quick
            test_source_uninitialized_only_when_both_files_absent;
          test_case "missing after init" `Quick test_source_missing_after_init;
          test_case "not json" `Quick test_source_not_json;
          test_case "schema rejected names criterion_revision" `Quick
            test_source_schema_rejected_names_criterion_revision;
          test_case "unreadable EISDIR" `Quick test_source_unreadable_eisdir;
          test_case "unreadable EACCES" `Quick test_source_unreadable_eacces;
          test_case "available never consults the mirror" `Quick
            test_source_available_never_consults_the_mirror;
          test_case "mirror four states are evidence" `Quick
            test_mirror_four_states_are_evidence;
          test_case "writers refuse unavailable and keep bytes" `Quick
            test_writers_refuse_unavailable_and_keep_bytes;
          test_case "find_goal three arms" `Quick test_find_goal_three_arms;
          test_case "load_source twice moves nothing" `Quick
            test_load_source_twice_moves_nothing;
          test_case "first write creates the store" `Quick
            test_first_write_creates_the_store ] ) ]
