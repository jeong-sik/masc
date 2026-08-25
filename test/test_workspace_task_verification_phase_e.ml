(* RFC-0109 Phase E regression guard.

   The transition layer does not decide whether evidence is sufficient. It
   preserves explicitly typed producer refs and represents completion prose as
   [note:] evidence; contract requirements are projected separately. *)

module V = Workspace_task_verification

let dummy_task ?contract ?handoff_context () : Masc_domain.task =
  { id = "t-phase-e"
  ; title = "phase e regression"
  ; description = ""
  ; files = []
  ; created_at = "2026-05-27T00:00:00Z"
  ; task_status = Masc_domain.Todo
  ; priority = 5
  ; created_by = None
  ; predecessor_task_id = None
  ; contract
  ; handoff_context
  ; cycle_count = 0
  ; reclaim_policy = None
  ; execution_links = Masc_domain.no_execution_links
  ; do_not_reclaim_reason = None
  ; skills = []
  }

let test_analysis_only_with_plain_notes_keeps_notes () =
  (* Non-empty notes reach the configured LLM as an explicit narrative item. *)
  let task = dummy_task () in
  let refs =
    V.verification_submission_evidence_refs task ~notes:"investigated 24h log audit" None
  in
  Alcotest.(check (list string))
    "plain prose notes become typed narrative evidence"
    [ "note:investigated 24h log audit" ]
    refs

let test_analysis_only_with_empty_notes_returns_empty () =
  let task = dummy_task () in
  let refs = V.verification_submission_evidence_refs task ~notes:"" None in
  Alcotest.(check (list string)) "empty notes -> empty refs" [] refs

let test_placeholder_like_notes_reach_llm_evidence () =
  let task = dummy_task () in
  let refs = V.verification_submission_evidence_refs task ~notes:"tbd" None in
  Alcotest.(check (list string)) "tbd is preserved for LLM judgment" [ "note:tbd" ] refs;
  let refs2 = V.verification_submission_evidence_refs task ~notes:"  DRAFT  " None in
  Alcotest.(check (list string)) "source whitespace is normalized only" [ "note:DRAFT" ] refs2

let test_contracted_task_keeps_requirements_out_of_submitted_refs () =
  let contract : Masc_domain.task_contract =
    { strict = false
    ; completion_contract = []
    ; required_evidence = [ "test_keeper_lifecycle PASS" ]
    ; inspect_gate_evidence = []
    ; verify_gate_evidence = [ "PR #18810 merged" ]
    }
  in
  let task = dummy_task ~contract () in
  let refs = V.verification_submission_evidence_refs task ~notes:"" None in
  Alcotest.(check (list string))
    "contract requirements are not submitted evidence"
    []
    refs

let test_handoff_context_evidence_refs_survive_typed () =
  (* Typed producer refs are preserved; the configured LLM judges their
     evidentiary value. *)
  let handoff_context : Masc_domain.task_handoff_context =
    { summary = "investigated repeat failure"
    ; reason = None
    ; next_step = None
    ; failure_mode = None
    ; reclaim_policy = None
    ; evidence_refs = [ "note:see retro"; "note:n/a"; "  " ]
    ; updated_at = None
    ; updated_by = None
    }
  in
  let task = dummy_task ~handoff_context () in
  let refs = V.verification_submission_evidence_refs task ~notes:"" None in
  Alcotest.(check bool)
    "typed handoff evidence_ref survives" true
    (List.mem "note:see retro" refs);
  Alcotest.(check bool)
    "n/a preserved for LLM judgment" true
    (List.mem "note:n/a" refs);
  Alcotest.(check bool)
    "non-empty summary survives" true
    (List.mem "note:investigated repeat failure" refs)

let () =
  Alcotest.run
    "task_state_verification_phase_e"
    [ ( "phase_e_regression"
      , [ Alcotest.test_case "analysis-only plain notes" `Quick
            test_analysis_only_with_plain_notes_keeps_notes
        ; Alcotest.test_case "empty notes" `Quick
            test_analysis_only_with_empty_notes_returns_empty
        ; Alcotest.test_case "placeholder-like values reach LLM" `Quick
            test_placeholder_like_notes_reach_llm_evidence
        ; Alcotest.test_case "contract refs stay requirements" `Quick
            test_contracted_task_keeps_requirements_out_of_submitted_refs
        ; Alcotest.test_case "handoff typed evidence survives" `Quick
            test_handoff_context_evidence_refs_survive_typed
        ] )
    ]
