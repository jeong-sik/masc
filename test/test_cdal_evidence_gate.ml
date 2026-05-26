(** RFC-0109 Phase D — Cdal_evidence_gate decision matrix tests.

    Covers all 5 rows of §6.5.2 plus the operator-visible payload
    shape for Violated and Inconclusive rejections. The verdict
    lookup is injected via the [~lookup] parameter so the tests do
    not require the dated_jsonl store. *)

open Alcotest
open Masc_mcp

module Gate = Cdal_evidence_gate
module Ct = Cdal_types

let make_verdict
      ?(run_id = "run-test")
      ?(contract_id = "md5:test-contract")
      ?(judgment_hash = "md5:test-hash")
      ?(findings = [])
      ?(completeness_gaps = [])
      ?(check_results = [])
      status
    : Ct.contract_verdict
  =
  { run_id
  ; contract_id
  ; claim_scope = Ct.claim_scope_phase1
  ; judgment_basis_hash = "md5:basis"
  ; judgment_hash
  ; loader_semantics_version = Ct.loader_semantics_version_phase1
  ; schema_compat_mode = Ct.schema_compat_mode_v1
  ; status
  ; findings
  ; completeness_gaps
  ; check_results
  }

let finding
      ?(event_id = None)
      ?(observed = `String "actual")
      ?(expected = `String "expected")
      ?(trace_ref = None)
      check_id
    : Ct.contract_finding
  =
  { check_id; event_id; observed; expected; trace_ref }

let gap ?(impact = Ct.Blocks_verdict) artifact reason : Ct.completeness_gap =
  { artifact; reason; impact }

let make_task
      ?(id = "task-1")
      ?(contract : Masc_domain.task_contract option = None)
      ?(handoff_context : Masc_domain.task_handoff_context option = None)
      ()
    : Masc_domain.task
  =
  { id
  ; title = "test"
  ; description = "test task"
  ; task_status = Masc_domain.Todo
  ; priority = 3
  ; files = []
  ; created_at = "2026-05-26T00:00:00Z"
  ; created_by = None
  ; goal_id = None
  ; stage = None
  ; contract
  ; handoff_context
  ; cycle_count = 0
  ; reclaim_policy = None
  ; do_not_reclaim_reason = None
  }

let make_contract
      ?(strict = false)
      ?(completion_contract = [])
      ?(required_tools = [])
      ?(required_evidence = [])
      ?(inspect_gate_evidence = [])
      ?(verify_gate_evidence = [])
      ()
    : Masc_domain.task_contract
  =
  { strict
  ; completion_contract
  ; required_tools
  ; required_evidence
  ; inspect_gate_evidence
  ; verify_gate_evidence
  ; links = { operation_id = None; session_id = None }
  }

let lookup_returns v ~task_id:_ = v

(* ─────────────────────────────────────────────────────────────── *)
(* §6.5.2 row 1: Some Satisfied → Pass                              *)
(* ─────────────────────────────────────────────────────────────── *)
let test_satisfied_verdict_passes () =
  let verdict = make_verdict Ct.Satisfied in
  match
    Gate.decide
      ~lookup:(lookup_returns (Some verdict))
      ~task_id:"task-1"
      ~task_opt:(Some (make_task ()))
      ~notes:""
      ~handoff_context:None
      ()
  with
  | Gate.Pass -> ()
  | Gate.Reject { rule_id; _ } ->
    failf "Satisfied verdict should Pass, got Reject rule_id=%s" rule_id

