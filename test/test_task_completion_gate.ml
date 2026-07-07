(** Task_completion_gate — evidence-substantiveness decision tests.

    The gate verifies explicit verification submissions by the presence of
    evidence a reviewer can inspect downstream: substantive notes plus the
    contract's required_evidence, or a handoff reference. There is no verdict
    ledger; the gate consults only the task + notes + handoff. *)

open Alcotest
open Masc

module Gate = Task_completion_gate

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
  ; contract
  ; handoff_context
  ; cycle_count = 0
  ; reclaim_policy = None
  ; do_not_reclaim_reason = None
  }

let make_contract
      ?(strict = false)
      ?(completion_contract = [])
      ?(required_evidence = [])
      ?(inspect_gate_evidence = [])
      ?(verify_gate_evidence = [])
      ()
    : Masc_domain.task_contract
  =
  { strict
  ; completion_contract
  ; required_evidence
  ; inspect_gate_evidence
  ; verify_gate_evidence
  ; evidence_claims = []
  ; stale_claim_timeout_sec = 0
  ; links = { operation_id = None; session_id = None }
  }

let handoff_with_refs refs : Masc_domain.task_handoff_context =
  { summary = "submitted"
  ; reason = None
  ; next_step = None
  ; failure_mode = None
  ; reclaim_policy = None
  ; evidence_refs = refs
  ; updated_at = None
  ; updated_by = None
  }

(* ─────────────────────────────────────────────────────────────── *)
(* No contract -> explicit handoff evidence_refs required            *)
(* ─────────────────────────────────────────────────────────────── *)
let test_no_contract_without_handoff_refs_rejects () =
  let cases =
    [ None
    ; Some (handoff_with_refs [])
    ; Some (handoff_with_refs [ ""; "  " ])
    ]
  in
  List.iter
    (fun handoff_context ->
       match
         Gate.decide
           ~task_id:"task-analysis"
           ~task_opt:(Some (make_task ()))
           ~notes:"substantive notes alone do not satisfy no-contract evidence"
           ~handoff_context
           ()
       with
       | Gate.Pass -> fail "no-contract task without evidence_refs must Reject"
       | Gate.Reject { rule_id; payload_json; _ } ->
         check string "rule_id" Gate.rule_id_evidence_incomplete rule_id;
         (match payload_json with
          | `Assoc fields ->
            (match List.assoc_opt "required_evidence_unsatisfied" fields with
             | Some (`List [ `String "handoff_context.evidence_refs" ]) -> ()
             | _ -> fail "payload did not identify missing handoff evidence_refs")
          | _ -> fail "payload is not Assoc"))
    cases

let test_no_contract_with_handoff_refs_passes () =
  match
    Gate.decide
      ~task_id:"task-analysis"
      ~task_opt:(Some (make_task ()))
      ~notes:""
      ~handoff_context:(Some (handoff_with_refs [ "trace:task-1815" ]))
      ()
  with
  | Gate.Pass -> ()
  | Gate.Reject { rule_id; _ } ->
    failf "no-contract task with evidence_refs should Pass, got Reject rule_id=%s" rule_id

let test_no_contract_with_untrusted_handoff_refs_rejects () =
  List.iter
    (fun ref_ ->
       match
         Gate.decide
           ~task_id:"task-analysis"
           ~task_opt:(Some (make_task ()))
           ~notes:"substantive notes alone do not satisfy no-contract evidence"
           ~handoff_context:(Some (handoff_with_refs [ ref_ ]))
           ()
       with
       | Gate.Pass ->
         failf "untrusted no-contract handoff ref %S must not Pass" ref_
       | Gate.Reject { rule_id; payload_json; _ } ->
         check string "rule_id" Gate.rule_id_evidence_incomplete rule_id;
         (match payload_json with
          | `Assoc fields ->
            (match List.assoc_opt "required_evidence_unsatisfied" fields with
             | Some (`List [ `String "handoff_context.evidence_refs" ]) -> ()
             | _ -> fail "payload did not identify missing trusted handoff ref")
          | _ -> fail "payload is not Assoc"))
    [ "done"; "n/a"; "local prose"; "logs/output.json" ]

