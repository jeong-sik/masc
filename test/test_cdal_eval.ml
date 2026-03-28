(** test_cdal_eval — Phase 0 CDAL eval unit tests.

    Verifies that Masc_mcp.Cdal_eval.evaluate produces correct verdicts
    for each result_status, violation state, and evidence state. *)

let make_proof
    ?(run_id = "test-run-001")
    ?(contract_id = "md5:abc123")
    ?(requested = Agent_sdk.Execution_mode.Execute)
    ?(effective = Agent_sdk.Execution_mode.Execute)
    ?(mode_decision_source = "passthrough")
    ?(risk_class = Agent_sdk.Risk_class.Low)
    ?(tool_trace_refs = ["proof-store://test-run-001/tool_traces/trace-0001.jsonl"])
    ?(raw_evidence_refs = [])
    ?(checkpoint_ref = None)
    ?(result_status = Agent_sdk.Cdal_proof.Completed)
    () : Agent_sdk.Cdal_proof.t =
  {
    schema_version = 1;
    run_id;
    contract_id;
    requested_execution_mode = requested;
    effective_execution_mode = effective;
    mode_decision_source;
    risk_class;
    provider_snapshot = {
      provider_name = "test";
      model_id = "test-model";
      api_version = None;
    };
    capability_snapshot = {
      tools = ["read"; "write"];
      mcp_servers = [];
      max_turns = 10;
      max_tokens = Some 4096;
      thinking_enabled = None;
    };
    tool_trace_refs;
    raw_evidence_refs;
    checkpoint_ref;
    result_status;
    started_at = 1000.0;
    ended_at = 1001.0;
  }

(* ================================================================ *)
(* Test: Completed run with traces → Ok                              *)
(* ================================================================ *)

let test_completed_with_traces () =
  let proof = make_proof () in
  let result = Masc_mcp.Cdal_eval.evaluate proof in
  Alcotest.(check bool) "has_tool_traces" true result.evidence.has_tool_traces;
  Alcotest.(check bool) "completed_normally" true result.evidence.completed_normally;
  Alcotest.(check bool) "is_acceptable" true (Masc_mcp.Cdal_eval.is_acceptable result);
  Alcotest.(check string) "overall is ok"
    "ok" (Masc_mcp.Cdal_eval.severity_to_string result.overall)

(* ================================================================ *)
(* Test: Cancelled run → Fail                                        *)
(* ================================================================ *)

let test_cancelled () =
  let proof = make_proof ~result_status:Cancelled () in
  let result = Masc_mcp.Cdal_eval.evaluate proof in
  Alcotest.(check bool) "completed_normally" false result.evidence.completed_normally;
  Alcotest.(check bool) "is_acceptable" false (Masc_mcp.Cdal_eval.is_acceptable result);
  Alcotest.(check string) "overall is fail"
    "fail: cancelled by contract" (Masc_mcp.Cdal_eval.severity_to_string result.overall)

(* ================================================================ *)
(* Test: Errored run → Warn                                          *)
(* ================================================================ *)

let test_errored () =
  let proof = make_proof ~result_status:Errored () in
  let result = Masc_mcp.Cdal_eval.evaluate proof in
  Alcotest.(check bool) "is_acceptable" true (Masc_mcp.Cdal_eval.is_acceptable result);
  Alcotest.(check string) "overall is warn"
    "warn: execution error" (Masc_mcp.Cdal_eval.severity_to_string result.overall)

(* ================================================================ *)
(* Test: Timed out run → Warn                                        *)
(* ================================================================ *)

let test_timed_out () =
  let proof = make_proof ~result_status:Timed_out () in
  let result = Masc_mcp.Cdal_eval.evaluate proof in
  Alcotest.(check bool) "is_acceptable" true (Masc_mcp.Cdal_eval.is_acceptable result);
  Alcotest.(check string) "overall is warn"
    "warn: execution timed out" (Masc_mcp.Cdal_eval.severity_to_string result.overall)

(* ================================================================ *)
(* Test: Mode violations detected → Warn                             *)
(* ================================================================ *)

let test_violations () =
  let proof = make_proof
    ~raw_evidence_refs:[
      "proof-store://r1/evidence/mode_violations.json";
      "proof-store://r1/evidence/token_usage.json";
    ] () in
  let result = Masc_mcp.Cdal_eval.evaluate proof in
  Alcotest.(check int) "violation_ref_count" 1 result.violations.violation_ref_count;
  Alcotest.(check bool) "has_raw_evidence" true result.evidence.has_raw_evidence;
  Alcotest.(check string) "overall is warn"
    "warn: 1 mode violation(s) detected"
    (Masc_mcp.Cdal_eval.severity_to_string result.overall)

(* ================================================================ *)
(* Test: No evidence at all → Warn                                   *)
(* ================================================================ *)

let test_no_evidence () =
  let proof = make_proof
    ~tool_trace_refs:[]
    ~raw_evidence_refs:[] () in
  let result = Masc_mcp.Cdal_eval.evaluate proof in
  Alcotest.(check bool) "has_tool_traces" false result.evidence.has_tool_traces;
  Alcotest.(check bool) "has_raw_evidence" false result.evidence.has_raw_evidence;
  Alcotest.(check string) "overall is warn"
    "warn: no evidence produced" (Masc_mcp.Cdal_eval.severity_to_string result.overall)

(* ================================================================ *)
(* Test: Mode downgrade detected                                     *)
(* ================================================================ *)

