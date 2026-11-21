open Alcotest
open Masc

module Pass = Keeper_working_context_pass

let with_workspace f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = Filename.temp_dir "librarian-goal-context" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree dir) (fun () ->
    let config = Workspace.default_config dir in
    ignore (Workspace.init config ~agent_name:(Some "test"));
    f config)

let goal id title : Goal_store.goal =
  let now = Masc_domain.now_iso () in
  { id; title; criterion_revision = "revision-" ^ id
  ; measure = Goal_measure_fixture.done_when "2"; procedure = "accepted artifacts"
  ; due_date = None; priority = 3; phase = Goal_phase.Executing
  ; last_review_note = None; last_review_at = None
  ; created_at = now; updated_at = now }

let write_goals config goals =
  Goal_store.write_state config
    { pending_events = []; pending_notifications = []; version = 1; updated_at = Masc_domain.now_iso (); goals }

let meta ?current_task_id () =
  let fields = [ "name", `String "keeper-goal"; "trace_id", `String "trace-goal" ] in
  let fields = match current_task_id with
    | None -> fields
    | Some task_id -> ("current_task_id", `String task_id) :: fields in
  match Masc_test_deps.meta_of_json_fixture (`Assoc fields) with
  | Ok meta -> meta
  | Error detail -> failf "fixture metadata: %s" detail

let queue_goal_context config meta =
  (Pass.input ~config ~keeper_id:(Masc_test_deps.keeper_id_fixture "keeper-goal") ~meta
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
    [ "queue pass Goal context",
      [ test_case "current task goals reach the queue input" `Quick
          test_queue_pass_reads_current_task_goals ] ]