let test_no_task_passes () =
  match
    Gate.decide
      ~task_id:"task-ghost"
      ~task_opt:None
      ~notes:""
      ~handoff_context:None
      ()
  with
  | Gate.Pass -> ()
  | Gate.Reject { rule_id; _ } ->
    failf "missing task should Pass, got Reject rule_id=%s" rule_id

(* Contract + all required_evidence mentioned + substantive notes → Pass *)
let test_required_evidence_satisfied_passes () =
  let contract = make_contract ~required_evidence:[ "src/main.ml" ] () in
  let task = make_task ~contract:(Some contract) () in
  match
    Gate.decide
      ~task_id:"task-ev"
      ~task_opt:(Some task)
      ~notes:"completed work on src/main.ml"
      ~handoff_context:None
      ()
  with
  | Gate.Pass -> ()
  | Gate.Reject { rule_id; _ } ->
    failf "satisfied required_evidence should Pass, got Reject rule_id=%s" rule_id

(* Contract (no required_evidence) + substantive notes → Pass *)
let test_substantive_notes_pass () =
  let task = make_task ~contract:(Some (make_contract ())) () in
  match
    Gate.decide
      ~task_id:"task-notes"
      ~task_opt:(Some task)
      ~notes:"see commit abc123 for the typed evidence-gate collapse"
      ~handoff_context:None
      ()
  with
  | Gate.Pass -> ()
  | Gate.Reject { rule_id; _ } ->
    failf "substantive notes should Pass, got Reject rule_id=%s" rule_id

(* Contract (no required_evidence) + handoff reference url, empty notes → Pass *)
let test_handoff_reference_passes () =
  let task = make_task ~contract:(Some (make_contract ())) () in
  match
    Gate.decide
      ~task_id:"task-handoff"
      ~task_opt:(Some task)
      ~notes:""
      ~handoff_context:
        (Some (handoff_with_refs [ "https://example.test/pr/42" ]))
      ()
  with
  | Gate.Pass -> ()
  | Gate.Reject { rule_id; _ } ->
    failf "handoff reference should Pass, got Reject rule_id=%s" rule_id

let test_plain_handoff_reference_rejects () =
  let task = make_task ~contract:(Some (make_contract ())) () in
  List.iter
    (fun ref_ ->
       match
         Gate.decide
           ~task_id:"task-weak-handoff"
           ~task_opt:(Some task)
           ~notes:""
           ~handoff_context:(Some (handoff_with_refs [ ref_ ]))
           ()
       with
       | Gate.Pass ->
         failf "plain handoff text %S must not count as concrete evidence" ref_
       | Gate.Reject { rule_id; _ } ->
         check string "rule_id" Gate.rule_id_evidence_incomplete rule_id)
    [ "see retro"; "see retro." ]

let test_placeholder_handoff_reference_rejects () =
  let task = make_task ~contract:(Some (make_contract ())) () in
  List.iter
    (fun ref_ ->
       match
         Gate.decide
           ~task_id:"task-placeholder-handoff"
           ~task_opt:(Some task)
           ~notes:""
           ~handoff_context:(Some (handoff_with_refs [ ref_ ]))
           ()
       with
       | Gate.Pass ->
         failf "placeholder handoff ref %S must not count as evidence" ref_
       | Gate.Reject { rule_id; _ } ->
         check string "rule_id" Gate.rule_id_evidence_incomplete rule_id)
    [ "http://"; "https://"; "file://"; "trace:"; "turn:"; "receipt:"; "/"; "//"; "./" ]

let test_unvalidated_file_handoff_reference_rejects () =
  let task = make_task ~contract:(Some (make_contract ())) () in
  List.iter
    (fun ref_ ->
       match
         Gate.decide
           ~task_id:"task-file-handoff"
           ~task_opt:(Some task)
           ~notes:""
           ~handoff_context:(Some (handoff_with_refs [ ref_ ]))
           ()
       with
       | Gate.Pass ->
         failf
           "unvalidated file-shaped handoff ref %S must not count as trusted evidence"
           ref_
       | Gate.Reject { rule_id; _ } ->
         check string "rule_id" Gate.rule_id_evidence_incomplete rule_id)
    [ "logs/output.json"; "a/b"; "x.txt"; "file://logs/output.json"; "file:///tmp/proof.log" ]

