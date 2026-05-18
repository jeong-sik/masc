open Alcotest
open Masc_mcp

module RC = Masc_mcp_cdal_runtime.Risk_contract
module EM = Masc_mcp_cdal_runtime.Execution_mode
module RK = Masc_mcp_cdal_runtime.Risk_class
module CP = Masc_mcp_cdal_runtime.Cdal_proof

let make_meta ?(name = "cdal-keeper") ?current_task_id () =
  let fields =
    [ "name", `String name
    ; "agent_name", `String (name ^ "-agent")
    ; "trace_id", `String "cdal-contract-trace"
    ; "sandbox_profile", `String "local"
    ; "network_mode", `String "none"
    ; "allowed_paths", `List [ `String "/workspace/project" ]
    ; "active_goal_ids", `List [ `String "goal-cdal" ]
    ; "tool_access", Keeper_types.tool_access_to_json (Keeper_types.Custom [ "keeper_bash" ])
    ]
  in
  let fields =
    match current_task_id with
    | None -> fields
    | Some task_id -> ("current_task_id", `String task_id) :: fields
  in
  match Masc_test_deps.meta_of_json_fixture (`Assoc fields) with
  | Ok meta -> meta
  | Error err -> failwith ("make_meta failed: " ^ err)
;;

let require_contract meta =
  match Keeper_cdal_contract.of_keeper_meta meta with
  | Some contract -> contract
  | None -> fail "expected keeper CDAL contract"
;;

let member key = function
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some value -> value
     | None -> failf "missing JSON member %s" key)
  | json -> failf "expected object while reading %s, got %s" key (Yojson.Safe.to_string json)
;;

let check_json_string key expected json =
  match member key json with
  | `String actual -> check string key expected actual
  | value -> failf "expected %s to be string, got %s" key (Yojson.Safe.to_string value)
;;

let check_json_list key expected json =
  match member key json with
  | `List values ->
    let actual =
      List.map
        (function
          | `String value -> value
          | value -> failf "expected %s entries to be strings, got %s" key (Yojson.Safe.to_string value))
        values
    in
    check (list string) key expected actual
  | value -> failf "expected %s to be list, got %s" key (Yojson.Safe.to_string value)
;;

let make_proof run_id : CP.t =
  { schema_version = CP.schema_version_current
  ; run_id
  ; contract_id = "md5:test"
  ; requested_execution_mode = EM.Execute
  ; effective_execution_mode = EM.Execute
  ; mode_decision_source = "passthrough"
  ; risk_class = RK.Low
  ; provider_snapshot =
      { provider_name = "test"; model_id = "test-model"; api_version = None }
  ; capability_snapshot =
      { tools = []
      ; mcp_servers = []
      ; max_turns = 8
      ; max_tokens = Some 4096
      ; thinking_enabled = None
      }
  ; tool_trace_refs = []
  ; raw_evidence_refs = []
  ; checkpoint_ref = None
  ; result_status = CP.Completed
  ; started_at = 1000.0
  ; ended_at = 1001.0
  ; scope = None
  }
;;

let check_selected_proof_run_id label expected selected =
  match selected with
  | Some proof -> check string label expected proof.CP.run_id
  | None -> failf "expected %s proof" label
;;

let test_keeper_meta_projects_capture_only_contract () =
  let meta = make_meta ~current_task_id:"task-cdal-001" () in
  let contract = require_contract meta in
  let constraints = contract.RC.runtime_constraints in
  check string "requested mode" "execute" (EM.to_string constraints.requested_execution_mode);
  check string "risk class" "low" (RK.to_string constraints.risk_class);
  check (list string) "allowed mutations" [] constraints.allowed_mutations;
  check (option string) "review requirement" None constraints.review_requirement;
  let criteria = contract.RC.eval_criteria in
  check_json_string "kind" "keeper_turn_capture_v1" criteria;
  check_json_string "keeper_name" "cdal-keeper" criteria;
  check_json_string "agent_name" "cdal-keeper-agent" criteria;
  check_json_string "sandbox_profile" "local" criteria;
  check_json_string "network_mode" "none" criteria;
  check_json_string "current_task_id_at_start" "task-cdal-001" criteria;
  check_json_list "allowed_paths" [ "/workspace/project" ] criteria;
  check_json_list "active_goal_ids" [ "goal-cdal" ] criteria;
  match member "tool_access" criteria with
  | `Assoc _ as tool_access ->
    check_json_string "kind" "custom" tool_access;
    check_json_list "tools" [ "keeper_bash" ] tool_access
  | value -> failf "expected tool_access object, got %s" (Yojson.Safe.to_string value)
;;

let test_contract_id_is_stable_for_same_meta () =
  let meta = make_meta () in
  let first = require_contract meta in
  let second = require_contract meta in
  check string "contract id" (RC.contract_id first) (RC.contract_id second)
;;

let test_select_cdal_proof_prefers_result_proof () =
  let result_proof = make_proof "result-proof" in
  let captured_proof = make_proof "captured-proof" in
  Keeper_agent_run.For_testing.select_cdal_proof
    ~result_proof:(Some result_proof)
    ~captured_proof:(Some captured_proof)
  |> check_selected_proof_run_id "selected proof" "result-proof"
;;

let test_select_cdal_proof_falls_back_to_captured_proof () =
  let captured_proof = make_proof "captured-proof" in
  Keeper_agent_run.For_testing.select_cdal_proof
    ~result_proof:None
    ~captured_proof:(Some captured_proof)
  |> check_selected_proof_run_id "selected proof" "captured-proof"
;;

let tool_call ?task_id tool_name : Keeper_agent_run.tool_call_detail =
  { tool_name
  ; provider = "runtime"
  ; outcome = "ok"
  ; latency_ms = 1.0
  ; task_id
  ; route_evidence = None
  }
;;

let test_cdal_task_id_prefers_current_task () =
  let selected =
    Keeper_agent_run.For_testing.cdal_task_id_for_verdict
      ~current_task_id:(Some "task-current")
      ~tool_calls:[ tool_call ~task_id:"task-tool" "masc_transition" ]
  in
  check (option string) "selected task id" (Some "task-current") selected
;;

let test_cdal_task_id_falls_back_to_tool_target () =
  let selected =
    Keeper_agent_run.For_testing.cdal_task_id_for_verdict
      ~current_task_id:None
      ~tool_calls:
        [ tool_call "keeper_status"
        ; tool_call ~task_id:"task-approve-target" "masc_transition"
        ]
  in
  check
    (option string)
    "selected task id"
    (Some "task-approve-target")
    selected
;;

let () =
  Alcotest.run
    "keeper_cdal_contract"
    [ ( "projection"
      , [ test_case
            "keeper meta projects capture-only contract"
            `Quick
            test_keeper_meta_projects_capture_only_contract
        ; test_case
            "contract id stable for same keeper meta"
            `Quick
            test_contract_id_is_stable_for_same_meta
        ] )
    ; ( "run"
      , [ test_case
            "selects result proof before captured proof"
            `Quick
            test_select_cdal_proof_prefers_result_proof
        ; test_case
            "falls back to captured proof"
            `Quick
            test_select_cdal_proof_falls_back_to_captured_proof
        ; test_case
            "prefers current task id for verdict scope"
            `Quick
            test_cdal_task_id_prefers_current_task
        ; test_case
            "falls back to lifecycle tool target for verdict scope"
            `Quick
            test_cdal_task_id_falls_back_to_tool_target
        ] )
    ]
;;
