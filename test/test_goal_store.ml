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

(* [Sys.is_directory] follows a link, so a directory alias is descended into and
   then refused by [Unix.rmdir] (ENOTDIR), and a dangling link reads false from
   [Sys.file_exists] and is skipped, leaving the parent non-empty (#26648).
   [Unix.lstat] decides: only a real directory is descended. *)
let rm_rf dir =
  let rec rm path =
    match Unix.lstat path with
    | exception Unix.Unix_error ((Unix.ENOENT | Unix.ENOTDIR), _, _) -> ()
    | { Unix.st_kind = Unix.S_DIR; _ } ->
      Sys.readdir path
      |> Array.iter (fun entry -> rm (Filename.concat path entry));
      Unix.rmdir path
    | _ -> Sys.remove path
  in
  try rm dir with _ -> ()

let utc_time date time =
  match Ptime.of_date_time (date, (time, 0)) with
  | Some now -> now
  | None -> fail "invalid UTC clock fixture"

(* Calendar fixtures use the existing clock dependency, never wall time. *)
let calendar_fixture_now = utc_time (2026, 9, 22) (12, 0, 0)

let with_workspace ?now ?dir f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = match dir with Some path -> path | None -> temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Option.iter (fun _ -> Time_compat.clear_clock ()) now;
      rm_rf dir)
    (fun () ->
      Option.iter (fun now ->
        let clock = Eio_mock.Clock.make () in
        Eio_mock.Clock.set_time clock (Ptime.to_float_s now);
        Time_compat.set_clock (clock :> float Eio.Time.clock_ty Eio.Resource.t)) now;
      let config = Workspace.default_config dir in
      ignore (Workspace.init config ~agent_name:(Some "test"));
      f config)

let iso_now () = Masc_domain.now_iso ()

let goals_recovery_path config =
  Goal_store.goals_path config ^ ".last-good"

let make_goal id title =
  let ts = iso_now () in
  {
    Goal_store.id;
    criterion_revision = "fixture-criterion-" ^ id; title;
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

type goal_publication_backend = Goal_file_system | Goal_memory

let with_goal_publication_backend backend_kind f =
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  Fs_compat.set_fs fs;
  let dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf dir)
    (fun () ->
      let backend_config : Backend_types.config =
        { base_path = Filename.concat dir Common.masc_dirname
        ; node_id = "goal-local-publication-test"
        }
      in
      let backend =
        match backend_kind with
        | Goal_file_system ->
            Workspace_utils.FileSystem (Backend.FileSystem.create ~fs backend_config)
        | Goal_memory -> Workspace_utils.Memory (Backend.Memory.create ())
      in
      let config : Workspace_utils.config =
        { base_path = dir
        ; workspace_path = dir
        ; lock_expiry_minutes = 2
        ; backend_config
        ; backend
        }
      in
      ignore (Workspace.init config ~agent_name:(Some "test"));
      f config)

let goal_backend_key config path =
  match Workspace_utils.key_of_path config path with
  | Some key -> key
  | None -> fail "Goal path must have a workspace backend key"

let goal_backend_document config path =
  match Workspace_utils.backend_get config ~key:(goal_backend_key config path) with
  | Ok document -> document
  | Error error -> fail (Backend_types.show_error error)

(* Seed independent documents only where the generic backend is physically
   separate. A FileSystem key aliases the local Goal file, so seeding it would
   poison the actual authoritative input instead of creating an independent
   backend observation. *)
let seed_goal_memory_documents config =
  match config.Workspace_utils.backend with
  | Workspace_utils.FileSystem _ -> None
  | Workspace_utils.Memory _ ->
      let seed path role =
        let value = Yojson.Safe.to_string
          (`Assoc ["backend_only", `String role]) in
        match Workspace_utils.backend_set config
                ~key:(goal_backend_key config path) ~value with
        | Ok () -> value
        | Error error -> fail (Backend_types.show_error error)
      in
      let primary = seed (Goal_store.goals_path config) "primary" in
      let recovery = seed (goals_recovery_path config) "recovery" in
      Some (primary, recovery)

let check_goal_memory_documents config = function
  | None -> ()
  | Some (primary, recovery) ->
      check (option string) "independent backend primary remains exact"
        (Some primary) (goal_backend_document config (Goal_store.goals_path config));
      check (option string) "independent backend recovery remains exact"
        (Some recovery) (goal_backend_document config (goals_recovery_path config))

let check_goal_filesystem_alias config =
  match config.Workspace_utils.backend with
  | Workspace_utils.Memory _ -> ()
  | Workspace_utils.FileSystem _ ->
      let primary = Goal_store.goals_path config in
      check (option string) "filesystem key reads the authoritative local primary"
        (Some (Fs_compat.load_file primary)) (goal_backend_document config primary)

let test_delete_goal_bumps_version () =
  with_workspace @@ fun config ->
  let g = make_goal "g-1" "to delete" in
  Goal_store.write_state config
    { pending_events = []; pending_notifications = []; version = 10; updated_at = iso_now (); goals = [g] };
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
    { pending_events = []; pending_notifications = []; version = 5; updated_at = iso_now (); goals };
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
    { pending_events = []; pending_notifications = []; version = 42; updated_at = iso_now (); goals = [g] };
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
    { pending_events = []; pending_notifications = []; version = 1; updated_at = stale_ts; goals = [g] };
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
    { pending_events = []; pending_notifications = []; version = 1; updated_at = iso_now (); goals = [ deleted; preserved ] };
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

let test_delete_refuses_duplicate_goal_identity () =
  with_workspace @@ fun config ->
  let goal = make_goal "duplicate" "First Goal" in
  let duplicate = { goal with title = "Different Goal"; phase = Goal_phase.Verifying;
                              criterion_revision = "other-revision" } in
  let independent = make_goal "independent" "Independent Goal" in
  (match Goal_store.write_state_result config
      { pending_events = []; pending_notifications = []; version = 3; updated_at = iso_now ();
        goals = [goal; duplicate; independent] } with
   | Ok () -> () | Error detail -> fail detail);
  Workspace_goal_index.write_goal_task_links config
    [goal.id, ["task-a"]; independent.id, ["task-b"]];
  let primary = Goal_store.goals_path config in
  let mirror = goals_recovery_path config in
  let links = Workspace_goal_index.goal_task_links_path config in
  let before = Fs_compat.load_file primary, Fs_compat.load_file mirror, Fs_compat.load_file links in
  (match Goal_store.delete_goal config ~goal_id:goal.id with
   | Error (Goal_store.Ambiguous_goal id) -> check string "ambiguous Goal ID" goal.id id
   | Error error -> fail (Goal_store.delete_goal_error_to_string error)
   | Ok _ -> fail "ambiguous Goal was deleted");
  let goals_before, mirror_before, links_before = before in
  check string "primary unchanged" goals_before (Fs_compat.load_file primary);
  check string "mirror unchanged" mirror_before (Fs_compat.load_file mirror);
  check string "links not pruned" links_before (Fs_compat.load_file links);
  (match Goal_store.delete_goal config ~goal_id:independent.id with
   | Ok Goal_store.Deleted -> ()
   | Ok (Goal_store.Deleted_with_orphaned_links detail) -> fail detail
   | Error error -> fail (Goal_store.delete_goal_error_to_string error));
  check bool "independent delete keeps both decoded Goal rows" true ((available config).goals = [goal; duplicate]);
  let remaining_links = Workspace_goal_index.read_goal_task_links config in
  check bool "ambiguous Goal link remains" true
    (List.exists (fun (id, tasks) -> String.equal id goal.id && List.mem "task-a" tasks) remaining_links)

let test_delete_goal_wraps_prune_failure_after_goal_delete () =
  with_workspace
  @@ fun config ->
  let deleted = make_goal "g-1" "deleted goal" in
  Goal_store.write_state config
    { pending_events = []; pending_notifications = []; version = 1; updated_at = iso_now (); goals = [ deleted ] };
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

