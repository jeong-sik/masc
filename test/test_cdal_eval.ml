(** test_cdal_eval — Content-based CDAL eval tests.

    Tests both pure evaluation (evaluate_content) and artifact-reading
    evaluation (evaluate ~store) with synthetic proof bundles. *)

module CE = Masc_mcp.Cdal_eval
module VR = Masc_mcp.Violation_record
module TU = Masc_mcp.Token_usage_record

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

let make_violation ?(ts = 1000.5) ?(tool_name = "write")
    ?(input_summary = "{}") ?(effective_mode = Agent_sdk.Execution_mode.Diagnose)
    ?(violation_kind = VR.Mutating_in_diagnose)
    () : VR.t =
  { ts; tool_name; input_summary; effective_mode; violation_kind }

(* ================================================================ *)
(* Pure evaluate_content tests                                       *)
(* ================================================================ *)

let test_completed_no_violations () =
  let proof = make_proof () in
  let result = CE.evaluate_content ~violations:[] ~token_usage:[] ~trace_count:1 proof in
  Alcotest.(check string) "ok" "ok" (CE.severity_to_string result.overall);
  Alcotest.(check bool) "acceptable" true (CE.is_acceptable result);
  Alcotest.(check bool) "no recommendation" true (result.recommendation = None)

let test_cancelled () =
  let proof = make_proof ~result_status:Cancelled () in
  let result = CE.evaluate_content ~violations:[] ~token_usage:[] ~trace_count:0 proof in
  Alcotest.(check string) "fail" "fail: cancelled by contract"
    (CE.severity_to_string result.overall);
  Alcotest.(check bool) "not acceptable" false (CE.is_acceptable result)

let test_errored () =
  let proof = make_proof ~result_status:Errored () in
  let result = CE.evaluate_content ~violations:[] ~token_usage:[] ~trace_count:0 proof in
  Alcotest.(check string) "warn" "warn: execution error"
    (CE.severity_to_string result.overall)

let test_timed_out () =
  let proof = make_proof ~result_status:Timed_out () in
  let result = CE.evaluate_content ~violations:[] ~token_usage:[] ~trace_count:0 proof in
  Alcotest.(check string) "warn" "warn: execution timed out"
    (CE.severity_to_string result.overall)

let test_mutating_in_diagnose () =
  let v = make_violation ~tool_name:"fs_edit"
    ~effective_mode:Diagnose ~violation_kind:Mutating_in_diagnose () in
  let proof = make_proof ~effective:Diagnose () in
  let result = CE.evaluate_content ~violations:[v] ~token_usage:[] ~trace_count:1 proof in
  (match result.recommendation with
   | Some r ->
     Alcotest.(check string) "min required = Draft"
       "draft" (Agent_sdk.Execution_mode.to_string r.minimum_required);
     Alcotest.(check int) "gap = 1" 1 r.gap;
     Alcotest.(check (list string)) "offending tools"
       ["fs_edit"] r.offending_tools
   | None -> Alcotest.fail "expected recommendation for violation")

let test_external_in_draft () =
  let v = make_violation ~tool_name:"mcp__slack_send"
    ~effective_mode:Draft ~violation_kind:External_in_draft () in
  let proof = make_proof ~effective:Draft () in
  let result = CE.evaluate_content ~violations:[v] ~token_usage:[] ~trace_count:1 proof in
  (match result.recommendation with
   | Some r ->
     Alcotest.(check string) "min required = Execute"
       "execute" (Agent_sdk.Execution_mode.to_string r.minimum_required);
     Alcotest.(check int) "gap = 1" 1 r.gap
   | None -> Alcotest.fail "expected recommendation")

let test_multiple_violations_max_mode () =
  let v1 = make_violation ~tool_name:"write"
    ~effective_mode:Diagnose ~violation_kind:Mutating_in_diagnose () in
  let v2 = make_violation ~tool_name:"bash"
    ~effective_mode:Diagnose ~violation_kind:External_in_draft () in
  let proof = make_proof ~effective:Diagnose () in
  let result = CE.evaluate_content ~violations:[v1; v2] ~token_usage:[] ~trace_count:1 proof in
  (match result.recommendation with
   | Some r ->
     Alcotest.(check string) "max = Execute"
       "execute" (Agent_sdk.Execution_mode.to_string r.minimum_required);
     Alcotest.(check int) "gap = 2" 2 r.gap;
     Alcotest.(check int) "2 offending tools" 2 (List.length r.offending_tools)
   | None -> Alcotest.fail "expected recommendation")

