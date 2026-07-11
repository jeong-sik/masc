open Alcotest
open Masc

let make_config () =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc_keeper_runtime_contract_%d_%d"
         (Unix.getpid ())
         (int_of_float (Unix.gettimeofday () *. 1000.)))
  in
  Unix.mkdir dir 0o755;
  let config = Workspace.default_config dir in
  let _ = Workspace.init config ~agent_name:(Some "keeper-runtime-contract") in
  config
;;

let cleanup_config config =
  let _ = Workspace.reset config in
  ()
;;

let make_meta ?(active_goal_ids = []) () =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ "name", `String "runtime-contract-keeper"
        ; "agent_name", `String "keeper-runtime-contract"
        ; "trace_id", `String "runtime-contract-trace"
        ; ( "active_goal_ids"
          , `List (List.map (fun id -> `String id) active_goal_ids) )
        ])
  with
  | Ok meta -> meta
  | Error e -> failf "make_meta failed: %s" e
;;

let add_task ?goal_id config ~title =
  let result = Workspace.add_task ?goal_id config ~title ~priority:1 ~description:"" in
  if String.starts_with ~prefix:"Error:" result
  then failf "add_task failed: %s" result
;;

let test_active_goal_ids_filter_claimable_tasks () =
  let config = make_config () in
  Fun.protect
    ~finally:(fun () -> cleanup_config config)
    (fun () ->
      add_task ~goal_id:"goal-a" config ~title:"goal a task";
      add_task ~goal_id:"goal-b" config ~title:"goal b task";
      let meta = make_meta ~active_goal_ids:[ "goal-a" ] () in
      let scope =
        Keeper_runtime_contract.resolve_claim_goal_scope ~config ~meta ()
      in
      check string "mode" "active_goal_ids"
        (Keeper_runtime_contract.claim_scope_mode_to_string scope.mode);
      check (list string) "effective goal ids" [ "goal-a" ] scope.effective_goal_ids;
      let tasks = Workspace.get_tasks_raw config in
      let included =
        tasks
        |> List.filter scope.task_filter
        |> List.map (fun (task : Masc_domain.task) -> task.title)
      in
      check (list string) "scope includes only linked task" [ "goal a task" ] included;
      match
        Workspace.claim_next_r config ~agent_name:"keeper-runtime-contract"
          ~task_filter:scope.task_filter
          ()
      with
      | Workspace.Claim_next_claimed { task_id; _ } ->
        check string "claimed scoped task" "task-001" task_id
      | Workspace.Claim_next_no_unclaimed ->
        fail "expected scoped claim, got no_unclaimed"
      | Workspace.Claim_next_no_eligible { excluded_count; _ } ->
        failf "expected scoped claim, got no_eligible excluded=%d" excluded_count
      | Workspace.Claim_next_error msg ->
        failf "expected scoped claim, got error: %s" msg)
;;

let test_no_scoped_match_falls_back_to_all_tasks () =
  let config = make_config () in
  Fun.protect
    ~finally:(fun () -> cleanup_config config)
    (fun () ->
      (* Backlog holds a claimable task linked to goal-b while the keeper is
         scoped to goal-a. Goal-scope is a priority hint, not a hard gate: with
         no goal-a task to claim, the keeper falls back to all_tasks instead of
         starving. Restores RFC-0067 §1 allow_empty_goal_scope_fallback. *)
      add_task ~goal_id:"goal-b" config ~title:"goal b task";
      let meta = make_meta ~active_goal_ids:[ "goal-a" ] () in
      let scope =
        Keeper_runtime_contract.resolve_claim_goal_scope ~config ~meta ()
      in
      check string "fallback mode" "empty_goal_scope_fallback_all_tasks"
        (Keeper_runtime_contract.claim_scope_mode_to_string scope.mode);
      check (option string) "fallback reason recorded"
        (Some "no_scoped_claimable_tasks") scope.fallback_reason;
      check (list string) "effective goal ids preserved" [ "goal-a" ]
        scope.effective_goal_ids;
      match
        Workspace.claim_next_r config ~agent_name:"keeper-runtime-contract"
          ~task_filter:scope.task_filter
          ()
      with
      | Workspace.Claim_next_claimed { task_id; _ } ->
        check string "claimed via fallback" "task-001" task_id
      | Workspace.Claim_next_no_eligible { excluded_count; _ } ->
        failf "expected fallback claim, got no_eligible excluded=%d"
          excluded_count
      | Workspace.Claim_next_no_unclaimed ->
        fail "expected fallback claim, got no_unclaimed"
      | Workspace.Claim_next_error msg ->
        failf "expected fallback claim, got error: %s" msg)
;;

let test_preloaded_tasks_fall_back_to_all_tasks () =
  let config = make_config () in
  Fun.protect
    ~finally:(fun () -> cleanup_config config)
    (fun () ->
      add_task ~goal_id:"goal-b" config ~title:"goal b task";
      let meta = make_meta ~active_goal_ids:[ "goal-a" ] () in
      let tasks = Workspace.get_tasks_raw config in
      let scope =
        Keeper_runtime_contract.resolve_claim_goal_scope_for_tasks ~config
          ~meta ~tasks ()
      in
      check string "fallback mode" "empty_goal_scope_fallback_all_tasks"
        (Keeper_runtime_contract.claim_scope_mode_to_string scope.mode);
      check (option string) "fallback reason recorded"
        (Some "no_scoped_claimable_tasks") scope.fallback_reason;
      check (list string) "effective goal ids preserved" [ "goal-a" ]
        scope.effective_goal_ids)
;;

let test_scoped_match_present_keeps_isolation () =
  let config = make_config () in
  Fun.protect
    ~finally:(fun () -> cleanup_config config)
    (fun () ->
      (* When the keeper's goal DOES have a claimable task, scope stays a hard
         filter: out-of-scope work is left for its own keeper. Fallback only
         triggers on an empty scoped pool. *)
      add_task ~goal_id:"goal-a" config ~title:"goal a task";
      add_task ~goal_id:"goal-b" config ~title:"goal b task";
      let meta = make_meta ~active_goal_ids:[ "goal-a" ] () in
      let scope =
        Keeper_runtime_contract.resolve_claim_goal_scope ~config ~meta ()
      in
      check string "scoped mode" "active_goal_ids"
        (Keeper_runtime_contract.claim_scope_mode_to_string scope.mode);
      check (option string) "no fallback reason" None scope.fallback_reason;
      let tasks = Workspace.get_tasks_raw config in
      let included =
        tasks
        |> List.filter scope.task_filter
        |> List.map (fun (task : Masc_domain.task) -> task.title)
      in
      check (list string) "only linked task in scope" [ "goal a task" ] included)
;;

let () =
  run
    "keeper_runtime_contract"
    [ ( "active_goal_claim_scope"
      , [ test_case "filters claimable tasks" `Quick
            test_active_goal_ids_filter_claimable_tasks
        ; test_case "keeps isolation when scoped match present" `Quick
            test_scoped_match_present_keeps_isolation
        ; test_case "falls back to all_tasks when no scoped match" `Quick
            test_no_scoped_match_falls_back_to_all_tasks
        ; test_case "preloaded tasks fall back to all_tasks" `Quick
            test_preloaded_tasks_fall_back_to_all_tasks
        ] )
    ]
;;