let test_delete_goal_reports_ambiguous_link_cleanup () =
  with_workspace @@ fun config ->
  let goal = make_goal "g-1" "deleted goal" in
  Goal_store.write_state config
    { pending_events = []; pending_notifications = []; version = 1; updated_at = iso_now (); goals = [goal] };
  Workspace_goal_index.write_goal_task_links config [ "g-1", [ "task-a" ] ];
  let path = Workspace_goal_index.goal_task_links_path config in
  let mirror = path ^ ".last-good" in
  let raw = {|{"links":[{"goal_id":" g-1 ","task_ids":["task-a"]}]}|} in
  let write path = Out_channel.with_open_bin path (fun oc -> Out_channel.output_string oc raw) in
  write path; write mirror;
  (match Goal_store.delete_goal config ~goal_id:"g-1" with
   | Ok (Goal_store.Deleted_with_orphaned_links detail) ->
       check bool "cleanup failure is reported" true (String.length detail > 0)
   | Ok Goal_store.Deleted -> fail "ambiguous links were silently rewritten"
   | Error error -> fail (Goal_store.delete_goal_error_to_string error));
  check bool "Goal deletion committed" false
    (List.exists (fun (item : Goal_store.goal) -> String.equal item.id goal.id) (available config).goals);
  check string "ambiguous primary retained" raw (In_channel.with_open_bin path In_channel.input_all);
  check string "ambiguous recovery retained" raw (In_channel.with_open_bin mirror In_channel.input_all);
  (match Goal_store.delete_goal config ~goal_id:"g-1" with
   | Error (Goal_store.Unknown_goal _) -> ()
   | Error error -> fail (Goal_store.delete_goal_error_to_string error)
   | Ok _ -> fail "a repeated Goal deletion does not retry cleanup")

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
   | Goal_store.Missing_after_init | Goal_store.Unreadable _ | Goal_store.Nonregular _ | Goal_store.Not_json _ ->
     fail "a row with the retired status field must be a schema rejection");
  (* Fail-closed: an unreadable store must not license a write.  Without this
     the next upsert would overwrite goals.json AND its .last-good mirror with an
     empty state, turning one undecodable row into permanent loss. *)
  (match
     Goal_store.upsert_goal_with_events ~actor:"test" config ~title:"phase only" ~metric:"m"
       ~target_value:"1" ()
   with
   | Ok _ -> fail "Goal upsert wrote over an undecodable store"
   | Error (Goal_store.Store_unavailable u) ->
       check string "refusal names the store path" (Goal_store.goals_path config) u.file
   | Error (Goal_store.Goal_not_found _ | Goal_store.Goal_identity_ambiguous _ | Goal_store.Rejected _
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
    Goal_store.upsert_goal_with_events ~actor:"test" config ~title:"phase only" ~metric:"m"
      ~target_value:"1" ()
  with
  | Error error -> fail (write_error_msg error)
  | Ok (goal, _, _) -> (
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
    { pending_events = []; pending_notifications = []; version = 1; updated_at = iso_now (); goals = [ goal ] };
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
    Goal_store.transact_goal config ~goal_id:goal.id (fun current -> Ok (current, ()))
  with
  | Ok _ -> fail "unknown field licensed a write"
  | Error (Goal_store.Store_unavailable
             { reason = Goal_store.Schema_rejected { field = "unexpected_assignment"; _ }; _ }) -> ()
  | Error other -> fail ("unknown field write was not Store_unavailable: " ^ write_error_msg other)

let test_duplicate_document_members_refuse_writes () =
  with_workspace @@ fun config ->
  let goal = make_goal "goal-duplicate-member" "original title" in
  let independent = make_goal "independent-goal" "another title" in
  (match Goal_store.write_state_result config
      { version = 1; updated_at = iso_now (); goals = [goal; independent];
        pending_events = []; pending_notifications = [] } with
   | Ok () -> () | Error detail -> fail detail);
  let primary = Goal_store.goals_path config in
  let mirror = goals_recovery_path config in
  let valid = Fs_compat.load_file primary in
  let mirror_before = Fs_compat.load_file mirror in
  let root_fields, goal_fields, independent_row =
    match Yojson.Safe.from_string valid with
    | `Assoc fields ->
        (match List.assoc_opt "goals" fields with
         | Some (`List [`Assoc row; other]) -> fields, row, other
         | _ -> fail "fixture does not contain two Goals")
    | _ -> fail "fixture is not a document object" in
  let duplicate field value before fields =
    let fields = if List.mem_assoc field fields then fields else (field, `Null) :: fields in
    if before then (field, value) :: fields else fields @ [field, value] in
  let cases = [
    `Root, "goals", "goals", `List [];
    `Root, "version", "version", `Int 42;
    `Root, "pending_events", "pending_events", `List [];
    `Root, "pending_notifications", "pending_notifications", `List [];
    `Root, "", "$", `Int 1;
    `Root, " ", "$", `Int 1;
    `Root, "name with spaces", "$", `Int 1;
    `Root, "\t", "$", `Int 1;
    `Root, "\n", "$", `Int 1;
    `Root, "bad\027name", "$", `Int 1;
    `Root, "비가시", "$", `Int 1;
    `Goal, "id", "id", `String "other-goal";
    `Goal, "id", "id", `String goal.id;
    `Goal, "title", "title", `String "different criterion";
    `Goal, "criterion_revision", "criterion_revision", `String "other-revision";
    `Goal, "phase", "phase", `String "dropped";
    `Goal, "priority", "priority", `Int 1;
    `Goal, "metric", "metric", `Null;
    `Goal, "", "goals", `Int 1;
    `Goal, " ", "goals", `Int 1;
    `Goal, "name with spaces", "goals", `Int 1;
    `Goal, "\t", "goals", `Int 1;
    `Goal, "\n", "goals", `Int 1;
    `Goal, "bad\027name", "goals", `Int 1;
    `Goal, "비가시", "goals", `Int 1;
    `Goal, "$", "$", `Int 1;
    `Single_goal, "", "goals", `Int 1;
    `Single_goal, " ", "goals", `Int 1;
    `Single_goal, "\n", "goals", `Int 1;
    `Single_goal, "$", "$", `Int 1;
  ] in
  List.iter (fun (level, field, expected_location, value) ->
    List.iter (fun before ->
      let with_row fields =
        let row = `Assoc fields in
        `Assoc (List.map (fun (key, old) ->
          if String.equal key "goals" then key, `List [row; independent_row] else key, old) root_fields) in
      let json = match level with
        | `Root -> `Assoc (duplicate field value before root_fields)
        | `Goal -> with_row (duplicate field value before goal_fields)
        | `Single_goal -> with_row
            (if before then (field, value) :: goal_fields else goal_fields @ [field, value]) in
      (match Goal_store.validate_state_json json with
       | Error detail ->
         check bool "setup validator retains the safe location" true
           (String_util.contains_substring detail (Printf.sprintf "(location %S)" expected_location))
       | Ok () -> fail ("validation admitted duplicate " ^ field));
      let bytes = Yojson.Safe.to_string json in
      write_raw primary bytes;
      let failure = match Goal_store.load_source config with
       | Goal_store.Unavailable
           ({ reason = Goal_store.Schema_rejected { field = actual; detail };
              mirror = Goal_store.Mirror_decodes { goal_count = 2; _ }; _ } as failure) ->
           check string "rejection names member or location" expected_location actual;
           check bool "internal detail preserves the quoted name" true
             (String_util.contains_substring detail (Printf.sprintf "%S" field));
           failure
       | Goal_store.Unavailable failure -> fail (Goal_store.unavailable_to_string failure)
       | Goal_store.Available _ | Goal_store.Uninitialized -> fail "duplicate document was readable" in
      (match Goal_unavailable_envelope.to_yojson failure with
       | `Assoc fields ->
           check (list string) "wire keeps its exact member set"
             ["error_code"; "field"; "file"; "mirror"; "ok"; "reason"; "reset_step"]
             (List.sort String.compare (List.map fst fields));
           check bool "wire carries the nonempty location" true
             (List.assoc_opt "field" fields = Some (`String expected_location));
           check bool "wire names the repair step" true
             (List.assoc_opt "reset_step" fields = Some (`String "repair_field"))
       | _ -> fail "unavailable envelope was not an object");
      let called = ref false and projected = ref false in
      let effects _ _ : Goal_store.transition_effects =
        projected := true; { events = []; notifications = [] } in
      (match Goal_store.transact_goal ~effects config ~goal_id:independent.id
          (fun current -> called := true; Ok ({ current with title = "changed" }, ())) with
       | Error (Goal_store.Store_unavailable
           { reason = Goal_store.Schema_rejected { field = actual; _ }; _ }) ->
           check string "write refusal names duplicate" expected_location actual
       | Error other -> fail ("wrong write refusal: " ^ write_error_msg other)
       | Ok _ -> fail "duplicate document licensed a write");
      check bool "writer callback not entered" false !called;
      check bool "writer effects not projected" false !projected;
      (match Goal_store.upsert_goal_with_events ~actor:"test" config ~title:"new goal" ~metric:"m" ~target_value:"1" () with
       | Error (Goal_store.Store_unavailable _) -> ()
       | Error other -> fail ("wrong upsert refusal: " ^ write_error_msg other)
       | Ok _ -> fail "duplicate document licensed an upsert");
      check string "primary bytes preserved" bytes (Fs_compat.load_file primary);
      check string "mirror bytes preserved" mirror_before (Fs_compat.load_file mirror)
    ) [true; false]
  ) cases;
  write_raw primary valid;
  (match Goal_store.transact_goal config ~goal_id:goal.id
      (fun current -> Ok ({ current with title = "valid update" }, ())) with
   | Ok (updated, ()) -> check string "valid document remains writable" "valid update" updated.title
   | Error error -> fail ("valid document was refused: " ^ write_error_msg error))

let test_undecodable_store_read_error_names_path () =
  with_workspace @@ fun config ->
  let goal = make_goal "read-error" "read error names the store path" in
  Goal_store.write_state config
    { pending_events = []; pending_notifications = []; version = 1; updated_at = iso_now (); goals = [ goal ] };
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
  | Goal_store.Missing_after_init | Goal_store.Unreadable _ | Goal_store.Nonregular _ | Goal_store.Not_json _ ->
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
  | Goal_store.Missing_after_init | Goal_store.Unreadable _ | Goal_store.Nonregular _ | Goal_store.Not_json _ ->
    fail "a priority-less row must be a schema rejection"

(* A goal in [phase], for fixtures. Creation makes Executing goals; the
   phase is then seeded through a Goal transaction. *)
let upsert_goal_in_phase config ~title phase =
  match Goal_store.upsert_goal_with_events ~actor:"test" config ~title ~metric:"m" ~target_value:"1" () with
  | Error error -> Error error
  | Ok (goal, _, _) when goal.Goal_store.phase = phase -> Ok goal
  | Ok (goal, _, _) ->
    Goal_store.transact_goal config ~goal_id:goal.Goal_store.id
      (fun current -> Ok ({ current with Goal_store.phase }, ()))
    |> Result.map fst
;;

let test_dropped_phase_serializes_without_status () =
  with_workspace @@ fun config ->
  let goal =
    match upsert_goal_in_phase config ~title:"Dropped goal" Goal_phase.Dropped with
    | Ok goal -> goal
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
    match upsert_goal_in_phase config ~title phase with
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
    { pending_events = []; pending_notifications = []; version = 9; updated_at = iso_now (); goals = [ goal ] };
  let before = available config in
  (match
     Goal_store.transact_goal config ~goal_id:"ghost" (fun current -> Ok (current, ()))
   with
   | Error (Goal_store.Goal_not_found "ghost") -> ()
   | Error other -> fail ("expected Goal_not_found: " ^ write_error_msg other)
   | Ok _ -> fail "expected missing goal error");
  let after = available config in
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
    { pending_events = []; pending_notifications = []; version = 1; updated_at = iso_now (); goals = [ goal ] };
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

let test_goal_publication_uses_local_authority backend_kind () =
  with_goal_publication_backend backend_kind @@ fun config ->
  let independent = seed_goal_memory_documents config in
  (* Backend-only copies cannot initialize or authorize the Goal store. *)
  (match Goal_store.load_source config with
   | Goal_store.Uninitialized -> ()
   | Goal_store.Available _ | Goal_store.Unavailable _ ->
       fail "backend-only documents changed the local Goal source");
  let generation = Goal_projection_generation.current () in
  let goal, events =
    match Goal_store.upsert_goal_with_events config ~actor:"local-author"
            ~title:"Local authority" ~metric:"proof" ~target_value:"1" () with
    | Ok (goal, `created, events) -> goal, events
    | Ok (_, `updated _, _) -> fail "expected local Goal creation"
    | Error error -> fail (write_error_msg error)
  in
  let stored = available config in
  check bool "public read sees the committed local Goal" true
    (stored.goals = [goal]);
  check int "successful primary advances generation once" (generation + 1)
    (Goal_projection_generation.current ());
  check int "creation returns one durable audit intent" 1 (List.length events);
  check bool "local snapshot retains exactly the returned outbox" true
    (stored.pending_events = events);
  List.iter (fun (event : Goal_store.pending_event) ->
      check int "outbox witnesses this local commit" stored.version event.store_revision)
    events;
  let primary = Goal_store.goals_path config in
  check string "recovery holds the same local state and outbox"
    (Fs_compat.load_file primary) (Fs_compat.load_file (goals_recovery_path config));
  check bool "publication has not delivered the pending audit intent" false
    (Sys.file_exists (Filename.concat (Filename.dirname primary) "goal_events.jsonl"));
  check_goal_memory_documents config independent;
  check_goal_filesystem_alias config

let test_blocked_goal_primary_preserves_publication backend_kind () =
  with_goal_publication_backend backend_kind @@ fun config ->
  let goal =
    match Goal_store.upsert_goal_with_events config ~actor:"original-author"
            ~title:"Preserved local Goal" ~metric:"proof" ~target_value:"1" () with
    | Ok (goal, `created, _) -> goal
    | Ok (_, `updated _, _) -> fail "expected initial Goal creation"
    | Error error -> fail (write_error_msg error)
  in
  let before = available config in
  let primary = Goal_store.goals_path config in
  let recovery = goals_recovery_path config in
  let primary_bytes = Fs_compat.load_file primary in
  let recovery_bytes = Fs_compat.load_file recovery in
  let independent = seed_goal_memory_documents config in
  let generation = Goal_projection_generation.current () in
  let next =
    { before with
      version = before.version + 1;
      goals = [{ goal with priority = goal.priority + 1 }]
    }
  in
  let saved_primary = primary ^ ".blocked-write-original" in
  Sys.rename primary saved_primary;
  Unix.mkdir primary 0o755;
  Fun.protect
    ~finally:(fun () -> rm_rf primary; Sys.rename saved_primary primary)
    (fun () ->
      (* The low-level public writer deliberately does not read first. This
         is the I/O fault boundary, not a claim that upsert would authorize a
         directory: normal read-modify-write correctly refuses it earlier. *)
      (match Goal_store.write_state_result config next with
       | Error _ -> ()
       | Ok () -> fail "a directory accepted an authoritative Goal replacement");
      check int "failed local primary does not advance generation" generation
        (Goal_projection_generation.current ());
      check string "failed primary never rewrites recovery or its outbox"
        recovery_bytes (Fs_compat.load_file recovery);
      check string "original local primary and outbox remain exact"
        primary_bytes (Fs_compat.load_file saved_primary);
      check bool "failed local primary remains unavailable" true
        (match Goal_store.load_source config with
         | Goal_store.Unavailable _ -> true
         | Goal_store.Uninitialized | Goal_store.Available _ -> false);
      check bool "failed publication delivers no audit rows" false
        (Sys.file_exists (Filename.concat (Filename.dirname primary) "goal_events.jsonl"));
      check_goal_memory_documents config independent);
  let restored = available config in
  check string "restored authority has the original bytes" primary_bytes
    (Fs_compat.load_file primary);
  check bool "failed publication leaves original state and pending outbox"
    true (restored = before);
  check_goal_filesystem_alias config

let test_write_state_result_keeps_primary_commit_when_recovery_write_fails
    backend_kind () =
  with_goal_publication_backend backend_kind @@ fun config ->
  let independent = seed_goal_memory_documents config in
  Unix.mkdir (goals_recovery_path config) 0o755;
  let goal = make_goal "recovery-mirror-fail" "recovery mirror fail" in
  let state =
    { Goal_store.pending_events = []; pending_notifications = []; version = 3;
      updated_at = iso_now (); goals = [goal] }
  in
  let generation = Goal_projection_generation.current () in
  (match Goal_store.write_state_result config state with
   | Ok () -> ()
   | Error _ -> fail "recovery failure rejected a committed local primary");
  check int "primary success advances generation before failed recovery"
    (generation + 1) (Goal_projection_generation.current ());
  check bool "failed recovery path remains a directory" true
    (Sys.is_directory (goals_recovery_path config));
  (match Goal_store.find_goal config ~goal_id:goal.Goal_store.id with
   | Goal_store.Goal_found stored -> check string "primary has goal" goal.title stored.title
   | Goal_store.Goal_absent -> fail "primary Goal missing after recovery failure"
   | Goal_store.Store_unavailable _ -> fail "recovery failure hid committed local primary");
  check bool "primary retains the supplied state" true (available config = state);
  check_goal_memory_documents config independent;
  check_goal_filesystem_alias config

let upsert_exn config ?id ?title ?metric ?target_value ?due_date ?priority () =
  match Goal_store.upsert_goal_with_events ~actor:"test" config ?id ?title ?metric ?target_value ?due_date ?priority () with
  | Ok (goal, _, _) -> goal
  | Error error -> fail (write_error_msg error)

let test_blank_criterion_edits_preserve_store_and_outbox () =
  List.iter (fun phase ->
    with_workspace @@ fun config ->
    let created = match Goal_store.upsert_goal_with_events config ~actor:"creator"
        ~title:"Measured service" ~metric:"p99" ~target_value:"400ms" () with
      | Ok (goal, `created, _) -> goal
      | Ok (_, `updated _, _) -> fail "expected a creation"
      | Error error -> fail (write_error_msg error) in
    let current = { created with phase; last_review_note = Some "prior review";
      last_review_at = Some (iso_now ()) } in
    let state = available config in
    Goal_store.write_state config { state with goals = [current] };
    let primary = Goal_store.goals_path config in
    let mirror = goals_recovery_path config in
    let ledger = Filename.concat (Filename.dirname primary) "goal_events.jsonl" in
    let before = Fs_compat.load_file primary, Fs_compat.load_file mirror in
    let generation = Goal_projection_generation.current () in
    List.iter (fun blank ->
      let attempts =
        [ (fun () -> Goal_store.upsert_goal_with_events config ~actor:"editor"
              ~id:created.id ~title:blank ());
          (fun () -> Goal_store.upsert_goal_with_events config ~actor:"editor"
              ~id:created.id ~metric:blank ());
          (fun () -> Goal_store.upsert_goal_with_events config ~actor:"editor"
              ~id:created.id ~target_value:blank ()) ] in
      List.iter (fun attempt ->
        (match attempt () with
         | Error (Goal_store.Rejected _) -> ()
         | Error error -> fail (write_error_msg error)
         | Ok _ -> fail "blank criterion edit was accepted");
        check string "refusal preserves primary, revision, review and outbox"
          (fst before) (Fs_compat.load_file primary);
        check string "refusal preserves recovery mirror"
          (snd before) (Fs_compat.load_file mirror);
        check int "refusal preserves projection generation" generation
          (Goal_projection_generation.current ());
        check bool "refusal publishes no audit rows" false (Sys.file_exists ledger))
        attempts) [""; " \t\n"])
    Goal_phase.all

let test_incomplete_historical_criterion_can_be_maintained_and_repaired () =
  with_workspace ~now:calendar_fixture_now @@ fun config ->
  let old = { (make_goal "historical" "Historical condition") with
    phase = Goal_phase.Paused Goal_phase.Resume_verifying;
    last_review_note = Some "old review"; last_review_at = Some (iso_now ()) } in
  Goal_store.write_state config
    { pending_events = []; pending_notifications = []; version = 7;
      updated_at = iso_now (); goals = [old] };
  let maintained = upsert_exn config ~id:old.id ~priority:1
      ~due_date:"2026-09-21" () in
  check string "maintenance preserves revision" old.criterion_revision maintained.criterion_revision;
  check bool "maintenance preserves suspension" true (old.phase = maintained.phase);
  check int "priority still editable" 1 maintained.priority;
  check (option string) "existing goals may be overdue" (Some "2026-09-21") maintained.due_date;
  let primary = Goal_store.goals_path config in
  let before = Fs_compat.load_file primary in
  (match Goal_store.upsert_goal_with_events ~actor:"test" config ~id:old.id ~title:"Renamed" () with
   | Error (Goal_store.Rejected _) -> ()
   | Error error -> fail (write_error_msg error)
   | Ok _ -> fail "partial edit left an incomplete effective criterion");
  check string "partial repair writes nothing" before (Fs_compat.load_file primary);
  (* Supplying the exact stored value is unchanged, including on historical
     incomplete rows. It retains existing successful-upsert semantics. *)
  let unchanged = upsert_exn config ~id:old.id ~title:old.title () in
  check string "unchanged criterion preserves revision" old.criterion_revision unchanged.criterion_revision;
  let repaired = upsert_exn config ~id:old.id ~title:"  Repaired condition  "
      ~metric:"  board:measurement  " ~target_value:"  zero failures  " () in
  check string "accepted title is not normalized" "  Repaired condition  " repaired.title;
  check (option string) "accepted metric is not normalized"
    (Some "  board:measurement  ") repaired.metric;
  check (option string) "accepted target is not numerically constrained"
    (Some "  zero failures  ") repaired.target_value;
  check bool "repair changes revision" true (repaired.criterion_revision <> old.criterion_revision);
  check bool "repair keeps suspension with fresh restore target" true
    (repaired.phase = Goal_phase.Paused Goal_phase.Resume_executing);
  check (option string) "repair clears current review" None repaired.last_review_note

let test_criterion_edits_invalidate_proof_phase () =
  with_workspace @@ fun config ->
  let original = upsert_exn config ~title:"Measured service" ~metric:"p99" ~target_value:"400ms" () in
  check bool "creation has revision" true (original.criterion_revision <> "");
  let completed = { original with phase = Goal_phase.Completed;
    last_review_note = Some "proved"; last_review_at = Some (iso_now ()) } in
  Goal_store.write_state config { pending_events = []; pending_notifications = []; version = 1; updated_at = iso_now (); goals = [completed] };
  let same = upsert_exn config ~id:original.id ~title:original.title ~metric:"p99"
      ~target_value:"400ms" ~priority:1 ~due_date:"2027-09-23" () in
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
  Goal_store.write_state config { pending_events = []; pending_notifications = []; version = 4; updated_at = iso_now (); goals = [verifying] };
  let renamed = upsert_exn config ~id:original.id ~title:"Another measurement" () in
  check bool "title edit supersedes active review" true (renamed.phase = Goal_phase.Executing);
  let dropped = { renamed with phase = Goal_phase.Dropped } in
  Goal_store.write_state config { pending_events = []; pending_notifications = []; version = 6; updated_at = iso_now (); goals = [dropped] };
  let updated = upsert_exn config ~id:original.id ~metric:"p95" () in
  check bool "criterion edit does not reopen dropped Goal" true (updated.phase = Goal_phase.Dropped)

(* [due_date] is a calendar day written YYYY-MM-DD; it falls due at 23:59:59
   UTC of that day (Goal_due). A value the reader cannot read is refused where
   it is written, so it never reaches the store. "2_26" and "+026" are the
   spellings [int_of_string_opt] alone would take as a year. *)
let due_dates_that_are_not_a_calendar_day =
  [ "tomorrow"; ""; "2026-9-3"; "2026-09-3"; "26-09-23"; "2026-13-01"
  ; "2026-00-10"; "2026-02-30"; "2027-02-29"; " 2027-09-23"; "2027-09-23 "
  ; "2027-09-23T10:00:00Z"; "2026/09/23"; "2026-0x-23"; "+026-09-23"
  ; "2_26-09-23" ]

let test_upsert_refuses_a_due_date_that_is_not_a_calendar_day () =
  with_workspace @@ fun config ->
  List.iter
    (fun raw ->
      match
        Goal_store.upsert_goal_with_events ~actor:"test" config ~title:"Dated" ~metric:"m"
          ~target_value:"1" ~due_date:raw ()
      with
      | Error (Goal_store.Rejected message) ->
        check bool (Printf.sprintf "%S: the refusal says what a due date is" raw) true
          (String.starts_with
             ~prefix:"due_date must be a calendar date written YYYY-MM-DD" message);
        check bool (Printf.sprintf "%S: the refusal names the value" raw) true
          (String.ends_with ~suffix:(Printf.sprintf "got %S" raw) message)
      | Error other ->
        fail (Printf.sprintf "%S refused as %s" raw (write_error_msg other))
      | Ok _ -> fail (Printf.sprintf "%S was accepted" raw))
    due_dates_that_are_not_a_calendar_day;
  check bool "a refused create wrote no goals.json" false
    (Sys.file_exists (Goal_store.goals_path config))

let test_upsert_accepts_a_real_calendar_day () =
  with_workspace ~now:calendar_fixture_now @@ fun config ->
  List.iter
    (fun raw ->
      let goal =
        upsert_exn config ~title:("Due " ^ raw) ~metric:"m" ~target_value:"1"
          ~due_date:raw ()
      in
      check (option string) (raw ^ " is stored as written") (Some raw)
        goal.due_date)
    [ "2026-09-23"; "2028-02-29"; "9999-12-31" ]

(* Creation input check. A goal born without a
   name states no success condition to hold it to, on either create path. *)
let test_upsert_refuses_a_blank_title_at_creation () =
  with_workspace ~now:calendar_fixture_now @@ fun config ->
  let rejected_naming affix = function
    | Error (Goal_store.Rejected message) ->
      check bool ("the refusal says " ^ affix) true
        (String_util.contains_substring message affix)
    | Error other -> fail ("creation refusal was not Rejected: " ^ write_error_msg other)
    | Ok _ -> fail "an infeasible goal was created"
  in
  (* A whitespace title states nothing, on the id-less path (refused before
     the lock, beside the pre-existing missing-title check) … *)
  (match Goal_store.upsert_goal_with_events ~actor:"test" config ~title:"   " ~metric:"m" ~target_value:"1" () with
   | Error (Goal_store.Rejected _) -> ()
   | Error other -> fail ("blank title was not Rejected: " ^ write_error_msg other)
   | Ok _ -> fail "a goal with a blank title was created");
  (* … and an explicit unknown id no longer defaults to "Untitled goal". *)
  rejected_naming "non-blank title"
    (Goal_store.upsert_goal_with_events ~actor:"test" config ~id:"goal-explicit-no-title" ~metric:"m"
       ~target_value:"1" ());
  (* Blank or whitespace-padded Goal IDs are refused so Goal store rows and
     trimmed goal_task_links keys cannot diverge (#39964). *)
  List.iter
    (fun bad_id ->
       match
         Goal_store.upsert_goal_with_events ~actor:"test" config ~id:bad_id ~title:"Padded id" ~metric:"m"
           ~target_value:"1" ()
       with
       | Error (Goal_store.Rejected _) -> ()
       | Error other ->
         fail (Printf.sprintf "id %S was not Rejected: %s" bad_id (write_error_msg other))
       | Ok _ -> fail (Printf.sprintf "a goal with id %S was accepted" bad_id))
    [ ""; "   "; " goal-x"; "goal-x "; "\tgoal-x\n" ];
  check bool "refused creates wrote no goals.json" false
    (Sys.file_exists (Goal_store.goals_path config));
  (* A due date already past is stored as written. *)
  let goal =
    upsert_exn config ~title:"Late" ~metric:"m" ~target_value:"1"
      ~due_date:"2026-09-21" ()
  in
  check (option string) "the past date is stored" (Some "2026-09-21") goal.due_date
;;

(* An update is checked like a create, and a refused one changes nothing. *)
let test_upsert_keeps_the_stored_due_date_when_the_new_one_is_refused () =
  with_workspace ~now:calendar_fixture_now @@ fun config ->
  let goal =
    upsert_exn config ~title:"Dated" ~metric:"m" ~target_value:"1"
      ~due_date:"2026-09-23" ()
  in
  let before = available config in
  (match Goal_store.upsert_goal_with_events ~actor:"test" config ~id:goal.id ~due_date:"TBD" () with
   | Error (Goal_store.Rejected _) -> ()
   | Error other -> fail ("TBD refused as " ^ write_error_msg other)
   | Ok _ -> fail "an update to TBD was accepted");
  let after = available config in
  check int "a refused update writes nothing" before.version after.version;
  match after.goals with
  | [ stored ] ->
    check (option string) "the stored due date is unchanged" (Some "2026-09-23")
      stored.due_date
  | goals -> fail (Printf.sprintf "expected one goal, got %d" (List.length goals))

(* An update hands back the row as it was, read inside the write lock, so the
   caller can record what the edit replaced (#39878). *)
let test_upsert_returns_the_row_as_it_was_before_an_update () =
  with_workspace ~now:calendar_fixture_now @@ fun config ->
  let created =
    upsert_exn config ~title:"Dated" ~metric:"m" ~target_value:"1"
      ~due_date:"2026-09-23" ~priority:2 ()
  in
  match
    Goal_store.upsert_goal_with_events ~actor:"test" config ~id:created.id ~due_date:"2026-10-15" ~priority:5 ()
  with
  | Ok (updated, `updated previous, _) ->
    check (option string) "the due date it held" (Some "2026-09-23") previous.due_date;
    check int "the priority it held" 2 previous.priority;
    check (option string) "the due date now" (Some "2026-10-15") updated.due_date;
    check int "the priority now" 5 updated.priority
  | Ok (_, `created, _) -> fail "an existing id must update, not create"
  | Error error -> fail (write_error_msg error)

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

let test_duplicate_identity_refuses_goal_writers () =
  with_workspace @@ fun config ->
  let first = make_goal "duplicate-goal" "First criterion" in
  let duplicate = { first with title = "Different criterion"; phase = Goal_phase.Verifying;
                               criterion_revision = "other-revision" } in
  let other = make_goal "independent-goal" "Independent" in
  (match Goal_store.write_state_result config
      { version = 7; updated_at = iso_now (); goals = [first; duplicate; other];
        pending_events = []; pending_notifications = [] } with
   | Ok () -> () | Error detail -> fail detail);
  let primary = Goal_store.goals_path config in
  let mirror = goals_recovery_path config in
  let before = Fs_compat.load_file primary, Fs_compat.load_file mirror in
  let unchanged () =
    check string "refusal keeps primary bytes" (fst before) (Fs_compat.load_file primary);
    check string "refusal keeps recovery bytes" (snd before) (Fs_compat.load_file mirror) in
  let expect_ambiguous label = function
    | Error (Goal_store.Goal_identity_ambiguous id) -> check string label first.id id
    | Error error -> fail (label ^ ": " ^ write_error_msg error)
    | Ok _ -> fail (label ^ ": duplicate Goal was accepted") in
  let entered = ref false in
  let projected = ref false in
  let effects _ _ : Goal_store.transition_effects =
    projected := true; { events = []; notifications = [] } in
  expect_ambiguous "no-op transaction rejects duplicate" (Goal_store.transact_goal ~effects config ~goal_id:first.id
    (fun goal -> entered := true; Ok (goal, ())));
  expect_ambiguous "changing transaction rejects duplicate" (Goal_store.transact_goal ~effects config ~goal_id:first.id
    (fun goal -> entered := true; Ok ({ goal with phase = Goal_phase.Dropped }, ())));
  check bool "transaction callbacks not entered" false !entered;
  check bool "transaction effects not projected" false !projected;
  expect_ambiguous "audited upsert rejects duplicate" (Goal_store.upsert_goal_with_events config ~actor:"tester" ~id:first.id ~priority:1 ());
  (match Goal_verification.bind_review config ~goal_id:first.id with
   | Error (Goal_verification.Binding_unavailable _) -> ()
   | Error (Goal_verification.No_current_review _) -> fail "ambiguous binding was called ended"
   | Ok _ -> fail "ambiguous Goal admitted a review");
  unchanged ();
  List.iter (fun target ->
    match Goal_store.transact_goal config ~goal_id:other.id
            (fun goal -> Ok ({ goal with id = target }, ())) with
    | Error (Goal_store.Rejected _) -> unchanged ()
    | Error error -> fail ("identity replacement returned wrong error: " ^ write_error_msg error)
    | Ok _ -> fail "transaction replaced Goal identity") [first.id; "missing-goal"];
  let events = match Goal_store.upsert_goal_with_events config ~actor:"tester" ~id:other.id ~priority:1 () with
    | Ok (_, `updated _, events) -> events
    | Ok (_, `created, _) -> fail "independent Goal was recreated"
    | Error error -> fail (write_error_msg error) in
  check bool "independent update records audit intents" true (events <> []);
  let state = available config in
  check int "only independent update advances version" 8 state.version;
  check bool "independent update leaves both decoded duplicate rows" true
    (List.filter (fun (goal : Goal_store.goal) -> String.equal goal.id first.id) state.goals = [first; duplicate]);
  (match Goal_store.flush_pending_events config with Ok () -> () | Error detail -> fail detail);
  check int "independent audit intents are acknowledged" 0 (List.length (available config).pending_events)

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
  | Goal_store.Nonregular _ -> "nonregular"
  | Goal_store.Not_json _ -> "not_json"
  | Goal_store.Schema_rejected _ -> "schema_rejected"

let test_nonregular_and_unix_errors_have_distinct_durable_values () =
  let record reason mirror : Goal_store.unavailable =
    { file = "/work/.masc/goals.json"; reason; mirror; reset_step = Goal_store.Inspect_path }
  in
  let roundtrip value =
    match Goal_store_unavailable.record_of_yojson (Goal_store_unavailable.record_to_yojson value) with
    | Ok decoded -> check bool "exact unavailable value survives" true (decoded = value)
    | Error detail -> fail detail
  in
  let kinds = Goal_store.[ Nonregular_directory, Unix.S_DIR; Nonregular_character_device, Unix.S_CHR;
    Nonregular_block_device, Unix.S_BLK; Nonregular_symbolic_link, Unix.S_LNK;
    Nonregular_fifo, Unix.S_FIFO; Nonregular_socket, Unix.S_SOCK ] in
  List.iter (fun (kind, unix_kind) ->
    let value = record (Goal_store.Nonregular kind) (Goal_store.Mirror_nonregular kind) in
    roundtrip value;
    let json = Goal_store_unavailable.record_to_yojson value in
    let encoded_kind = Yojson.Safe.Util.(json |> member "reason" |> member "file_kind" |> to_string) in
    check string "kind spelling agrees with filesystem diagnostics"
      (Fs_compat.file_kind_to_string unix_kind) encoded_kind) kinds;
  List.iter (fun error ->
    roundtrip (record (Goal_store.Unreadable error) (Goal_store.Mirror_unreadable error)))
    [Unix.EISDIR; Unix.EOPNOTSUPP];
  let legacy = `Assoc [
    "file", `String "/work/.masc/goals.json";
    "reason", `Assoc ["kind", `String "unreadable"; "error", `Assoc ["kind", `String "eopnotsupp"]];
    "mirror", `Assoc ["kind", `String "mirror_unreadable"; "error", `Assoc ["kind", `String "eisdir"]];
    "reset_step", `Assoc ["kind", `String "inspect_path"]] in
  (match Goal_store_unavailable.record_of_yojson legacy with
   | Ok decoded ->
       check bool "historical errno remains an errno" true
         (decoded = record (Goal_store.Unreadable Unix.EOPNOTSUPP) (Goal_store.Mirror_unreadable Unix.EISDIR))
   | Error detail -> fail detail);
  let rejected reason mirror =
    let json = `Assoc ["file", `String "/work/.masc/goals.json"; "reason", reason;
      "mirror", mirror; "reset_step", `Assoc ["kind", `String "inspect_path"]] in
    match Goal_store_unavailable.record_of_yojson json with
    | Error _ -> ()
    | Ok _ -> fail "invalid nonregular value was accepted"
  in
  let valid_reason = `Assoc ["kind", `String "nonregular"; "file_kind", `String "fifo"] in
  let valid_mirror = `Assoc ["kind", `String "mirror_nonregular"; "file_kind", `String "fifo"] in
  rejected (`Assoc ["kind", `String "nonregular"; "file_kind", `String "invented"]) valid_mirror;
  rejected valid_reason (`Assoc ["kind", `String "mirror_nonregular"; "file_kind", `String "invented"]);
  rejected (`Assoc ["kind", `String "nonregular"]) valid_mirror;
  rejected valid_reason (`Assoc ["kind", `String "mirror_nonregular"; "file_kind", `String "fifo"; "extra", `Null])

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
    { pending_events = []; pending_notifications = []; version = 7; updated_at = stamp; goals = [ make_goal "g-1" "survivor" ] };
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