(* §6.5.2 row 2: Some Violated → Reject with typed findings *)
let test_violated_verdict_rejects_with_findings () =
  let findings = [ finding "check-a"; finding "check-b" ] in
  let verdict = make_verdict ~findings Ct.Violated in
  match
    Gate.decide
      ~lookup:(lookup_returns (Some verdict))
      ~task_id:"task-violated"
      ~task_opt:(Some (make_task ()))
      ~notes:"PR #999"  (* substring shim would Pass; CDAL takes precedence *)
      ~handoff_context:None
      ()
  with
  | Gate.Pass ->
    fail "Violated verdict should Reject even when substring shim would Pass"
  | Gate.Reject { rule_id; payload_json; reason; _ } ->
    check string "rule_id" Gate.rule_id_violated rule_id;
    check bool "reason mentions Violated" true
      (String_util.contains_substring_ci reason "Violated");
    (match payload_json with
     | `Assoc fields ->
       (match List.assoc_opt "verdict_status" fields with
        | Some (`String s) -> check string "verdict_status" "violated" s
        | _ -> fail "payload missing verdict_status");
       (match List.assoc_opt "findings" fields with
        | Some (`List xs) ->
          check int "findings length" 2 (List.length xs)
        | _ -> fail "payload missing findings list")
     | _ -> fail "payload is not Assoc")

(* §6.5.2 row 3a: Some Inconclusive with no gaps and no unsatisfied
   required_evidence → Pass *)
let test_inconclusive_passes_when_evidence_satisfied () =
  let verdict = make_verdict Ct.Inconclusive in
  let contract = make_contract ~required_evidence:[ "src/main.ml" ] () in
  let task = make_task ~contract:(Some contract) () in
  match
    Gate.decide
      ~lookup:(lookup_returns (Some verdict))
      ~task_id:"task-3a"
      ~task_opt:(Some task)
      ~notes:"completed work on src/main.ml"
      ~handoff_context:None
      ()
  with
  | Gate.Pass -> ()
  | Gate.Reject { rule_id; _ } ->
    failf
      "Inconclusive with all evidence satisfied should Pass, got Reject \
       rule_id=%s"
      rule_id

(* §6.5.2 row 3b: Some Inconclusive with unsatisfied required_evidence
   → Reject *)
let test_inconclusive_rejects_when_evidence_missing () =
  let verdict = make_verdict Ct.Inconclusive in
  let contract = make_contract ~required_evidence:[ "src/missing.ml" ] () in
  let task = make_task ~contract:(Some contract) () in
  match
    Gate.decide
      ~lookup:(lookup_returns (Some verdict))
      ~task_id:"task-3b"
      ~task_opt:(Some task)
      ~notes:"completed something else"
      ~handoff_context:None
      ()
  with
  | Gate.Pass ->
    fail "Inconclusive with unsatisfied evidence should Reject"
  | Gate.Reject { rule_id; payload_json; _ } ->
    check string "rule_id" Gate.rule_id_inconclusive rule_id;
    (match payload_json with
     | `Assoc fields ->
       (match List.assoc_opt "required_evidence_unsatisfied" fields with
        | Some (`List [ `String s ]) ->
          check string "unsatisfied entry" "src/missing.ml" s
        | _ -> fail "payload missing required_evidence_unsatisfied")
     | _ -> fail "payload is not Assoc")

(* §6.5.2 row 3c: Some Inconclusive with completeness_gaps → Reject *)
let test_inconclusive_rejects_when_completeness_gaps () =
  let gaps = [ gap "dashboard_attribution" "no events emitted" ] in
  let verdict = make_verdict ~completeness_gaps:gaps Ct.Inconclusive in
  match
    Gate.decide
      ~lookup:(lookup_returns (Some verdict))
      ~task_id:"task-3c"
      ~task_opt:(Some (make_task ()))
      ~notes:""
      ~handoff_context:None
      ()
  with
  | Gate.Pass -> fail "Inconclusive with completeness_gaps should Reject"
  | Gate.Reject { rule_id; payload_json; _ } ->
    check string "rule_id" Gate.rule_id_inconclusive rule_id;
    (match payload_json with
     | `Assoc fields ->
       (match List.assoc_opt "completeness_gaps" fields with
        | Some (`List xs) ->
          check int "completeness_gaps length" 1 (List.length xs)
        | _ -> fail "payload missing completeness_gaps")
     | _ -> fail "payload is not Assoc")

(* §6.5.2 row 4: None verdict + task.contract = None →
   Pass (analysis-only task bypass; the core operator-visible fix) *)
let test_no_verdict_no_contract_bypasses () =
  match
    Gate.decide
      ~lookup:(lookup_returns None)
      ~task_id:"task-analysis"
      ~task_opt:(Some (make_task ()))  (* contract = None *)
      ~notes:""
      ~handoff_context:None
      ()
  with
  | Gate.Pass -> ()
  | Gate.Reject { rule_id; _ } ->
    failf
      "Analysis-only task (no contract) should Pass without evidence; got \
       Reject rule_id=%s"
      rule_id

