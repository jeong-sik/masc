(** Unit tests for [Workspace_goal_index].

    Covers: empty task list, tasks with no goal_id, multiple tasks per goal,
    different goals correctly separated, open-task counting.

    After the task↔goal boundary refactor, goal-task links are no longer
    stored on task records. The index is built from explicit
    [goal_task_links] mappings. *)

open Masc_domain
open Masc

let with_test_env f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let tmp_dir = Filename.temp_dir "masc_goal_index_" "" in
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

let string_contains ~needle haystack =
  let needle_len = String.length needle in
  let haystack_len = String.length haystack in
  if needle_len = 0 then true
  else
    let rec loop idx =
      idx + needle_len <= haystack_len
      && (String.equal (String.sub haystack idx needle_len) needle || loop (idx + 1))
    in
    loop 0
;;

let with_activity_counter f =
  let previous = Atomic.get Workspace_hooks.activity_emit_fn in
  let count = ref 0 in
  Fun.protect
    ~finally:(fun () -> Atomic.set Workspace_hooks.activity_emit_fn previous)
    (fun () ->
       Atomic.set
         Workspace_hooks.activity_emit_fn
         (fun _config ~actor:_ ?subject:_ ~kind:_ ~payload:_ ~tags:_ () ->
            incr count);
       f (fun () -> !count))
;;

let with_mutation_counter f =
  let previous = Atomic.get Workspace_hooks.on_task_mutation_fn in
  let count = ref 0 in
  Fun.protect
    ~finally:(fun () -> Atomic.set Workspace_hooks.on_task_mutation_fn previous)
    (fun () ->
       Atomic.set Workspace_hooks.on_task_mutation_fn (fun () -> incr count);
       f (fun () -> !count))
;;

let message_count config =
  List.length (Workspace.get_messages_raw config ~since_seq:0 ~limit:10)
;;

let check_no_create_side_effects config ~message_count_before activity_count mutation_count =
  check_int "no task activity emitted" 0 (activity_count ());
  check_int "no task mutation hook fired" 0 (mutation_count ());
  check_int
    "no broadcast messages emitted"
    message_count_before
    (message_count config)
;;

let make_path_unwritable path =
  if Sys.file_exists path && not (Sys.is_directory path) then Sys.remove path;
  if not (Sys.file_exists path) then Unix.mkdir path 0o755
;;

let make_primary_goal_task_links_path_unwritable config =
  make_path_unwritable (Workspace_goal_index.goal_task_links_path config)
;;

let make_goal_task_links_recovery_path_unwritable config =
  make_path_unwritable (Workspace_goal_index.goal_task_links_recovery_path config)
;;

let make_backlog_path_unwritable config =
  make_path_unwritable (Workspace_backlog.backlog_path config)
;;

let goal_link_exists_in_file path ~goal_id ~task_id =
  if (not (Sys.file_exists path)) || Sys.is_directory path then false
  else
    match Yojson.Safe.from_file path with
    | `Assoc fields ->
      (match List.assoc_opt "links" fields with
       | Some (`List links) ->
         List.exists
           (function
             | `Assoc link_fields ->
               (match List.assoc_opt "goal_id" link_fields with
                | Some (`String candidate_goal_id) ->
                  String.equal candidate_goal_id goal_id
                  &&
                  (match List.assoc_opt "task_ids" link_fields with
                   | Some (`List task_ids) ->
                     List.exists
                       (function
                         | `String candidate_task_id ->
                           String.equal candidate_task_id task_id
                         | _ -> false)
                       task_ids
                   | _ -> false)
                | _ -> false)
             | _ -> false)
           links
       | _ -> false)
    | _ -> false
;;

let goal_link_exists_in_primary_or_recovery config ~goal_id ~task_id =
  let primary_path = Workspace_goal_index.goal_task_links_path config in
  let recovery_path = primary_path ^ ".last-good" in
  goal_link_exists_in_file primary_path ~goal_id ~task_id
  || goal_link_exists_in_file recovery_path ~goal_id ~task_id
;;

let check_no_goal_link_files config ~goal_id ~task_id =
  check_bool
    (Printf.sprintf "no primary/recovery link for %s/%s" goal_id task_id)
    false
    (goal_link_exists_in_primary_or_recovery config ~goal_id ~task_id)
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

(* ── persistent goal-task registry ──────────────────────────────────── *)

