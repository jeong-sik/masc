(** Contract_composer unit tests *)

open Alcotest
module CC = Masc_mcp.Contract_composer
module CB = Masc_mcp.Cdal_contract_bridge
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

let make_keeper_meta ?(name = "keeper-test") ?(trace_id = "trace-test")
    ?(short_goal = "stabilize proof spine") ?(scope_kind = "local")
    ?(execution_scope = "observe_only") ?(allowed_paths = []) () =
  match Masc_mcp.Keeper_types.meta_of_json
          (`Assoc
            [
              ("name", `String name);
              ("agent_name", `String name);
              ("trace_id", `String trace_id);
              ("short_goal", `String short_goal);
              ("scope_kind", `String scope_kind);
              ("execution_scope", `String execution_scope);
              ( "allowed_paths",
                `List (List.map (fun path -> `String path) allowed_paths) );
            ])
  with
  | Ok meta -> meta
  | Error err -> fail err

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

let test_keeper_bridge_compose_observe () =
  let meta =
    make_keeper_meta ~scope_kind:"local" ~execution_scope:"observe_only" ()
  in
  let rc = CB.of_keeper_meta meta in
  check string "observe_only -> diagnose" "diagnose"
    (EM.to_string rc.runtime_constraints.requested_execution_mode);
  check string "observe_only -> low" "low"
    (Agent_sdk.Risk_class.to_string rc.runtime_constraints.risk_class);
  check (list string) "observe_only allowed mutations"
    [] rc.runtime_constraints.allowed_mutations

let test_keeper_bridge_compose_allowed_paths () =
  let meta =
    make_keeper_meta ~scope_kind:"local"
      ~execution_scope:"limited_code_change"
      ~allowed_paths:[ "/tmp/demo" ] ()
  in
  let rc = CB.of_keeper_meta meta in
  let criteria = rc.eval_criteria in
  let open Yojson.Safe.Util in
  check string "local -> draft" "draft"
    (EM.to_string rc.runtime_constraints.requested_execution_mode);
  check (list string) "allowed_paths still workspace_only"
    [ "workspace_only" ] rc.runtime_constraints.allowed_mutations;
  check string "keeper criteria name" "keeper-test"
    (criteria |> member "keeper_name" |> to_string)

let () =
  Eio_main.run @@ fun _env ->
  run "Contract_composer" [
    "compose", [
      "basic compose", `Quick, test_compose_basic;
      "zero budget → Draft", `Quick, test_compose_zero_budget;
      "high risk → review required", `Quick, test_compose_high_risk_review;
      "eval_criteria fields", `Quick, test_eval_criteria_fields;
      "keeper bridge observe", `Quick, test_keeper_bridge_compose_observe;
      "keeper bridge allowed_paths", `Quick,
      test_keeper_bridge_compose_allowed_paths;
    ];
  ]