let test_unvalidated_file_required_evidence_rejects () =
  List.iter
    (fun ref_ ->
       let contract = make_contract ~required_evidence:[ ref_ ] () in
       let task = make_task ~contract:(Some contract) () in
       match
         Gate.decide
           ~task_id:"task-file-required"
           ~task_opt:(Some task)
           ~notes:"substantive completion notes without the file-shaped reference"
           ~handoff_context:(Some (handoff_with_refs [ ref_ ]))
           ()
       with
       | Gate.Pass ->
         failf
           "unvalidated file-shaped handoff ref %S must not satisfy required_evidence"
           ref_
       | Gate.Reject { rule_id; payload_json; _ } ->
         check string "rule_id" Gate.rule_id_evidence_incomplete rule_id;
         (match payload_json with
          | `Assoc fields ->
            (match List.assoc_opt "required_evidence_unsatisfied" fields with
             | Some (`List [ `String actual ]) -> check string "unsatisfied" ref_ actual
             | _ -> fail "payload did not preserve unsatisfied file evidence")
          | _ -> fail "payload is not Assoc"))
    [ "logs/output.json"; "a/b"; "x.txt"; "file://logs/output.json" ]

let test_placeholder_required_evidence_reference_rejects () =
  let contract = make_contract ~required_evidence:[ "trace:" ] () in
  let task = make_task ~contract:(Some contract) () in
  match
    Gate.decide
      ~task_id:"task-placeholder-required-ref"
      ~task_opt:(Some task)
      ~notes:"substantive completion notes are present here"
      ~handoff_context:(Some (handoff_with_refs [ "trace:" ]))
      ()
  with
  | Gate.Pass ->
    fail "placeholder required_evidence reference must remain unsatisfied"
  | Gate.Reject { rule_id; payload_json; _ } ->
    check string "rule_id" Gate.rule_id_evidence_incomplete rule_id;
    (match payload_json with
     | `Assoc fields ->
       (match List.assoc_opt "required_evidence_unsatisfied" fields with
        | Some (`List [ `String "trace:" ]) -> ()
        | _ -> fail "payload did not preserve placeholder evidence entry")
     | _ -> fail "payload is not Assoc")

let test_evidence_ref_parser_ssot () =
  let parses_as label expected = function
    | Some actual -> check string label expected actual
    | None -> failf "%s did not parse" label
  in
  let rejects label raw =
    match Evidence_ref.of_string raw with
    | None -> ()
    | Some ref_ ->
      failf "%s should reject, parsed %S" label (Evidence_ref.to_string ref_)
  in
  Evidence_ref.of_string "https://example.test/pr/42"
  |> Option.map (function
    | Evidence_ref.Url value -> value
    | other -> Evidence_ref.to_string other)
  |> parses_as "url ref" "https://example.test/pr/42";
  Evidence_ref.of_string "PR#42"
  |> Option.map (function
    | Evidence_ref.Pr value -> string_of_int value
    | other -> Evidence_ref.to_string other)
  |> parses_as "PR ref" "42";
  Evidence_ref.of_string "trace:run-123"
  |> Option.map (function
    | Evidence_ref.Trace_ref (Evidence_ref.Trace, value) -> value
    | other -> Evidence_ref.to_string other)
  |> parses_as "trace ref" "run-123";
  Evidence_ref.of_string "logs/output.json"
  |> Option.map (function
    | Evidence_ref.File_path value -> value
    | other -> Evidence_ref.to_string other)
  |> parses_as "file path ref" "logs/output.json";
  List.iter
    (fun (label, raw) -> rejects label raw)
    [ "bare http", "http://"
    ; "bare https", "https://"
    ; "bare file URI", "file://"
    ; "bare trace", "trace:"
    ; "bare path separator", "/"
    ; "absolute path", "/etc/passwd"
    ; "parent-dir traversal", "../../etc/passwd"
    ; "parent-dir mid-segment", "logs/../../etc/passwd"
    ; "hex PR number", "PR#0x2A"
    ; "octal PR number", "#0o10"
    ; "signed PR number", "PR#+42"
    ]

let test_blank_required_evidence_rejects () =
  let contract = make_contract ~required_evidence:[ "  " ] () in
  let task = make_task ~contract:(Some contract) () in
  match
    Gate.decide
      ~task_id:"task-blank-required"
      ~task_opt:(Some task)
      ~notes:"substantive completion notes are present here"
      ~handoff_context:None
      ()
  with
  | Gate.Pass -> fail "blank required_evidence entry must not auto-satisfy"
  | Gate.Reject { rule_id; payload_json; _ } ->
    check string "rule_id" Gate.rule_id_evidence_incomplete rule_id;
    (match payload_json with
     | `Assoc fields ->
       (match List.assoc_opt "required_evidence_unsatisfied" fields with
        | Some (`List xs) -> check int "blank unsatisfied count" 1 (List.length xs)
        | _ -> fail "payload missing required_evidence_unsatisfied")
     | _ -> fail "payload is not Assoc")

