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
  ; predecessor_task_id = None
  ; contract = None
  ; handoff_context = None
  ; cycle_count = 0
  ; reclaim_policy = None
  ; execution_links = Masc_domain.no_execution_links
  ; do_not_reclaim_reason = None
  ; skills = []
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
  (* A failed create can still fence Dashboard readers after a provisional
     goal-link write has been rolled back.  That reconciliation callback is
     not a published task side effect. *)
  ignore (mutation_count ());
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
  make_path_unwritable (Workspace_goal_index.goal_task_links_path config ^ ".last-good")
;;

(* A readable snapshot at the final revision reaches the real backlog
   precommit refusal after the provisional link has been written. *)
let exhaust_backlog_revision config =
  let backlog = match Workspace_backlog.read_backlog_r config with
    | Ok backlog -> backlog
    | Error detail -> Alcotest.fail detail in
  Workspace_utils.write_json config (Workspace_backlog.backlog_path config)
    (backlog_to_yojson { backlog with version = max_int })
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
    ; make_task ~id:"t6"
        ~status:
          (AwaitingVerification
             { assignee = "a"
             ; started_at = "2026-07-13T00:00:00Z"
             ; submitted_at = ""
             ; intent = Complete_task
             ; verification_id = ""
             })
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
    with_mutation_counter (fun mutation_count ->
      let result =
        Workspace.add_task
          ~goal_id:"goal-a"
          config
          ~title:"linked task"
          ~priority:1
          ~description:""
      in
      check_bool "add_task succeeds" true (String.starts_with ~prefix:"Added task-001" result);
      check_int "committed task mutation observed once" 1 (mutation_count ());
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
         | Not_found -> false)))
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
        check_int "source rejection performs no mutation notification" 0 (mutation_count ());
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
        check_int "batch tasks were not published" 0 (List.length (Workspace.get_tasks_safe config));
        check_no_goal_link_files config ~goal_id:"goal-a" ~task_id:"task-001";
        check_no_goal_link_files config ~goal_id:"goal-b" ~task_id:"task-002";
        check_int "batch source rejection performs no mutation notification" 0 (mutation_count ());
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
        exhaust_backlog_revision config;
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
        check_no_goal_link_files config ~goal_id:"goal-a" ~task_id:"task-001";
        check_int "failed backlog commit publishes no tasks" 0 (List.length (Workspace.get_tasks_safe config));
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
        exhaust_backlog_revision config;
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
        check_no_goal_link_files config ~goal_id:"goal-a" ~task_id:"task-001";
        check_no_goal_link_files config ~goal_id:"goal-b" ~task_id:"task-002";
        check_int "failed backlog commit publishes no tasks" 0 (List.length (Workspace.get_tasks_safe config));
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
        let message_count_before = message_count config in
        exhaust_backlog_revision config;
        Workspace_goal_index.For_testing.with_before_unlink_task_from_goal
          (fun hook_config ~goal_id ~task_id ->
             check_bool "provisional link exists before rollback injection" true
               (goal_link_exists_in_file (Workspace_goal_index.goal_task_links_path hook_config)
                  ~goal_id ~task_id);
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
        (* Rollback failure is surfaced above; unlike the successful rollback
           cases, these paths cannot promise that goal_task_links was cleaned. *)
        check_bool
          "failed rollback settlement fenced dashboard readers"
          true
          (mutation_count () > 0);
        check_int "failed backlog commit publishes no tasks" 0 (List.length (Workspace.get_tasks_safe config));
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
        let message_count_before = message_count config in
        exhaust_backlog_revision config;
        Workspace_goal_index.For_testing.with_before_unlink_task_from_goal
          (fun hook_config ~goal_id ~task_id ->
             check_bool "provisional link exists before rollback injection" true
               (goal_link_exists_in_file (Workspace_goal_index.goal_task_links_path hook_config)
                  ~goal_id ~task_id);
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
        (* Rollback failure is surfaced above; unlike the successful rollback
           cases, these paths cannot promise that goal_task_links was cleaned. *)
        check_bool
          "failed batch rollback settlement fenced dashboard readers"
          true
          (mutation_count () > 0);
        check_int "failed backlog commit publishes no tasks" 0 (List.length (Workspace.get_tasks_safe config));
        check_no_create_side_effects
          config
          ~message_count_before
          activity_count
          mutation_count)))
;;

(* ── test suite ─────────────────────────────────────────────────────── *)