let with_goal_file_link path target f =
  Unix.symlink target path;
  Fun.protect
    ~finally:(fun () ->
      match Unix.unlink path with
      | () -> ()
      | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ())
    f

let check_goal_file_link path target =
  check bool "link remains a symlink" true ((Unix.lstat path).Unix.st_kind = Unix.S_LNK);
  check string "link target is unchanged" target (Unix.readlink path)

let fifo_primary_case dir =
  with_workspace ~dir @@ fun config ->
  let primary = Goal_store.goals_path config in
  Unix.mkfifo primary 0o600;
  let expect_unavailable () =
    match unavailable config with
    | { reason = Goal_store.Nonregular Goal_store.Nonregular_fifo;
        mirror = Goal_store.Mirror_absent; reset_step = Goal_store.Inspect_path; _ } as u ->
        (match Goal_store_unavailable.record_of_yojson (Goal_store_unavailable.record_to_yojson u) with
         | Ok decoded -> check bool "unsupported kind survives durable codec" true (decoded = u)
         | Error detail -> fail detail)
    | u -> fail ("expected an unreadable FIFO: " ^ Goal_store.unavailable_to_string u)
  in
  expect_unavailable ();
  (match Goal_store.upsert_goal_with_events ~actor:"test" config ~title:"new" ~metric:"count" ~target_value:"1" () with
   | Error (Goal_store.Store_unavailable _) -> ()
   | Error error -> fail (write_error_msg error)
   | Ok _ -> fail "upsert accepted a FIFO primary");
  let reader = Unix.openfile primary [Unix.O_RDONLY; Unix.O_NONBLOCK] 0 in
  Fun.protect ~finally:(fun () -> Unix.close reader) (fun () ->
    let writer = Unix.openfile primary [Unix.O_WRONLY; Unix.O_NONBLOCK] 0 in
    Fun.protect ~finally:(fun () -> Unix.close writer) (fun () ->
      let payload = "not a Goal store" in
      check int "queued FIFO fixture" (String.length payload)
        (Unix.write_substring writer payload 0 (String.length payload));
      expect_unavailable ();
      let data = Bytes.create (String.length payload) in
      check int "reader can still consume all bytes" (String.length payload)
        (Unix.read reader data 0 (Bytes.length data));
      check string "store reader did not consume FIFO bytes" payload (Bytes.to_string data)));
  check bool "primary remains a FIFO" true ((Unix.lstat primary).Unix.st_kind = Unix.S_FIFO);
  check bool "no mirror created" false (Sys.file_exists (mirror_path config))