(* Contract + required_evidence unsatisfied → Reject *)
let test_required_evidence_unsatisfied_rejects () =
  let contract =
    make_contract ~required_evidence:[ "test_results"; "coverage_report" ] ()
  in
  let task = make_task ~contract:(Some contract) () in
  match
    Gate.decide
      ~task_id:"task-missing"
      ~task_opt:(Some task)
      ~notes:"finished the work, see PR"
      ~handoff_context:None
      ()
  with
  | Gate.Pass -> fail "unsatisfied required_evidence must Reject"
  | Gate.Reject { rule_id; payload_json; _ } ->
    check string "rule_id" Gate.rule_id_evidence_incomplete rule_id;
    (match payload_json with
     | `Assoc fields ->
       (match List.assoc_opt "required_evidence_unsatisfied" fields with
        | Some (`List xs) -> check int "unsatisfied count" 2 (List.length xs)
        | _ -> fail "payload missing required_evidence_unsatisfied");
       (match List.assoc_opt "evidence_summary" fields with
        | Some (`Assoc _) -> ()
        | _ -> fail "payload missing evidence_summary")
     | _ -> fail "payload is not Assoc")

let test_required_evidence_embedded_substring_rejects () =
  let contract = make_contract ~required_evidence:[ "error" ] () in
  let task = make_task ~contract:(Some contract) () in
  match
    Gate.decide
      ~task_id:"task-embedded-substring"
      ~task_opt:(Some task)
      ~notes:"completed an errorless run with enough context"
      ~handoff_context:None
      ()
  with
  | Gate.Pass -> fail "embedded substring must not satisfy required_evidence"
  | Gate.Reject { rule_id; payload_json; _ } ->
    check string "rule_id" Gate.rule_id_evidence_incomplete rule_id;
    (match payload_json with
     | `Assoc fields ->
       (match List.assoc_opt "required_evidence_unsatisfied" fields with
        | Some (`List [ `String "error" ]) -> ()
        | _ -> fail "payload did not preserve unsatisfied evidence entry")
     | _ -> fail "payload is not Assoc")