(* A link row the writer never produces is damage, not an answer. Folding a
   missing or non-list "task_ids" to [] made a corrupt registry read as "this
   goal has no linked tasks" — the same shape the [links] guard already
   refuses one layer out (#29355). *)
let test_a_link_row_without_task_ids_is_not_an_empty_goal () =
  with_test_env (fun config ->
    let path = Workspace_goal_index.goal_task_links_path config in
    let write contents =
      Out_channel.with_open_text path (fun oc -> Out_channel.output_string oc contents)
    in
    write {|{"links":[{"goal_id":"g-1","task_ids":["t-1"]}]}|};
    (match Workspace_goal_index.read_goal_task_links_r config with
     | Ok [ ("g-1", [ "t-1" ]) ] -> ()
     | Ok other ->
       Alcotest.failf "a well-formed row must read back: %d link(s)" (List.length other)
     | Error detail -> Alcotest.failf "a well-formed row must read back: %s" detail);
    write {|{"links":[{"goal_id":"g-1"}]}|};
    (match Workspace_goal_index.read_goal_task_links_r config with
     | Ok links ->
       Alcotest.failf
         "a row with no task_ids must not read as a goal with no links (got %d)"
         (List.length links)
     | Error _ -> ());
    write {|{"links":[{"goal_id":"g-1","task_ids":"t-1"}]}|};
    match Workspace_goal_index.read_goal_task_links_r config with
    | Ok links ->
      Alcotest.failf
        "a row whose task_ids is not a list must not read as empty (got %d)"
        (List.length links)
    | Error _ -> ())
;;

let test_link_mutations_require_intact_primary () =
  let mutations =
    [ "link", (fun config ->
        Workspace_goal_index.link_task_to_goal_result config
          ~goal_id:"goal-new" ~task_id:"task-new")
    ; "batch", (fun config ->
        Workspace_goal_index.link_tasks_to_goals_result config
          [ "task-new", Some "goal-new" ])
    ; "unlink", (fun config ->
        Workspace_goal_index.unlink_task_from_goal_result config
          ~goal_id:"goal-old" ~task_id:"task-old")
    ; "prune", (fun config ->
        Workspace_goal_index.prune_links_for_goal_result config ~goal_id:"goal-old")
    ; "assign", (fun config ->
        match Workspace_goal_index.link_goalless_task_to_goal config
          ~goal_id:"goal-new" ~task_id:"task-new" with
        | Ok () -> Ok ()
        | Error (Workspace_goal_index.Link_write_failed detail) -> Error detail
        | Error (Workspace_goal_index.Already_linked_to_goals _) ->
          Alcotest.fail "source failure must not be classified as already assigned")
    ]
  in
  let good = {|{"links":[{"goal_id":"goal-old","task_ids":["task-old"]}]}|} in
  let cases =
    [ "invalid JSON", Some "{", good
    ; "missing collection", Some "{}", good
    ; "missing primary", None, good
    ; "invalid task ID", Some {|{"links":[{"goal_id":"goal-old","task_ids":[123,"task-old"]}]}|}, good
    ; "blank task ID", Some {|{"links":[{"goal_id":"goal-old","task_ids":["task-old"," "]}]}|}, good
    ; "both unreadable", Some "{", "{"
    ]
  in
  List.iter (fun (scenario, primary, recovery) ->
    with_test_env (fun config ->
      let path = Workspace_goal_index.goal_task_links_path config in
      let mirror = path ^ ".last-good" in
      let write path contents =
        Out_channel.with_open_bin path (fun oc -> Out_channel.output_string oc contents)
      in
      (match primary with
       | Some contents -> write path contents
       | None -> if Sys.file_exists path then Sys.remove path);
      write mirror recovery;
      List.iter (fun (name, mutate) ->
        (match mutate config with
         | Error _ -> ()
         | Ok () -> Alcotest.failf "%s: %s accepted damaged primary" scenario name);
        let actual =
          if Sys.file_exists path then Some (In_channel.with_open_bin path In_channel.input_all)
          else None
        in
        Alcotest.(check (option string)) (scenario ^ ": primary unchanged") primary actual;
        Alcotest.(check string) (scenario ^ ": recovery unchanged") recovery
          (In_channel.with_open_bin mirror In_channel.input_all)) mutations)) cases;
  with_test_env (fun config ->
    (match Workspace_goal_index.link_task_to_goal_result config
       ~goal_id:"goal-new" ~task_id:"task-new" with
     | Ok () -> ()
     | Error detail -> Alcotest.failf "fresh registry must accept links: %s" detail);
    match Workspace_goal_index.read_goal_task_links_authoritative_r config with
    | Ok [ ("goal-new", [ "task-new" ]) ] -> ()
    | _ -> Alcotest.fail "fresh registry must persist the exact new link")
;;

let test_unreadable_registry_directory_is_not_absence () =
  with_test_env (fun config ->
    let path = Workspace_goal_index.goal_task_links_path config in
    let directory = Filename.dirname path in
    let permissions = (Unix.stat directory).Unix.st_perm in
    Unix.chmod directory 0o000;
    Fun.protect
      ~finally:(fun () -> Unix.chmod directory permissions)
      (fun () ->
        match Workspace_goal_index.read_goal_task_links_authoritative_r config with
        | Error _ -> ()
        | Ok _ -> Alcotest.fail "unreadable registry directory must not authorize an empty registry"))
;;

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
              "unreadable registry directory is not absence"
              `Quick
              test_unreadable_registry_directory_is_not_absence
          ; test_case
              "all link mutations require intact primary without rewriting evidence"
              `Quick
              test_link_mutations_require_intact_primary
          ; test_case
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
          ; test_case
              "a link row without task_ids is not an empty goal"
              `Quick
              test_a_link_row_without_task_ids_is_not_an_empty_goal
          ] )
    ]
;;