let fifo_mirror_link_case dir =
  with_workspace ~dir @@ fun config ->
  let state : Goal_store.state =
    { version = 1; updated_at = iso_now (); goals = [make_goal "fifo-mirror" "mirror"];
      pending_events = []; pending_notifications = [] } in
  (match Goal_store.write_state_result config state with Ok () -> () | Error e -> fail e);
  let primary = Goal_store.goals_path config in
  let mirror = mirror_path config in
  let target = "fifo-mirror-target" in
  let target_path = Filename.concat (Filename.dirname mirror) target in
  Unix.unlink mirror;
  Unix.mkfifo target_path 0o600;
  with_goal_file_link mirror target @@ fun () ->
  let next = { state with version = state.version + 1 } in
  (match Goal_store.write_state_result config next with Ok () -> () | Error e -> fail e);
  check_goal_file_link mirror target;
  check int "primary commit remains available" next.version (available config).version;
  Unix.unlink primary;
  (match unavailable config with
   | { reason = Goal_store.Missing_after_init;
       mirror = Goal_store.Mirror_nonregular Goal_store.Nonregular_fifo;
       reset_step = Goal_store.Inspect_path; _ } -> ()
   | u -> fail ("expected FIFO mirror inspection: " ^ Goal_store.unavailable_to_string u));
  (match Goal_store.upsert_goal_with_events ~actor:"test" config ~title:"new" ~metric:"count" ~target_value:"1" () with
   | Error (Goal_store.Store_unavailable _) -> ()
   | Error error -> fail (write_error_msg error)
   | Ok _ -> fail "upsert accepted a FIFO mirror");
  check_goal_file_link mirror target;
  check bool "mirror target remains a FIFO" true ((Unix.lstat target_path).Unix.st_kind = Unix.S_FIFO);
  check bool "no primary recreated" false (Sys.file_exists primary)

