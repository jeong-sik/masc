module Types = Masc_domain

open Alcotest
open Masc

let temp_dir () = Filename.temp_dir "goal_store_test" ""

let rm_rf dir =
  let rec rm path =
    if Sys.file_exists path
    then if Sys.is_directory path
      then begin
        Sys.readdir path |> Array.iter (fun entry -> rm (Filename.concat path entry));
        Unix.rmdir path
      end
      else Sys.remove path
  in
  try rm dir with _ -> ()
;;

let with_workspace f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = temp_dir () in
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () ->
    let config = Workspace.default_config dir in
    ignore (Workspace.init config ~agent_name:(Some "test"));
    f config)
;;

let iso_now () = Masc_domain.now_iso ()
let goals_recovery_path config = Goal_store.goals_path config ^ ".last-good"

let make_goal id title =
  let ts = iso_now () in
  { Goal_store.id
  ; title
  ; metric = None
  ; target_value = None
  ; due_date = None
  ; priority = 3
  ; phase = Goal_phase.executing
  ; parent_goal_id = None
  ; last_review_note = None
  ; last_review_at = None
  ; completion_review_failure = None
  ; completion_receipt = None
  ; created_at = ts
  ; updated_at = ts
  }
;;

let write_fixture config version goals =
  Goal_store.For_testing.write_state
    config
    { Goal_store.version; updated_at = iso_now (); goals }
;;

let test_delete_goal_bumps_version () =
  with_workspace @@ fun config ->
  write_fixture config 10 [ make_goal "g-1" "to delete" ];
  let before = (Goal_store.read_state config).version in
  (match Goal_store.delete_goal config ~goal_id:"g-1" with
   | Ok Goal_store.Deleted -> ()
   | Ok (Goal_store.Deleted_with_orphaned_links msg) -> fail msg
   | Error error -> fail (Goal_store.delete_goal_error_to_string error));
  check int "version bumped" (before + 1) (Goal_store.read_state config).version
;;

let test_multiple_deletes_each_bump () =
  with_workspace @@ fun config ->
  let goals = List.init 3 (fun index -> make_goal (string_of_int index) "goal") in
  write_fixture config 5 goals;
  List.iter
    (fun index -> ignore (Goal_store.delete_goal config ~goal_id:(string_of_int index)))
    [ 0; 1; 2 ];
  let state = Goal_store.read_state config in
  check int "three versions" 8 state.version;
  check int "empty" 0 (List.length state.goals)
;;

let test_delete_nonexistent_does_not_bump () =
  with_workspace @@ fun config ->
  write_fixture config 42 [ make_goal "exists" "one goal" ];
  let before = Goal_store.read_state config in
  (match Goal_store.delete_goal config ~goal_id:"ghost" with
   | Error (Goal_store.Unknown_goal _) -> ()
   | Error error -> fail (Goal_store.delete_goal_error_to_string error)
   | Ok _ -> fail "missing goal was deleted");
  let after = Goal_store.read_state config in
  check int "version unchanged" before.version after.version
;;

let test_delete_goal_prunes_links () =
  with_workspace @@ fun config ->
  write_fixture config 1 [ make_goal "g-1" "delete"; make_goal "g-2" "keep" ];
  Workspace_goal_index.write_goal_task_links
    config
    [ "g-1", [ "task-a" ]; "g-2", [ "task-b" ] ];
  ignore (Goal_store.delete_goal config ~goal_id:"g-1");
  let links = Workspace_goal_index.read_goal_task_links config in
  check bool "deleted links absent" false (List.mem_assoc "g-1" links);
  check bool "other links retained" true (List.mem_assoc "g-2" links)
;;

let expect_current_state_invalid config label =
  try
    ignore (Goal_store.read_state config);
    fail (label ^ " unexpectedly decoded")
  with
  | Goal_store.Current_state_invalid _ -> ()
;;

let current_state_json goal_fields =
  `Assoc
    [ "version", `Int 1
    ; "updated_at", `String (iso_now ())
    ; "goals", `List [ `Assoc goal_fields ]
    ]
;;

let base_goal_fields =
  [ "id", `String "g"
  ; "title", `String "Goal"
  ; "metric", `Null
  ; "target_value", `Null
  ; "due_date", `Null
  ; "priority", `Int 3
  ; "phase", `String "executing"
  ; "parent_goal_id", `Null
  ; "last_review_note", `Null
  ; "last_review_at", `Null
  ; "completion_review_failure", `Null
  ; "completion_receipt", `Null
  ; "created_at", `String (iso_now ())
  ; "updated_at", `String (iso_now ())
  ]
;;

let test_status_field_is_rejected () =
  with_workspace @@ fun config ->
  Workspace.write_json
    config
    (Goal_store.goals_path config)
    (current_state_json (("status", `String "active") :: base_goal_fields));
  expect_current_state_invalid config "legacy status field"
;;

let test_phaseless_row_is_rejected () =
  with_workspace @@ fun config ->
  let fields = List.remove_assoc "phase" base_goal_fields in
  Workspace.write_json config (Goal_store.goals_path config) (current_state_json fields);
  expect_current_state_invalid config "phaseless row"
;;

let test_nonterminal_phase_update () =
  with_workspace @@ fun config ->
  let goal, _ =
    match Goal_store.upsert_goal config ~title:"Blocked goal" () with
    | Ok value -> value
    | Error msg -> fail msg
  in
  let updated =
    match
      Goal_store.set_nonterminal_phase_if_unchanged
        config
        ~expected:goal
        ~phase:Goal_store.Phase.N_blocked
        ~review_note:(Some "waiting")
    with
    | Ok updated -> updated
    | Error error -> fail (Goal_store.conditional_update_error_to_string error)
  in
  check bool "blocked" true (Goal_phase.is_blocked updated.phase);
  check (option string) "note" (Some "waiting") updated.last_review_note