(* §6.5.2 row 4 variant: task_opt = None → Pass too (no contract = no
   verification obligation) *)
let test_no_verdict_no_task_bypasses () =
  match
    Gate.decide
      ~lookup:(lookup_returns None)
      ~task_id:"task-ghost"
      ~task_opt:None
      ~notes:""
      ~handoff_context:None
      ()
  with
  | Gate.Pass -> ()
  | Gate.Reject { rule_id; _ } ->
    failf "Missing task should Pass, got Reject rule_id=%s" rule_id

(* §6.5.2 row 5a: None verdict + task.contract = Some _ +
   notes carry PR ref → Pass via substring fallback *)
let test_substring_fallback_passes_with_pr_ref () =
  let contract = make_contract () in
  let task = make_task ~contract:(Some contract) () in
  match
    Gate.decide
      ~lookup:(lookup_returns None)
      ~task_id:"task-legacy-pass"
      ~task_opt:(Some task)
      ~notes:"PR #18712 ready for verifier"
      ~handoff_context:None
      ()
  with
  | Gate.Pass -> ()
  | Gate.Reject { rule_id; _ } ->
    failf
      "Substring fallback should Pass when notes carry PR ref; got Reject \
       rule_id=%s"
      rule_id

(* §6.5.2 row 5b: None verdict + task.contract = Some _ +
   notes empty → Reject via substring fallback with legacy rule_id *)
let test_substring_fallback_rejects_when_empty () =
  let contract = make_contract () in
  let task = make_task ~contract:(Some contract) () in
  match
    Gate.decide
      ~lookup:(lookup_returns None)
      ~task_id:"task-legacy-reject"
      ~task_opt:(Some task)
      ~notes:""
      ~handoff_context:None
      ()
  with
  | Gate.Pass ->
    fail "Substring fallback should Reject when notes are empty and contract is set"
  | Gate.Reject { rule_id; _ } ->
    check string "legacy rule_id preserved"
      Gate.rule_id_substring_fallback
      rule_id

(* Bonus: rule_id constants are stable strings consumers can match on *)
let test_rule_id_constants_are_stable () =
  check string "violated rule_id" "cdal_verdict_violated" Gate.rule_id_violated;
  check string "inconclusive rule_id" "cdal_verdict_inconclusive_incomplete"
    Gate.rule_id_inconclusive;
  check string "substring fallback rule_id" "submit_verification_missing_evidence"
    Gate.rule_id_substring_fallback

let () =
  Alcotest.run
    "cdal_evidence_gate"
    [ ( "decision matrix"
      , [ test_case "row 1: Satisfied → Pass" `Quick test_satisfied_verdict_passes
        ; test_case "row 2: Violated → Reject with findings" `Quick
            test_violated_verdict_rejects_with_findings
        ; test_case "row 3a: Inconclusive + evidence satisfied → Pass" `Quick
            test_inconclusive_passes_when_evidence_satisfied
        ; test_case "row 3b: Inconclusive + evidence missing → Reject" `Quick
            test_inconclusive_rejects_when_evidence_missing
        ; test_case "row 3c: Inconclusive + completeness_gaps → Reject" `Quick
            test_inconclusive_rejects_when_completeness_gaps
        ; test_case "row 4: None + contract=None → Pass (analysis-only bypass)"
            `Quick test_no_verdict_no_contract_bypasses
        ; test_case "row 4 variant: None + task_opt=None → Pass" `Quick
            test_no_verdict_no_task_bypasses
        ; test_case "row 5a: None + contract=Some + PR ref → Pass (substring shim)"
            `Quick test_substring_fallback_passes_with_pr_ref
        ; test_case "row 5b: None + contract=Some + empty notes → Reject (legacy rule_id)"
            `Quick test_substring_fallback_rejects_when_empty
        ] )
    ; ( "stable constants"
      , [ test_case "rule_id constants" `Quick test_rule_id_constants_are_stable
        ] )
    ]
;;
