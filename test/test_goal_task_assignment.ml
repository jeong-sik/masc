(** RFC-0267 Phase 2 — [Task.Goal_assignment.set_task_goal].

    Pins the single validated backend shared by the MCP tool
    [masc_task_set_goal] and the dashboard assign-goal HTTP route:
    - an unknown task or unknown goal is a typed error (never a silent no-op),
    - a goalless task links cleanly to an existing goal,
    - a task that already carries a link is rejected (reassignment is a
      deliberate Non-Goal, RFC-0267 §4). *)

open Alcotest
open Masc_domain
open Masc

module Goal_assignment = Masc.Task.Goal_assignment

let with_test_env f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let tmp_dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf
         "masc_set_task_goal_%d_%d"
         (Unix.getpid ())
         (int_of_float (Unix.gettimeofday () *. 1000.)))
  in
  Unix.mkdir tmp_dir 0o755;
  let config = Workspace.default_config tmp_dir in
  let _ = Workspace.init config ~agent_name:(Some "claude") in
  try
    f config;
    let _ = Workspace.reset config in
    Unix.rmdir tmp_dir
  with
  | e ->
    let _ = Workspace.reset config in
    Unix.rmdir tmp_dir;
    raise e
;;

let make_goal config ~id =
  match Goal_store.upsert_goal config ~id ~title:("Goal " ^ id) () with
  | Ok _ -> ()
  | Error msg -> failf "upsert_goal %s failed: %s" id msg
;;

(* Create a single goalless task and return its minted id. A fresh workspace
   mints sequential ids, so the just-added task is the only backlog entry. *)
let make_unassigned_task config ~title =
  let _ = Workspace.add_task config ~title ~priority:3 ~description:"" in
  match Workspace.get_tasks_safe config with
  | (t : task) :: _ -> t.id
  | [] -> fail "task was not created"
;;

let err_to_string = Goal_assignment.set_task_goal_error_to_string

let read_file path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> In_channel.input_all ic)
;;

let write_file path content =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)
;;

let rec source_root_from dir hops =
  let anchor = Filename.concat dir "lib/task/task_goal_assignment.ml" in
  if Sys.file_exists anchor
  then dir
  else if hops >= 8
  then fail "could not locate repository source root"
  else (
    let parent = Filename.dirname dir in
    if String.equal parent dir
    then fail "could not locate repository source root"
    else source_root_from parent (hops + 1))
;;

let source_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root -> root
  | None -> source_root_from (Sys.getcwd ()) 0
;;

let read_source_file rel = read_file (Filename.concat (source_root ()) rel)

let contains_substring s needle =
  let s_len = String.length s in
  let n_len = String.length needle in
  let rec loop i =
    if n_len = 0
    then true
    else if i + n_len > s_len
    then false
    else if String.sub s i n_len = needle
    then true
    else loop (i + 1)
  in
  loop 0
;;

let find_substring_from source needle start =
  let source_len = String.length source in
  let needle_len = String.length needle in
  let rec loop i =
    if needle_len = 0
    then Some i
    else if i + needle_len > source_len
    then None
    else if String.sub source i needle_len = needle
    then Some i
    else loop (i + 1)
  in
  loop start
;;

let find_substring source needle = find_substring_from source needle 0

let slice_between source ~start_marker ~end_marker =
  match find_substring source start_marker with
  | None -> fail ("missing start marker: " ^ start_marker)
  | Some start ->
    (match find_substring_from source end_marker start with
     | None -> fail ("missing end marker: " ^ end_marker)
     | Some finish -> String.sub source start (finish - start))
;;

