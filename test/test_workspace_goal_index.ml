(** Unit tests for [Workspace_goal_index].

    Covers: empty task list, tasks with no goal_id, multiple tasks per goal,
    different goals correctly separated, open-task counting.

    After the task↔goal boundary refactor, goal-task links are no longer
    stored on task records. The index is built from explicit
    [goal_task_links] mappings. *)

open Masc_domain

let make_task ~id ~status =
  { id
  ; title = "Task " ^ id
  ; description = ""
  ; task_status = status
  ; priority = 3
  ; files = []
  ; created_at = "2026-06-03T00:00:00Z"
  ; created_by = None
  ; contract = None
  ; handoff_context = None
  ; cycle_count = 0
  ; reclaim_policy = None
  ; do_not_reclaim_reason = None
  }
;;

let done_status =
  Done { assignee = "bot"; completed_at = "2026-06-03T01:00:00Z"; notes = None }
;;

let cancelled_status =
  Cancelled { cancelled_by = "bot"; cancelled_at = "2026-06-03T01:00:00Z"; reason = None }
;;

let check_int label expected actual =
  Alcotest.(check int) label expected actual
;;

let check_bool label expected actual =
  Alcotest.(check bool) label expected actual
;;

let check_list_len label expected tasks =
  check_int label expected (List.length tasks)
;;

(* ── build_goal_task_index ──────────────────────────────────────────── *)

let test_empty_task_list () =
  let index = Workspace_goal_index.build_goal_task_index [] in
  check_bool "empty index has no bindings" true (Hashtbl.length index = 0)
;;

let test_tasks_with_no_goal_id () =
  let tasks =
    [ make_task ~id:"t1" ~status:Todo
    ; make_task ~id:"t2" ~status:(Claimed { assignee = "a"; claimed_at = "" })
    ]
  in
  let index = Workspace_goal_index.build_goal_task_index tasks in
  check_bool "no-goal tasks produce empty index" true (Hashtbl.length index = 0)
;;

let test_multiple_tasks_same_goal () =
  let tasks =
    [ make_task ~id:"t1" ~status:Todo
    ; make_task ~id:"t2" ~status:done_status
    ; make_task ~id:"t3" ~status:Todo
    ]
  in
  let index = Workspace_goal_index.build_goal_task_index tasks ~goal_task_links:[("g1", ["t1"; "t2"; "t3"])] in
  let found = Workspace_goal_index.tasks_for_goal index ~goal_id:"g1" in
  check_list_len "all 3 tasks found for g1" 3 found
;;

let test_different_goals_separated () =
  let tasks =
    [ make_task ~id:"t1" ~status:Todo
    ; make_task ~id:"t2" ~status:Todo
    ; make_task ~id:"t3" ~status:Todo
    ; make_task ~id:"t4" ~status:Todo
    ; make_task ~id:"t5" ~status:Todo
    ]
  in
  let index = Workspace_goal_index.build_goal_task_index tasks
    ~goal_task_links:[("g1", ["t1"; "t3"]); ("g2", ["t2"; "t4"])]
  in
  let g1_tasks = Workspace_goal_index.tasks_for_goal index ~goal_id:"g1" in
  let g2_tasks = Workspace_goal_index.tasks_for_goal index ~goal_id:"g2" in
  let g3_tasks = Workspace_goal_index.tasks_for_goal index ~goal_id:"g3" in
  check_list_len "g1 has 2 tasks" 2 g1_tasks;
  check_list_len "g2 has 2 tasks" 2 g2_tasks;
  check_list_len "g3 has 0 tasks (not found)" 0 g3_tasks;
  check_int "index has 2 goals" 2 (Hashtbl.length index)
;;

let test_tasks_for_goal_missing_key () =
  let index = Workspace_goal_index.build_goal_task_index [] in
  let found = Workspace_goal_index.tasks_for_goal index ~goal_id:"nonexistent" in
  check_list_len "missing key returns []" 0 found
;;

(* ── open_task_count_for_goal_indexed ───────────────────────────────── *)

let test_open_count_only_non_terminal () =
  let tasks =
    [ make_task ~id:"t1" ~status:Todo
    ; make_task ~id:"t2" ~status:done_status
    ; make_task ~id:"t3" ~status:cancelled_status
    ; make_task ~id:"t4" ~status:(Claimed { assignee = "a"; claimed_at = "" })
    ; make_task ~id:"t5" ~status:(InProgress { assignee = "a"; started_at = "" })
    ; make_task ~id:"t6" ~status:(AwaitingVerification { assignee = "a"; submitted_at = ""; verification_id = ""; phase = Awaiting_verifier })
    ]
  in
  let index = Workspace_goal_index.build_goal_task_index tasks
    ~goal_task_links:[("g1", ["t1"; "t2"; "t3"; "t4"; "t5"; "t6"])]
  in
  let count = Workspace_goal_index.open_task_count_for_goal_indexed index ~goal_id:"g1" in
  (* open: Todo, Claimed, InProgress, AwaitingVerification = 4
     terminal: Done, Cancelled = 2 *)
  check_int "open task count excludes Done and Cancelled" 4 count
;;

let test_open_count_empty () =
  let index = Workspace_goal_index.build_goal_task_index [] in
  let count = Workspace_goal_index.open_task_count_for_goal_indexed index ~goal_id:"g1" in
  check_int "empty index has 0 open tasks" 0 count
;;

let test_open_count_all_terminal () =
  let tasks =
    [ make_task ~id:"t1" ~status:done_status
    ; make_task ~id:"t2" ~status:cancelled_status
    ]
  in
  let index = Workspace_goal_index.build_goal_task_index tasks
    ~goal_task_links:[("g1", ["t1"; "t2"])]
  in
  let count = Workspace_goal_index.open_task_count_for_goal_indexed index ~goal_id:"g1" in
  check_int "all terminal -> 0 open tasks" 0 count
;;

(* ── test suite ─────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "workspace_goal_index"
    [ ( "build_goal_task_index"
      , Alcotest.[ test_case "empty task list" `Quick test_empty_task_list
                 ; test_case "tasks with no goal_id" `Quick test_tasks_with_no_goal_id
                 ; test_case "multiple tasks same goal" `Quick test_multiple_tasks_same_goal
                 ; test_case "different goals separated" `Quick test_different_goals_separated
                 ; test_case "missing key returns []" `Quick test_tasks_for_goal_missing_key
                 ] )
    ; ( "open_task_count_for_goal_indexed"
      , Alcotest.[ test_case "counts only non-terminal" `Quick test_open_count_only_non_terminal
                 ; test_case "empty index has 0" `Quick test_open_count_empty
                 ; test_case "all terminal has 0" `Quick test_open_count_all_terminal
                 ] )
    ]
;;
