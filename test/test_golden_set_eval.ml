(** test_golden_set_eval -- Calibration baseline for CDAL evaluator.

    Runs all 52 golden set cases through Cdal_judge to measure whether
    the structural evaluator can distinguish positive from negative cases.

    Expected outcome: the evaluator returns "satisfied" for ALL cases
    because its 4 checks (mode, risk_class, contract snapshot, required
    artifact) are structural, not semantic. This proves the gap:
    semantic task-level judgment is not yet implemented.

    The confusion matrix output is the calibration baseline. *)

module CJ = Masc_mcp.Cdal_judge
module CT = Masc_mcp.Cdal_types
module CL = Masc_mcp.Cdal_loader
module GS = Masc_mcp.Golden_set
module L = Masc_mcp.Labeling

(* ================================================================ *)
(* Proof synthesis from golden cases                                 *)
(* ================================================================ *)

let risk_class_of_string = function
  | "low" -> Agent_sdk.Risk_class.Low
  | "medium" -> Agent_sdk.Risk_class.Medium
  | "high" -> Agent_sdk.Risk_class.High
  | "critical" -> Agent_sdk.Risk_class.Critical
  | _ -> Agent_sdk.Risk_class.Low

let mode_for_risk = function
  | Agent_sdk.Risk_class.Low | Medium -> Agent_sdk.Execution_mode.Execute
  | High -> Agent_sdk.Execution_mode.Draft
  | Critical -> Agent_sdk.Execution_mode.Diagnose

(** Synthesize a structurally valid proof bundle from a golden case.
    All bundles are structurally valid: matching mode, risk class,
    contract hash, and present artifacts. *)