let test_assignment_validation_runs_under_link_lock_source () =
  let assignment_source = read_source_file "lib/task/task_goal_assignment.ml" in
  check
    bool
    "assignment delegates checked registry transaction"
    true
    (contains_substring
       assignment_source
       "link_goalless_task_to_goal_checked");
  check
    bool
    "assignment no longer calls raw goalless linker"
    false
    (contains_substring assignment_source "link_goalless_task_to_goal config");
  let index_source = read_source_file "lib/workspace/workspace_goal_index.ml" in
  let mutation_helpers_source =
    slice_between
      index_source
      ~start_marker:"let prune_links_for_goal"
      ~end_marker:"let link_tasks_to_goals"
  in
  check
    bool
    "registry mutations use fail-closed reader"
    true
    (contains_substring
       mutation_helpers_source
       "read_goal_task_links_for_mutation");
  check
    bool
    "registry mutations do not use fail-soft reader directly"
    false
    (contains_substring mutation_helpers_source "read_goal_task_links config");
  let checked_helper_source =
    slice_between
      index_source
      ~start_marker:"let link_goalless_task_to_goal_checked"
      ~end_marker:"let link_tasks_to_goals"
  in
  let lock_idx =
    match
      find_substring
        checked_helper_source
        "with_file_lock config (goal_task_links_lock_path config)"
    with
    | Some idx -> idx
    | None -> fail "checked helper missing goal-task-links file lock"
  in
  let task_check_idx =
    match find_substring checked_helper_source "task_exists ~task_id" with
    | Some idx -> idx
    | None -> fail "checked helper missing task_exists callback"
  in
  let goal_check_idx =
    match find_substring checked_helper_source "goal_exists ~goal_id" with
    | Some idx -> idx
    | None -> fail "checked helper missing goal_exists callback"
  in
  let write_idx =
    match find_substring checked_helper_source "write_goal_task_links_result" with
    | Some idx -> idx
    | None -> fail "checked helper missing result-aware registry write"
  in
  let fail_closed_reader_idx =
    match
      find_substring
        checked_helper_source
        "read_goal_task_links_for_mutation"
    with
    | Some idx -> idx
    | None -> fail "checked helper missing fail-closed registry reader"
  in
  check bool "task check happens after link lock" true (lock_idx < task_check_idx);
  check bool "goal check happens after link lock" true (lock_idx < goal_check_idx);
  check bool "fail-closed reader runs after link lock" true
    (lock_idx < fail_closed_reader_idx);
  check bool "checks happen before registry write" true
    (task_check_idx < write_idx && goal_check_idx < write_idx)
;;

let test_unknown_task () =
  with_test_env (fun config ->
    make_goal config ~id:"goal-a";
    match
      Goal_assignment.set_task_goal config ~task_id:"task-nope" ~goal_id:"goal-a"
    with
    | Error (Goal_assignment.Unknown_task t) ->
      check string "names the missing task" "task-nope" t
    | Ok () -> fail "expected Unknown_task, got Ok"
    | Error other -> failf "expected Unknown_task, got %s" (err_to_string other))
;;

let test_unknown_goal () =
  with_test_env (fun config ->
    let task_id = make_unassigned_task config ~title:"t" in
    match
      Goal_assignment.set_task_goal config ~task_id ~goal_id:"goal-nope"
    with
    | Error (Goal_assignment.Unknown_goal g) ->
      check string "names the missing goal" "goal-nope" g
    | Ok () -> fail "expected Unknown_goal, got Ok"
    | Error other -> failf "expected Unknown_goal, got %s" (err_to_string other))
;;

let test_links_goalless_task () =
  with_test_env (fun config ->
    make_goal config ~id:"goal-a";
    let task_id = make_unassigned_task config ~title:"t" in
    (match Goal_assignment.set_task_goal config ~task_id ~goal_id:"goal-a" with
     | Ok () -> ()
     | Error e -> failf "expected Ok, got %s" (err_to_string e));
    let links = Workspace_goal_index.read_goal_task_links config in
    check
      bool
      "registry records goal-a -> task link"
      true
      (List.exists
         (fun (gid, task_ids) ->
            String.equal gid "goal-a" && List.mem task_id task_ids)
         links))
;;

