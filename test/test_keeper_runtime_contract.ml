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

let make_path_unreadable path =
  if Sys.file_exists path && not (Sys.is_directory path) then Sys.remove path;
  if not (Sys.file_exists path) then Unix.mkdir path 0o755
;;

let make_goal_task_link_registry_unreadable config =
  make_path_unreadable (Workspace_goal_index.goal_task_links_path config);
  make_path_unreadable (Workspace_goal_index.goal_task_links_recovery_path config)
;;

let assoc_opt name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None
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
      check string "mode"
        Keeper_runtime_contract.claim_scope_mode_active_goal_ids
        scope.mode;
      check (option string) "no read error" None
        (Option.map
           Keeper_runtime_contract.claim_goal_scope_read_error_to_string
           scope.read_error);
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
      check string "fallback mode"
        Keeper_runtime_contract.claim_scope_mode_empty_goal_scope_fallback_all_tasks
        scope.mode;
      check (option string) "fallback reason recorded"
        (Some "no_scoped_claimable_tasks") scope.fallback_reason;
      check (option string) "no read error" None
        (Option.map
           Keeper_runtime_contract.claim_goal_scope_read_error_to_string
           scope.read_error);
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
      check string "scoped mode"
        Keeper_runtime_contract.claim_scope_mode_active_goal_ids
        scope.mode;
      check (option string) "no fallback reason" None scope.fallback_reason;
      check (option string) "no read error" None
        (Option.map
           Keeper_runtime_contract.claim_goal_scope_read_error_to_string
           scope.read_error);
      let tasks = Workspace.get_tasks_raw config in
      let included =
        tasks
        |> List.filter scope.task_filter
        |> List.map (fun (task : Masc_domain.task) -> task.title)
      in
      check (list string) "only linked task in scope" [ "goal a task" ] included)
;;

let test_goal_link_read_failure_keeps_claim_scope_closed () =
  let config = make_config () in
  Fun.protect
    ~finally:(fun () -> cleanup_config config)
    (fun () ->
      add_task ~goal_id:"goal-a" config ~title:"goal a task";
      add_task ~goal_id:"goal-b" config ~title:"goal b task";
      make_goal_task_link_registry_unreadable config;
      let meta = make_meta ~active_goal_ids:[ "goal-a" ] () in
      let scope =
        Keeper_runtime_contract.resolve_claim_goal_scope ~config ~meta ()
      in
      check string "read failure mode"
        Keeper_runtime_contract.claim_scope_mode_goal_task_links_read_failed
        scope.mode;
      check (option string) "no all-tasks fallback reason" None scope.fallback_reason;
      let read_error =
        Option.map
          Keeper_runtime_contract.claim_goal_scope_read_error_to_string
          scope.read_error
      in
      check bool "read error recorded" true (Option.is_some read_error);
      let runtime_contract =
        Keeper_runtime_contract.runtime_contract_json ~config meta
      in
      let goal_progress =
        match assoc_opt "goal_progress" runtime_contract with
        | Some json -> json
        | None -> fail "runtime contract missing goal_progress"
      in
      check (option string) "goal progress status unknown" (Some "unknown")
        (match assoc_opt "status" goal_progress with
         | Some (`String status) -> Some status
         | _ -> None);
      check bool "goal progress read error recorded" true
        (match assoc_opt "read_error" goal_progress with
         | Some (`String msg) -> String.length msg > 0
         | _ -> false);
      check bool "blocked task count remains unknown" true
        (match assoc_opt "blocked_task_count" runtime_contract with
         | Some `Null -> true
         | _ -> false);
      check bool "blocked task count known is false" true
        (match assoc_opt "blocked_task_count_known" runtime_contract with
         | Some (`Bool false) -> true
         | _ -> false);
      let tasks = Workspace.get_tasks_raw config in
      let included =
        tasks
        |> List.filter scope.task_filter
        |> List.map (fun (task : Masc_domain.task) -> task.title)
      in
      check (list string) "read failure does not widen claim scope" [] included;
      match
        Workspace.claim_next_r config ~agent_name:"keeper-runtime-contract"
          ~task_filter:scope.task_filter
          ()
      with
      | Workspace.Claim_next_no_eligible { excluded_count; _ } ->
        check int "all tasks excluded by closed scope" 2 excluded_count
      | Workspace.Claim_next_claimed { task_id; _ } ->
        failf "expected closed scope, claimed %s" task_id
      | Workspace.Claim_next_no_unclaimed ->
        fail "expected closed scope with excluded unclaimed tasks"
      | Workspace.Claim_next_error msg ->
        failf "expected closed scope, got error: %s" msg)
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
        ; test_case "keeps scope closed when goal links cannot be read" `Quick
            test_goal_link_read_failure_keeps_claim_scope_closed
        ] )
    ]
;;
