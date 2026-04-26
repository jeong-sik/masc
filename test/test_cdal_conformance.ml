(** CDAL conformance tests — verify OAS JSON fixtures decode correctly.

    These tests ensure MASC can consume OAS-produced proof bundles
    and risk contracts without schema drift. *)

open Alcotest
module RC = Agent_sdk.Risk_contract
module Proof = Agent_sdk.Cdal_proof
module EM = Agent_sdk.Execution_mode
module RK = Agent_sdk.Risk_class

(* Inline fixtures — avoids CWD issues in CI where dune runs tests
   from _build/default/test/ rather than the repo root. Canonical
   copies live in fixtures/cdal/ for external tooling. *)

let risk_contract_v1_json =
  {|{
  "runtime_constraints": {
    "requested_execution_mode": "draft",
    "risk_class": "medium",
    "allowed_mutations": ["keeper_fs_edit", "keeper_write"],
    "review_requirement": null
  },
  "eval_criteria": {
    "success_criteria": ["tests pass", "no lint errors"],
    "required_evidence": ["src/main.ml", "test/test_main.ml"],
    "contract_id": "dc-fixture-001",
    "evaluator_cascade": "cross_verifier"
  }
}|}
;;

let cdal_proof_v1_json =
  {|{
  "schema_version": 1,
  "run_id": "cdal-fixture-abc123",
  "contract_id": "md5:a1b2c3d4e5f6",
  "requested_execution_mode": "execute",
  "effective_execution_mode": "draft",
  "mode_decision_source": "risk_class_downgrade",
  "risk_class": "high",
  "provider_snapshot": {
    "provider_name": "glm",
    "model_id": "glm-4-plus",
    "api_version": null
  },
  "capability_snapshot": {
    "tools": ["keeper_read", "keeper_fs_edit", "keeper_bash"],
    "mcp_servers": [],
    "max_turns": 3,
    "max_tokens": null,
    "thinking_enabled": null
  },
  "tool_trace_refs": [
    "proof-store://cdal-fixture-abc123/tool_traces/trace-001"
  ],
  "raw_evidence_refs": [],
  "checkpoint_ref": null,
  "result_status": "completed",
  "started_at": 1711900000.0,
  "ended_at": 1711900120.0
}|}
;;

(* --- Risk Contract Fixture --- *)

let test_risk_contract_fixture () =
  let json = Yojson.Safe.from_string risk_contract_v1_json in
  match RC.of_yojson json with
  | Ok rc ->
    check
      string
      "requested_mode"
      "draft"
      (EM.to_string rc.runtime_constraints.requested_execution_mode);
    check string "risk_class" "medium" (RK.to_string rc.runtime_constraints.risk_class);
    check
      (list string)
      "allowed_mutations"
      [ "keeper_fs_edit"; "keeper_write" ]
      rc.runtime_constraints.allowed_mutations;
    check
      bool
      "review_requirement is None"
      true
      (Option.is_none rc.runtime_constraints.review_requirement);
    (* eval_criteria is opaque JSON — just verify it roundtrips *)
    let contract_id_opt =
      Yojson.Safe.Util.(member "contract_id" rc.eval_criteria |> to_string_option)
    in
    check
      (option string)
      "eval_criteria.contract_id"
      (Some "dc-fixture-001")
      contract_id_opt
  | Error msg -> fail (Printf.sprintf "risk_contract decode failed: %s" msg)
;;

(* --- Cdal Proof Fixture --- *)

let test_cdal_proof_fixture () =
  let json = Yojson.Safe.from_string cdal_proof_v1_json in
  match Proof.of_json json with
  | Ok proof ->
    check int "schema_version" 1 proof.schema_version;
    check string "run_id" "cdal-fixture-abc123" proof.run_id;
    check string "contract_id" "md5:a1b2c3d4e5f6" proof.contract_id;
    check string "requested_mode" "execute" (EM.to_string proof.requested_execution_mode);
    check string "effective_mode" "draft" (EM.to_string proof.effective_execution_mode);
    check string "mode_decision_source" "risk_class_downgrade" proof.mode_decision_source;
    check string "risk_class" "high" (RK.to_string proof.risk_class);
    check string "provider" "glm" proof.provider_snapshot.provider_name;
    check string "model_id" "glm-4-plus" proof.provider_snapshot.model_id;
    check int "tool_trace_refs count" 1 (List.length proof.tool_trace_refs);
    check bool "result_status is Completed" true (proof.result_status = Proof.Completed)
  | Error msg -> fail (Printf.sprintf "cdal_proof decode failed: %s" msg)
;;

(* --- Schema Version Mismatch --- *)

let test_schema_version_mismatch () =
  let json =
    `Assoc
      [ "schema_version", `Int 999
      ; "run_id", `String "test"
      ; "contract_id", `String "test"
      ; "requested_execution_mode", `String "execute"
      ; "effective_execution_mode", `String "execute"
      ; "mode_decision_source", `String "passthrough"
      ; "risk_class", `String "low"
      ; ( "provider_snapshot"
        , `Assoc
            [ "provider_name", `String "test"
            ; "model_id", `String "test"
            ; "api_version", `Null
            ] )
      ; ( "capability_snapshot"
        , `Assoc
            [ "tools", `List []
            ; "mcp_servers", `List []
            ; "max_turns", `Int 10
            ; "max_tokens", `Null
            ; "thinking_enabled", `Null
            ] )
      ; "tool_trace_refs", `List []
      ; "raw_evidence_refs", `List []
      ; "checkpoint_ref", `Null
      ; "result_status", `String "completed"
      ; "started_at", `Float 0.0
      ; "ended_at", `Float 0.0
      ]
  in
  match Proof.of_json json with
  | Ok proof ->
    (* OAS currently accepts any schema_version — the consumer
       should check. Verify the value is preserved for detection. *)
    check int "schema_version preserved" 999 proof.schema_version
  | Error _ ->
    (* If OAS rejects unknown versions, that is also acceptable. *)
    ()
;;

let () =
  Eio_main.run
  @@ fun _env ->
  run
    "CDAL_conformance"
    [ "risk_contract", [ "decode fixture v1", `Quick, test_risk_contract_fixture ]
    ; ( "cdal_proof"
      , [ "decode fixture v1", `Quick, test_cdal_proof_fixture
        ; "schema version mismatch", `Quick, test_schema_version_mismatch
        ] )
    ]
;;