let test_required_evidence_extended_reference_rejects () =
  let cases =
    [ "src/main.ml", "completed work in src/main.ml.bak with enough notes"
    ; "file.tar", "completed work in file.tar.gz with enough notes"
    ; ( "https://example.test/pr/42"
      , "completed work in https://example.test/pr/42.extra with enough notes" )
    ; "trace:run-123", "completed work in trace:run-123:retry with enough notes"
    ]
  in
  List.iter
    (fun (required, notes) ->
       let contract = make_contract ~required_evidence:[ required ] () in
       let task = make_task ~contract:(Some contract) () in
       match
         Gate.decide
           ~task_id:"task-extended-reference"
           ~task_opt:(Some task)
           ~notes
           ~handoff_context:None
           ()
       with
       | Gate.Pass ->
         failf
           "longer reference in notes must not satisfy required_evidence %S"
           required
       | Gate.Reject { rule_id; payload_json; _ } ->
         check string "rule_id" Gate.rule_id_evidence_incomplete rule_id;
         (match payload_json with
          | `Assoc fields ->
            (match List.assoc_opt "required_evidence_unsatisfied" fields with
             | Some (`List [ `String actual ]) -> check string "unsatisfied" required actual
             | _ -> fail "payload did not preserve unsatisfied evidence entry")
          | _ -> fail "payload is not Assoc"))
    cases

let test_required_evidence_path_with_punctuation_passes () =
  let contract = make_contract ~required_evidence:[ "src/main.ml" ] () in
  let task = make_task ~contract:(Some contract) () in
  match
    Gate.decide
      ~task_id:"task-path-boundary"
      ~task_opt:(Some task)
      ~notes:"implemented the fix in src/main.ml. review notes attached"
      ~handoff_context:None
      ()
  with
  | Gate.Pass -> ()
  | Gate.Reject { rule_id; _ } ->
    failf "path mention followed by punctuation should Pass, got %s" rule_id

let test_required_evidence_word_with_colon_passes () =
  let contract = make_contract ~required_evidence:[ "error" ] () in
  let task = make_task ~contract:(Some contract) () in
  match
    Gate.decide
      ~task_id:"task-word-colon-boundary"
      ~task_opt:(Some task)
      ~notes:"Error: reproduced and fixed with detailed validation notes"
      ~handoff_context:None
      ()
  with
  | Gate.Pass -> ()
  | Gate.Reject { rule_id; _ } ->
    failf "word mention followed by colon should Pass, got %s" rule_id

(* Contract (no required_evidence) + placeholder notes, no handoff → Reject *)
let test_placeholder_notes_reject () =
  let task = make_task ~contract:(Some (make_contract ())) () in
  List.iter
    (fun placeholder ->
       match
         Gate.decide
           ~task_id:"task-placeholder"
           ~task_opt:(Some task)
           ~notes:placeholder
           ~handoff_context:None
           ()
       with
       | Gate.Pass ->
         failf "placeholder note %S should Reject" placeholder
       | Gate.Reject { rule_id; _ } ->
         check string "rule_id" Gate.rule_id_evidence_incomplete rule_id)
    [ ""; "done"; "ok"; "n/a"; "pending"; "draft" ]

let test_rule_id_constant_stable () =
  check string "evidence_incomplete rule_id" "cdal_evidence_incomplete"
    Gate.rule_id_evidence_incomplete

let () =
  Alcotest.run
    "task_completion_gate"
    [ ( "evidence-substantiveness"
      , [ test_case "no contract without handoff refs → Reject" `Quick
            test_no_contract_without_handoff_refs_rejects
        ; test_case "no contract with handoff refs → Pass" `Quick
            test_no_contract_with_handoff_refs_passes
        ; test_case "no contract with untrusted handoff refs → Reject" `Quick
            test_no_contract_with_untrusted_handoff_refs_rejects
        ; test_case "no task → Pass" `Quick test_no_task_passes
        ; test_case "required_evidence satisfied → Pass" `Quick
            test_required_evidence_satisfied_passes
        ; test_case "substantive notes → Pass" `Quick test_substantive_notes_pass
        ; test_case "handoff reference → Pass" `Quick test_handoff_reference_passes
        ; test_case "plain handoff text → Reject" `Quick
            test_plain_handoff_reference_rejects
        ; test_case "placeholder handoff ref → Reject" `Quick
            test_placeholder_handoff_reference_rejects
        ; test_case "unvalidated file handoff ref → Reject" `Quick
            test_unvalidated_file_handoff_reference_rejects
        ; test_case "unvalidated file required ref → Reject" `Quick
            test_unvalidated_file_required_evidence_rejects
        ; test_case "placeholder required ref → Reject" `Quick
            test_placeholder_required_evidence_reference_rejects
        ; test_case "evidence ref parser SSOT" `Quick test_evidence_ref_parser_ssot
        ; test_case "blank required_evidence → Reject" `Quick
            test_blank_required_evidence_rejects
        ; test_case "required_evidence unsatisfied → Reject" `Quick
            test_required_evidence_unsatisfied_rejects
        ; test_case "embedded required_evidence substring → Reject" `Quick
            test_required_evidence_embedded_substring_rejects
        ; test_case "extended required_evidence reference → Reject" `Quick
            test_required_evidence_extended_reference_rejects
        ; test_case "required_evidence path punctuation → Pass" `Quick
            test_required_evidence_path_with_punctuation_passes
        ; test_case "required_evidence word colon → Pass" `Quick
            test_required_evidence_word_with_colon_passes
        ; test_case "placeholder notes → Reject" `Quick
            test_placeholder_notes_reject
        ] )
    ; ( "stable constants"
      , [ test_case "rule_id constant" `Quick test_rule_id_constant_stable ] )
    ]
;;