let test_no_evidence () =
  let proof = make_proof ~tool_trace_refs:[] () in
  let result = CE.evaluate_content ~violations:[] ~token_usage:[] ~trace_count:0 proof in
  Alcotest.(check string) "warn" "warn: no evidence produced"
    (CE.severity_to_string result.overall)

let test_token_usage_in_evidence () =
  let usage = [
    { TU.turn = 0; input_tokens = 100; output_tokens = 50; cost_usd = Some 0.01 };
    { TU.turn = 1; input_tokens = 200; output_tokens = 100; cost_usd = Some 0.02 };
  ] in
  let proof = make_proof () in
  let result = CE.evaluate_content ~violations:[] ~token_usage:usage ~trace_count:1 proof in
  Alcotest.(check int) "total tokens" 450
    (TU.total_tokens result.evidence.token_usage)

let test_json_has_violations_detail () =
  let v = make_violation ~tool_name:"bash" ~violation_kind:External_in_draft () in
  let proof = make_proof ~effective:Draft () in
  let result = CE.evaluate_content ~violations:[v] ~token_usage:[] ~trace_count:1 proof in
  let json = CE.to_json result in
  match json with
  | `Assoc fields ->
    Alcotest.(check bool) "has violations"
      true (List.mem_assoc "violations" fields);
    Alcotest.(check bool) "has recommendation"
      true (List.mem_assoc "recommendation" fields);
    (match List.assoc "violations" fields with
     | `List [_v] -> ()
     | _ -> Alcotest.fail "expected 1 violation in JSON")
  | _ -> Alcotest.fail "expected JSON object"

let test_json_no_recommendation_when_ok () =
  let proof = make_proof () in
  let result = CE.evaluate_content ~violations:[] ~token_usage:[] ~trace_count:1 proof in
  let json = CE.to_json result in
  match json with
  | `Assoc fields ->
    Alcotest.(check bool) "no recommendation"
      false (List.mem_assoc "recommendation" fields)
  | _ -> Alcotest.fail "expected JSON object"

(* ================================================================ *)
(* Integration test: write proof artifacts, then evaluate             *)
(* ================================================================ *)

let test_integration_read_violations () =
  Eio_main.run @@ fun _env ->
  let tmp_dir = Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "cdal_eval_int_%d" (Unix.getpid ())) in
  let store : Agent_sdk.Proof_store.config = { root = tmp_dir } in
  let run_id = "int-test-001" in
  let run_dir = Filename.concat (Filename.concat tmp_dir "proofs") run_id in
  let () =
    let rec mkdirp path =
      if not (Sys.file_exists path) then begin
        mkdirp (Filename.dirname path);
        Unix.mkdir path 0o755
      end
    in
    mkdirp (Filename.concat run_dir "tool_traces");
    mkdirp (Filename.concat run_dir "evidence")
  in
  (* Write synthetic violation evidence *)
  let violation_json = `List [
    `Assoc [
      ("ts", `Float 1000.5);
      ("tool_name", `String "bash");
      ("input_summary", `String "rm -rf /tmp/x");
      ("effective_mode", `String "draft");
      ("violation_kind", `String "external_in_draft");
    ]
  ] in
  Agent_sdk.Proof_store.write_evidence store ~run_id
    ~ref_id:"mode_violations" violation_json;
  (* Write synthetic token usage *)
  let token_json = `List [
    `Assoc [
      ("turn", `Int 0);
      ("input_tokens", `Int 500);
      ("output_tokens", `Int 100);
      ("cost_usd", `Float 0.005);
    ]
  ] in
  Agent_sdk.Proof_store.write_evidence store ~run_id
    ~ref_id:"token_usage" token_json;
  (* Build proof manifest with refs *)
  let proof = make_proof ~run_id ~effective:Draft
    ~raw_evidence_refs:[
      Agent_sdk.Proof_store.make_ref ~run_id ~subpath:"evidence/mode_violations.json";
      Agent_sdk.Proof_store.make_ref ~run_id ~subpath:"evidence/token_usage.json";
    ] () in
  (* Evaluate with artifact reading *)
  let result = CE.evaluate ~store proof in
  Alcotest.(check int) "1 violation read" 1
    (List.length result.evidence.violations);
  Alcotest.(check int) "1 token record read" 1
    (List.length result.evidence.token_usage);
  (match result.recommendation with
   | Some r ->
     Alcotest.(check string) "min = execute"
       "execute" (Agent_sdk.Execution_mode.to_string r.minimum_required);
     Alcotest.(check (list string)) "offending = [bash]"
       ["bash"] r.offending_tools
   | None -> Alcotest.fail "expected recommendation from read violations");
  (* Verify JSONL persistence *)
  let jsonl_dir = Filename.concat tmp_dir "cdal_evals_test" in
  CE.set_store_for_testing ~base_dir:jsonl_dir;
  CE.persist result;
  Alcotest.(check bool) "jsonl dir exists" true (Sys.file_exists jsonl_dir);
  CE.reset_store_for_testing ()

