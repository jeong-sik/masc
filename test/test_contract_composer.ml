(** Contract_composer unit tests *)

open Alcotest
module CC = Masc_mcp.Contract_composer
module RC = Agent_sdk.Risk_contract
module EM = Agent_sdk.Execution_mode

let make_dc ?(acceptance_checks = ["tests pass"]) ?(required_artifacts = ["main.ml"])
    ?(repair_budget = 3) () : Team_session_types.delivery_contract =
  { contract_id = "dc-test";
    summary = "test";
    acceptance_checks;
    required_artifacts;
    repair_budget;
    generator_roles = ["execute"];
    evaluator_role = None;
    evaluator_cascade = "cross_verifier";
    evidence_refs = [];
    updated_by = "test";
    updated_at_iso = "2026-01-01T00:00:00Z";
  }

let test_compose_basic () =
  let dc = make_dc () in
  let tools = ["keeper_read"; "keeper_fs_edit"] in
  let rc = CC.compose ~delivery_contract:dc ~tool_names:tools in
  check string "requested_mode Execute (budget > 0)"
    "execute"
    (EM.to_string rc.runtime_constraints.requested_execution_mode);
  check (list string) "allowed_mutations"
    ["keeper_fs_edit"]
    rc.runtime_constraints.allowed_mutations;
  check bool "review_requirement is None"
    true (Option.is_none rc.runtime_constraints.review_requirement)

let test_compose_zero_budget () =
  let dc = make_dc ~repair_budget:0 () in
  let tools = ["keeper_read"] in
  let rc = CC.compose ~delivery_contract:dc ~tool_names:tools in
  check string "requested_mode Draft (budget = 0)"
    "draft"
    (EM.to_string rc.runtime_constraints.requested_execution_mode)

let test_compose_high_risk_review () =
  let dc = make_dc ~repair_budget:0 () in
  let tools = ["keeper_fs_edit"] in
  let rc = CC.compose ~delivery_contract:dc ~tool_names:tools in
  check string "risk_class high"
    "high"
    (Agent_sdk.Risk_class.to_string rc.runtime_constraints.risk_class);
  check (option string) "review_requirement set"
    (Some "human_review")
    rc.runtime_constraints.review_requirement

let test_eval_criteria_fields () =
  let dc = make_dc ~acceptance_checks:["lint"; "test"]
    ~required_artifacts:["a.ml"; "b.ml"] () in
  let rc = CC.compose ~delivery_contract:dc ~tool_names:[] in
  let open Yojson.Safe.Util in
  let criteria = rc.eval_criteria in
  let success = criteria |> member "success_criteria" |> to_list
    |> List.map to_string in
  let evidence = criteria |> member "required_evidence" |> to_list
    |> List.map to_string in
  check (list string) "success_criteria" ["lint"; "test"] success;
  check (list string) "required_evidence" ["a.ml"; "b.ml"] evidence;
  check string "contract_id" "dc-test"
    (criteria |> member "contract_id" |> to_string)

let () =
  Eio_main.run @@ fun _env ->
  run "Contract_composer" [
    "compose", [
      "basic compose", `Quick, test_compose_basic;
      "zero budget → Draft", `Quick, test_compose_zero_budget;
      "high risk → review required", `Quick, test_compose_high_risk_review;
      "eval_criteria fields", `Quick, test_eval_criteria_fields;
    ];
  ]
