open Masc_mcp

let expect_error ~label ~expected = function
  | Error message -> Alcotest.(check string) label expected message
  | Ok _ -> Alcotest.fail (label ^ ": expected error")

let with_test_config f =
  let base = Test_command_plane_v2_support.temp_dir () in
  Fun.protect
    ~finally:(fun () -> Test_command_plane_v2_support.cleanup_dir base)
    (fun () -> Test_command_plane_v2_support.with_eio_test base f)

let test_dispatch_assign_requires_operation_id () =
  with_test_config @@ fun config ->
  expect_error
    ~label:"dispatch_assign missing operation_id"
    ~expected:"operation_id is required. Call masc_operation_start first."
    (Command_plane_v2.dispatch_assign_json config ~actor:"owner"
       (`Assoc [ ("target_unit_id", `String "platoon-alpha") ]))

let test_dispatch_escalate_requires_operation_id () =
  with_test_config @@ fun config ->
  expect_error
    ~label:"dispatch_escalate missing operation_id"
    ~expected:"operation_id is required. Call masc_operation_start first."
    (Command_plane_v2.dispatch_escalate_json config ~actor:"owner" (`Assoc []))

let test_unit_reparent_requires_unit_id () =
  with_test_config @@ fun config ->
  expect_error
    ~label:"unit_reparent missing unit_id"
    ~expected:"unit_id is required"
    (Command_plane_v2.unit_reparent_json config ~actor:"owner"
       (`Assoc [ ("parent_unit_id", `String "company-main") ]))

let test_policy_update_requires_unit_id () =
  with_test_config @@ fun config ->
  expect_error
    ~label:"policy_update missing unit_id"
    ~expected:"unit_id is required"
    (Command_plane_v2.policy_update_json config ~actor:"owner"
       (`Assoc [ ("policy", `Assoc []); ("budget", `Assoc []) ]))

let test_start_operation_rejects_unit_policy_model_mismatch () =
  with_test_config @@ fun config ->
  let owner = "owner-root-node" in
  let alpha_lead = "alpha-lead-node" in
  let alpha_two = "alpha-two-node" in
  let research_lead = "research-lead-node" in
  Test_command_plane_v2_support.setup_company_and_platoon config ~owner
    ~alpha_lead ~alpha_two;
  ignore (Room.join config ~agent_name:research_lead ~capabilities:[] ());
  ignore
    (Test_command_plane_v2_support.unwrap_ok
       (Command_plane_v2.unit_update_json config ~actor:"owner"
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
                    `String research_lead;
                  ] );
            ])));
  ignore
    (Test_command_plane_v2_support.unwrap_ok
       (Command_plane_v2.unit_update_json config ~actor:"owner"
          (`Assoc
            [
              ("unit_id", `String "squad-research");
              ("kind", `String "squad");
              ("label", `String "Research Squad");
              ("parent_unit_id", `String "platoon-alpha");
              ("leader_id", `String research_lead);
              ("roster", `List [ `String research_lead ]);
              ( "capability_profile",
                `List [ `String "model:glm"; `String "runtime:codex" ] );
              ( "policy",
                `Assoc
                  [ ("model_allowlist", `List [ `String "qwen" ]) ] );
            ])));
  expect_error
    ~label:"start_operation policy model mismatch"
    ~expected:
      "assigned unit policy blocks research_pipeline/normalize: no allowed model capability remains for unit squad-research"
    (Command_plane_v2.start_operation config ~actor:"owner"
       (`Assoc
         [
           ("assigned_unit_id", `String "squad-research");
           ("objective", `String "Normalize research artifacts");
           ("workload_profile", `String "research_pipeline");
           ("stage", `String "normalize");
           ("search_strategy", `String "best_first_v1");
         ]))