let test_integration_missing_artifact () =
  let store : Agent_sdk.Proof_store.config =
    { root = "/nonexistent/path" } in
  let proof = make_proof
    ~raw_evidence_refs:["proof-store://missing/evidence/mode_violations.json"]
    () in
  let result = CE.evaluate ~store proof in
  Alcotest.(check int) "0 violations (graceful)" 0
    (List.length result.evidence.violations);
  Alcotest.(check string) "ok (no violations read)" "ok"
    (CE.severity_to_string result.overall)

(* ================================================================ *)
(* Violation_record unit tests                                       *)
(* ================================================================ *)

let test_violation_parse () =
  let json = `Assoc [
    ("ts", `Float 1.0);
    ("tool_name", `String "write");
    ("input_summary", `String "content");
    ("effective_mode", `String "diagnose");
    ("violation_kind", `String "mutating_in_diagnose");
  ] in
  match VR.of_json json with
  | Ok v ->
    Alcotest.(check string) "tool" "write" v.tool_name;
    Alcotest.(check string) "kind" "mutating_in_diagnose"
      (VR.violation_kind_to_string v.violation_kind);
    Alcotest.(check string) "min mode" "draft"
      (Agent_sdk.Execution_mode.to_string (VR.minimum_required_mode v))
  | Error e -> Alcotest.fail e

let test_violation_unknown_kind () =
  let json = `Assoc [
    ("ts", `Float 1.0);
    ("tool_name", `String "x");
    ("input_summary", `String "");
    ("effective_mode", `String "execute");
    ("violation_kind", `String "new_kind_v2");
  ] in
  match VR.of_json json with
  | Ok v ->
    (match v.violation_kind with
     | VR.Unknown "new_kind_v2" -> ()
     | _ -> Alcotest.fail "expected Unknown");
    Alcotest.(check string) "min mode unchanged" "execute"
      (Agent_sdk.Execution_mode.to_string (VR.minimum_required_mode v))
  | Error e -> Alcotest.fail e

(* ================================================================ *)
(* Runner                                                            *)
(* ================================================================ *)

let () =
  Alcotest.run "Cdal_eval" [
    ("pure_eval", [
      Alcotest.test_case "completed no violations" `Quick test_completed_no_violations;
      Alcotest.test_case "cancelled" `Quick test_cancelled;
      Alcotest.test_case "errored" `Quick test_errored;
      Alcotest.test_case "timed out" `Quick test_timed_out;
      Alcotest.test_case "mutating in diagnose" `Quick test_mutating_in_diagnose;
      Alcotest.test_case "external in draft" `Quick test_external_in_draft;
      Alcotest.test_case "multiple violations max mode" `Quick test_multiple_violations_max_mode;
      Alcotest.test_case "no evidence" `Quick test_no_evidence;
      Alcotest.test_case "token usage" `Quick test_token_usage_in_evidence;
      Alcotest.test_case "json violations detail" `Quick test_json_has_violations_detail;
      Alcotest.test_case "json no recommendation when ok" `Quick test_json_no_recommendation_when_ok;
    ]);
    ("integration", [
      Alcotest.test_case "read violations from store" `Quick test_integration_read_violations;
      Alcotest.test_case "missing artifact graceful" `Quick test_integration_missing_artifact;
    ]);
    ("violation_record", [
      Alcotest.test_case "parse" `Quick test_violation_parse;
      Alcotest.test_case "unknown kind" `Quick test_violation_unknown_kind;
    ]);
  ]
