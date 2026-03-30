open Masc_mcp
open Test_command_plane_v2_support

let test_operation_defaults_to_coding_task_best_first () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let owner = "owner-root-node" in
      let alpha_lead = "alpha-lead-node" in
      let alpha_two = "alpha-two-node" in
      with_eio_test base_dir @@ fun config ->
      setup_company_and_platoon config ~owner ~alpha_lead ~alpha_two;
      let operation =
        start_operation_exn config ~actor:"owner"
          (`Assoc
            [
              ("assigned_unit_id", `String "company-main");
              ("objective", `String "Patch command plane defaults");
            ])
      in
      Alcotest.(check string) "default workload_profile" "coding_task"
        (Command_plane_v2.operation_workload_profile operation);
      Alcotest.(check string) "default search strategy" "best_first_v1"
        operation.search_strategy)

let test_generic_alias_normalizes_to_coding_task_and_keeps_artifact_scope () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let owner = "owner-root-node" in
      let alpha_lead = "alpha-lead-node" in
      let alpha_two = "alpha-two-node" in
      with_eio_test base_dir @@ fun config ->
      setup_company_and_platoon config ~owner ~alpha_lead ~alpha_two;
      let operation =
        start_operation_exn config ~actor:"owner"
          (`Assoc
            [
              ("assigned_unit_id", `String "company-main");
              ("objective", `String "Inspect command plane defaults");
              ("workload_profile", `String "generic");
              ("stage", `String "inspect");
              ( "artifact_scope",
                `List
                  [
                    `String "lib/command_plane_v2.ml";
                    `String "test/test_command_plane_v2.ml";
                  ] );
            ])
      in
      Alcotest.(check string) "generic alias normalized" "coding_task"
        (Command_plane_v2.operation_workload_profile operation);
      Alcotest.(check (list string)) "artifact_scope preserved"
        [ "lib/command_plane_v2.ml"; "test/test_command_plane_v2.ml" ]
        operation.artifact_scope)

let test_workload_template_defaults_apply_expected_profile_and_stage () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let owner = "owner-root-node" in
      let alpha_lead = "alpha-lead-node" in
      let alpha_two = "alpha-two-node" in
      with_eio_test base_dir @@ fun config ->
      setup_company_and_platoon config ~owner ~alpha_lead ~alpha_two;
      let coding_op =
        start_operation_exn config ~actor:"owner"
          (`Assoc
            [
              ("assigned_unit_id", `String "company-main");
              ("objective", `String "Run coding team");
              ("workload_template", `String "coding_team");
            ])
      in
      Alcotest.(check (option string)) "coding template stored"
        (Some "coding_team") coding_op.workload_template;
      Alcotest.(check string) "coding template workload" "coding_task"
        (Command_plane_v2.operation_workload_profile coding_op);
      Alcotest.(check (option string)) "coding template stage"
        (Some "decompose") coding_op.stage;
      let research_op =
        start_operation_exn config ~actor:"owner"
          (`Assoc
            [
              ("assigned_unit_id", `String "company-main");
              ("objective", `String "Run research team");
              ("workload_template", `String "research_team");
            ])
      in
      Alcotest.(check (option string)) "research template stored"
        (Some "research_team") research_op.workload_template;
      Alcotest.(check string) "research template workload" "research_pipeline"
        (Command_plane_v2.operation_workload_profile research_op);
      Alcotest.(check (option string)) "research template stage"
        (Some "normalize") research_op.stage;
      let ops_op =
        start_operation_exn config ~actor:"owner"
          (`Assoc
            [
              ("assigned_unit_id", `String "company-main");
              ("objective", `String "Run ops governance team");
              ("workload_template", `String "ops_governance_team");
            ])
      in
      Alcotest.(check (option string)) "ops template stored"
        (Some "ops_governance_team") ops_op.workload_template;
      Alcotest.(check string) "ops template workload" "research_pipeline"
        (Command_plane_v2.operation_workload_profile ops_op);
      Alcotest.(check (option string)) "ops template stage"
        (Some "audit") ops_op.stage)

let test_workload_template_rejects_mismatched_workload_profile () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let owner = "owner-root-node" in
      let alpha_lead = "alpha-lead-node" in
      let alpha_two = "alpha-two-node" in
      with_eio_test base_dir @@ fun config ->
      setup_company_and_platoon config ~owner ~alpha_lead ~alpha_two;
      match
        Command_plane_v2.start_operation config ~actor:"owner"
          (`Assoc
            [
              ("assigned_unit_id", `String "company-main");
              ("objective", `String "Mismatch template/profile");
              ("workload_template", `String "coding_team");
              ("workload_profile", `String "research_pipeline");
            ])
      with
      | Error message ->
          Alcotest.(check string)
            "template/profile mismatch"
            "workload_template coding_team requires workload_profile=coding_task"
            message
      | Ok _ -> Alcotest.fail "expected workload_template mismatch to fail")

let test_start_operation_uses_legacy_chain_run_id_as_checkpoint_ref () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let owner = "owner-root-node" in
      let alpha_lead = "alpha-lead-node" in
      let alpha_two = "alpha-two-node" in
      with_eio_test base_dir @@ fun config ->
      setup_company_and_platoon config ~owner ~alpha_lead ~alpha_two;
      let operation =
        start_operation_exn config ~actor:"owner"
          (`Assoc
            [
              ("assigned_unit_id", `String "company-main");
              ("objective", `String "Resume legacy chain checkpoint");
              ("chain", `Assoc [ ("run_id", `String "legacy-run-123") ]);
            ])
      in
      Alcotest.(check (option string)) "legacy chain run_id promoted"
        (Some "legacy-run-123") operation.checkpoint_ref)

let test_operation_json_preserves_chain_null_for_wire_compat () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let owner = "owner-root-node" in
      let alpha_lead = "alpha-lead-node" in
      let alpha_two = "alpha-two-node" in
      with_eio_test base_dir @@ fun config ->
      setup_company_and_platoon config ~owner ~alpha_lead ~alpha_two;
      let operation =
        start_operation_exn config ~actor:"owner"
          (`Assoc
            [
              ("assigned_unit_id", `String "company-main");
              ("objective", `String "Serialize command plane operation");
            ])
      in
      let fields =
        match Command_plane_v2.operation_to_json operation with
        | `Assoc fields -> fields
        | _ -> Alcotest.fail "expected operation JSON object"
      in
      let chain_field = List.assoc_opt "chain" fields in
      Alcotest.(check bool) "chain key present" true (Option.is_some chain_field);
      Alcotest.(check bool) "chain key is null" true
        (match chain_field with
        | Some `Null -> true
        | _ -> false))

let test_operation_of_json_uses_legacy_chain_run_id_as_checkpoint_ref () =
  let legacy_json =
    `Assoc
      [
        ("operation_id", `String "op-legacy-chain");
        ("objective", `String "Load legacy chain snapshot");
        ("assigned_unit_id", `String "company-main");
        ("trace_id", `String "trace-legacy-chain");
        ("created_by", `String "owner");
        ("status", `String "active");
        ("chain", `Assoc [ ("run_id", `String "legacy-run-456") ]);
      ]
  in
  match Command_plane_v2.operation_of_json legacy_json with
  | Some operation ->
      Alcotest.(check (option string)) "legacy stored chain run_id promoted"
        (Some "legacy-run-456") operation.checkpoint_ref
  | None -> Alcotest.fail "expected legacy operation JSON to load"

let test_coding_verify_and_review_require_expected_dependencies () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let owner = "owner-root-node" in
      let alpha_lead = "alpha-lead-node" in
      let alpha_two = "alpha-two-node" in
      with_eio_test base_dir @@ fun config ->
      setup_company_and_platoon config ~owner ~alpha_lead ~alpha_two;
      match
        Command_plane_v2.start_operation config ~actor:"owner"
          (`Assoc
            [
              ("assigned_unit_id", `String "company-main");
              ("objective", `String "Run verify without implement dependency");
              ("workload_profile", `String "coding_task");
              ("stage", `String "verify");
            ])
      with
      | Ok _ -> Alcotest.fail "verify without implement dependency should fail"
      | Error message ->
          Alcotest.(check string) "verify dependency error"
            "coding_task verify stage requires at least one implement dependency"
            message;
      let implement_op =
        start_operation_exn config ~actor:"owner"
          (`Assoc
            [
              ("assigned_unit_id", `String "company-main");
              ("objective", `String "Implement command plane patch");
              ("workload_profile", `String "coding_task");
              ("stage", `String "implement");
            ])
      in
      let verify_op =
        start_operation_exn config ~actor:"owner"
          (`Assoc
            [
              ("assigned_unit_id", `String "company-main");
              ("objective", `String "Verify command plane patch");
              ("workload_profile", `String "coding_task");
              ("stage", `String "verify");
              ("depends_on_operation_ids", `List [ `String implement_op.operation_id ]);
            ])
      in
      match
        Command_plane_v2.start_operation config ~actor:"owner"
          (`Assoc
            [
              ("assigned_unit_id", `String "company-main");
              ("objective", `String "Review without verify dependency");
              ("workload_profile", `String "coding_task");
              ("stage", `String "review");
              ("depends_on_operation_ids", `List [ `String implement_op.operation_id ]);
            ])
      with
      | Ok _ -> Alcotest.fail "review without verify dependency should fail"
      | Error message ->
          Alcotest.(check string) "review dependency error"
            "coding_task review stage requires a coding_task verify dependency"
            message;
      let review_op =
        start_operation_exn config ~actor:"owner"
          (`Assoc
            [
              ("assigned_unit_id", `String "company-main");
              ("objective", `String "Review command plane patch");
              ("workload_profile", `String "coding_task");
              ("stage", `String "review");
              ("depends_on_operation_ids", `List [ `String verify_op.operation_id ]);
            ])
      in
      Alcotest.(check string) "review stage accepted" "review"
        (Option.value ~default:"" review_op.stage))

let test_intent_create_update_and_operation_inheritance () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let owner = "owner-root-node" in
      let alpha_lead = "alpha-lead-node" in
      let alpha_two = "alpha-two-node" in
      with_eio_test base_dir @@ fun config ->
      setup_company_and_platoon config ~owner ~alpha_lead ~alpha_two;
      let intent =
        unwrap_ok
          (Command_plane_v2.create_intent_json config ~actor:"owner"
             (`Assoc
               [
                 ("title", `String "Stabilize command plane intent path");
                 ("artifact_priors", `List [ `String "lib/command_plane_v2.ml" ]);
                 ( "current_focus",
                   `Assoc [ ("stage", `String "inspect") ] );
               ]))
      in
      let operation =
        start_operation_exn config ~actor:"owner"
          (`Assoc
            [
              ("assigned_unit_id", `String "company-main");
              ("objective", `String "Inspect intent-linked command plane path");
              ("intent_id", `String intent.intent_id);
              ("stage", `String "inspect");
            ])
      in
      Alcotest.(check (option string)) "intent linked"
        (Some intent.intent_id) operation.intent_id;
      Alcotest.(check (list string)) "artifact priors inherited"
        [ "lib/command_plane_v2.ml" ] operation.artifact_scope;
      let updated_intent =
        unwrap_ok
          (Command_plane_v2.update_intent_json config ~actor:"owner"
             (`Assoc
               [
                 ("intent_id", `String intent.intent_id);
                 ("state", `String "blocked");
               ]))
      in
      Alcotest.(check string) "state updated" "blocked"
        (Command_plane_v2.string_of_intent_state updated_intent.state);
      let forecast =
        unwrap_ok
          (Command_plane_v2.intent_forecast_json config intent.intent_id ())
      in
      Alcotest.(check bool) "forecast has candidates" true
        (forecast |> Yojson.Safe.Util.member "candidate_next_states"
       |> Yojson.Safe.Util.to_list <> []);
      Alcotest.(check string) "forecast current focus stage" "inspect"
        (forecast |> Yojson.Safe.Util.member "current_focus"
       |> Yojson.Safe.Util.member "stage" |> Yojson.Safe.Util.to_string))