let fifo_mirror_direct_case dir =
  with_workspace ~dir @@ fun config ->
  let primary = Goal_store.goals_path config in
  let mirror = mirror_path config in
  Unix.mkfifo mirror 0o600;
  (match unavailable config with
   | { reason = Goal_store.Missing_after_init;
       mirror = Goal_store.Mirror_nonregular Goal_store.Nonregular_fifo;
       reset_step = Goal_store.Inspect_path; _ } -> ()
   | u -> fail ("expected a direct FIFO mirror: " ^ Goal_store.unavailable_to_string u));
  write_raw primary "{broken";
  (match unavailable config with
   | { reason = Goal_store.Not_json _;
       mirror = Goal_store.Mirror_nonregular Goal_store.Nonregular_fifo;
       reset_step = Goal_store.Inspect_path; _ } -> ()
   | u -> fail ("expected FIFO mirror inspection: " ^ Goal_store.unavailable_to_string u));
  check bool "mirror remains a FIFO" true ((Unix.lstat mirror).Unix.st_kind = Unix.S_FIFO)

(* Run each FIFO case in a child so a blocking open or read fails the test
   without hanging the suite. The parent owns and removes the fixture even
   when the child needs to be killed. *)
let rec remove_fifo_fixture path =
  match Unix.lstat path with
  | stat ->
      (match stat.Unix.st_kind with
       | Unix.S_DIR ->
           Sys.readdir path
           |> Array.iter (fun entry -> remove_fifo_fixture (Filename.concat path entry));
           Unix.rmdir path
       | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK ->
           Unix.unlink path)
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let run_fifo_case name =
  let dir = temp_dir () in
  Fun.protect ~finally:(fun () -> remove_fifo_fixture dir) (fun () ->
    let exe = Sys.executable_name in
    let pid = Unix.create_process exe [|exe; "--goal-fifo-case"; name; dir|]
        Unix.stdin Unix.stdout Unix.stderr in
    let reaped = ref false in
    Fun.protect
      ~finally:(fun () ->
        if not !reaped then begin
          (try Unix.kill pid Sys.sigkill with Unix.Unix_error (Unix.ESRCH, _, _) -> ());
          (try ignore (Unix.waitpid [] pid) with Unix.Unix_error (Unix.ECHILD, _, _) -> ())
        end)
      (fun () ->
        let deadline = Unix.gettimeofday () +. 30.0 in
        let rec wait () =
          match Unix.waitpid [Unix.WNOHANG] pid with
          | 0, _ ->
              if Unix.gettimeofday () >= deadline then fail ("Goal FIFO case blocked: " ^ name);
              ignore (Unix.select [] [] [] 0.05);
              wait ()
          | _, status ->
              reaped := true;
              (match status with
               | Unix.WEXITED 0 -> ()
               | Unix.WEXITED code -> fail (Printf.sprintf "Goal FIFO case %s exited %d" name code)
               | Unix.WSIGNALED signal -> fail (Printf.sprintf "Goal FIFO case %s signaled %d" name signal)
               | Unix.WSTOPPED signal -> fail (Printf.sprintf "Goal FIFO case %s stopped %d" name signal))
          | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait ()
        in
        wait ()))

let test_fifo_primary_is_unavailable_without_consuming_data () = run_fifo_case "primary"
let test_fifo_mirror_link_survives_commit_and_is_unavailable () = run_fifo_case "mirror-link"
let test_fifo_mirror_direct_is_unavailable () = run_fifo_case "mirror-direct"

let test_regular_file_links_remain_readable () =
  with_workspace @@ fun config ->
  let stamp = "2026-09-08T16:20:13Z" in
  Goal_store.write_state config
    { pending_events = []; pending_notifications = []; version = 7; updated_at = stamp;
      goals = [make_goal "linked-goal" "linked"] };
  let primary = Goal_store.goals_path config in
  let primary_target = "regular-primary-target" in
  Unix.rename primary (Filename.concat (Filename.dirname primary) primary_target);
  with_goal_file_link primary primary_target (fun () ->
    check int "linked regular primary decodes" 7 (available config).version;
    check_goal_file_link primary primary_target);
  let mirror = mirror_path config in
  let mirror_target = "regular-mirror-target" in
  Unix.rename mirror (Filename.concat (Filename.dirname mirror) mirror_target);
  write_raw primary "{broken";
  with_goal_file_link mirror mirror_target (fun () ->
    (match unavailable config with
     | { reason = Goal_store.Not_json _;
         mirror = Goal_store.Mirror_decodes { goal_count = 1; updated_at };
         reset_step = Goal_store.Reset_goal_store; _ } ->
         check string "linked regular mirror is evidence" stamp updated_at
     | u -> fail ("expected regular linked mirror evidence: " ^ Goal_store.unavailable_to_string u));
    check_goal_file_link mirror mirror_target)

let test_dangling_primary_is_not_uninitialized () =
  with_workspace @@ fun config ->
  let primary = Goal_store.goals_path config in
  let target = "missing-primary-goal-store" in
  with_goal_file_link primary target @@ fun () ->
  (match unavailable config with
   | { reason = Goal_store.Unreadable Unix.ENOENT; mirror = Goal_store.Mirror_absent;
       reset_step = Goal_store.Inspect_path; _ } -> ()
   | u -> fail ("expected unreadable dangling primary: " ^ Goal_store.unavailable_to_string u));
  (match Goal_store.upsert_goal_with_events ~actor:"test" config ~title:"new" ~metric:"count" ~target_value:"1" () with
   | Error (Goal_store.Store_unavailable _) -> ()
   | Error error -> fail (write_error_msg error)
   | Ok _ -> fail "upsert replaced a dangling primary link");
  check_goal_file_link primary target;
  check bool "no mirror created" false (Sys.file_exists (mirror_path config))

let test_dangling_mirror_is_evidence_of_prior_store () =
  with_workspace @@ fun config ->
  let mirror = mirror_path config in
  let target = "missing-goal-mirror" in
  with_goal_file_link mirror target @@ fun () ->
  (match unavailable config with
   | { reason = Goal_store.Missing_after_init;
       mirror = Goal_store.Mirror_unreadable Unix.ENOENT; reset_step = Goal_store.Inspect_path; _ } -> ()
   | u -> fail ("expected unreadable dangling mirror: " ^ Goal_store.unavailable_to_string u));
  (match Goal_store.upsert_goal_with_events ~actor:"test" config ~title:"new" ~metric:"count" ~target_value:"1" () with
   | Error (Goal_store.Store_unavailable _) -> ()
   | Error error -> fail (write_error_msg error)
   | Ok _ -> fail "upsert treated a dangling mirror as an absent store");
  check_goal_file_link mirror target;
  check bool "no primary created" false (Sys.file_exists (Goal_store.goals_path config))

let test_store_root_symlink_paths () =
  with_workspace @@ fun config ->
  let root = Filename.dirname (Goal_store.goals_path config) in
  let saved = root ^ ".saved" in
  Unix.rename root saved;
  Fun.protect ~finally:(fun () -> Unix.rename saved root) (fun () ->
    with_goal_file_link root "missing-masc-directory" (fun () ->
      match unavailable config with
      | { reason = Goal_store.Unreadable Unix.ENOENT;
          mirror = Goal_store.Mirror_unreadable Unix.ENOENT; reset_step = Goal_store.Inspect_path; _ } -> ()
      | u -> fail ("expected unreadable workspace link: " ^ Goal_store.unavailable_to_string u));
    with_goal_file_link root (Filename.basename saved) (fun () ->
      (match Goal_store.load_source config with
       | Goal_store.Uninitialized -> ()
       | Goal_store.Available _ -> fail "new linked workspace was already initialized"
       | Goal_store.Unavailable u -> fail (Goal_store.unavailable_to_string u));
      (match Goal_store.upsert_goal_with_events ~actor:"test" config ~title:"linked root" ~metric:"count" ~target_value:"1" () with
       | Ok _ -> () | Error error -> fail (write_error_msg error));
      check_goal_file_link root (Filename.basename saved);
      ignore (available config)))

let test_unreadable_mirror_takes_precedence_over_reset () =
  with_workspace @@ fun config ->
  let primary = Goal_store.goals_path config in
  let mirror = mirror_path config in
  write_raw primary "{broken";
  with_goal_file_link mirror "missing-mirror-target" (fun () ->
    let u = unavailable config in
    (match u with
     | { reason = Goal_store.Not_json _; mirror = Goal_store.Mirror_unreadable Unix.ENOENT;
         reset_step = Goal_store.Inspect_path; _ } -> ()
     | _ -> fail ("expected mirror inspection: " ^ Goal_store.unavailable_to_string u));
    (match Goal_store_unavailable.record_of_yojson (Goal_store_unavailable.record_to_yojson u) with
     | Ok decoded -> check bool "path inspection survives durable codec" true (decoded = u)
     | Error detail -> fail detail);
    check_goal_file_link mirror "missing-mirror-target")