let test_add_task_persists_goal_link () =
  with_test_env (fun config ->
    let result =
      Workspace.add_task
        ~goal_id:"goal-a"
        config
        ~title:"linked task"
        ~priority:1
        ~description:""
    in
    check_bool "add_task succeeds" true (String.starts_with ~prefix:"Added task-001" result);
    let links = Workspace_goal_index.read_goal_task_links config in
    check_bool
      "registry records goal link"
      true
      (List.exists
         (fun (goal_id, task_ids) ->
            String.equal goal_id "goal-a" && List.mem "task-001" task_ids)
         links);
    let tasks = Workspace.get_tasks_safe config in
    let index = Workspace_goal_index.build_goal_task_index_for_config config tasks in
    check_list_len
      "config-aware index sees linked task"
      1
      (Workspace_goal_index.tasks_for_goal index ~goal_id:"goal-a");
    let task_goal_index =
      Workspace_goal_index.build_task_goal_index_for_config config
    in
    check_bool
      "reverse index sees linked goal"
      true
      (try List.mem "goal-a" (Hashtbl.find task_goal_index "task-001") with
       | Not_found -> false))
;;

let test_prune_goal_links_preserves_other_goals () =
  with_test_env (fun config ->
    Workspace_goal_index.write_goal_task_links
      config
      [ "goal-a", [ "task-001"; "task-002" ]; "goal-b", [ "task-003" ] ];
    (match Workspace_goal_index.prune_links_for_goal_result config ~goal_id:"goal-a" with
     | Ok () -> ()
     | Error msg -> Alcotest.fail msg);
    let links = Workspace_goal_index.read_goal_task_links config in
    check_bool
      "deleted goal links removed"
      false
      (List.exists (fun (goal_id, _) -> String.equal goal_id "goal-a") links);
    check_bool
      "other goal links preserved"
      true
      (List.exists
         (fun (goal_id, task_ids) ->
            String.equal goal_id "goal-b" && List.mem "task-003" task_ids)
         links))
;;

let test_write_failure_does_not_refresh_recovery_before_primary_commit () =
  with_test_env (fun config ->
    make_primary_goal_task_links_path_unwritable config;
    (match
       Workspace_goal_index.write_goal_task_links_result
         config
         [ "goal-a", [ "task-001" ] ]
     with
     | Ok () -> Alcotest.fail "expected primary write failure"
     | Error msg ->
       check_bool "failure message is populated" true (String.length msg > 0));
    check_no_goal_link_files config ~goal_id:"goal-a" ~task_id:"task-001")
;;

let test_add_task_goal_link_write_failure_does_not_publish_task () =
  with_test_env (fun config ->
    with_activity_counter (fun activity_count ->
      with_mutation_counter (fun mutation_count ->
        make_primary_goal_task_links_path_unwritable config;
        let message_count_before = message_count config in
        (match
           Workspace.add_task_with_result
             ~goal_id:"goal-a"
             config
             ~title:"blocked linked task"
             ~priority:1
             ~description:""
         with
         | Error (Workspace.Goal_link_write_failed msg) ->
           check_bool "failure message is populated" true (String.length msg > 0)
         | Error err ->
           Alcotest.failf
             "expected Goal_link_write_failed, got %s"
             (Workspace.add_task_error_to_string err)
        | Ok created -> Alcotest.failf "expected failure, created %s" created.task_id);
        check_int "task was not published" 0 (List.length (Workspace.get_tasks_safe config));
        check_no_goal_link_files config ~goal_id:"goal-a" ~task_id:"task-001";
        check_no_create_side_effects
          config
          ~message_count_before
          activity_count
          mutation_count)))
;;

let test_batch_add_task_goal_link_write_failure_does_not_publish_tasks () =
  with_test_env (fun config ->
    with_activity_counter (fun activity_count ->
      with_mutation_counter (fun mutation_count ->
        make_primary_goal_task_links_path_unwritable config;
        let message_count_before = message_count config in
        (match
           Workspace.batch_add_tasks_with_contracts_result
             config
             [ "blocked batch a", 1, "", None, Some "goal-a"
             ; "blocked batch b", 2, "", None, Some "goal-b"
             ]
         with
         | Error (Workspace.Batch_goal_link_write_failed msg) ->
           check_bool "failure message is populated" true (String.length msg > 0)
         | Error err ->
           Alcotest.failf
             "expected Batch_goal_link_write_failed, got %s"
             (Workspace.batch_add_tasks_error_to_string err)
        | Ok created ->
          Alcotest.failf "expected failure, created %d tasks" created.count);
        check_int "tasks were not published" 0 (List.length (Workspace.get_tasks_safe config));
        check_no_goal_link_files config ~goal_id:"goal-a" ~task_id:"task-001";
        check_no_goal_link_files config ~goal_id:"goal-b" ~task_id:"task-002";
       check_no_create_side_effects
         config
         ~message_count_before
         activity_count
         mutation_count)))
