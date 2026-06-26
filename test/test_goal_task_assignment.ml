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

let make_primary_goal_task_links_path_unwritable config =
  let path = Workspace_goal_index.goal_task_links_path config in
  if Sys.file_exists path && not (Sys.is_directory path) then Sys.remove path;
  if not (Sys.file_exists path) then Unix.mkdir path 0o755
;;

let err_to_string = Goal_assignment.set_task_goal_error_to_string

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

let test_assignment_reports_goal_link_write_failure () =
  with_test_env (fun config ->
    make_goal config ~id:"goal-a";
    let task_id = make_unassigned_task config ~title:"t" in
    make_primary_goal_task_links_path_unwritable config;
    match Goal_assignment.set_task_goal config ~task_id ~goal_id:"goal-a" with
    | Error (Goal_assignment.Link_write_failed msg) ->
      check bool "failure message is populated" true (String.length msg > 0)
    | Ok () -> fail "expected Link_write_failed, got Ok"
    | Error other -> failf "expected Link_write_failed, got %s" (err_to_string other))
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
            "link write failure is reported"
            `Quick
            test_assignment_reports_goal_link_write_failure
        ] )
    ]
;;