let test_unresolvable_links_request_path_inspection () =
  with_workspace @@ fun config ->
  let primary = Goal_store.goals_path config in
  let mirror = mirror_path config in
  with_goal_file_link primary (Filename.basename primary) (fun () ->
    match unavailable config with
    | { reason = Goal_store.Unreadable Unix.ELOOP; reset_step = Goal_store.Inspect_path; _ } -> ()
    | u -> fail ("expected cyclic primary inspection: " ^ Goal_store.unavailable_to_string u));
  with_goal_file_link mirror (Filename.basename mirror) (fun () ->
    match unavailable config with
    | { reason = Goal_store.Missing_after_init; mirror = Goal_store.Mirror_unreadable Unix.ELOOP;
        reset_step = Goal_store.Inspect_path; _ } -> ()
    | u -> fail ("expected cyclic mirror inspection: " ^ Goal_store.unavailable_to_string u));
  let regular = Filename.concat (Filename.dirname primary) "regular-ancestor" in
  write_raw regular "file, not directory";
  with_goal_file_link mirror "regular-ancestor/child" (fun () ->
    match unavailable config with
    | { reason = Goal_store.Missing_after_init; mirror = Goal_store.Mirror_unreadable Unix.ENOTDIR;
        reset_step = Goal_store.Inspect_path; _ } -> ()
    | u -> fail ("expected invalid mirror path inspection: " ^ Goal_store.unavailable_to_string u))

let test_mirror_symlink_is_not_replaced_on_write () =
  with_workspace @@ fun config ->
  let state : Goal_store.state =
    { version = 1; updated_at = iso_now (); goals = [make_goal "mirror-goal" "mirror"];
      pending_events = []; pending_notifications = [] } in
  (match Goal_store.write_state_result config state with Ok () -> () | Error e -> fail e);
  let mirror = mirror_path config in
  let target = "original-goals-mirror.json" in
  let target_path = Filename.concat (Filename.dirname mirror) target in
  Unix.rename mirror target_path;
  let bytes = Fs_compat.load_file target_path in
  with_goal_file_link mirror target @@ fun () ->
  let next = { state with version = state.version + 1 } in
  (match Goal_store.write_state_result config next with Ok () -> () | Error e -> fail e);
  check_goal_file_link mirror target;
  check string "mirror target bytes are unchanged" bytes (Fs_compat.load_file target_path);
  check int "primary commit still succeeds" next.version (available config).version

let test_dangling_mirror_is_preserved_after_primary_commit () =
  with_workspace @@ fun config ->
  let state : Goal_store.state =
    { version = 1; updated_at = iso_now (); goals = [make_goal "mirror-goal" "mirror"];
      pending_events = []; pending_notifications = [] } in
  (match Goal_store.write_state_result config state with Ok () -> () | Error e -> fail e);
  let mirror = mirror_path config in
  Unix.unlink mirror;
  with_goal_file_link mirror "missing-mirror-target" @@ fun () ->
  let next = { state with version = state.version + 1 } in
  (match Goal_store.write_state_result config next with Ok () -> () | Error e -> fail e);
  check_goal_file_link mirror "missing-mirror-target";
  check int "primary commit still succeeds" next.version (available config).version

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

(* Setup validation and the authoritative reader must agree on the first
   document rejection, without promoting a readable mirror to current state. *)