let test_intent_forecast_advances_after_completed_operation () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let owner = "owner-root-node" in
      let alpha_lead = "alpha-lead-node" in
      let alpha_two = "alpha-two-node" in
      with_eio_test base_dir @@ fun config ->
      setup_company_and_platoon config ~owner ~alpha_lead ~alpha_two;
      let intent =
        unwrap_ok
          (Command_plane_v2.create_intent_json config ~actor:"owner"
             (`Assoc
               [
                 ("title", `String "Ship coding-task intent flow");
                 ("artifact_priors", `List [ `String "lib/cp_search_fabric.ml" ]);
               ]))
      in
      let implement_op =
        start_operation_exn config ~actor:"owner"
          (`Assoc
            [
              ("assigned_unit_id", `String "company-main");
              ("objective", `String "Implement intent forecast support");
              ("intent_id", `String intent.intent_id);
              ("stage", `String "implement");
            ])
      in
      ignore
        (unwrap_ok
           (Command_plane_v2.finalize_operation_json config ~actor:"owner"
              (`Assoc [ ("operation_id", `String implement_op.operation_id) ])));
      let forecast =
        unwrap_ok
          (Command_plane_v2.intent_forecast_json config intent.intent_id ())
      in
      Alcotest.(check string) "recommended next stage" "verify"
        (forecast |> Yojson.Safe.Util.member "recommended_focus"
       |> Yojson.Safe.Util.member "stage" |> Yojson.Safe.Util.to_string))

let test_intent_state_aggregates_across_parallel_operations () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let owner = "owner-root-node" in
      let alpha_lead = "alpha-lead-node" in
      let alpha_two = "alpha-two-node" in
      with_eio_test base_dir @@ fun config ->
      setup_company_and_platoon config ~owner ~alpha_lead ~alpha_two;
      let intent =
        unwrap_ok
          (Command_plane_v2.create_intent_json config ~actor:"owner"
             (`Assoc [ ("title", `String "Parallel intent") ]))
      in
      let op_a =
        start_operation_exn config ~actor:"owner"
          (`Assoc
            [
              ("assigned_unit_id", `String "company-main");
              ("objective", `String "Implement branch A");
              ("intent_id", `String intent.intent_id);
              ("stage", `String "implement");
            ])
      in
      ignore
        (start_operation_exn config ~actor:"owner"
           (`Assoc
             [
               ("assigned_unit_id", `String "company-main");
               ("objective", `String "Implement branch B");
               ("intent_id", `String intent.intent_id);
               ("stage", `String "implement");
             ]));
      ignore
        (unwrap_ok
           (Command_plane_v2.finalize_operation_json config ~actor:"owner"
              (`Assoc [ ("operation_id", `String op_a.operation_id) ])));
      let intent_status =
        Command_plane_v2.list_intents_json ~intent_id:intent.intent_id config
      in
      Alcotest.(check string) "intent stays active while parallel op remains"
        "active"
        (intent_status |> Yojson.Safe.Util.member "intents"
       |> Yojson.Safe.Util.index 0
       |> Yojson.Safe.Util.member "state"
       |> Yojson.Safe.Util.to_string))

let test_intent_forecast_resolves_dependencies_against_all_operations () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let owner = "owner-root-node" in
      let alpha_lead = "alpha-lead-node" in
      let alpha_two = "alpha-two-node" in
      with_eio_test base_dir @@ fun config ->
      setup_company_and_platoon config ~owner ~alpha_lead ~alpha_two;
      let shared_upstream =
        start_operation_exn config ~actor:"owner"
          (`Assoc
            [
              ("assigned_unit_id", `String "company-main");
              ("objective", `String "Shared setup");
              ("workload_profile", `String "coding_task");
              ("stage", `String "implement");
            ])
      in
      ignore
        (unwrap_ok
           (Command_plane_v2.finalize_operation_json config ~actor:"owner"
              (`Assoc [ ("operation_id", `String shared_upstream.operation_id) ])));
      let intent =
        unwrap_ok
          (Command_plane_v2.create_intent_json config ~actor:"owner"
             (`Assoc
               [
                 ("title", `String "Cross intent dependency forecast");
                 ("artifact_priors", `List [ `String "lib/command_plane_v2.ml" ]);
               ]))
      in
      ignore
        (start_operation_exn config ~actor:"owner"
           (`Assoc
             [
               ("assigned_unit_id", `String "company-main");
               ("objective", `String "Verify after shared setup");
               ("intent_id", `String intent.intent_id);
               ("workload_profile", `String "coding_task");
               ("stage", `String "verify");
               ("depends_on_operation_ids", `List [ `String shared_upstream.operation_id ]);
             ]));
      let forecast =
        unwrap_ok
          (Command_plane_v2.intent_forecast_json config intent.intent_id ())
      in
      Alcotest.(check (list string)) "blocked_by empty when upstream already completed" []
        (forecast |> Yojson.Safe.Util.member "blocked_by"
       |> Yojson.Safe.Util.to_list |> List.map Yojson.Safe.Util.to_string);
      Alcotest.(check bool) "no verification gap risk" false
        (forecast |> Yojson.Safe.Util.member "risk_flags"
       |> Yojson.Safe.Util.to_list
       |> List.exists (fun value ->
              String.equal (Yojson.Safe.Util.to_string value) "verification_gap")))