let bundle_of_golden_case (gc : GS.golden_case) : CL.loaded_bundle =
  let risk = risk_class_of_string gc.risk_class in
  let mode = mode_for_risk risk in
  let contract : Agent_sdk.Risk_contract.t = {
    runtime_constraints = {
      requested_execution_mode = mode;
      risk_class = risk;
      allowed_mutations = ["keeper_fs_edit"];
      review_requirement = None;
    };
    eval_criteria = `Assoc [
      ("task_title", `String gc.task_title);
      ("task_description", `String gc.task_description);
    ];
  } in
  let recomputed_contract_id =
    Agent_sdk.Risk_contract.contract_id contract in
  let proof : Agent_sdk.Cdal_proof.t = {
    schema_version = Agent_sdk.Cdal_proof.schema_version_current;
    run_id = gc.case_id;
    contract_id = recomputed_contract_id;
    requested_execution_mode = mode;
    effective_execution_mode = mode;
    mode_decision_source = "passthrough";
    risk_class = risk;
    provider_snapshot = {
      provider_name = "test";
      model_id = "golden-eval";
      api_version = None;
    };
    capability_snapshot = {
      tools = ["read"; "write"; "edit"];
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
  } in
  {
    proof;
    manifest_json = `Assoc [];
    contract;
    contract_json = `Assoc [];
    recomputed_contract_id;
  }

(* ================================================================ *)
(* Evaluation and confusion matrix                                   *)
(* ================================================================ *)

type eval_result = {
  case_id : string;
  case_class : GS.case_class;
  expected_verdict : string;
  actual_status : string;
  match_ : bool;
}

let evaluate_case (gc : GS.golden_case) : eval_result =
  let bundle = bundle_of_golden_case gc in
  let verdict = CJ.judge bundle in
  let actual_status = CT.contract_status_to_string verdict.status in
  let expected_pass = gc.expected_verdict = "pass" in
  let actual_pass = actual_status = "satisfied" in
  { case_id = gc.case_id;
    case_class = gc.case_class;
    expected_verdict = gc.expected_verdict;
    actual_status;
    match_ = expected_pass = actual_pass }

let evaluate_all () =
  List.map evaluate_case GS.all_cases

(* ================================================================ *)
(* Tests                                                             *)
(* ================================================================ *)

let test_calibration_baseline () =
  let results = evaluate_all () in
  let total = List.length results in
  let correct = List.length (List.filter (fun r -> r.match_) results) in
  let incorrect = total - correct in

  (* Count by class *)
  let pos_total = List.length (List.filter
    (fun r -> r.case_class = Positive) results) in
  let neg_total = List.length (List.filter
    (fun r -> r.case_class = Negative) results) in
  let pos_correct = List.length (List.filter
    (fun r -> r.case_class = Positive && r.match_) results) in
  let neg_correct = List.length (List.filter
    (fun r -> r.case_class = Negative && r.match_) results) in

  (* Print calibration report *)
  Printf.printf "\n=== CDAL Calibration Baseline ===\n";
  Printf.printf "Total cases: %d\n" total;
  Printf.printf "Correct: %d (%.1f%%)\n" correct
    (100.0 *. float_of_int correct /. float_of_int total);
  Printf.printf "Incorrect: %d (%.1f%%)\n" incorrect
    (100.0 *. float_of_int incorrect /. float_of_int total);
  Printf.printf "\nBy class:\n";
  Printf.printf "  Positive: %d/%d correct (%.1f%%)\n" pos_correct pos_total
    (if pos_total > 0
     then 100.0 *. float_of_int pos_correct /. float_of_int pos_total
     else 0.0);
  Printf.printf "  Negative: %d/%d correct (%.1f%%)\n" neg_correct neg_total
    (if neg_total > 0
     then 100.0 *. float_of_int neg_correct /. float_of_int neg_total
     else 0.0);
  Printf.printf "================================\n";

  (* The critical assertion: document what the evaluator CAN and CANNOT do.
     Positive cases should all pass (structural checks are trivially satisfied).
     Negative cases will ALSO pass (evaluator has no semantic judgment).
     This is the expected baseline — it proves the semantic gap. *)
  Alcotest.(check int) "positive cases all satisfied" pos_total pos_correct;

  (* Negative cases: we expect the evaluator to say "satisfied" for ALL
     negative cases too, because structural checks cannot detect semantic
     violations. This documents the known gap. *)
  let neg_false_positive = List.length (List.filter
    (fun r -> r.case_class = Negative && not r.match_) results) in
  Printf.printf "\nNegative false positive rate: %d/%d (%.1f%%)\n"
    neg_false_positive neg_total
    (if neg_total > 0
     then 100.0 *. float_of_int neg_false_positive /. float_of_int neg_total
     else 0.0);

  (* Print each mismatched case for visibility *)
  List.iter (fun r ->
    if not r.match_ then
      Printf.printf "  MISMATCH: %s (%s) expected=%s actual=%s\n"
        r.case_id (GS.case_class_to_string r.case_class)
        r.expected_verdict r.actual_status
  ) results

let test_structural_checks_pass_for_valid_proofs () =
  (* Verify that structurally valid proofs always get 5/5 satisfied checks *)
  let bundle = bundle_of_golden_case (List.hd GS.positive_cases) in
  let verdict = CJ.judge bundle in
  Alcotest.(check int) "5 check results" 5
    (List.length verdict.check_results);
  List.iter (fun (cr : CT.check_result) ->
    Alcotest.(check string) (cr.check_id ^ " satisfied") "satisfied"
      (CT.contract_status_to_string cr.status)
  ) verdict.check_results

let test_confusion_matrix_computation () =
  (* Compute a confusion matrix by treating positive=supported, negative=unsupported *)
  let results = evaluate_all () in
  let labeled_verdicts = List.filter_map (fun r ->
    match r.case_class with
    | Positive | Negative ->
      let label =
        if r.match_ then L.Supported
        else L.Unsupported
      in
      let verdict = CT.{
        run_id = r.case_id;
        contract_id = "calibration";
        claim_scope = CT.claim_scope_phase1;
        judgment_basis_hash = "";
        judgment_hash = "";
        loader_semantics_version = CT.loader_semantics_version_phase1;
        schema_compat_mode = CT.schema_compat_mode_v1;
        status = Satisfied;
        findings = [];
        completeness_gaps = [];
        check_results = [];
      } in
      Some L.{ verdict; label; labeler = "calibration:auto";
               note = None; labeled_at = "2026-03-30T00:00:00Z" }
    | Edge | Drift_probe -> None
  ) results in
  let confusion = L.compute_confusion labeled_verdicts in
  Printf.printf "\nConfusion matrix: supported=%d unsupported=%d ambiguous=%d drift=%d\n"
    confusion.supported confusion.unsupported confusion.ambiguous confusion.drift;
  let strict = L.compute_precision_strict confusion in
  Printf.printf "Precision (strict): %.3f\n" strict;
  (* We expect ~50% precision: positive cases correct, negative cases wrong *)
  Alcotest.(check bool) "confusion has entries" true
    (confusion.supported + confusion.unsupported > 0)

(* ================================================================ *)
(* Test runner                                                       *)
(* ================================================================ *)

let () =
  Alcotest.run "Golden_set_eval"
    [
      "calibration", [
        Alcotest.test_case "baseline measurement" `Quick
          test_calibration_baseline;
        Alcotest.test_case "structural checks pass" `Quick
          test_structural_checks_pass_for_valid_proofs;
        Alcotest.test_case "confusion matrix" `Quick
          test_confusion_matrix_computation;
      ];
    ]
