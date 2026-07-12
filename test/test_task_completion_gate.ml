(** Task_completion_gate — L1 evidence-gate decision tests (RFC-0311 Phase 1).

    The gate accepts a completion iff the caller supplies at least one trusted,
    reviewer-inspectable evidence reference on handoff_context.evidence_refs.
    Reference shape alone is not trusted: the gate validates refs against the
    local base path / artifact store. Completion notes are IGNORED for the
    decision, the contract's required_evidence entries are NOT consulted, and a
    missing live task fails closed. These tests pin those invariants and guard
    against a regression to notes/substring matching or shape-only trust. *)

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
  ; predecessor_task_id = None
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

let rec mkdir_p path =
  if Sys.file_exists path then ()
  else begin
    let parent = Filename.dirname path in
    if not (String.equal parent path) then mkdir_p parent;
    try Unix.mkdir path 0o755 with
    | Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

let write_file path contents =
  mkdir_p (Filename.dirname path);
  let output = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr output)
    (fun () -> output_string output contents)

let with_base_path f =
  let dir = Filename.temp_file "task-completion-gate-" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  f dir

let seed_trace_artifact ~base_path trace_id =
  let path =
    Filename.concat
      (Filename.concat
         (Filename.concat base_path ".masc")
         "trajectories/gate-test-keeper")
      (trace_id ^ ".jsonl")
  in
  write_file path
    {|{"type":"evidence_gate_test","trace_id":"test-trace","turn":0}|}

let seed_file_artifact ~base_path rel_path =
  write_file (Filename.concat base_path rel_path)
    {|{"type":"evidence_gate_test","status":"ok"}|}

(* Assert the reject payload names the one missing thing: a trusted evidence
   reference on handoff_context.evidence_refs. This token is uniform across
   contract/no-contract rejects in Phase 1. *)
