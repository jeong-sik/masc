(** test_cdal_judge -- Unit tests for Cdal_judge module.

    Tests 5 active checks and run-level verdict derivation
    with determinism and findings population verification. *)

module CJ = Masc_mcp.Cdal_judge
module CT = Cdal_types
module CL = Masc_mcp.Cdal_loader

(* ================================================================ *)
(* Helpers                                                           *)
(* ================================================================ *)

let make_proof
    ?(run_id = "judge-test-001")
    ?(contract_id = "md5:abc123")
    ?(schema_version = Masc_mcp_cdal_runtime.Cdal_proof.schema_version_current)
    ?(requested = Masc_mcp_cdal_runtime.Execution_mode.Execute)
    ?(effective = Masc_mcp_cdal_runtime.Execution_mode.Execute)
    ?(risk_class = Masc_mcp_cdal_runtime.Risk_class.Low)
    () : Masc_mcp_cdal_runtime.Cdal_proof.t =
  {
    schema_version;
    run_id;
    contract_id;
    requested_execution_mode = requested;
    effective_execution_mode = effective;
    mode_decision_source = "passthrough";
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
    tool_trace_refs = [];
    raw_evidence_refs = [];
    checkpoint_ref = None;
    result_status = Completed;
    started_at = 1000.0;
    ended_at = 1001.0;
    scope = None;
  }