let test_document_rejection_order_through_public_consumers () =
  with_workspace @@ fun config ->
  let goal =
    { (make_goal "codec-goal" "Resume the verification") with
      phase = Goal_phase.Paused Goal_phase.Resume_verifying }
  in
  let stamp = goal.updated_at in
  let created : Goal_store.pending_event =
    { event_id = "event-z"; goal_id = goal.id; store_revision = 6;
      recorded_at = stamp; kind = Goal_store.Created;
      payload = `Assoc ["actor", `String "original-creator"] }
  in
  let events =
    [ created;
      { created with event_id = "event-a"; store_revision = 7; kind = Goal_store.Phase;
        payload = `Assoc ["phase", `String "paused"] } ]
  in
  let state : Goal_store.state =
    { version = 7; updated_at = stamp; goals = [goal];
      pending_events = events; pending_notifications = [] }
  in
  (match Goal_store.write_state_result config state with
   | Ok () -> () | Error detail -> fail detail);
  let primary = Goal_store.goals_path config in
  let mirror = mirror_path config in
  let read path = In_channel.with_open_bin path In_channel.input_all in
  let valid_primary = read primary in
  let valid_mirror = read mirror in
  let goal_fields = match Goal_store.goal_to_yojson goal with
    | `Assoc fields -> fields
    | _ -> fail "Goal serializer returned a non-object"
  in
  let damaged_primary resume_phase =
    let row = `Assoc (("resume_phase", `String resume_phase)
      :: List.remove_assoc "resume_phase" goal_fields) in
    Yojson.Safe.to_string (`Assoc [
      "version", `Int state.version; "updated_at", `String stamp;
      "goals", `List [row]; "pending_events", `Null;
      "pending_notifications", `List []])
  in
  let expect_unavailable expected_field expected_detail (u : Goal_store.unavailable) =
    check string "unavailable names the primary file" primary u.file;
    (match u.reason with
     | Goal_store.Schema_rejected { field; detail } ->
       check string "reader keeps the canonical rejected field" expected_field field;
       check string "reader keeps the canonical rejection detail" expected_detail detail
     | Goal_store.Missing_after_init | Goal_store.Unreadable _ | Goal_store.Nonregular _ | Goal_store.Not_json _ ->
       fail (Goal_store.unavailable_to_string u));
    (match u.mirror with
     | Goal_store.Mirror_decodes { goal_count; updated_at } ->
       check int "valid mirror remains evidence" 1 goal_count;
       check string "mirror evidence keeps its timestamp" stamp updated_at
     | Goal_store.Mirror_absent | Goal_store.Mirror_unreadable _ | Goal_store.Mirror_nonregular _ | Goal_store.Mirror_rejected _ ->
       fail ("expected a readable mirror: " ^ Goal_store.unavailable_to_string u));
    check bool "repair step names the rejected field" true
      (u.reset_step = Goal_store.Repair_field expected_field)
  in
  let check_rejection resume_phase expected_field expected_detail =
    write_raw primary (damaged_primary resume_phase);
    let before = read primary in
    (match Goal_store.validate_state_json (Yojson.Safe.from_string before) with
     | Error detail ->
       check string "setup validator renders the same canonical rejection"
         (Printf.sprintf "%s (location %S)" expected_detail expected_field) detail
     | Ok () -> fail "setup validator accepted a malformed document");
    expect_unavailable expected_field expected_detail (unavailable config);
    let entered = ref false in
    let result = Goal_store.transact_goal config ~goal_id:goal.id
      (fun current ->
        entered := true;
        Ok ({ current with title = "must not commit" }, ())) in
    check bool "rejected mutation never enters its callback" false !entered;
    (match result with
     | Error (Goal_store.Store_unavailable u) ->
       expect_unavailable expected_field expected_detail u
     | Error error -> fail ("unexpected mutation refusal: " ^ write_error_msg error)
     | Ok _ -> fail "readable mirror authorized a mutation");
    check string "refused primary remains byte-identical" before (read primary);
    check string "refused mutation leaves mirror unchanged" valid_mirror (read mirror)
  in
  check_rejection "completed" "phase"
    "goal \"codec-goal\": suspended Goal requires a live resume_phase";
  (* Only the restore target is repaired; the outbox is still malformed. *)
  check_rejection "verifying" "pending_events" "pending_events must be a list";
  write_raw primary valid_primary;
  (match Goal_store.validate_state_json (Yojson.Safe.from_string (read primary)) with
   | Ok () -> () | Error detail -> fail detail);
  let restored = available config in
  check bool "restored primary retains the suspended Goal and its restore target" true
    (restored.goals = [goal]);
  check bool "restored primary retains outbox payloads in submitted order" true
    (restored.pending_events = events);
  check int "restored primary retains its own revision" state.version restored.version;
  check string "reading restored primary leaves the mirror unchanged" valid_mirror (read mirror)

(* A directory is classified by the observed kind without inventing errno. *)
let test_source_nonregular_directory () =
  with_workspace @@ fun config ->
  Unix.mkdir (Goal_store.goals_path config) 0o755;
  match unavailable config with
  | { reason = Goal_store.Nonregular Goal_store.Nonregular_directory; mirror = Goal_store.Mirror_absent;
      reset_step = Goal_store.Inspect_path; _ } -> ()
  | u -> fail ("expected nonregular directory: " ^ Goal_store.unavailable_to_string u)

let test_source_unreadable_eacces () =
  if Unix.geteuid () = 0 then begin
    print_endline "skipped: running as root, chmod 000 does not deny the read";
    Alcotest.skip ()
  end;
  with_workspace @@ fun config ->
  Goal_store.write_state config
    { pending_events = []; pending_notifications = []; version = 1; updated_at = iso_now (); goals = [ make_goal "g-1" "locked out" ] };
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
    { pending_events = []; pending_notifications = []; version = 2; updated_at = iso_now ();
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
    | Goal_store.Mirror_unreadable _ | Goal_store.Mirror_nonregular _ | Goal_store.Mirror_decodes _
    | Goal_store.Mirror_rejected _ -> false);
  Unix.mkdir mirror 0o755;
  expect "nonregular directory" (function Goal_store.Mirror_nonregular Goal_store.Nonregular_directory -> true
    | Goal_store.Mirror_unreadable _ | Goal_store.Mirror_absent
    | Goal_store.Mirror_nonregular _ | Goal_store.Mirror_decodes _ | Goal_store.Mirror_rejected _ -> false);
  Unix.rmdir mirror;
  let stamp = "2026-09-09T00:10:29Z" in
  Goal_store.write_state config
    { pending_events = []; pending_notifications = []; version = 3; updated_at = stamp; goals = phase_fixture_goals () };
  write_raw primary "{broken";
  expect "decodes" (function
    | Goal_store.Mirror_decodes { goal_count = 5; updated_at } -> String.equal updated_at stamp
    | Goal_store.Mirror_decodes _ | Goal_store.Mirror_unreadable _ | Goal_store.Mirror_nonregular _
    | Goal_store.Mirror_absent | Goal_store.Mirror_rejected _ -> false);
  write_raw mirror (bytes_without_criterion_revision (phase_fixture_goals ()));
  expect "rejected" (function
    | Goal_store.Mirror_rejected
        (Goal_store.Schema_rejected { field = "criterion_revision"; _ }) -> true
    | Goal_store.Mirror_rejected _ | Goal_store.Mirror_unreadable _ | Goal_store.Mirror_nonregular _
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
  (match Goal_store.upsert_goal_with_events ~actor:"test" config ~title:"new" ~metric:"m" ~target_value:"1" () with
   | Ok _ -> fail "upsert wrote over an unavailable store"
   | Error error -> refused "upsert_goal_with_events" error);
  unchanged "upsert_goal_with_events";
  let entered = ref false in
  (match Goal_store.transact_goal config ~goal_id:"goal-0"
           (fun goal -> entered := true; Ok (goal, ())) with
   | Ok _ -> fail "transact_goal wrote over an unavailable store"
   | Error error -> refused "transact_goal" error);
  check bool "transact_goal callback not entered" false !entered;
  unchanged "transact_goal";
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
    { pending_events = []; pending_notifications = []; version = 1; updated_at = iso_now (); goals = [ make_goal "known" "found" ] };
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
  (* A refused create commits nothing, so the source stays Uninitialized. *)
  (match Goal_store.upsert_goal_with_events ~actor:"test" config ~title:"no condition" () with
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
  (match Goal_store.upsert_goal_with_events ~actor:"test" config ~title:"first" ~metric:"m" ~target_value:"1" () with
   | Ok (_, `created, _) -> ()
   | Ok (_, `updated _, _) -> fail "first write reported an update"
   | Error error -> fail (write_error_msg error));
  let state = available config in
  check int "first write holds one goal" 1 (List.length state.goals);
  check int "first write starts the version counter" 2 state.version

let event_rows path =
  Fs_compat.load_file path |> String.split_on_char '\n'
  |> List.filter (fun line -> line <> "") |> List.map Yojson.Safe.from_string

let test_refused_audited_upserts_preserve_store_and_outbox () =
  with_workspace ~now:calendar_fixture_now @@ fun config ->
  let primary = Goal_store.goals_path config in
  let mirror = goals_recovery_path config in
  let ledger = Filename.concat (Filename.dirname primary) "goal_events.jsonl" in
  let refused = function
    | Error (Goal_store.Rejected _) -> ()
    | Error error -> fail (write_error_msg error)
    | Ok _ -> fail "an invalid audited upsert was accepted" in
  let attempts =
    [ (fun () -> Goal_store.upsert_goal_with_events config ~actor:"rejected"
          ~id:"unknown-goal" ~metric:"m" ~target_value:"1" ());
      (fun () -> Goal_store.upsert_goal_with_events config ~actor:"rejected"
          ~title:"No condition" ()) ] in
  List.iter (fun attempt ->
    refused (attempt ());
    (match Goal_store.load_source config with
     | Goal_store.Uninitialized -> ()
     | Goal_store.Available _ | Goal_store.Unavailable _ ->
         fail "a refused audited creation initialized the store");
    List.iter (fun path ->
      check bool "refused creation writes no store, mirror or ledger" false
        (Sys.file_exists path)) [primary; mirror; ledger]) attempts;
  let goal = match Goal_store.upsert_goal_with_events config ~actor:"creator"
      ~title:"Keep attribution" ~metric:"m" ~target_value:"1" () with
    | Ok (goal, `created, _) -> goal
    | Ok (_, `updated _, _) -> fail "expected the first accepted creation"
    | Error error -> fail (write_error_msg error) in
  let before = available config in
  check int "accepted creation has a pending intent" 1 (List.length before.pending_events);
  let primary_bytes = Fs_compat.load_file primary in
  let mirror_bytes = Fs_compat.load_file mirror in
  let invalid_update () =
    Goal_store.upsert_goal_with_events config ~actor:"rejected"
      ~id:goal.id ~due_date:"TBD" () in
  List.iter (fun attempt ->
    refused (attempt ());
    check string "rejection preserves primary and its outbox" primary_bytes
      (Fs_compat.load_file primary);
    check string "rejection preserves recovery mirror" mirror_bytes
      (Fs_compat.load_file mirror);
    check bool "rejection publishes no audit rows" false (Sys.file_exists ledger))
    (invalid_update :: attempts)

let test_identical_audited_upsert_still_commits () =
  with_workspace ~now:calendar_fixture_now @@ fun config ->
  let created = match Goal_store.upsert_goal_with_events config ~actor:"creator"
      ~title:"Confirmed criterion" ~metric:"m" ~target_value:"1"
      ~due_date:"2026-09-23" ~priority:2 () with
    | Ok (goal, `created, _) -> goal
    | Ok (_, `updated _, _) -> fail "expected a creation"
    | Error error -> fail (write_error_msg error) in
  let completed =
    { created with phase = Goal_phase.Completed;
      last_review_note = Some "confirmed"; last_review_at = Some created.updated_at } in
  let initial = available config in
  Goal_store.write_state config { initial with goals = [completed] };
  let event_ids events =
    List.map (fun (event : Goal_store.pending_event) -> event.event_id) events in
  let attempts =
    [ (fun () -> Goal_store.upsert_goal_with_events config ~actor:"editor"
          ~id:created.id ());
      (fun () -> Goal_store.upsert_goal_with_events config ~actor:"editor"
          ~id:created.id ~title:"Confirmed criterion" ~metric:"m" ~target_value:"1"
          ~due_date:"2026-09-23" ~priority:2 ()) ] in
  List.iter (fun attempt ->
    let before = available config in
    let previous = List.hd before.goals in
    let (goal, events : Goal_store.goal * Goal_store.pending_event list) = match attempt () with
      | Ok (goal, `updated actual_previous, events) ->
          check bool "action carries the exact authoritative previous row" true
            (actual_previous = previous);
          goal, events
      | Ok (_, `created, _) -> fail "an existing goal became a creation"
      | Error error -> fail (write_error_msg error) in
    let after = available config in
    check int "identical update advances the store version" (before.version + 1) after.version;
    check string "criterion identity stays bound" completed.criterion_revision goal.Goal_store.criterion_revision;
    check bool "completed phase is retained" true (goal.phase = Goal_phase.Completed);
    check (option string) "review note is retained" completed.last_review_note goal.last_review_note;
    check (option string) "review time is retained" completed.last_review_at goal.last_review_at;
    check bool "returned goal is the persisted row" true (after.goals = [goal]);
    (match events with
     | [event] ->
         check bool "identical edit emits Updated only" true (event.Goal_store.kind = Goal_store.Updated);
         check int "event witnesses this commit" after.version event.store_revision;
         check int "snapshot witnesses the same commit" after.version
           Yojson.Safe.Util.(event.payload |> member "store_version" |> to_int)
     | _ -> fail "expected one Updated event for an identical edit");
    check (list string) "accepted edit appends to the existing durable outbox"
      (event_ids before.pending_events @ event_ids events)
      (event_ids after.pending_events)) attempts

let test_audit_outbox_retains_creation_and_deduplicates_retry () =
  with_workspace @@ fun config ->
  let path = Filename.concat (Filename.dirname (Goal_store.goals_path config)) "goal_events.jsonl" in
  Unix.mkdir path 0o700;
  let goal, events = match Goal_store.upsert_goal_with_events config ~actor:"original-creator"
      ~title:"durable attribution" ~metric:"proof" ~target_value:"1" () with
    | Ok (goal, `created, events) -> goal, events
    | Ok _ -> fail "expected a creation"
    | Error error -> fail (write_error_msg error) in
  check int "snapshot intent committed with the Goal" 1 (List.length events);
  (match Goal_store.flush_pending_events config with
   | Error _ -> () | Ok () -> fail "a directory cannot accept audit rows");
  let retained = available config in
  check int "failed append keeps the intent" 1 (List.length retained.pending_events);
  let event = List.hd retained.pending_events in
  check string "creator survives a disk reload" "original-creator"
    Yojson.Safe.Util.(event.payload |> member "actor" |> to_string);
  check string "pending snapshot belongs to committed Goal" goal.id event.goal_id;
  check int "revision is assigned by the Goal commit" retained.version event.store_revision;
  check int "strict snapshot reader receives that same committed witness" retained.version
    Yojson.Safe.Util.(event.payload |> member "store_version" |> to_int);
  let mirror = Yojson.Safe.from_file (goals_recovery_path config) in
  check int "recovery mirror also holds the audit intent" 1
    Yojson.Safe.Util.(mirror |> member "pending_events" |> to_list |> List.length);
  Unix.rmdir path;
  (* Crash window: ledger publication completed, but the durable Goal intent
     still exists because its acknowledgement did not commit. *)
  Fs_compat.append_jsonl path (Goal_store.pending_event_to_yojson event);
  (match Goal_store.flush_pending_events config with
   | Ok () -> () | Error detail -> fail detail);
  let rows = event_rows path in
  check int "retry never duplicates the creator event" 1 (List.length rows);
  check string "creation did not become an update" "goal_created"
    Yojson.Safe.Util.(List.hd rows |> member "event_type" |> to_string);
  let acknowledged = available config in
  check int "successful delivery acknowledges its intent" 0 (List.length acknowledged.pending_events);
  check int "acknowledgement advances the store version" (retained.version + 1) acknowledged.version;
  check int "event retains the original mutation revision" retained.version
    Yojson.Safe.Util.(List.hd rows |> member "store_revision" |> to_int);
  let collision = { event with payload = `Assoc [ "actor", `String "another-creator" ] } in
  Goal_store.write_state config { acknowledged with pending_events = [collision] };
  (match Goal_store.flush_pending_events config with
   | Error _ -> () | Ok () -> fail "one event ID cannot acknowledge different content");
  check int "conflicting identity remains pending" 1 (List.length (available config).pending_events);
  check int "conflicting identity does not append" 1 (List.length (event_rows path));
  Goal_store.write_state config { acknowledged with pending_events = [event; collision] };
  (match Goal_store.load_source config with
   | Goal_store.Unavailable { reason = Schema_rejected { field = "pending_events"; _ }; _ } -> ()
   | _ -> fail "duplicate IDs in one pending batch must refuse the source");
  (match Goal_store.flush_pending_events config with
   | Error _ -> () | Ok () -> fail "a duplicate pending batch cannot publish");
  check int "duplicate pending batch leaves the ledger untouched" 1 (List.length (event_rows path))

let test_audit_outbox_preserves_malformed_complete_rows () =
  with_workspace @@ fun config ->
  let path = Filename.concat (Filename.dirname (Goal_store.goals_path config)) "goal_events.jsonl" in
  let prefix = "{\"event_id\":\"old-before\"}\nBROKEN\n{\"event_id\":\"old-after\"}\n" in
  let write contents =
    let channel = open_out_bin path in
    Fun.protect ~finally:(fun () -> close_out channel)
      (fun () -> output_string channel contents) in
  write prefix;
  let events = match Goal_store.upsert_goal_with_events config ~actor:"creator"
      ~title:"audit continues" ~metric:"proof" ~target_value:"1" () with
    | Ok (_, _, events) -> events
    | Error error -> fail (write_error_msg error) in
  let event = List.hd events in
  let flush () = match Goal_store.flush_pending_events config with
    | Ok () -> () | Error detail -> fail detail in
  flush ();
  check int "first tick acknowledges delivery" 0
    (List.length (available config).pending_events);
  let delivered = Fs_compat.load_file path in
  flush ();
  check string "second tick does not duplicate delivery" delivered (Fs_compat.load_file path);
  let other = upsert_exn config ~title:"another Goal" ~metric:"proof" ~target_value:"1" () in
  let phase = `Assoc ["goal_id", `String other.id; "event_type", `String "goal_phase";
      "payload", `Assoc ["phase", Goal_phase.to_yojson Goal_phase.Dropped]] in
  (match Goal_store.append_audit_event_after_pending config phase with
   | Ok () -> () | Error detail -> fail detail);
  let contents = Fs_compat.load_file path in
  check string "historical bytes remain intact" prefix
    (String.sub contents 0 (String.length prefix));
  let rows, malformed = Fs_compat.load_jsonl_diagnostics path in
  check int "reader still reports malformed evidence" 1 malformed;
  check int "historical rows and every new event readable" 5 (List.length rows);
  check int "creation delivered exactly once" 1
    (List.filter (fun row -> Json_util.get_string row "event_id" = Some event.event_id)
       rows |> List.length);
  check bool "unrelated phase delivered" true (List.exists (Yojson.Safe.equal phase) rows);
  let acknowledged = available config in
  Goal_store.write_state config { acknowledged with pending_events = [event] };
  write (contents ^ "{\"torn\":");
  let torn = Fs_compat.load_file path in
  (match Goal_store.flush_pending_events config with
   | Error _ -> () | Ok () -> fail "incomplete tail must still refuse delivery");
  check string "incomplete tail unchanged" torn (Fs_compat.load_file path);
  check int "incomplete tail retains intent" 1
    (List.length (available config).pending_events);
  write contents;
  let collision = { event with payload = `Assoc ["actor", `String "different"] } in
  Goal_store.write_state config { acknowledged with pending_events = [collision] };
  (match Goal_store.flush_pending_events config with
   | Error _ -> () | Ok () -> fail "malformed history must not conceal an ID collision");
  check string "collision keeps every byte" contents (Fs_compat.load_file path);
  check int "collision retains intent" 1 (List.length (available config).pending_events)

