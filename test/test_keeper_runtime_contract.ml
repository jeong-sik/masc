open Alcotest
open Masc

let () = Workspace_metric_hooks.install ()

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
        (* [agent_name] is omitted: Masc_test_deps derives the canonical
           [keeper-<name>-agent] from [name]. Spelling it here pinned a value
           that stopped matching when 28ef484a39 made the meta decoder check
           the pair, which killed this suite in make_meta before any
           active_goal_claim_scope assertion ran. *)
        [ "name", `String "runtime-contract-keeper"
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
        Keeper_runtime_contract.resolve_claim_goal_scope
          ~config ~meta ~task_eligible:(fun _ -> true) ()
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
        Keeper_runtime_contract.resolve_claim_goal_scope
          ~config ~meta ~task_eligible:(fun _ -> true) ()
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
          ~meta ~tasks ~task_eligible:(fun _ -> true) ()
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
        Keeper_runtime_contract.resolve_claim_goal_scope
          ~config ~meta ~task_eligible:(fun _ -> true) ()
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

let test_scoped_verification_keeps_isolation () =
  let config = make_config () in
  Fun.protect
    ~finally:(fun () -> cleanup_config config)
    (fun () ->
      add_task ~goal_id:"goal-a" config ~title:"goal a verification";
      add_task ~goal_id:"goal-b" config ~title:"goal b task";
      let _ =
        Workspace.claim_task
          config
          ~agent_name:"keeper-runtime-contract"
          ~task_id:"task-001"
      in
      (match
         Workspace.transition_task_r
           config
           ~agent_name:"keeper-runtime-contract"
           ~task_id:"task-001"
           ~action:Masc_domain.Submit_for_verification
           ~notes:"verification setup notes"
           ()
       with
       | Ok _ -> ()
       | Error error -> fail (Masc_domain.masc_error_to_string error));
      let meta = make_meta ~active_goal_ids:[ "goal-a" ] () in
      let scope =
        Keeper_runtime_contract.resolve_claim_goal_scope
          ~config
          ~meta
          ~task_eligible:(fun _ -> true)
          ()
      in
      check
        string
        "verification keeps scoped mode"
        "active_goal_ids"
        (Keeper_runtime_contract.claim_scope_mode_to_string scope.mode);
      check (option string) "no fallback reason" None scope.fallback_reason;
      let included =
        Workspace.get_tasks_raw config
        |> List.filter scope.task_filter
        |> List.map (fun (task : Masc_domain.task) -> task.title)
      in
      check
        (list string)
        "scope includes linked verification"
        [ "goal a verification" ]
        included)
;;

let put_goal config ~id ~phase =
  match Goal_store.upsert_goal config ~id ~title:("Goal " ^ id) ~phase () with
  | Ok _ -> ()
  | Error msg -> failf "upsert_goal %s failed: %s" id msg
;;

(* The predicate under test is [Goal_phase.admits_self_directed_progress], so
   every terminal constructor is asserted rather than Completed standing in for
   the group: Blocked and Paused are the two that read as "still mine, just not
   now", which is exactly the reading that would justify keeping them in scope. *)
let test_validate_drops_every_terminal_phase () =
  let config = make_config () in
  Fun.protect
    ~finally:(fun () -> cleanup_config config)
    (fun () ->
      let terminal =
        [ "goal-completed", Goal_phase.Completed
        ; "goal-dropped", Goal_phase.Dropped
        ; "goal-blocked", Goal_phase.Blocked
        ; "goal-paused", Goal_phase.Paused
        ]
      in
      put_goal config ~id:"goal-executing" ~phase:Goal_phase.Executing;
      List.iter (fun (id, phase) -> put_goal config ~id ~phase) terminal;
      let meta =
        make_meta ~active_goal_ids:("goal-executing" :: List.map fst terminal) ()
      in
      check
        (list string)
        "only the executing goal survives"
        [ "goal-executing" ]
        (Keeper_runtime_contract.validate_active_goal_ids ~config ~meta ()))
;;

(* The live shape this closes (2026-08-07): the only keeper with a configured
   scope pointed at a goal that had completed, and the runtime contract went on
   stamping goal_ids from the raw list for 5,362 tool calls while the prompt —
   which applies the same predicate — showed no goal at all. Asserting the
   emptiness matters more than the filtering: empty is what makes the claim
   scope fall to All_tasks and the stamp read honestly. *)
let test_scope_of_a_completed_goal_is_empty_not_scoped () =
  let config = make_config () in
  Fun.protect
    ~finally:(fun () -> cleanup_config config)
    (fun () ->
      put_goal config ~id:"goal-finished" ~phase:Goal_phase.Completed;
      add_task ~goal_id:"goal-finished" config ~title:"task under a finished goal";
      add_task config ~title:"unscoped task";
      let meta = make_meta ~active_goal_ids:[ "goal-finished" ] () in
      let surviving = Keeper_runtime_contract.validate_active_goal_ids ~config ~meta () in
      check (list string) "nothing survives" [] surviving;
      let meta = make_meta ~active_goal_ids:surviving () in
      let scope =
        Keeper_runtime_contract.resolve_claim_goal_scope
          ~config
          ~meta
          ~task_eligible:(fun _ -> true)
          ()
      in
      check
        string
        "claim scope is all_tasks, not a scope over a finished goal"
        "all_tasks"
        (Keeper_runtime_contract.claim_scope_mode_to_string scope.mode);
      check (list string) "no effective goal ids" [] scope.effective_goal_ids)
;;

(* A goal id that resolves to nothing was already pruned before this change;
   pinning it keeps the two reasons from being merged back into one branch. *)
let test_validate_still_drops_ids_absent_from_the_store () =
  let config = make_config () in
  Fun.protect
    ~finally:(fun () -> cleanup_config config)
    (fun () ->
      put_goal config ~id:"goal-real" ~phase:Goal_phase.Executing;
      let meta = make_meta ~active_goal_ids:[ "goal-real"; "goal-typo" ] () in
      check
        (list string)
        "unknown id dropped, existing executing goal kept"
        [ "goal-real" ]
        (Keeper_runtime_contract.validate_active_goal_ids ~config ~meta ()))
;;

let () =
  run
    "keeper_runtime_contract"
    [ ( "active_goal_ids_validation"
      , [ test_case "drops every terminal phase" `Quick
            test_validate_drops_every_terminal_phase
        ; test_case "a completed goal leaves an empty scope" `Quick
            test_scope_of_a_completed_goal_is_empty_not_scoped
        ; test_case "still drops ids absent from the store" `Quick
            test_validate_still_drops_ids_absent_from_the_store
        ] )
    ; ( "active_goal_claim_scope"
      , [ test_case "filters claimable tasks" `Quick
            test_active_goal_ids_filter_claimable_tasks
        ; test_case "keeps isolation when scoped match present" `Quick
            test_scoped_match_present_keeps_isolation
        ; test_case "falls back to all_tasks when no scoped match" `Quick
            test_no_scoped_match_falls_back_to_all_tasks
        ; test_case "preloaded tasks fall back to all_tasks" `Quick
            test_preloaded_tasks_fall_back_to_all_tasks
        ; test_case "keeps isolation for scoped verification" `Quick
            test_scoped_verification_keeps_isolation
        ] )
    ]
;;