let test_rejects_reassignment () =
  with_test_env (fun config ->
    make_goal config ~id:"goal-a";
    make_goal config ~id:"goal-b";
    let task_id = make_unassigned_task config ~title:"t" in
    (match Goal_assignment.set_task_goal config ~task_id ~goal_id:"goal-a" with
     | Ok () -> ()
     | Error e -> failf "first assign should succeed: %s" (err_to_string e));
    match Goal_assignment.set_task_goal config ~task_id ~goal_id:"goal-b" with
    | Error (Goal_assignment.Already_assigned { task_id = t; existing_goal_ids }) ->
      check string "error names the task" task_id t;
      check (list string) "reports the existing link" [ "goal-a" ] existing_goal_ids
    | Ok () -> fail "expected Already_assigned, got Ok (reassignment must be rejected)"
    | Error other -> failf "expected Already_assigned, got %s" (err_to_string other))
;;

let test_corrupt_registry_fails_closed_without_overwrite () =
  with_test_env (fun config ->
    make_goal config ~id:"goal-a";
    let task_id = make_unassigned_task config ~title:"t" in
    let path = Workspace_goal_index.goal_task_links_path config in
    let recovery = path ^ ".last-good" in
    let corrupt_primary = "{primary-corrupt" in
    let corrupt_recovery = "{recovery-corrupt" in
    write_file path corrupt_primary;
    write_file recovery corrupt_recovery;
    match Goal_assignment.set_task_goal config ~task_id ~goal_id:"goal-a" with
    | Error (Goal_assignment.Registry_unreadable msg) ->
      check
        bool
        "registry error names fail-closed read"
        true
        (contains_substring msg "refusing to overwrite registry");
      check string "primary corrupt file preserved" corrupt_primary (read_file path);
      check
        string
        "recovery corrupt file preserved"
        corrupt_recovery
        (read_file recovery)
    | Ok () -> fail "corrupt registry must not be overwritten"
    | Error other ->
      failf "expected Registry_unreadable, got %s" (err_to_string other))
;;

let test_missing_primary_corrupt_recovery_fails_closed () =
  with_test_env (fun config ->
    make_goal config ~id:"goal-a";
    let task_id = make_unassigned_task config ~title:"t" in
    let path = Workspace_goal_index.goal_task_links_path config in
    let recovery = path ^ ".last-good" in
    let corrupt_recovery = "{recovery-corrupt" in
    if Sys.file_exists path then Sys.remove path;
    write_file recovery corrupt_recovery;
    match Goal_assignment.set_task_goal config ~task_id ~goal_id:"goal-a" with
    | Error (Goal_assignment.Registry_unreadable msg) ->
      check
        bool
        "registry error names recovery read failure"
        true
        (contains_substring msg "recovery read failed");
      check bool "primary remains missing" false (Sys.file_exists path);
      check
        string
        "recovery corrupt file preserved"
        corrupt_recovery
        (read_file recovery)
    | Ok () -> fail "missing primary with corrupt recovery must not be overwritten"
    | Error other ->
      failf "expected Registry_unreadable, got %s" (err_to_string other))
;;

let () =
  run
    "goal_task_assignment"
    [ ( "RFC-0267 Phase 2 — set_task_goal"
      , [ test_case "unknown task is rejected" `Quick test_unknown_task
        ; test_case "unknown goal is rejected" `Quick test_unknown_goal
        ; test_case "goalless task links to goal" `Quick test_links_goalless_task
        ; test_case "reassignment is rejected" `Quick test_rejects_reassignment
        ; test_case
            "corrupt registry fails closed"
            `Quick
            test_corrupt_registry_fails_closed_without_overwrite
        ; test_case
            "missing primary corrupt recovery fails closed"
            `Quick
            test_missing_primary_corrupt_recovery_fails_closed
        ; test_case
            "validation runs under link lock"
            `Quick
            test_assignment_validation_runs_under_link_lock_source
        ] )
    ]
;;
