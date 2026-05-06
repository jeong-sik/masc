open Alcotest

module Catalog = Masc_mcp.Masc_contract_catalog
module Json = Yojson.Safe.Util

let names specs = List.map (fun (spec : Catalog.contract_spec) -> spec.name) specs

let test_all_contract_names () =
  check
    (list string)
    "catalog names"
    [ "masc-cascade-critical"; "masc-keeper-lifecycle"; "masc-dashboard-telemetry" ]
    (names Catalog.all)
;;

let test_cascade_contract_shape () =
  let spec = Catalog.cascade_critical in
  check string "name" "masc-cascade-critical" spec.name;
  check
    (list string)
    "invariants"
    [ "reaction_chain_never_empty"
    ; "provider_health_min_threshold"
    ; "cascade_step_timeout_max_5s"
    ; "keeper_stall_max_60s"
    ]
    spec.invariants;
  check
    bool
    "critical risk"
    true
    (Agent_sdk.Risk_class.equal spec.risk_class Agent_sdk.Risk_class.Critical);
  check
    bool
    "execute mode"
    true
    (Agent_sdk.Execution_mode.equal
       spec.requested_execution_mode
       Agent_sdk.Execution_mode.Execute)
;;

let test_find_by_name () =
  match Catalog.find "masc-keeper-lifecycle" with
  | Some spec ->
    check string "description" "Keeper의 생명주기 관리 계약" spec.description;
    check
      bool
      "high risk"
      true
      (Agent_sdk.Risk_class.equal spec.risk_class Agent_sdk.Risk_class.High)
  | None -> fail "expected keeper lifecycle contract"
;;

let test_eval_criteria_carries_metadata () =
  let json = Catalog.eval_criteria Catalog.dashboard_telemetry in
  check
    string
    "contract_name"
    "masc-dashboard-telemetry"
    Json.(json |> member "contract_name" |> to_string);
  check
    (list string)
    "invariants"
    [ "all_keeper_states_telemetryzed"
    ; "operator_nudge_response_5s"
    ; "cascade_hits_visible_realtime"
    ]
    Json.(json |> member "invariants" |> to_list |> List.map to_string)
;;

let test_risk_contract_projection_is_deterministic () =
  let first = Catalog.to_risk_contract Catalog.keeper_lifecycle in
  let second = Catalog.to_risk_contract Catalog.keeper_lifecycle in
  check
    string
    "contract id deterministic"
    (Agent_sdk.Risk_contract.contract_id first)
    (Agent_sdk.Risk_contract.contract_id second);
  check
    (list string)
    "allowed mutations"
    [ "keeper_lifecycle_update"; "supervisor_restart"; "telemetry_emit" ]
    first.runtime_constraints.allowed_mutations;
  check
    (option string)
    "review requirement"
    (Some "supervisor_review")
    first.runtime_constraints.review_requirement
;;

let () =
  run
    "masc_contract_catalog"
    [ ( "catalog"
      , [ test_case "names" `Quick test_all_contract_names
        ; test_case "cascade shape" `Quick test_cascade_contract_shape
        ; test_case "find" `Quick test_find_by_name
        ; test_case "eval criteria" `Quick test_eval_criteria_carries_metadata
        ; test_case
            "risk contract projection deterministic"
            `Quick
            test_risk_contract_projection_is_deterministic
        ] )
    ]
;;
