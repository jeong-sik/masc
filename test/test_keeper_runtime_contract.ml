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

module Sandbox = Keeper_types_profile_sandbox
module Routing = Keeper_runtime_contract.Sandbox_routing

let routing_stage label = function
  | Ok value -> value
  | Error invalid ->
    failf "%s: %s" label (Routing.invalid_boundary_to_string invalid)
;;

let requested ~sandbox_profile ~network_mode =
  Routing.requested_of_config ~sandbox_profile ~network_mode
  |> routing_stage "config request"
;;

let effective ~sandbox_profile ~network_mode =
  Routing.effective_resolved ~sandbox_profile ~network_mode
  |> routing_stage "effective resolution"
;;

let receipt ~sandbox_profile ~network_mode =
  Routing.receipt_observed ~sandbox_profile ~network_mode
  |> routing_stage "receipt observation"
;;

let json_string path json =
  let open Yojson.Safe.Util in
  List.fold_left (fun cursor field -> member field cursor) json path |> to_string
;;

let test_sandbox_routing_verifies_matching_docker_evidence () =
  let requested =
    requested ~sandbox_profile:Sandbox.Docker ~network_mode:Sandbox.Network_none
  in
  let effective =
    effective ~sandbox_profile:Sandbox.Docker ~network_mode:Sandbox.Network_none
  in
  let receipt =
    receipt ~sandbox_profile:Sandbox.Docker ~network_mode:Sandbox.Network_none
  in
  let evidence = Routing.evidence ~requested ~effective ~receipt in
  (match Routing.verify evidence with
   | Ok _ -> ()
   | Error violation ->
     failf "expected verified Docker containment: %s"
       (Routing.violation_to_string violation));
  let descriptor = Routing.descriptor_to_yojson evidence in
  check string "verified status" "verified"
    (json_string [ "verification"; "status" ] descriptor);
  check string "verified containment" "docker_contained"
    (json_string [ "verification"; "containment" ] descriptor)
;;

let test_sandbox_routing_exposes_requested_effective_receipt_mismatch () =
  (* Live-shaped negative fixture: config requests Docker/none while both the
     resolved runtime and its receipt report local/inherit. The legacy flat
     fields look internally consistent; the staged descriptor must not turn
     them into a containment claim. *)
  let requested =
    requested ~sandbox_profile:Sandbox.Docker ~network_mode:Sandbox.Network_none
  in
  let effective =
    effective ~sandbox_profile:Sandbox.Local ~network_mode:Sandbox.Network_inherit
  in
  let receipt =
    receipt ~sandbox_profile:Sandbox.Local ~network_mode:Sandbox.Network_inherit
  in
  let evidence = Routing.evidence ~requested ~effective ~receipt in
  (match Routing.verify evidence with
   | Error (Routing.Config_effective_mismatch { requested; effective }) ->
     check string "requested boundary" "docker_contained"
       (Routing.boundary_to_string requested);
     check string "effective boundary" "host_local"
       (Routing.boundary_to_string effective)
   | Error violation ->
     failf "expected config/effective mismatch, got %s"
       (Routing.violation_to_string violation)
   | Ok _ -> fail "mismatched routing evidence must fail closed");
  let descriptor = Routing.descriptor_to_yojson evidence in
  check string "descriptor config request" "docker_contained"
    (json_string [ "config_requested" ] descriptor);
  check string "descriptor effective" "host_local"
    (json_string [ "resolved_effective"; "boundary" ] descriptor);
  check string "descriptor receipt" "host_local"
    (json_string [ "receipt_evidence"; "boundary" ] descriptor);
  check string "descriptor mismatch status" "mismatch"
    (json_string [ "verification"; "status" ] descriptor);
  check string "descriptor never claims containment" "not_verified"
    (json_string [ "verification"; "containment" ] descriptor);
  check string "typed violation" "config_effective_mismatch"
    (json_string [ "verification"; "violation" ] descriptor);
  let operator_contract =
    Keeper_runtime_contract.runtime_observability_contract_json_from_fields
      ~keeper_name:"code-reviewer"
      ~sandbox_profile:"local"
      ~network_mode:"inherit"
      ~sandbox_routing:evidence
      ()
  in
  check string "operator contract retains request" "docker_contained"
    (json_string [ "sandbox_routing"; "config_requested" ] operator_contract);
  let keeper_contract =
    Keeper_runtime_contract.runtime_contract_json_from_fields
      ~keeper_name:"code-reviewer"
      ~sandbox_profile:"local"
      ~network_mode:"inherit"
      ~sandbox_routing:evidence
      ()
  in
  check bool "keeper projection redacts backend routing evidence" true
    (Yojson.Safe.Util.member "sandbox_routing" keeper_contract = `Null)
;;

let test_sandbox_routing_requires_receipt_evidence () =
  let requested =
    requested ~sandbox_profile:Sandbox.Docker ~network_mode:Sandbox.Network_none
  in
  let effective =
    effective ~sandbox_profile:Sandbox.Docker ~network_mode:Sandbox.Network_none
  in
  let receipt =
    match
      Routing.receipt_unobserved
        ~detail:"execution receipt did not record the runtime route"
    with
    | Ok receipt -> receipt
    | Error error -> fail error
  in
  let evidence = Routing.evidence ~requested ~effective ~receipt in
  (match Routing.verify evidence with
   | Error (Routing.Receipt_evidence_unavailable _) -> ()
   | Error violation ->
     failf "expected unavailable receipt, got %s"
       (Routing.violation_to_string violation)
   | Ok _ -> fail "missing receipt evidence must fail closed");
  let descriptor = Routing.descriptor_to_yojson evidence in
  check string "unobserved status" "unobserved"
    (json_string [ "verification"; "status" ] descriptor);
  check string "unobserved never claims containment" "not_verified"
    (json_string [ "verification"; "containment" ] descriptor)
;;

let test_sandbox_routing_rejects_unenforceable_host_network_none () =
  match
    Routing.requested_of_config
      ~sandbox_profile:Sandbox.Local
      ~network_mode:Sandbox.Network_none
  with
  | Error Routing.Host_network_none_unenforceable -> ()
  | Ok _ -> fail "local/network-none cannot be represented as enforced"
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
        ; test_case "keeps isolation for scoped verification" `Quick
            test_scoped_verification_keeps_isolation
        ] )
    ; ( "sandbox_routing"
      , [ test_case "verifies matching Docker evidence" `Quick
            test_sandbox_routing_verifies_matching_docker_evidence
        ; test_case "exposes requested/effective/receipt mismatch" `Quick
            test_sandbox_routing_exposes_requested_effective_receipt_mismatch
        ; test_case "requires receipt evidence" `Quick
            test_sandbox_routing_requires_receipt_evidence
        ; test_case "rejects unenforceable host network-none" `Quick
            test_sandbox_routing_rejects_unenforceable_host_network_none
        ] )
    ]
;;
