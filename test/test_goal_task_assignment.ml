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
  Masc_test_deps.init_eio_clock env;
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
  match Goal_store.upsert_goal config ~id ~title:("Goal " ^ id)
          ~metric:"m" ~target_value:"1" () with
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

(* The writer always emits {"links": [...]}, so a file that is valid JSON but
   not that shape is damaged. Folding it to [] made a corrupt registry read as
   "this goal has no linked tasks", which is the same answer a healthy empty
   registry gives (#29355). *)
let test_corrupt_links_file_is_not_read_as_empty () =
  with_test_env (fun config ->
    let path = Workspace_goal_index.goal_task_links_path config in
    let oc = open_out path in
    Fun.protect
      ~finally:(fun () -> close_out_noerr oc)
      (fun () -> output_string oc {|{"links":{"goal-a":[]}}|});
    match Workspace_goal_index.read_goal_task_links_r config with
    | Ok links ->
      failf "a corrupt links file read as %d link(s)" (List.length links)
    | Error msg ->
      check bool
        ("the error names the field: " ^ msg)
        true
        (let needle = "links" in
         let n = String.length needle and h = String.length msg in
         let rec scan i = i + n <= h && (String.sub msg i n = needle || scan (i + 1)) in
         scan 0))
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

let test_assignment_rejects_recovered_task_snapshot () =
  with_test_env (fun config ->
    make_goal config ~id:"goal-a";
    let task_id = make_unassigned_task config ~title:"t" in
    Out_channel.with_open_text (Workspace.backlog_path config) (fun oc ->
      output_string oc "{\"tasks\":[],\"last_updated\":\"now\",\"version\":0}");
    match Goal_assignment.set_task_goal config ~task_id ~goal_id:"goal-a" with
    | Error (Goal_assignment.Backlog_read_failed _) -> ()
    | Ok () -> fail "recovered task snapshot authorized a goal-link mutation"
    | Error other -> failf "expected Backlog_read_failed, got %s" (err_to_string other))
;;

let file_bytes path =
  if Sys.file_exists path then Some (In_channel.with_open_bin path In_channel.input_all)
  else None
;;

let corrupt path = Out_channel.with_open_text path (fun oc -> output_string oc "{broken")

let test_goal_source_failure_blocks_all_bindings () =
  List.iter (fun corrupt_mirror ->
    with_test_env (fun config ->
      make_goal config ~id:"goal-a";
      let task_id = make_unassigned_task config ~title:"existing" in
      let primary = Goal_store.goals_path config in
      let recovery = primary ^ ".last-good" in
      let links_path = Workspace_goal_index.goal_task_links_path config in
      let backlog_path = Workspace.backlog_path config in
      let before_links = file_bytes links_path in
      let before_backlog = file_bytes backlog_path in
      check bool "valid recovery exists before corruption" true (Sys.file_exists recovery);
      corrupt primary;
      if corrupt_mirror then corrupt recovery
      else check bool "recovery read still finds the Goal" true
        (Option.is_some (Goal_store.get_goal config ~goal_id:"goal-a"));
      (match Goal_assignment.set_task_goal config ~task_id ~goal_id:"goal-a" with
       | Error (Goal_assignment.Goal_source_unavailable _) -> ()
       | Error e -> fail (err_to_string e)
       | Ok () -> fail "damaged primary authorized assignment");
      (match Goal_assignment.add_task_with_result ~goal_id:"goal-a" config
         ~title:"new" ~priority:3 ~description:"bound" with
       | Error (Workspace_task.Goal_source_unavailable _) -> ()
       | Error e -> fail (Workspace_task.add_task_error_to_string e)
       | Ok _ -> fail "damaged primary authorized task creation");
      (match Goal_assignment.batch_add_tasks_with_contracts_result config
         ["goalless",3,"",None,None; "bound",3,"",None,Some "goal-a"] with
       | Error (Workspace_task.Batch_goal_source_unavailable _) -> ()
       | Error e -> fail (Workspace_task.batch_add_tasks_error_to_string e)
       | Ok _ -> fail "damaged primary authorized partial batch");
      check (option string) "backlog bytes unchanged" before_backlog (file_bytes backlog_path);
      check (option string) "link bytes unchanged" before_links (file_bytes links_path);
      (match Goal_assignment.add_task_with_result config
         ~title:"independent" ~priority:3 ~description:"goalless" with
       | Ok _ -> ()
       | Error e -> fail (Workspace_task.add_task_error_to_string e));
      (match Goal_assignment.batch_add_tasks_with_contracts_result config
         ["independent batch",3,"",None,None] with
       | Ok _ -> ()
       | Error e -> fail (Workspace_task.batch_add_tasks_error_to_string e))))
    [false; true]
;;

let test_unknown_goal_batch_has_no_partial_write () =
  with_test_env (fun config ->
    make_goal config ~id:"goal-a";
    let before = file_bytes (Workspace.backlog_path config) in
    let links = file_bytes (Workspace_goal_index.goal_task_links_path config) in
    (match Goal_assignment.batch_add_tasks_with_contracts_result config
      ["valid",3,"",None,Some "goal-a"; "missing",3,"",None,Some "missing"] with
     | Error (Workspace_task.Batch_unknown_goal "missing") -> ()
     | Error e -> fail (Workspace_task.batch_add_tasks_error_to_string e)
     | Ok _ -> fail "batch linked a missing Goal");
    check (option string) "no partial backlog" before (file_bytes (Workspace.backlog_path config));
    check (option string) "no partial links" links (file_bytes (Workspace_goal_index.goal_task_links_path config)))
;;

(* Exercise the authority primitive with a real dependent backlog/link write.
   The delete is submitted while membership is held; its completion must follow
   the dependent commit. Promises determine order without sleep-based races. *)
let test_delete_and_binding_share_membership_lock () =
  with_test_env (fun config ->
    make_goal config ~id:"goal-a";
    let events = ref [] in
    let submitted, submit = Eio.Promise.create () in
    let deletion, deleted = Eio.Promise.create () in
    Eio.Switch.run (fun sw ->
      let result = Goal_store.with_existing_goals config ~goal_ids:["goal-a"] (fun () ->
        Eio.Fiber.fork ~sw (fun () ->
          Eio.Promise.resolve submit ();
          let result = Goal_store.delete_goal config ~goal_id:"goal-a" in
          events := !events @ ["deleted"];
          Eio.Promise.resolve deleted result);
        Eio.Promise.await submitted;
        Eio.Fiber.yield ();
        let created = Workspace_task.add_task_with_result ~goal_id:"goal-a" config
          ~title:"bound before deletion" ~priority:3 ~description:"" in
        events := !events @ ["bound"];
        created) in
      (match result with
       | Ok (Ok _) -> ()
       | _ -> fail "binding failed while holding Goal membership");
      (match Eio.Promise.await deletion with
       | Ok Goal_store.Deleted -> ()
       | _ -> fail "Goal deletion did not complete cleanly"));
    check (list string) "commit precedes deletion" ["bound";"deleted"] !events;
    check (list (pair string (list string))) "deleted Goal has no links" []
      (Workspace_goal_index.read_goal_task_links config);
    (match Goal_assignment.add_task_with_result ~goal_id:"goal-a" config
      ~title:"after deletion" ~priority:3 ~description:"" with
     | Error (Workspace_task.Unknown_goal "goal-a") -> ()
     | _ -> fail "binding after deletion must reject the missing Goal"))
;;

let () =
  run
    "goal_task_assignment"
    [ ( "RFC-0267 Phase 2 — set_task_goal"
      , [ test_case "Goal source failure prevents every binding" `Quick test_goal_source_failure_blocks_all_bindings
        ; test_case "batch unknown Goal has no partial write" `Quick test_unknown_goal_batch_has_no_partial_write
        ; test_case "delete and binding share membership lock" `Quick test_delete_and_binding_share_membership_lock
        ; test_case "unknown task is rejected" `Quick test_unknown_task
        ; test_case "unknown goal is rejected" `Quick test_unknown_goal
        ; test_case "goalless task links to goal" `Quick test_links_goalless_task
        ; test_case "reassignment is rejected" `Quick test_rejects_reassignment
        ; test_case
            "link write failure is reported"
            `Quick
            test_assignment_reports_goal_link_write_failure
        ; test_case
            "recovered task snapshot cannot authorize a link"
            `Quick
            test_assignment_rejects_recovered_task_snapshot
        ; test_case
            "a corrupt links file is not read as empty"
            `Quick
            test_corrupt_links_file_is_not_read_as_empty
        ] )
    ]
;;