;;

let test_capacity_rejection_fails_closed_on_goal_link_read_failure () =
  with_test_env (fun config ->
    with_activity_counter (fun activity_count ->
      with_mutation_counter (fun mutation_count ->
        make_primary_goal_task_links_path_unwritable config;
        make_goal_task_links_recovery_path_unwritable config;
        let message_count_before = message_count config in
        let backlog = Workspace.read_backlog config in
        (match
           Workspace_task_capacity.check_for_config_result
             config
             ~goal_id:"goal-a"
             backlog
         with
         | Error msg ->
           check_bool
             "capacity read failure is typed"
             true
             (string_contains
                ~needle:Workspace_task_capacity.goal_task_links_read_failed_prefix
                msg)
         | Ok _ -> Alcotest.fail "expected goal-task link read failure");
        (match
           Workspace.add_task_with_result
             ~goal_id:"goal-a"
             ~reject_if:
               (Workspace_task_capacity.rejection_for_add_task_for_config
                  config
                  ~goal_id:"goal-a")
             config
             ~title:"blocked capacity read task"
             ~priority:1
             ~description:""
         with
         | Error (Workspace.Rejected msg) ->
           check_bool
             "task creation rejects goal-task read failure"
             true
             (string_contains
                ~needle:Workspace_task_capacity.goal_task_links_read_failed_prefix
                msg)
         | Error err ->
           Alcotest.failf
             "expected Rejected, got %s"
             (Workspace.add_task_error_to_string err)
         | Ok created -> Alcotest.failf "expected failure, created %s" created.task_id);
        check_int "task was not published" 0 (List.length (Workspace.get_tasks_safe config));
        check_no_create_side_effects
          config
          ~message_count_before
          activity_count
          mutation_count)))
;;

let test_add_task_backlog_write_failure_rolls_back_goal_link () =
  with_test_env (fun config ->
    with_activity_counter (fun activity_count ->
      with_mutation_counter (fun mutation_count ->
        make_backlog_path_unwritable config;
        let message_count_before = message_count config in
        (match
           Workspace.add_task_with_result
             ~goal_id:"goal-a"
             config
             ~title:"blocked backlog task"
             ~priority:1
             ~description:""
         with
         | Error (Workspace.Backlog_write_failed msg) ->
           check_bool "failure message is populated" true (String.length msg > 0)
         | Error err ->
           Alcotest.failf
             "expected Backlog_write_failed, got %s"
             (Workspace.add_task_error_to_string err)
         | Ok created -> Alcotest.failf "expected failure, created %s" created.task_id);
        check_int "task was not published" 0 (List.length (Workspace.get_tasks_safe config));
        check_no_goal_link_files config ~goal_id:"goal-a" ~task_id:"task-001";
        check_no_create_side_effects
          config
          ~message_count_before
          activity_count
          mutation_count)))
;;

let test_batch_add_task_backlog_write_failure_rolls_back_goal_links () =
  with_test_env (fun config ->
    with_activity_counter (fun activity_count ->
      with_mutation_counter (fun mutation_count ->
        make_backlog_path_unwritable config;
        let message_count_before = message_count config in
        (match
           Workspace.batch_add_tasks_with_contracts_result
             config
             [ "blocked batch a", 1, "", None, Some "goal-a"
             ; "blocked batch b", 2, "", None, Some "goal-b"
             ]
         with
         | Error (Workspace.Batch_backlog_write_failed msg) ->
           check_bool "failure message is populated" true (String.length msg > 0)
         | Error err ->
           Alcotest.failf
             "expected Batch_backlog_write_failed, got %s"
             (Workspace.batch_add_tasks_error_to_string err)
         | Ok created ->
           Alcotest.failf "expected failure, created %d tasks" created.count);
        check_int "tasks were not published" 0 (List.length (Workspace.get_tasks_safe config));
        check_no_goal_link_files config ~goal_id:"goal-a" ~task_id:"task-001";
        check_no_goal_link_files config ~goal_id:"goal-b" ~task_id:"task-002";
        check_no_create_side_effects
          config
          ~message_count_before
          activity_count
          mutation_count)))
;;