let check_missing_evidence_payload payload_json =
  match payload_json with
  | `Assoc fields ->
    (match List.assoc_opt "required_evidence_unsatisfied" fields with
     | Some (`List [ `String "handoff_context.evidence_refs" ]) -> ()
     | _ -> fail "payload did not identify the missing trusted evidence_refs")
  | _ -> fail "payload is not Assoc"

(* ─────────────────────────────────────────────────────────────── *)
(* No contract -> a trusted handoff evidence_ref is required          *)
(* ─────────────────────────────────────────────────────────────── *)
let test_no_contract_without_handoff_refs_rejects () =
  with_base_path (fun base_path ->
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
             ~base_path
             ~task_id:"task-analysis"
             ~task_opt:(Some (make_task ()))
             ~notes:"substantive notes alone do not satisfy the evidence gate"
             ~handoff_context
             ()
         with
         | Gate.Pass -> fail "task without evidence_refs must Reject"
         | Gate.Reject { rule_id; payload_json; _ } ->
           check string "rule_id" Gate.rule_id_evidence_incomplete rule_id;
           check_missing_evidence_payload payload_json)
      cases)

let test_no_contract_with_handoff_refs_passes () =
  with_base_path (fun base_path ->
    seed_trace_artifact ~base_path "task-1815";
    match
      Gate.decide
        ~base_path
        ~task_id:"task-analysis"
        ~task_opt:(Some (make_task ()))
        ~notes:""
        ~handoff_context:(Some (handoff_with_refs [ "trace:task-1815" ]))
        ()
    with
    | Gate.Pass -> ()
    | Gate.Reject { rule_id; _ } ->
      failf "task with a validated evidence_ref should Pass, got Reject rule_id=%s" rule_id)

let test_no_contract_with_untrusted_handoff_refs_rejects () =
  with_base_path (fun base_path ->
    List.iter
      (fun ref_ ->
         match
           Gate.decide
             ~base_path
             ~task_id:"task-analysis"
             ~task_opt:(Some (make_task ()))
             ~notes:"substantive notes alone do not satisfy the evidence gate"
             ~handoff_context:(Some (handoff_with_refs [ ref_ ]))
             ()
         with
         | Gate.Pass ->
           failf "untrusted handoff ref %S must not Pass" ref_
         | Gate.Reject { rule_id; payload_json; _ } ->
           check string "rule_id" Gate.rule_id_evidence_incomplete rule_id;
           check_missing_evidence_payload payload_json)
      [ "done"; "n/a"; "local prose"; "logs/output.json" ])

(* A missing live task fails closed (defense-in-depth; the production caller
   rejects a missing task before the gate). *)
let test_no_task_rejects () =
  with_base_path (fun base_path ->
    match
      Gate.decide
        ~base_path
        ~task_id:"task-ghost"
        ~task_opt:None
        ~notes:""
        ~handoff_context:None
        ()
    with
    | Gate.Pass -> fail "missing task must Reject (fail closed)"
    | Gate.Reject { rule_id; _ } ->
      check string "rule_id" Gate.rule_id_evidence_incomplete rule_id)

(* A contracted task passes on a trusted handoff ref, empty notes. *)
let test_contract_with_handoff_ref_passes () =
  with_base_path (fun base_path ->
    seed_trace_artifact ~base_path "task-ev-proof";
    let contract = make_contract ~required_evidence:[ "src/main.ml" ] () in
    let task = make_task ~contract:(Some contract) () in
    match
      Gate.decide
        ~base_path
        ~task_id:"task-ev"
        ~task_opt:(Some task)
        ~notes:""
        ~handoff_context:(Some (handoff_with_refs [ "trace:task-ev-proof" ]))
        ()
    with
    | Gate.Pass -> ()
    | Gate.Reject { rule_id; _ } ->
      failf "contracted task with a validated ref should Pass, got Reject rule_id=%s" rule_id)

(* TRIPWIRE (RFC-0311 §6): substantive notes ALONE must not pass. The old gate
   accepted a >=20-char note; the new gate ignores notes entirely. *)
let test_substantive_notes_alone_reject () =
  with_base_path (fun base_path ->
    let task = make_task ~contract:(Some (make_contract ())) () in
    match
      Gate.decide
        ~base_path
        ~task_id:"task-notes"
        ~task_opt:(Some task)
        ~notes:"see commit abc123 for the typed evidence-gate collapse, all green"
        ~handoff_context:None
        ()
    with
    | Gate.Pass -> fail "substantive notes alone must Reject (notes are not proof)"
    | Gate.Reject { rule_id; payload_json; _ } ->
      check string "rule_id" Gate.rule_id_evidence_incomplete rule_id;
      check_missing_evidence_payload payload_json)

let test_handoff_reference_passes () =
  with_base_path (fun base_path ->
    seed_file_artifact ~base_path ".masc/harness-evidence/proof.json";
    let task = make_task ~contract:(Some (make_contract ())) () in
    match
      Gate.decide
        ~base_path
        ~task_id:"task-handoff"
        ~task_opt:(Some task)
        ~notes:""
        ~handoff_context:
          (Some (handoff_with_refs [ ".masc/harness-evidence/proof.json" ]))
        ()
    with
    | Gate.Pass -> ()
    | Gate.Reject { rule_id; _ } ->
      failf "validated handoff reference should Pass, got Reject rule_id=%s" rule_id)

let test_plain_handoff_reference_rejects () =
  with_base_path (fun base_path ->
    let task = make_task ~contract:(Some (make_contract ())) () in
    List.iter
      (fun ref_ ->
         match
           Gate.decide
             ~base_path
             ~task_id:"task-weak-handoff"
             ~task_opt:(Some task)
             ~notes:""
             ~handoff_context:(Some (handoff_with_refs [ ref_ ]))
             ()
         with
         | Gate.Pass ->
           failf "plain handoff text %S must not count as trusted evidence" ref_
         | Gate.Reject { rule_id; _ } ->
           check string "rule_id" Gate.rule_id_evidence_incomplete rule_id)
      [ "see retro"; "see retro." ])

let test_placeholder_handoff_reference_rejects () =
  with_base_path (fun base_path ->
    let task = make_task ~contract:(Some (make_contract ())) () in
    List.iter
      (fun ref_ ->
         match
           Gate.decide
             ~base_path
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
      [ "http://"; "https://"; "file://"; "trace:"; "turn:"; "receipt:"; "/"; "//"; "./" ])

let test_unvalidated_file_handoff_reference_rejects () =
  with_base_path (fun base_path ->
    let task = make_task ~contract:(Some (make_contract ())) () in
    List.iter
      (fun ref_ ->
         match
           Gate.decide
             ~base_path
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
      [ "logs/output.json"; "a/b"; "x.txt"; "file://logs/output.json"; "file:///tmp/proof.log" ])

let test_shape_only_handoff_reference_rejects () =
  with_base_path (fun base_path ->
    let task = make_task ~contract:(Some (make_contract ())) () in
    List.iter
      (fun ref_ ->
         match
           Gate.decide
             ~base_path
             ~task_id:"task-shape-only-handoff"
             ~task_opt:(Some task)
             ~notes:""
             ~handoff_context:(Some (handoff_with_refs [ ref_ ]))
             ()
         with
         | Gate.Pass ->
           failf "shape-only handoff ref %S must not count as trusted evidence" ref_
         | Gate.Reject { rule_id; _ } ->
           check string "rule_id" Gate.rule_id_evidence_incomplete rule_id)
      [ "https://example.test/pr/42"
      ; "PR#123"
      ; "abcdef0"
      ; "trace:missing-local-trace"
      ; "turn:missing-local-trace#1"
      ; "receipt:missing-local-trace#1"
      ])

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

(* TRIPWIRE (RFC-0311 §6): a contract whose required_evidence names the work is
   NOT rescued by notes that mention it — only a trusted handoff ref passes. *)
let test_contract_without_trusted_ref_rejects () =
  with_base_path (fun base_path ->
    let contract =
      make_contract ~required_evidence:[ "test_results"; "coverage_report" ] ()
    in
    let task = make_task ~contract:(Some contract) () in
    match
      Gate.decide
        ~base_path
        ~task_id:"task-missing"
        ~task_opt:(Some task)
        ~notes:"finished the work, updated test_results and coverage_report, see PR"
        ~handoff_context:None
        ()
    with
    | Gate.Pass -> fail "contract without a trusted handoff ref must Reject"
    | Gate.Reject { rule_id; payload_json; _ } ->
      check string "rule_id" Gate.rule_id_evidence_incomplete rule_id;
      check_missing_evidence_payload payload_json;
      (match payload_json with
       | `Assoc fields ->
         (match List.assoc_opt "evidence_summary" fields with
          | Some (`Assoc _) -> ()
          | _ -> fail "payload missing evidence_summary")
       | _ -> fail "payload is not Assoc"))

let test_placeholder_notes_reject () =
  with_base_path (fun base_path ->
    let task = make_task ~contract:(Some (make_contract ())) () in
    List.iter
      (fun placeholder ->
         match
           Gate.decide
             ~base_path
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
      [ ""; "done"; "ok"; "n/a"; "pending"; "draft" ])

let test_commit_ref_in_non_git_base_path_rejects () =
  with_base_path (fun base_path ->
    let handoff = handoff_with_refs ["commit:abc123def"] in
    let task =
      make_task ~handoff_context:(Some handoff) ()
    in
    match
      Gate.decide ~base_path ~task_id:task.id
        ~task_opt:(Some task) ~notes:""
        ~handoff_context:handoff ()
    with
    | Gate.Pass ->
      fail "commit ref in non-git base_path should Reject"
    | Gate.Reject { rule_id; _ } ->
      check string "rule_id" Gate.rule_id_evidence_incomplete rule_id)

let test_rule_id_constant_stable () =
  check string "evidence_incomplete rule_id" "cdal_evidence_incomplete"
    Gate.rule_id_evidence_incomplete

let () =
  Alcotest.run
    "task_completion_gate"
    [ ( "evidence-gate"
      , [ test_case "no contract without handoff refs → Reject" `Quick
            test_no_contract_without_handoff_refs_rejects
        ; test_case "no contract with trusted handoff ref → Pass" `Quick
            test_no_contract_with_handoff_refs_passes
        ; test_case "no contract with untrusted handoff refs → Reject" `Quick
            test_no_contract_with_untrusted_handoff_refs_rejects
        ; test_case "no task → Reject (fail closed)" `Quick test_no_task_rejects
        ; test_case "contract with trusted handoff ref → Pass" `Quick
            test_contract_with_handoff_ref_passes
        ; test_case "substantive notes alone → Reject" `Quick
            test_substantive_notes_alone_reject
        ; test_case "trusted handoff reference → Pass" `Quick
            test_handoff_reference_passes
        ; test_case "plain handoff text → Reject" `Quick
            test_plain_handoff_reference_rejects
        ; test_case "placeholder handoff ref → Reject" `Quick
            test_placeholder_handoff_reference_rejects
        ; test_case "unvalidated file handoff ref → Reject" `Quick
            test_unvalidated_file_handoff_reference_rejects
        ; test_case "shape-only handoff ref → Reject" `Quick
            test_shape_only_handoff_reference_rejects
        ; test_case "evidence ref parser SSOT" `Quick test_evidence_ref_parser_ssot
        ; test_case "contract without trusted ref → Reject" `Quick
            test_contract_without_trusted_ref_rejects
        ; test_case "placeholder notes → Reject" `Quick
          test_placeholder_notes_reject
        ; test_case "commit ref in non-git base_path → Reject" `Quick
          test_commit_ref_in_non_git_base_path_rejects
      , [ test_case "rule_id constant" `Quick test_rule_id_constant_stable ] )
    ]
;;