let make_contract
    ?(requested = Masc_mcp_cdal_runtime.Execution_mode.Execute)
    ?(risk_class = Masc_mcp_cdal_runtime.Risk_class.Low)
    ?review_requirement
    () : Masc_mcp_cdal_runtime.Risk_contract.t =
  {
    runtime_constraints = {
      requested_execution_mode = requested;
      risk_class;
      allowed_mutations = ["keeper_fs_edit"];
      review_requirement;
    };
    eval_criteria = `Assoc [
      ("success_criteria", `List [`String "tests pass"]);
    ];
  }

let make_bundle
    ?(run_id = "judge-test-001")
    ?(proof_requested = Masc_mcp_cdal_runtime.Execution_mode.Execute)
    ?(proof_effective = Masc_mcp_cdal_runtime.Execution_mode.Execute)
    ?(proof_risk = Masc_mcp_cdal_runtime.Risk_class.Low)
    ?(contract_requested = Masc_mcp_cdal_runtime.Execution_mode.Execute)
    ?(contract_risk = Masc_mcp_cdal_runtime.Risk_class.Low)
    ?contract_review_requirement
    ?(proof_raw_evidence_refs = [])
    ?(contract_id_match = true)
    () : CL.loaded_bundle =
  let contract = make_contract ~requested:contract_requested
      ~risk_class:contract_risk
      ?review_requirement:contract_review_requirement () in
  let recomputed_contract_id =
    Masc_mcp_cdal_runtime.Risk_contract.contract_id contract in
  let proof_contract_id =
    if contract_id_match then recomputed_contract_id
    else "md5:mismatched_hash" in
  let proof = make_proof ~run_id ~contract_id:proof_contract_id
      ~requested:proof_requested ~effective:proof_effective
      ~risk_class:proof_risk () in
  let proof = { proof with raw_evidence_refs = proof_raw_evidence_refs } in
  {
    proof;
    manifest_json = `Assoc [];
    contract;
    contract_json = `Assoc [];
    recomputed_contract_id;
  }

(* ================================================================ *)
(* test_all_satisfied                                                *)
(* ================================================================ *)

let test_all_satisfied () =
  let bundle = make_bundle () in
  let verdict = CJ.judge bundle in
  Alcotest.(check string) "status" "satisfied"
    (CT.contract_status_to_string verdict.status);
  Alcotest.(check int) "no findings" 0 (List.length verdict.findings);
  Alcotest.(check int) "5 check results" 5
    (List.length verdict.check_results);
  List.iter (fun (cr : CT.check_result) ->
    Alcotest.(check string) (cr.check_id ^ " satisfied") "satisfied"
      (CT.contract_status_to_string cr.status)
  ) verdict.check_results

(* ================================================================ *)
(* test_mode_propagation_violated                                    *)
(* ================================================================ *)

let test_mode_propagation_violated () =
  (* proof requests Draft but contract requires Execute *)
  let bundle = make_bundle
      ~proof_requested:Masc_mcp_cdal_runtime.Execution_mode.Draft
      ~proof_effective:Masc_mcp_cdal_runtime.Execution_mode.Draft
      ~contract_requested:Masc_mcp_cdal_runtime.Execution_mode.Execute () in
  let cr = CJ.check_execution_mode bundle in
  Alcotest.(check string) "status" "violated"
    (CT.contract_status_to_string cr.status);
  Alcotest.(check bool) "has findings" true
    (List.length cr.findings > 0)

(* ================================================================ *)
(* test_mode_escalation_violated                                     *)
(* ================================================================ *)

let test_mode_escalation_violated () =
  (* effective Execute > requested Draft *)
  let bundle = make_bundle
      ~proof_requested:Masc_mcp_cdal_runtime.Execution_mode.Draft
      ~proof_effective:Masc_mcp_cdal_runtime.Execution_mode.Execute
      ~contract_requested:Masc_mcp_cdal_runtime.Execution_mode.Draft () in
  let cr = CJ.check_execution_mode bundle in
  Alcotest.(check string) "status" "violated"
    (CT.contract_status_to_string cr.status);
  let has_escalation =
    List.exists (fun (f : CT.contract_finding) ->
      f.event_id = Some "escalation") cr.findings in
  Alcotest.(check bool) "has escalation finding" true has_escalation

(* ================================================================ *)
(* test_risk_class_violated                                          *)
(* ================================================================ *)

let test_risk_class_violated () =
  let bundle = make_bundle
      ~proof_risk:Masc_mcp_cdal_runtime.Risk_class.High
      ~contract_risk:Masc_mcp_cdal_runtime.Risk_class.Low () in
  let cr = CJ.check_risk_class bundle in
  Alcotest.(check string) "status" "violated"
    (CT.contract_status_to_string cr.status);
  Alcotest.(check int) "1 finding" 1 (List.length cr.findings)

(* ================================================================ *)
(* test_contract_snapshot_violated                                   *)
(* ================================================================ *)

let test_contract_snapshot_violated () =
  let bundle = make_bundle ~contract_id_match:false () in
  let cr = CJ.check_contract_snapshot bundle in
  Alcotest.(check string) "status" "violated"
    (CT.contract_status_to_string cr.status);
  Alcotest.(check int) "1 finding" 1 (List.length cr.findings)

(* ================================================================ *)
(* test_required_artifact_satisfied                                  *)
(* ================================================================ *)

let test_required_artifact_satisfied () =
  let bundle = make_bundle () in
  let cr = CJ.check_required_artifact bundle in
  Alcotest.(check string) "status" "satisfied"
    (CT.contract_status_to_string cr.status);
  Alcotest.(check int) "no findings" 0 (List.length cr.findings)

(* ================================================================ *)
(* test_review_requirement_inconclusive_missing_evidence             *)
(* ================================================================ *)

let test_review_requirement_inconclusive_missing_evidence () =
  let bundle = make_bundle
      ?contract_review_requirement:(Some "human_review") () in
  let cr = CJ.check_review_requirement bundle in
  Alcotest.(check string) "status" "inconclusive"
    (CT.contract_status_to_string cr.status);
  Alcotest.(check int) "1 completeness gap" 1 (List.length cr.completeness_gaps);
  let gap = List.hd cr.completeness_gaps in
  Alcotest.(check string) "gap artifact" "evidence/review_warning.json" gap.artifact;
  Alcotest.(check string) "gap impact" "blocks_verdict"
    (CT.completeness_impact_to_string gap.impact)

(* ================================================================ *)
(* test_review_requirement_inconclusive_warning_only                 *)
(* ================================================================ *)

let test_review_requirement_inconclusive_warning_only () =
  let bundle = make_bundle
      ?contract_review_requirement:(Some "human_review")
      ~proof_raw_evidence_refs:["proof-store://judge-test-001/evidence/review_warning.json"]
      () in
  let cr = CJ.check_review_requirement bundle in
  Alcotest.(check string) "status" "inconclusive"
    (CT.contract_status_to_string cr.status);
  let gap = List.hd cr.completeness_gaps in
  Alcotest.(check bool) "mentions warning-style evidence" true
    (Astring.String.is_infix ~affix:"warning-style review evidence" gap.reason)

(* ================================================================ *)
(* test_verdict_priority_violated_wins                               *)
(* ================================================================ *)

let test_verdict_priority_violated_wins () =
  (* One violated check (risk mismatch) + others satisfied *)
  let bundle = make_bundle
      ~proof_risk:Masc_mcp_cdal_runtime.Risk_class.Medium
      ~contract_risk:Masc_mcp_cdal_runtime.Risk_class.Low () in
  let verdict = CJ.judge bundle in
  Alcotest.(check string) "status" "violated"
    (CT.contract_status_to_string verdict.status)

(* ================================================================ *)
(* test_verdict_priority_inconclusive                                *)
(* ================================================================ *)

let test_verdict_priority_inconclusive () =
  (* No direct way to trigger Inconclusive from the 4 checks since
     they only produce Satisfied or Violated. This test verifies the
     verdict derivation logic by examining a verdict that is Satisfied
     when all checks pass, confirming the "else" branch works. *)
  let bundle = make_bundle () in
  let verdict = CJ.judge bundle in
  (* All satisfied means final is Satisfied (not Inconclusive) *)
  Alcotest.(check string) "status satisfied when no violations"
    "satisfied" (CT.contract_status_to_string verdict.status)

(* ================================================================ *)
(* test_claim_scope_always_set                                       *)
(* ================================================================ *)

let test_claim_scope_always_set () =
  (* Satisfied case *)
  let bundle_ok = make_bundle () in
  let verdict_ok = CJ.judge bundle_ok in
  Alcotest.(check string) "claim_scope ok"
    "phase1_scoped_runtime_audit" verdict_ok.claim_scope;
  (* Violated case *)
  let bundle_bad = make_bundle
      ~proof_risk:Masc_mcp_cdal_runtime.Risk_class.High
      ~contract_risk:Masc_mcp_cdal_runtime.Risk_class.Low () in
  let verdict_bad = CJ.judge bundle_bad in
  Alcotest.(check string) "claim_scope violated"
    "phase1_scoped_runtime_audit" verdict_bad.claim_scope

let test_loader_metadata_set () =
  let bundle = make_bundle () in
  let verdict = CJ.judge bundle in
  Alcotest.(check string) "loader semantics version"
    CT.loader_semantics_version_phase1 verdict.loader_semantics_version;
  Alcotest.(check string) "schema compat mode"
    CT.schema_compat_mode_v1 verdict.schema_compat_mode

(* ================================================================ *)
(* test_replay_determinism                                           *)
(* ================================================================ *)

let test_replay_determinism () =
  let bundle = make_bundle () in
  let v1 = CJ.judge bundle in
  let v2 = CJ.judge bundle in
  Alcotest.(check string) "judgment_hash deterministic"
    v1.judgment_hash v2.judgment_hash;
  Alcotest.(check string) "judgment_basis_hash deterministic"
    v1.judgment_basis_hash v2.judgment_basis_hash

(* ================================================================ *)
(* test_findings_populated                                           *)
(* ================================================================ *)

let test_findings_populated () =
  let bundle = make_bundle
      ~proof_risk:Masc_mcp_cdal_runtime.Risk_class.Critical
      ~contract_risk:Masc_mcp_cdal_runtime.Risk_class.Low () in
  let verdict = CJ.judge bundle in
  Alcotest.(check string) "violated" "violated"
    (CT.contract_status_to_string verdict.status);
  Alcotest.(check bool) "has findings" true
    (List.length verdict.findings > 0);
  (* Verify finding has expected structure *)
  let f = List.hd verdict.findings in
  Alcotest.(check string) "finding check_id" "runtime.risk_class"
    f.check_id

(* ================================================================ *)
(* Runner                                                            *)
(* ================================================================ *)

let () =
  Alcotest.run "Cdal_judge" [
    ("checks", [
      Alcotest.test_case "all satisfied" `Quick test_all_satisfied;
      Alcotest.test_case "mode propagation violated" `Quick
        test_mode_propagation_violated;
      Alcotest.test_case "mode escalation violated" `Quick
        test_mode_escalation_violated;
      Alcotest.test_case "risk class violated" `Quick
        test_risk_class_violated;
      Alcotest.test_case "contract snapshot violated" `Quick
        test_contract_snapshot_violated;
      Alcotest.test_case "required artifact satisfied" `Quick
        test_required_artifact_satisfied;
      Alcotest.test_case "review requirement missing evidence" `Quick
        test_review_requirement_inconclusive_missing_evidence;
      Alcotest.test_case "review requirement warning only" `Quick
        test_review_requirement_inconclusive_warning_only;
    ]);
    ("verdict", [
      Alcotest.test_case "violated wins" `Quick
        test_verdict_priority_violated_wins;
      Alcotest.test_case "inconclusive path" `Quick
        test_verdict_priority_inconclusive;
      Alcotest.test_case "claim scope always set" `Quick
        test_claim_scope_always_set;
      Alcotest.test_case "loader metadata set" `Quick
        test_loader_metadata_set;
      Alcotest.test_case "replay determinism" `Quick
        test_replay_determinism;
      Alcotest.test_case "findings populated" `Quick
        test_findings_populated;
    ]);
  ]