let test_pending_phase_precedes_drop_and_survives_retry () =
  with_workspace @@ fun config ->
  let path = Filename.concat (Filename.dirname (Goal_store.goals_path config)) "goal_events.jsonl" in
  let goal = upsert_exn config ~title:"Changed criterion then dropped"
      ~metric:"proof" ~target_value:"1" () in
  let state = available config in
  Goal_store.write_state config
    { state with goals = [{ goal with phase = Goal_phase.Verifying }] };
  let events = match Goal_store.upsert_goal_with_events config ~actor:"editor"
      ~id:goal.id ~target_value:"2" () with
    | Ok (updated, _, events) ->
        check bool "criterion edit returns to execution" true
          (updated.phase = Goal_phase.Executing);
        events
    | Error error -> fail (write_error_msg error) in
  (match Goal_store.transact_goal config ~goal_id:goal.id (fun current ->
        Ok ({ current with phase = Goal_phase.Dropped }, ())) with
   | Ok _ -> () | Error error -> fail (write_error_msg error));
  let closed_at = "2026-10-01T12:00:00Z" in
  let dropped = `Assoc
    [ "ts", `String closed_at; "goal_id", `String goal.id;
      "event_type", `String "goal_phase";
      "payload", `Assoc ["phase", `String "dropped"; "actor", `String "operator"] ] in
  (match Goal_store.append_audit_event_after_pending config dropped with
   | Ok () -> () | Error detail -> fail detail);
  let rows = event_rows path in
  let phases = List.filter_map (fun row ->
    let open Yojson.Safe.Util in
    if member "event_type" row = `String "goal_phase" then
      Some (row |> member "payload" |> member "phase" |> to_string)
    else None) rows in
  check (list string) "pending execution precedes terminal drop"
    ["executing"; "dropped"] phases;
  (* Restore acknowledged IDs to model a failed acknowledgement followed by retry. *)
  let acknowledged = available config in
  Goal_store.write_state config { acknowledged with pending_events = events };
  (match Goal_store.flush_pending_events config with
   | Ok () -> () | Error detail -> fail detail);
  check string "retry leaves ledger order and bytes intact"
    (String.concat "\n" (List.map Yojson.Safe.to_string rows))
    (String.concat "\n" (List.map Yojson.Safe.to_string (event_rows path)));
  (match Goal_store.delete_goal config ~goal_id:goal.id with
   | Ok _ -> () | Error error -> fail (Goal_store.delete_goal_error_to_string error));
  let history = Dashboard_goals.unlisted_goal_history_of_rows
      ~listed:[] ~rows:(event_rows path) ~malformed_lines:0 in
  let open Yojson.Safe.Util in
  let row = List.hd (history |> member "unlisted" |> to_list) in
  check string "deleted Goal retains terminal outcome" "dropped"
    (row |> member "final_phase" |> to_string);
  check string "deleted Goal retains closing timestamp" closed_at
    (row |> member "closed_at" |> to_string)

let test_audit_intents_survive_other_goal_mutations () =
  with_workspace @@ fun config ->
  let goal, initial = match Goal_store.upsert_goal_with_events config ~actor:"creator"
      ~title:"retained" ~metric:"proof" ~target_value:"1" () with
    | Ok (goal, _, events) -> goal, events
    | Error error -> fail (write_error_msg error) in
  let check_pending label =
    check (list string) label (List.map (fun e -> e.Goal_store.event_id) initial)
      (List.map (fun e -> e.Goal_store.event_id) (available config).pending_events) in
  (match Goal_store.transact_goal config ~goal_id:goal.id (fun current ->
       Ok ({ current with priority = 2 }, ())) with
   | Ok _ -> () | Error error -> fail (write_error_msg error));
  check_pending "transaction preserves audit intents";
  (match Goal_store.delete_goal config ~goal_id:goal.id with
   | Ok _ -> () | Error error -> fail (Goal_store.delete_goal_error_to_string error));
  check_pending "deletion preserves audit attribution"

(* [with_goal_file_link] builds the link this fixture later cleans; the cleanup
   alone must finish it, both for a live link into a directory and for a dangling
   one, and must not reach the target (#26648). *)
let test_rm_rf_unlinks_symlinks () =
  let root = temp_dir () in
  let kept_dir = temp_dir () in
  let kept = Filename.concat kept_dir "kept" in
  Out_channel.with_open_bin kept (fun oc -> output_string oc "kept");
  Unix.mkdir (Filename.concat root "owner") 0o755;
  Unix.symlink kept_dir (Filename.concat root "live_link");
  Unix.symlink (Filename.concat root "gone") (Filename.concat root "dangling");
  rm_rf root;
  check bool "the tree is gone" false (Sys.file_exists root);
  check bool "the link target survived" true (Sys.file_exists kept);
  rm_rf kept_dir

let () =
  match Array.to_list Sys.argv with
  | [_; "--goal-fifo-case"; "primary"; dir] -> fifo_primary_case dir
  | [_; "--goal-fifo-case"; "mirror-link"; dir] -> fifo_mirror_link_case dir
  | [_; "--goal-fifo-case"; "mirror-direct"; dir] -> fifo_mirror_direct_case dir
  | _ -> run "Goal_store"
    [ ( "temp directory cleanup",
        [ test_case "rm_rf unlinks live and dangling links" `Quick
            test_rm_rf_unlinks_symlinks ] );
      ( "audit outbox",
        [ test_case "refused audited upserts preserve store and outbox" `Quick
            test_refused_audited_upserts_preserve_store_and_outbox;
          test_case "identical audited update still commits" `Quick
            test_identical_audited_upsert_still_commits;
          test_case "malformed complete history preserves delivery and refusals" `Quick
            test_audit_outbox_preserves_malformed_complete_rows;
          test_case "failed creation delivery and duplicate-safe retry" `Quick
            test_audit_outbox_retains_creation_and_deduplicates_retry;
          test_case "intents survive every mutator" `Quick
            test_audit_intents_survive_other_goal_mutations;
          test_case "pending phase precedes drop and retry preserves history" `Quick
            test_pending_phase_precedes_drop_and_survives_retry ] );
      ( "proof identity",
        [ test_case "blank criterion edits preserve every phase and outbox" `Quick
            test_blank_criterion_edits_preserve_store_and_outbox;
          test_case "historical incomplete criteria remain maintainable and repairable" `Quick
            test_incomplete_historical_criterion_can_be_maintained_and_repaired;
          test_case "criterion edits invalidate proof phase" `Quick test_criterion_edits_invalidate_proof_phase;
          test_case "transaction uses primary and preserves no-op" `Quick test_transact_goal_authoritative_and_noop;
          test_case "duplicate identity refuses Goal writers and preserves independent work" `Quick test_duplicate_identity_refuses_goal_writers;
          test_case "missing revision refuses bound mutation" `Quick test_missing_criterion_revision_refuses_bound_mutation ] );
      ( "due date",
        [ test_case "a value that is not a calendar day is refused" `Quick
            test_upsert_refuses_a_due_date_that_is_not_a_calendar_day;
          test_case "a real calendar day is stored as written" `Quick
            test_upsert_accepts_a_real_calendar_day;
          test_case "creation refuses a blank title" `Quick
            test_upsert_refuses_a_blank_title_at_creation;
          test_case "a refused update keeps the stored due date" `Quick
            test_upsert_keeps_the_stored_due_date_when_the_new_one_is_refused;
          test_case "an update returns the row as it was" `Quick
            test_upsert_returns_the_row_as_it_was_before_an_update ] );
      ( "regression-7690",
        [ test_case "version bumps +1" `Quick test_delete_goal_bumps_version;
          test_case "three deletes = +3" `Quick
            test_multiple_deletes_each_bump;
          test_case "missing goal: no bump" `Quick
            test_delete_nonexistent_does_not_bump;
          test_case "duplicate Goal identity refuses deletion and link cleanup" `Quick
            test_delete_refuses_duplicate_goal_identity;
          test_case "updated_at also refreshed" `Quick
            test_updated_at_also_refreshed;
          test_case "delete prunes goal_task_links" `Quick
            test_delete_goal_prunes_goal_task_links;
          test_case "prune failure reports partial delete" `Quick
            test_delete_goal_wraps_prune_failure_after_goal_delete;
          test_case "ambiguous links report partial Goal deletion" `Quick
            test_delete_goal_reports_ambiguous_link_cleanup;
          test_case "status field no longer decodes" `Quick
            test_status_field_no_longer_decodes;
          test_case "serializer omits status" `Quick
            test_serializer_omits_status;
          test_case "other unknown goal field still fails" `Quick
            test_other_unknown_goal_field_still_fails;
          test_case "duplicate document members refuse writes" `Quick
            test_duplicate_document_members_refuse_writes;
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
          test_case "write_state sanitizes invalid utf8" `Quick
            test_write_state_sanitizes_invalid_utf8_before_persisting;
            test_case "local Goal publication uses FileSystem authority" `Quick
            (test_goal_publication_uses_local_authority Goal_file_system);
          test_case "local Goal publication leaves Memory documents independent" `Quick
            (test_goal_publication_uses_local_authority Goal_memory);
          test_case "blocked local primary preserves FileSystem Goal publication" `Quick
            (test_blocked_goal_primary_preserves_publication Goal_file_system);
          test_case "blocked local primary leaves Memory documents independent" `Quick
            (test_blocked_goal_primary_preserves_publication Goal_memory);
          test_case "recovery failure preserves FileSystem primary commit" `Quick
            (test_write_state_result_keeps_primary_commit_when_recovery_write_fails Goal_file_system);
          test_case "recovery failure preserves Memory local primary commit" `Quick
            (test_write_state_result_keeps_primary_commit_when_recovery_write_fails Goal_memory) ] );
      ( "rfc-0444 source",
        [ test_case "uninitialized only when both files are absent" `Quick
            test_source_uninitialized_only_when_both_files_absent;
          test_case "missing after init" `Quick test_source_missing_after_init;
          test_case "nonregular observations and Unix errors stay distinct in durable records" `Quick
            test_nonregular_and_unix_errors_have_distinct_durable_values;
          test_case "FIFO primary is unavailable without consuming data" `Quick
            test_fifo_primary_is_unavailable_without_consuming_data;
          test_case "FIFO mirror link survives commit and is unavailable" `Quick
            test_fifo_mirror_link_survives_commit_and_is_unavailable;
          test_case "direct FIFO mirror is unavailable" `Quick
            test_fifo_mirror_direct_is_unavailable;
          test_case "regular file links remain readable" `Quick
            test_regular_file_links_remain_readable;
          test_case "dangling primary is unavailable" `Quick test_dangling_primary_is_not_uninitialized;
          test_case "dangling mirror is prior-store evidence" `Quick test_dangling_mirror_is_evidence_of_prior_store;
          test_case "dangling and valid workspace links" `Quick test_store_root_symlink_paths;
          test_case "unreadable mirror takes recovery priority" `Quick test_unreadable_mirror_takes_precedence_over_reset;
          test_case "unresolvable links request inspection" `Quick test_unresolvable_links_request_path_inspection;
          test_case "mirror symlink is preserved on write" `Quick test_mirror_symlink_is_not_replaced_on_write;
          test_case "dangling mirror is preserved after primary commit" `Quick test_dangling_mirror_is_preserved_after_primary_commit;
          test_case "not json" `Quick test_source_not_json;
          test_case "schema rejected names criterion_revision" `Quick
            test_source_schema_rejected_names_criterion_revision;
          test_case "document errors agree through public consumers" `Quick
            test_document_rejection_order_through_public_consumers;
          test_case "nonregular directory" `Quick test_source_nonregular_directory;
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