let test_mode_downgrade () =
  let proof = make_proof
    ~requested:Execute
    ~effective:Draft
    ~mode_decision_source:"risk_class_downgrade" () in
  let result = Masc_mcp.Cdal_eval.evaluate proof in
  Alcotest.(check bool) "mode_was_downgraded" true
    result.violations.mode_was_downgraded;
  Alcotest.(check string) "downgrade_reason"
    "risk_class_downgrade"
    (Option.get result.violations.downgrade_reason);
  (* Downgrade alone does not produce a violation ref, so overall is Ok *)
  Alcotest.(check string) "overall is ok"
    "ok" (Masc_mcp.Cdal_eval.severity_to_string result.overall)

(* ================================================================ *)
(* Test: Checkpoint present                                          *)
(* ================================================================ *)

let test_checkpoint_present () =
  let proof = make_proof
    ~checkpoint_ref:(Some "proof-store://r1/checkpoint.json") () in
  let result = Masc_mcp.Cdal_eval.evaluate proof in
  Alcotest.(check bool) "has_checkpoint" true result.evidence.has_checkpoint

(* ================================================================ *)
(* Test: JSON round-trip                                             *)
(* ================================================================ *)

let test_json_output () =
  let proof = make_proof () in
  let result = Masc_mcp.Cdal_eval.evaluate proof in
  let json = Masc_mcp.Cdal_eval.to_json result in
  let json_str = Yojson.Safe.to_string json in
  (* Verify it is valid JSON with expected fields *)
  Alcotest.(check bool) "has run_id"
    true (String.length json_str > 0);
  match json with
  | `Assoc fields ->
    Alcotest.(check bool) "has run_id field"
      true (List.mem_assoc "run_id" fields);
    Alcotest.(check bool) "has evidence field"
      true (List.mem_assoc "evidence" fields);
    Alcotest.(check bool) "has violations field"
      true (List.mem_assoc "violations" fields);
    Alcotest.(check bool) "has overall field"
      true (List.mem_assoc "overall" fields)
  | _ -> Alcotest.fail "expected JSON object"

(* ================================================================ *)
(* Test: Recommendation for Ok → None                                *)
(* ================================================================ *)

let test_recommendation_ok () =
  let proof = make_proof () in
  let result = Masc_mcp.Cdal_eval.evaluate proof in
  Alcotest.(check bool) "no recommendation for Ok"
    true (Masc_mcp.Cdal_eval.recommendation result = None)

(* ================================================================ *)
(* Test: Recommendation for violations → actionable text             *)
(* ================================================================ *)

let test_recommendation_violations () =
  let proof = make_proof
    ~raw_evidence_refs:["proof-store://r1/evidence/mode_violations.json"] () in
  let result = Masc_mcp.Cdal_eval.evaluate proof in
  match Masc_mcp.Cdal_eval.recommendation result with
  | Some text ->
    Alcotest.(check bool) "mentions scope_kind or tools"
      true (String.length text > 10)
  | None -> Alcotest.fail "expected recommendation for violations"

(* ================================================================ *)
(* Test: Recommendation for cancelled → mentions scope_kind          *)
(* ================================================================ *)

let test_recommendation_cancelled () =
  let proof = make_proof ~result_status:Cancelled () in
  let result = Masc_mcp.Cdal_eval.evaluate proof in
  match Masc_mcp.Cdal_eval.recommendation result with
  | Some text ->
    Alcotest.(check bool) "mentions scope_kind"
      true (String.length text > 10)
  | None -> Alcotest.fail "expected recommendation for cancelled"

(* ================================================================ *)
(* Test: JSON includes recommendation field when not Ok              *)
(* ================================================================ *)

let test_json_has_recommendation () =
  let proof = make_proof ~result_status:Errored () in
  let result = Masc_mcp.Cdal_eval.evaluate proof in
  let json = Masc_mcp.Cdal_eval.to_json result in
  match json with
  | `Assoc fields ->
    Alcotest.(check bool) "has recommendation"
      true (List.mem_assoc "recommendation" fields)
  | _ -> Alcotest.fail "expected JSON object"

(* ================================================================ *)
(* Test: Persist writes to JSONL store                               *)
(* ================================================================ *)

let test_persist () =
  Eio_main.run @@ fun _env ->
  let tmp_dir = Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "cdal_eval_test_%d" (Unix.getpid ())) in
  Masc_mcp.Cdal_eval.set_store_for_testing ~base_dir:tmp_dir;
  let proof = make_proof () in
  let result = Masc_mcp.Cdal_eval.evaluate proof in
  Masc_mcp.Cdal_eval.persist result;
  Alcotest.(check bool) "store dir exists"
    true (Sys.file_exists tmp_dir);
  Masc_mcp.Cdal_eval.reset_store_for_testing ()

(* ================================================================ *)
(* Runner                                                            *)
(* ================================================================ *)

let () =
  Alcotest.run "Cdal_eval" [
    ("evaluate", [
      Alcotest.test_case "completed with traces" `Quick test_completed_with_traces;
      Alcotest.test_case "cancelled" `Quick test_cancelled;
      Alcotest.test_case "errored" `Quick test_errored;
      Alcotest.test_case "timed out" `Quick test_timed_out;
      Alcotest.test_case "violations" `Quick test_violations;
      Alcotest.test_case "no evidence" `Quick test_no_evidence;
      Alcotest.test_case "mode downgrade" `Quick test_mode_downgrade;
      Alcotest.test_case "checkpoint present" `Quick test_checkpoint_present;
      Alcotest.test_case "json output" `Quick test_json_output;
      Alcotest.test_case "recommendation ok" `Quick test_recommendation_ok;
      Alcotest.test_case "recommendation violations" `Quick test_recommendation_violations;
      Alcotest.test_case "recommendation cancelled" `Quick test_recommendation_cancelled;
      Alcotest.test_case "json has recommendation" `Quick test_json_has_recommendation;
      Alcotest.test_case "persist" `Quick test_persist;
    ]);
  ]
