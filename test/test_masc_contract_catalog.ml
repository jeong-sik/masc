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
    (Masc_mcp_cdal_runtime.Risk_class.equal spec.risk_class Masc_mcp_cdal_runtime.Risk_class.Critical);
  check
    bool
    "execute mode"
    true
    (Masc_mcp_cdal_runtime.Execution_mode.equal
       spec.requested_execution_mode
       Masc_mcp_cdal_runtime.Execution_mode.Execute)
;;

let test_find_by_name () =
  match Catalog.find "masc-keeper-lifecycle" with
  | Some spec ->
    check string "description" "Keeper의 생명주기 관리 계약" spec.description;
    check
      bool
      "high risk"
      true
      (Masc_mcp_cdal_runtime.Risk_class.equal spec.risk_class Masc_mcp_cdal_runtime.Risk_class.High)
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
    [ "all_keeper_states_telemetry_emitted"
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
    (Masc_mcp_cdal_runtime.Risk_contract.contract_id first)
    (Masc_mcp_cdal_runtime.Risk_contract.contract_id second);
  check
    (list string)
    "allowed mutations"
    [ "keeper_lifecycle_update"; "supervisor_restart"; "telemetry_emit" ]
    first.runtime_constraints.allowed_mutations;
  check
    (option string)
    "review requirement"
    None
    first.runtime_constraints.review_requirement
;;

let test_risk_contract_ids_are_pinned () =
  let ids =
    Catalog.all
    |> List.map (fun spec -> Masc_mcp_cdal_runtime.Risk_contract.contract_id (Catalog.to_risk_contract spec))
  in
  check
    (list string)
    "contract IDs frozen"
    [ "md5:49075d5b129328dece2801643272d7c9"
    ; "md5:2c09e6f101e138b52fdb86c9fde6ac4f"
    ; "md5:71b3d1fc918d95ebd6362152e5e3eeea"
    ]
    ids
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
        ; test_case "risk contract IDs are pinned" `Quick test_risk_contract_ids_are_pinned
        ] )
    ]
;;
