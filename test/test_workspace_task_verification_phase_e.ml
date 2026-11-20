(* The transition layer does not decide whether evidence is sufficient. It
   preserves explicitly typed producer refs and represents completion prose as
   [note:] evidence; contract requirements are projected separately. *)

module V = Workspace_task_verification

let test_analysis_only_with_plain_notes_keeps_notes () =
  (* Non-empty notes reach the configured LLM as an explicit narrative item. *)
  let refs =
    V.verification_submission_evidence_refs ~handoff:None
      ~notes:"investigated 24h log audit"
  in
  Alcotest.(check (list string))
    "plain prose notes become typed narrative evidence"
    [ "note:investigated 24h log audit" ]
    refs

let test_analysis_only_with_empty_notes_returns_empty () =
  let refs = V.verification_submission_evidence_refs ~handoff:None ~notes:"" in
  Alcotest.(check (list string)) "empty notes -> empty refs" [] refs

let test_placeholder_like_notes_reach_llm_evidence () =
  let refs = V.verification_submission_evidence_refs ~handoff:None ~notes:"tbd" in
  Alcotest.(check (list string)) "tbd is preserved for LLM judgment" [ "note:tbd" ] refs;
  let refs2 =
    V.verification_submission_evidence_refs ~handoff:None ~notes:"  DRAFT  "
  in
  Alcotest.(check (list string)) "source whitespace is normalized only" [ "note:DRAFT" ] refs2

let test_handoff_context_evidence_refs_survive_typed () =
  (* Typed producer refs are preserved; the configured LLM judges their
     evidentiary value. *)
  let handoff_context : Masc_domain.task_handoff_context =
    { summary = "investigated repeat failure"
    ; reason = None
    ; next_step = None
    ; failure_mode = None
    ; evidence_refs = [ "note:see retro"; "note:n/a"; "  " ]
    ; updated_at = None
    ; updated_by = None
    }
  in
  let refs =
    V.verification_submission_evidence_refs ~handoff:(Some handoff_context) ~notes:""
  in
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
        ; Alcotest.test_case "handoff typed evidence survives" `Quick
            test_handoff_context_evidence_refs_survive_typed
        ] )
    ]