;;

let test_list_goals_filters_by_view () =
  with_workspace @@ fun config ->
  let executing = make_goal "executing" "Executing" in
  let blocked = { (make_goal "blocked" "Blocked") with phase = Goal_phase.blocked } in
  write_fixture config 1 [ executing; blocked ];
  let goals = Goal_store.list_goals config ~phase:Goal_phase.Blocked () in
  check int "one blocked" 1 (List.length goals)
;;

let evidence_hash
      ?(workspace_identity = "workspace-a")
      ?(goal_json = `Assoc [ "id", `String "g"; "title", `String "Goal" ])
      ?(linked_tasks_json = `List [ `Assoc [ "id", `String "task-a" ] ])
      ()
  =
  Goal_completion_reviewer.For_testing.review_evidence_sha256
    ~workspace_identity
    ~goal_json
    ~completion_claim:"target reached"
    ~requesting_agent:"reviewer"
    ~linked_tasks_json
    ~linked_task_ids:[ "task-a" ]
    ~child_goals_json:(`List [])
;;

let digest ?(workspace_identity = "workspace-a") ?(expected_version = 7)
      ?(operation_id = "operation-a") ?(review_evidence_sha256 = evidence_hash ()) () =
  Goal_completion_reviewer.For_testing.completion_digest
    ~workspace_identity
    ~goal_json:(`Assoc [ "id", `String "g"; "title", `String "Goal" ])
    ~reviewed_goal_updated_at:"2026-07-27T00:00:00Z"
    ~goal_id:"g"
    ~expected_version
    ~operation_id
    ~evaluator_runtime:"runtime-a"
    ~reviewed_at:"2026-07-27T00:01:00Z"
    ~review_prompt_sha256:"prompt"
    ~review_evidence_sha256
    ~completion_claim:"target reached"
    ~requesting_agent:"reviewer"
    ~linked_task_ids:[ "task-a" ]
;;

let test_cross_workspace_digest_rejected () =
  check bool "workspace identity is bound" false
    (String.equal (digest ()) (digest ~workspace_identity:"workspace-b" ()))
;;

let test_operation_and_version_replay_rejected () =
  check bool "operation id is bound" false
    (String.equal (digest ()) (digest ~operation_id:"operation-b" ()));
  check bool "state version is bound" false
    (String.equal (digest ()) (digest ~expected_version:8 ()))
;;

let test_stale_evidence_changes_digest () =
  let stale = evidence_hash () in
  let current =
    evidence_hash
      ~linked_tasks_json:(`List [ `Assoc [ "id", `String "task-a"; "state", `String "done" ] ])
      ()
  in
  check bool "evidence hash changed" false (String.equal stale current);
  check bool "completion digest changed" false
    (String.equal
       (digest ~review_evidence_sha256:stale ())
       (digest ~review_evidence_sha256:current ()))
;;

let test_canonical_object_encoding () =
  let left = evidence_hash ~goal_json:(`Assoc [ "b", `Int 2; "a", `Int 1 ]) () in
  let right = evidence_hash ~goal_json:(`Assoc [ "a", `Int 1; "b", `Int 2 ]) () in
  check string "object key order is canonical" left right
;;

let test_write_state_sanitizes_invalid_utf8 () =
  with_workspace @@ fun config ->
  let goal = { (make_goal "utf8" "bad\xffgoal") with metric = Some "bad\xffmetric" } in
  write_fixture config 1 [ goal ];
  let raw = Fs_compat.load_file (Goal_store.goals_path config) in
  check bool "invalid byte removed" false (String.contains raw '\255')
;;

let test_recovery_mirror_failure_keeps_primary () =
  with_workspace @@ fun config ->
  Unix.mkdir (goals_recovery_path config) 0o755;
  let goal = make_goal "g" "primary" in
  let state = { Goal_store.version = 3; updated_at = iso_now (); goals = [ goal ] } in
  (match Goal_store.For_testing.write_state_result config state with
   | Ok () -> ()
   | Error msg -> fail msg);
  check bool "primary committed" true (Option.is_some (Goal_store.get_goal config ~goal_id:"g"))
;;

let () =
  run
    "Goal_store"
    [ ( "store"
      , [ test_case "delete bumps version" `Quick test_delete_goal_bumps_version
        ; test_case "multiple deletes bump" `Quick test_multiple_deletes_each_bump
        ; test_case "missing delete no bump" `Quick test_delete_nonexistent_does_not_bump
        ; test_case "delete prunes links" `Quick test_delete_goal_prunes_links
        ; test_case "status rejected" `Quick test_status_field_is_rejected
        ; test_case "phaseless rejected" `Quick test_phaseless_row_is_rejected
        ; test_case "typed nonterminal update" `Quick test_nonterminal_phase_update
        ; test_case "view filter" `Quick test_list_goals_filters_by_view
        ; test_case "utf8 write" `Quick test_write_state_sanitizes_invalid_utf8
        ; test_case "primary survives mirror failure" `Quick test_recovery_mirror_failure_keeps_primary
        ] )
    ; ( "completion-authority"
      , [ test_case "cross-workspace" `Quick test_cross_workspace_digest_rejected
        ; test_case "operation/version replay" `Quick test_operation_and_version_replay_rejected
        ; test_case "stale evidence" `Quick test_stale_evidence_changes_digest
        ; test_case "canonical encoding" `Quick test_canonical_object_encoding
        ] )
    ]
