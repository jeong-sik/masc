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
      ~notes:"PR #999"
      ~handoff_context:None
      ()
  with
  | Gate.Pass ->
    fail "Violated verdict should Reject even when notes contain a PR ref"
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

(* §6.5.2 row 5a (RFC-0109 Phase E-1, 2026-05-27): None verdict +
   task.contract = Some _ + substantive notes → Pass via evidence-based
   fallback.  Prior policy rejected even with a PR ref; Phase E-1 opens
   a recovery path when the contract has no [required_evidence] entries
   to enforce and the keeper supplied non-placeholder notes.  This
   closes the production dead-end where keeper_task_done →
   verifier-gate redirect → cdal_verdict_missing Reject formed an
   unrecoverable loop (logged in 2026-05-27 fleet runtime). *)
let test_missing_verdict_passes_with_substantive_notes () =
  let contract = make_contract () in
  let task = make_task ~contract:(Some contract) () in
  match
    Gate.decide
      ~lookup:(lookup_returns None)
      ~task_id:"task-evidence-pass"
      ~task_opt:(Some task)
      ~notes:"PR #18712 ready for verifier — see commit abc123 for the typed CDAL bridge fix"
      ~handoff_context:None
      ()
  with
  | Gate.Pass -> ()
  | Gate.Reject { rule_id; _ } ->
    failf
      "Missing CDAL verdict should Pass via evidence-based fallback when \
       notes are substantive and no required_evidence is enforced, got \
       Reject rule_id=%s"
      rule_id

(* RFC-0109 Phase E-1: evidence fallback closes when the contract
   *does* enforce required_evidence and the keeper failed to mention
   the entries verbatim — Phase E-1 must not be a blanket bypass. *)
let test_missing_verdict_rejects_when_required_evidence_unsatisfied () =
  let contract =
    make_contract ~required_evidence:[ "test_results"; "coverage_report" ] ()
  in
  let task = make_task ~contract:(Some contract) () in
  match
    Gate.decide
      ~lookup:(lookup_returns None)
      ~task_id:"task-missing-evidence"
      ~task_opt:(Some task)
      ~notes:"finished the work, see PR"
      ~handoff_context:None
      ()
  with
  | Gate.Pass ->
    fail
      "Missing CDAL verdict must Reject when contract.required_evidence \
       entries are not mentioned in notes/handoff"
  | Gate.Reject { rule_id; payload_json; _ } ->
    check string "rule_id" Gate.rule_id_missing_verdict rule_id;
    (match payload_json with
     | `Assoc fields ->
       (match List.assoc_opt "evidence_summary" fields with
        | Some (`Assoc _) -> ()
        | _ -> fail "payload missing evidence_summary diagnostic")
     | _ -> fail "payload is not Assoc")

(* RFC-0109 Phase E-1: handoff_context.evidence_refs alone (no
   substantive notes, contract.required_evidence = []) counts as
   "evidence supplied". *)
let test_missing_verdict_passes_with_handoff_evidence_refs () =
  let contract = make_contract () in
  let handoff : Masc_domain.task_handoff_context =
    { summary = "submitted"
    ; reason = None
    ; next_step = None
    ; failure_mode = None
    ; reclaim_policy = None
    ; evidence_refs = [ "https://github.com/jeong-sik/masc-mcp/pull/18712" ]
    ; updated_at = None
    ; updated_by = None
    }
  in
  let task = make_task ~contract:(Some contract) () in
  match
    Gate.decide
      ~lookup:(lookup_returns None)
      ~task_id:"task-handoff-evidence"
      ~task_opt:(Some task)
      ~notes:""
      ~handoff_context:(Some handoff)
      ()
  with
  | Gate.Pass -> ()
  | Gate.Reject { rule_id; _ } ->
    failf
      "Missing CDAL verdict should Pass when handoff.evidence_refs is \
       non-empty, got Reject rule_id=%s"
      rule_id

(* Phase E-1 must reject pure-placeholder notes (kept from old §6.5.2
   row 5b but expanded: also rejects single-word placeholders like
   "done" / "ok" even though they pass the length=0 check). *)
let test_missing_verdict_rejects_with_placeholder_notes () =
  let contract = make_contract () in
  let task = make_task ~contract:(Some contract) () in
  List.iter
    (fun placeholder ->
       match
         Gate.decide
           ~lookup:(lookup_returns None)
           ~task_id:"task-placeholder"
           ~task_opt:(Some task)
           ~notes:placeholder
           ~handoff_context:None
           ()
       with
       | Gate.Pass ->
         failf
           "Placeholder note %S should not pass evidence-based fallback"
           placeholder
       | Gate.Reject { rule_id; _ } ->
         check string "rule_id" Gate.rule_id_missing_verdict rule_id)
    [ ""; "done"; "ok"; "n/a"; "pending"; "draft" ]

(* Bonus: rule_id constants are stable strings consumers can match on *)
let test_rule_id_constants_are_stable () =
  check string "violated rule_id" "cdal_verdict_violated" Gate.rule_id_violated;
  check string "inconclusive rule_id" "cdal_verdict_inconclusive_incomplete"
    Gate.rule_id_inconclusive;
  check string "missing verdict rule_id" "cdal_verdict_missing"
    Gate.rule_id_missing_verdict

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
        ; test_case
            "row 5a (Phase E-1): None + contract=Some + substantive notes \
             → Pass via evidence fallback"
            `Quick test_missing_verdict_passes_with_substantive_notes
        ; test_case
            "row 5a' (Phase E-1): None + contract=Some + \
             handoff.evidence_refs → Pass via evidence fallback"
            `Quick test_missing_verdict_passes_with_handoff_evidence_refs
        ; test_case
            "row 5b (Phase E-1): None + contract.required_evidence \
             unsatisfied → Reject"
            `Quick test_missing_verdict_rejects_when_required_evidence_unsatisfied
        ; test_case
            "row 5c (Phase E-1): None + placeholder notes → Reject"
            `Quick test_missing_verdict_rejects_with_placeholder_notes
        ] )
    ; ( "stable constants"
      , [ test_case "rule_id constants" `Quick test_rule_id_constants_are_stable
        ] )
    ]
;;