let test_add_task_backlog_write_failure_surfaces_rollback_failure () =
  with_test_env (fun config ->
    with_activity_counter (fun activity_count ->
      with_mutation_counter (fun mutation_count ->
        make_backlog_path_unwritable config;
        let message_count_before = message_count config in
        Workspace_goal_index.For_testing.with_before_unlink_task_from_goal
          (fun hook_config ~goal_id:_ ~task_id:_ ->
             make_goal_task_links_recovery_path_unwritable hook_config)
          (fun () ->
             match
               Workspace.add_task_with_result
                 ~goal_id:"goal-a"
                 config
                 ~title:"rollback failure task"
                 ~priority:1
                 ~description:""
             with
             | Error (Workspace.Backlog_write_failed msg) ->
               check_bool
                 "rollback failure is surfaced"
                 true
                 (string_contains ~needle:"goal link rollback failed" msg)
             | Error err ->
               Alcotest.failf
                 "expected Backlog_write_failed, got %s"
                 (Workspace.add_task_error_to_string err)
             | Ok created -> Alcotest.failf "expected failure, created %s" created.task_id);
        check_int "task was not published" 0 (List.length (Workspace.get_tasks_safe config));
        (* Rollback failure is surfaced above; unlike the successful rollback
           cases, these paths cannot promise that goal_task_links was cleaned. *)
        check_no_create_side_effects
          config
          ~message_count_before
          activity_count
          mutation_count)))
;;

let test_batch_add_task_backlog_write_failure_surfaces_rollback_failure () =
  with_test_env (fun config ->
    with_activity_counter (fun activity_count ->
      with_mutation_counter (fun mutation_count ->
        make_backlog_path_unwritable config;
        let message_count_before = message_count config in
        Workspace_goal_index.For_testing.with_before_unlink_task_from_goal
          (fun hook_config ~goal_id:_ ~task_id:_ ->
             make_goal_task_links_recovery_path_unwritable hook_config)
          (fun () ->
             match
               Workspace.batch_add_tasks_with_contracts_result
                 config
                 [ "rollback failure batch a", 1, "", None, Some "goal-a"
                 ; "rollback failure batch b", 2, "", None, Some "goal-b"
                 ]
             with
             | Error (Workspace.Batch_backlog_write_failed msg) ->
               check_bool
                 "rollback failure is surfaced"
                 true
                 (string_contains ~needle:"goal link rollback failed" msg)
             | Error err ->
               Alcotest.failf
                 "expected Batch_backlog_write_failed, got %s"
                 (Workspace.batch_add_tasks_error_to_string err)
             | Ok created ->
               Alcotest.failf "expected failure, created %d tasks" created.count);
        check_int "tasks were not published" 0 (List.length (Workspace.get_tasks_safe config));
        (* Rollback failure is surfaced above; unlike the successful rollback
           cases, these paths cannot promise that goal_task_links was cleaned. *)
        check_no_create_side_effects
          config
          ~message_count_before
          activity_count
          mutation_count)))
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
    ; ( "persistent registry"
      , Alcotest.
          [ test_case
              "add_task persists explicit goal link"
              `Quick
              test_add_task_persists_goal_link
          ; test_case
              "prune removes only deleted goal links"
              `Quick
              test_prune_goal_links_preserves_other_goals
          ; test_case
              "write failure does not refresh recovery before primary commit"
              `Quick
              test_write_failure_does_not_refresh_recovery_before_primary_commit
          ; test_case
              "single create does not publish when goal link write fails"
              `Quick
              test_add_task_goal_link_write_failure_does_not_publish_task
          ; test_case
              "capacity rejects goal link read failure before task publish"
              `Quick
              test_capacity_rejection_fails_closed_on_goal_link_read_failure
          ; test_case
              "batch create does not publish when goal link write fails"
              `Quick
              test_batch_add_task_goal_link_write_failure_does_not_publish_tasks
          ; test_case
              "single create rolls back goal link when backlog write fails"
              `Quick
              test_add_task_backlog_write_failure_rolls_back_goal_link
          ; test_case
              "batch create rolls back goal links when backlog write fails"
              `Quick
              test_batch_add_task_backlog_write_failure_rolls_back_goal_links
          ; test_case
              "single create surfaces rollback failure when backlog write fails"
              `Quick
              test_add_task_backlog_write_failure_surfaces_rollback_failure
          ; test_case
              "batch create surfaces rollback failure when backlog write fails"
              `Quick
              test_batch_add_task_backlog_write_failure_surfaces_rollback_failure
          ] )
    ]
;;
