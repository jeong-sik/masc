(** Contract_risk unit tests *)

open Alcotest

let make_dc ?(acceptance_checks = []) ?(required_artifacts = [])
    ?(repair_budget = 3) () : Team_session_types.delivery_contract =
  { contract_id = "test-dc-001";
    summary = "test contract";
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

let check_risk msg expected actual =
  check string msg
    (Agent_sdk.Risk_class.to_string expected)
    (Agent_sdk.Risk_class.to_string actual)

(* --- Axis tests --- *)

let test_low_risk () =
  let dc = make_dc ~required_artifacts:["readme"] ~repair_budget:5 () in
  let tools = ["keeper_read"; "keeper_board_list"] in
  let risk =
    Masc_mcp.Contract_risk.of_delivery_contract ~execution_scope:None
      ~delivery_contract:dc ~tool_names:tools
  in
  check_risk "read-only + generous budget = Low" Agent_sdk.Risk_class.Low risk

let test_medium_risk () =
  let dc = make_dc ~required_artifacts:["src/main.ml"; "test/test.ml"]
    ~repair_budget:3 () in
  let tools = ["keeper_fs_edit"; "keeper_read"] in
  let risk =
    Masc_mcp.Contract_risk.of_delivery_contract ~execution_scope:None
      ~delivery_contract:dc ~tool_names:tools
  in
  check_risk "workspace-mutating + 2 artifacts = Medium"
    Agent_sdk.Risk_class.Medium risk

let test_high_risk () =
  (* High = exactly 1 max axis. workspace-mutating + zero budget:
     blast_radius=Medium (fs_edit + 1 artifact), irreversibility=Partial,
     recovery_cost=Rc_high (budget=0) → 1 max axis = High *)
  let dc = make_dc ~required_artifacts:["src/main.ml"] ~repair_budget:0 () in
  let tools = ["keeper_fs_edit"; "keeper_read"] in
  let risk =
    Masc_mcp.Contract_risk.of_delivery_contract ~execution_scope:None
      ~delivery_contract:dc ~tool_names:tools
  in
  check_risk "workspace-mutating + zero budget = High" Agent_sdk.Risk_class.High risk

let test_critical_risk () =
  let dc = make_dc ~required_artifacts:["a";"b";"c";"d";"e"]
    ~repair_budget:0 () in
  let tools = ["keeper_bash"; "keeper_github"] in
  let risk =
    Masc_mcp.Contract_risk.of_delivery_contract ~execution_scope:None
      ~delivery_contract:dc ~tool_names:tools
  in
  check_risk "external tools + zero budget = Critical"
    Agent_sdk.Risk_class.Critical risk

(* --- Edge cases --- *)

let test_empty_tools () =
  let dc = make_dc () in
  let risk =
    Masc_mcp.Contract_risk.of_delivery_contract ~execution_scope:None
      ~delivery_contract:dc ~tool_names:[]
  in
  check_risk "no tools + generous budget = Low" Agent_sdk.Risk_class.Low risk

let test_axes_assessment () =
  let dc = make_dc ~required_artifacts:["a";"b"] ~repair_budget:1 () in
  let tools = ["keeper_fs_edit"] in
  let axes =
    Masc_mcp.Contract_risk.assess ~execution_scope:None ~delivery_contract:dc
      ~tool_names:tools
  in
  check string "blast_radius medium"
    "Medium"
    (match axes.blast_radius with Small -> "Small" | Medium -> "Medium" | Large -> "Large");
  check string "irreversibility partial"
    "Partial"
    (match axes.irreversibility with Reversible -> "Reversible" | Partial -> "Partial" | Irreversible -> "Irreversible");
  check string "recovery_cost medium"
    "Rc_medium"
    (match axes.recovery_cost with Rc_low -> "Rc_low" | Rc_medium -> "Rc_medium" | Rc_high -> "Rc_high")

let test_shell_exec_is_external_effect () =
  let dc = make_dc ~required_artifacts:["readme"] ~repair_budget:3 () in
  let risk =
    Masc_mcp.Contract_risk.of_delivery_contract ~execution_scope:None
      ~delivery_contract:dc
      ~tool_names:["shell_exec"]
  in
  check_risk "shell_exec raises risk to critical" Agent_sdk.Risk_class.Critical
    risk

let test_observe_only_shell_exec_is_read_only () =
  let dc = make_dc ~required_artifacts:["readme"] ~repair_budget:3 () in
  let risk =
    Masc_mcp.Contract_risk.of_delivery_contract ~delivery_contract:dc
      ~tool_names:["shell_exec"]
      ~execution_scope:(Some Team_session_types.Observe_only)
  in
  check_risk "observe_only shell_exec stays low risk" Agent_sdk.Risk_class.Low
    risk

let test_observe_only_file_write_is_read_only () =
  let dc = make_dc ~required_artifacts:["readme"] ~repair_budget:3 () in
  let risk =
    Masc_mcp.Contract_risk.of_delivery_contract ~execution_scope:(Some Team_session_types.Observe_only)
      ~delivery_contract:dc ~tool_names:["file_write"]
  in
  check_risk "observe_only file_write stays low risk" Agent_sdk.Risk_class.Low
    risk

let test_file_write_is_workspace_mutation () =
  let dc = make_dc ~required_artifacts:["readme"] ~repair_budget:3 () in
  let risk =
    Masc_mcp.Contract_risk.of_delivery_contract ~execution_scope:None
      ~delivery_contract:dc
      ~tool_names:["file_write"]
  in
  check_risk "file_write raises risk to medium" Agent_sdk.Risk_class.Medium
    risk

let () =
  Eio_main.run @@ fun _env ->
  run "Contract_risk" [
    "risk_class", [
      "low risk (read-only)", `Quick, test_low_risk;
      "medium risk (workspace mutating)", `Quick, test_medium_risk;
      "high risk (external effect)", `Quick, test_high_risk;
      "critical risk (multi-axis max)", `Quick, test_critical_risk;
      "empty tools", `Quick, test_empty_tools;
      "axes assessment", `Quick, test_axes_assessment;
      "shell_exec is external effect", `Quick, test_shell_exec_is_external_effect;
      "observe_only shell_exec stays read-only", `Quick,
      test_observe_only_shell_exec_is_read_only;
      "observe_only file_write stays read-only", `Quick,
      test_observe_only_file_write_is_read_only;
      "file_write is workspace mutation", `Quick, test_file_write_is_workspace_mutation;
    ];
  ]
