open Masc_mcp
open Test_command_plane_v2_support

let test_best_first_search_blocks_and_routes_research_pipeline () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let owner = "owner-root-node" in
      let normalize_lead = "normalize-lead-node" in
      let verify_lead = "verify-lead-node" in
      with_eio_test base_dir @@ fun config ->
      ignore (Room.init config ~agent_name:(Some "owner"));
      ignore (Room.join config ~agent_name:owner ~capabilities:[] ());
      ignore (Room.join config ~agent_name:normalize_lead ~capabilities:[] ());
      ignore (Room.join config ~agent_name:verify_lead ~capabilities:[] ());
      unit_update_exn config ~actor:"owner"
        (`Assoc
          [
            ("unit_id", `String "company-main");
            ("kind", `String "company");
            ("label", `String "Main Company");
            ("leader_id", `String owner);
            ( "roster",
              `List
                [ `String owner; `String normalize_lead; `String verify_lead ] );
          ]);
      unit_update_exn config ~actor:"owner"
        (`Assoc
          [
            ("unit_id", `String "platoon-research");
            ("kind", `String "platoon");
            ("label", `String "Research Platoon");
            ("parent_unit_id", `String "company-main");
            ("leader_id", `String owner);
            ( "roster",
              `List [ `String normalize_lead; `String verify_lead ] );
            ("capability_profile", `List [ `String "research"; `String "research_pipeline" ]);
          ]);
      unit_update_exn config ~actor:"owner"
        (`Assoc
          [
            ("unit_id", `String "squad-normalize");
            ("kind", `String "squad");
            ("label", `String "Normalize Squad");
            ("parent_unit_id", `String "platoon-research");
            ("leader_id", `String normalize_lead);
            ("roster", `List [ `String normalize_lead ]);
            ( "capability_profile",
              `List
                [
                  `String "normalize";
                  `String "research";
                  `String "research_pipeline";
                ] );
          ]);
      unit_update_exn config ~actor:"owner"
        (`Assoc
          [
            ("unit_id", `String "squad-verify");
            ("kind", `String "squad");
            ("label", `String "Verify Squad");
            ("parent_unit_id", `String "platoon-research");
            ("leader_id", `String verify_lead);
            ("roster", `List [ `String verify_lead ]);
            ( "capability_profile",
              `List
                [
                  `String "verify";
                  `String "research";
                  `String "research_pipeline";
                ] );
          ]);
      let normalize_op =
        start_operation_exn config ~actor:"owner"
          (`Assoc
            [
              ("assigned_unit_id", `String "platoon-research");
              ("objective", `String "Normalize research items");
              ("policy_class", `String "guarded");
              ("budget_class", `String "standard");
              ("workload_profile", `String "research_pipeline");
              ("stage", `String "normalize");
              ("search_strategy", `String "best_first_v1");
            ])
      in
      let verify_op =
        start_operation_exn config ~actor:"owner"
          (`Assoc
            [
              ("assigned_unit_id", `String "platoon-research");
              ("objective", `String "Verify research items");
              ("policy_class", `String "guarded");
              ("budget_class", `String "standard");
              ("workload_profile", `String "research_pipeline");
              ("stage", `String "verify");
              ("search_strategy", `String "best_first_v1");
              ( "depends_on_operation_ids",
                `List [ `String normalize_op.operation_id ] );
            ])
      in
      let verify_plan_before = Command_plane_v2.dispatch_plan_json config
        (`Assoc [ ("operation_id", `String verify_op.operation_id) ])
      in
      Alcotest.(check string) "verify initially blocked" "blocked"
        (verify_plan_before |> Yojson.Safe.Util.member "readiness"
       |> Yojson.Safe.Util.to_string);
      Alcotest.(check int) "one dependency blocker" 1
        (verify_plan_before |> Yojson.Safe.Util.member "dependency_blockers"
       |> Yojson.Safe.Util.to_list |> List.length);
      Alcotest.(check bool) "score breakdown exposed" true
        (verify_plan_before |> Yojson.Safe.Util.member "recommended_units"
       |> Yojson.Safe.Util.index 0 |> Yojson.Safe.Util.member "score_breakdown"
       <> `Null);
      Alcotest.(check int) "verify has no detachment while blocked" 0
        (List.length (detachment_rows_for_operation config verify_op.operation_id));
      ignore
        (unwrap_ok
           (Command_plane_v2.dispatch_tick_json config ~actor:"owner"
              (`Assoc [ ("operation_id", `String normalize_op.operation_id) ])));
      let normalize_state =
        Command_plane_v2.operation_status_json config
          ~operation_id:normalize_op.operation_id ()
      in
      let normalize_assigned_unit =
        normalize_state |> Yojson.Safe.Util.member "operations"
        |> Yojson.Safe.Util.index 0
        |> Yojson.Safe.Util.member "operation"
        |> Yojson.Safe.Util.member "assigned_unit_id"
        |> Yojson.Safe.Util.to_string
      in
      Alcotest.(check string) "normalize routed to normalize squad"
        "squad-normalize" normalize_assigned_unit;
      ignore
        (unwrap_ok
           (Command_plane_v2.checkpoint_operation config ~actor:"owner"
              (`Assoc
                [
                  ("operation_id", `String normalize_op.operation_id);
                  ("checkpoint_ref", `String "ckpt-normalize-1");
                ])));
      let verify_tick =
        unwrap_ok
          (Command_plane_v2.dispatch_tick_json config ~actor:"owner"
             (`Assoc [ ("operation_id", `String verify_op.operation_id) ]))
      in
      Alcotest.(check int) "verify detachment materialized after upstream checkpoint" 1
        (verify_tick |> Yojson.Safe.Util.member "summary"
       |> Yojson.Safe.Util.member "detachments_considered"
       |> Yojson.Safe.Util.to_int);
      let verify_rows = detachment_rows_for_operation config verify_op.operation_id in
      Alcotest.(check int) "verify now has one detachment" 1 (List.length verify_rows);
      let detachment_id =
        verify_rows |> List.hd |> Yojson.Safe.Util.member "detachment"
        |> Yojson.Safe.Util.member "detachment_id"
        |> Yojson.Safe.Util.to_string
      in
      let verify_status =
        unwrap_ok
          (Command_plane_v2.detachment_status_json config
             (`Assoc [ ("detachment_id", `String detachment_id) ]))
      in
      Alcotest.(check string) "verify routed to verify squad"
        "squad-verify"
        (verify_status |> Yojson.Safe.Util.member "result"
       |> Yojson.Safe.Util.member "detachment"
       |> Yojson.Safe.Util.member "assigned_unit_id"
       |> Yojson.Safe.Util.to_string);
      Alcotest.(check string) "detachment status exposes search strategy"
        "best_first_v1"
        (verify_status |> Yojson.Safe.Util.member "result"
       |> Yojson.Safe.Util.member "search"
       |> Yojson.Safe.Util.member "strategy"
       |> Yojson.Safe.Util.to_string);
      let operations_overview =
        Command_plane_v2.list_operations_json config
      in
      Alcotest.(check bool) "operations overview exposes microarch summary" true
        (operations_overview |> Yojson.Safe.Util.member "microarch" <> `Null);
      Alcotest.(check bool) "microarch exposes search fabric summary" true
        (operations_overview |> Yojson.Safe.Util.member "microarch"
       |> Yojson.Safe.Util.member "search_fabric" <> `Null);
      Alcotest.(check bool) "microarch exposes operator signals" true
        (operations_overview |> Yojson.Safe.Util.member "microarch"
       |> Yojson.Safe.Util.member "signals" <> `Null);
      Alcotest.(check bool) "microarch exposes quality per token signal" true
        (operations_overview |> Yojson.Safe.Util.member "microarch"
       |> Yojson.Safe.Util.member "signals"
       |> Yojson.Safe.Util.member "quality_per_token" <> `Null))

let test_invalid_search_strategy_is_rejected () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let owner = "owner-root-node" in
      with_eio_test base_dir @@ fun config ->
      ignore (Room.init config ~agent_name:(Some "owner"));
      ignore (Room.join config ~agent_name:owner ~capabilities:[] ());
      unit_update_exn config ~actor:"owner"
        (`Assoc
          [
            ("unit_id", `String "company-main");
            ("kind", `String "company");
            ("label", `String "Main Company");
            ("leader_id", `String owner);
            ("roster", `List [ `String owner ]);
          ]);
      match
        Command_plane_v2.start_operation config ~actor:"owner"
          (`Assoc
            [
              ("assigned_unit_id", `String "company-main");
              ("objective", `String "Reject invalid strategy");
              ("search_strategy", `String "made_up_strategy");
            ])
      with
      | Ok _ -> Alcotest.fail "invalid search_strategy should be rejected"
      | Error message ->
          Alcotest.(check string) "validation error"
            "unsupported search_strategy: made_up_strategy" message)

let test_best_first_search_skips_units_blocked_by_tool_allowlist () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let owner = "owner-root-node" in
      let alpha_lead = "alpha-lead-node" in
      let alpha_two = "alpha-two-node" in
      let approved_lead = "approved-lead-node" in
      let blocked_lead = "blocked-lead-node" in
      with_eio_test base_dir @@ fun config ->
      setup_company_and_platoon config ~owner ~alpha_lead ~alpha_two;
      ignore (Room.join config ~agent_name:approved_lead ~capabilities:[] ());
      ignore (Room.join config ~agent_name:blocked_lead ~capabilities:[] ());
      unit_update_exn config ~actor:"owner"
        (`Assoc
          [
            ("unit_id", `String "platoon-alpha");
            ("kind", `String "platoon");
            ("label", `String "Alpha Platoon");
            ("parent_unit_id", `String "company-main");
            ("leader_id", `String alpha_lead);
            ( "roster",
              `List
                [
                  `String alpha_lead;
                  `String alpha_two;
                  `String approved_lead;
                  `String blocked_lead;
                ] );
          ]);
      unit_update_exn config ~actor:"owner"
        (`Assoc
          [
            ("unit_id", `String "squad-approved");
            ("kind", `String "squad");
            ("label", `String "Approved Squad");
            ("parent_unit_id", `String "platoon-alpha");
            ("leader_id", `String approved_lead);
            ("roster", `List [ `String approved_lead ]);
            ( "capability_profile",
              `List
                [
                  `String "tool:approved_tool";
                  `String "model:qwen";
                  `String "runtime:codex";
                ] );
            ( "policy",
              `Assoc
                [ ("tool_allowlist", `List [ `String "approved_tool" ]) ] );
          ]);
      unit_update_exn config ~actor:"owner"
        (`Assoc
          [
            ("unit_id", `String "squad-blocked");
            ("kind", `String "squad");
            ("label", `String "Blocked Squad");
            ("parent_unit_id", `String "platoon-alpha");
            ("leader_id", `String blocked_lead);
            ("roster", `List [ `String blocked_lead ]);
            ( "capability_profile",
              `List
                [
                  `String "tool:code_write";
                  `String "model:qwen";
                  `String "runtime:codex";
                ] );
            ( "policy",
              `Assoc
                [ ("tool_allowlist", `List [ `String "approved_tool" ]) ] );
          ]);
      let op =
        start_operation_exn config ~actor:"owner"
          (`Assoc
            [
              ("assigned_unit_id", `String "platoon-alpha");
              ("objective", `String "Implement approved tool change");
              ("workload_profile", `String "coding_task");
              ("stage", `String "implement");
              ("search_strategy", `String "best_first_v1");
            ])
      in
      let plan =
        Command_plane_v2.dispatch_plan_json config
          (`Assoc [ ("operation_id", `String op.operation_id) ])
      in
      let recommended =
        plan |> Yojson.Safe.Util.member "recommended_units"
        |> Yojson.Safe.Util.to_list
      in
      Alcotest.(check int) "only one recommended unit survives policy gate" 1
        (List.length recommended);
      Alcotest.(check string) "approved squad is recommended"
        "squad-approved"
        (recommended |> List.hd |> Yojson.Safe.Util.member "unit"
       |> Yojson.Safe.Util.member "unit_id"
       |> Yojson.Safe.Util.to_string);
      ignore
        (unwrap_ok
           (Command_plane_v2.dispatch_tick_json config ~actor:"owner"
              (`Assoc [ ("operation_id", `String op.operation_id) ])));
      let op_json =
        Command_plane_v2.operation_status_json config ~operation_id:op.operation_id
          ()
      in
      Alcotest.(check string) "tick assigns approved squad" "squad-approved"
        (op_json |> Yojson.Safe.Util.member "operations"
       |> Yojson.Safe.Util.index 0
       |> Yojson.Safe.Util.member "operation"
       |> Yojson.Safe.Util.member "assigned_unit_id"
       |> Yojson.Safe.Util.to_string))
