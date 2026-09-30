open Alcotest
open Masc

module Sources = Keeper_librarian_input_sources
module Queue = Keeper_librarian_queue_refresh.For_testing

let with_workspace f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = Filename.temp_dir "librarian-goal-context" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree dir) (fun () ->
    let config = Workspace.default_config dir in
    ignore (Workspace.init config ~agent_name:(Some "test"));
    f config)

let task id = Some (Keeper_id.Task_id.of_string id |> Result.get_ok)

let goal id title : Goal_store.goal =
  let now = Masc_domain.now_iso () in
  { id; title; criterion_revision = "revision-" ^ id
  ; metric = Some "accepted artifacts"; target_value = Some "2"
  ; due_date = None; priority = 3; phase = Goal_phase.Executing
  ; last_review_note = None; last_review_at = None
  ; created_at = now; updated_at = now }

let write_goals config goals =
  Goal_store.write_state config
    { version = 1; updated_at = Masc_domain.now_iso (); goals }

let expect_goal config task_id expected =
  match Sources.goal_context_for_task ~config (task task_id) with
  | Keeper_librarian.Task_goals { task_id = actual; criteria = Ok [id, phase, criterion] } ->
    check string "current task" task_id actual;
    check string "linked goal" expected.Goal_store.id id;
    check bool "goal phase retained" true (phase = expected.phase);
    check bool "authoritative criterion retained" true
      (Goal_store.criterion_equal (Goal_store.criterion_of_goal expected) criterion)
  | _ -> fail "expected exactly one authoritative linked Goal"

let test_task_switch_and_goal_revision () =
  with_workspace @@ fun config ->
  let first = goal "goal-first" "Write a report" in
  let second = { (goal "goal-second" "Render a film") with phase = Goal_phase.Completed } in
  write_goals config [first; second];
  Workspace_goal_index.write_goal_task_links config
    [first.id, ["task-first"]; second.id, ["task-second"]];
  (match Sources.goal_context_for_task ~config None with
   | Keeper_librarian.No_task -> ()
   | _ -> fail "unclaimed turn must remain taskless");
  expect_goal config "task-first" first;
  expect_goal config "task-second" second;
  let revised = { second with criterion_revision = "revised-film"; target_value = Some "3" } in
  write_goals config [first; revised];
  expect_goal config "task-second" revised

let expect_unavailable config =
  match Sources.goal_context_for_task ~config (task "task-first") with
  | Keeper_librarian.Task_goals { task_id; criteria = Error detail } ->
    check string "task survives context read failure" "task-first" task_id;
    check bool "failure reason preserved" true (String.length detail > 0)
  | _ -> fail "context read failure must not become a goalless task"

let test_missing_linked_goal () =
  with_workspace @@ fun config ->
  write_goals config [];
  Workspace_goal_index.write_goal_task_links config ["goal-missing", ["task-first"]];
  expect_unavailable config

let test_recovery_links_not_authoritative () =
  with_workspace @@ fun config ->
  let first = goal "goal-first" "Write a report" in
  write_goals config [first];
  Workspace_goal_index.write_goal_task_links config [first.id, ["task-first"]];
  let primary = Workspace_goal_index.goal_task_links_path config in
  check bool "recovery exists" true (Sys.file_exists (primary ^ ".last-good"));
  Sys.remove primary;
  expect_unavailable config

let test_goalless_task () =
  with_workspace @@ fun config ->
  match Sources.goal_context_for_task ~config (task "task-free") with
  | Keeper_librarian.Task_goals { task_id; criteria = Ok [] } ->
    check string "standalone task retained" "task-free" task_id
  | _ -> fail "a task without Goal links is a valid context"

let meta ?current_task_id () =
  let fields = [ "name", `String "keeper-goal"; "trace_id", `String "trace-goal" ] in
  let fields = match current_task_id with
    | None -> fields
    | Some task_id -> ("current_task_id", `String task_id) :: fields in
  match Masc_test_deps.meta_of_json_fixture (`Assoc fields) with
  | Ok meta -> meta
  | Error detail -> failf "fixture metadata: %s" detail

let queue_goal_context config meta =
  (Queue.queue_input ~config ~keeper_id:(Masc_test_deps.keeper_id_fixture "keeper-goal") ~meta ~current:None
     ~working_context:Keeper_librarian_context.empty).Keeper_librarian.goal_context

(* The queue pass is a production path: a Keeper holding a task hands the
   Librarian that task's linked Goals, and a Keeper without one hands none. *)
let test_queue_pass_reads_current_task_goals () =
  with_workspace @@ fun config ->
  let first = goal "goal-first" "Write a report" in
  write_goals config [first];
  Workspace_goal_index.write_goal_task_links config [first.id, ["task-first"]];
  (match queue_goal_context config (meta ~current_task_id:"task-first" ()) with
   | Keeper_librarian.Task_goals { task_id; criteria = Ok [id, _, criterion] } ->
     check string "queue pass names the current task" "task-first" task_id;
     check string "queue pass names the linked goal" first.id id;
     check bool "queue pass carries the authoritative criterion" true
       (Goal_store.criterion_equal (Goal_store.criterion_of_goal first) criterion)
   | _ -> fail "queue pass must carry the current task's linked Goal");
  match queue_goal_context config (meta ()) with
  | Keeper_librarian.No_task -> ()
  | Keeper_librarian.Task_goals { task_id; _ } ->
    failf "taskless Keeper's queue pass named task %s" task_id

let () =
  run "librarian authoritative task context"
    [ "task Goal context",
      [ test_case "task switch and revised criterion" `Quick test_task_switch_and_goal_revision
      ; test_case "missing linked Goal stays unavailable" `Quick test_missing_linked_goal
      ; test_case "recovery links cannot authorize context" `Quick test_recovery_links_not_authoritative
      ; test_case "goalless task stays valid" `Quick test_goalless_task ]
    ; "queue pass Goal context",
      [ test_case "current task goals reach the queue input" `Quick
          test_queue_pass_reads_current_task_goals ] ]
