(* RFC-0109 Phase E regression guard.

   Before Phase E, task-state verification applied a substring
   classifier (`/pull/` / `commit:` / `branch:` / `file:` ...
   token matching) inside the transition layer's
   [verification_submission_evidence_refs]. Analysis-only tasks (no
   contract, no handoff_context, plain prose notes) had no way to pass.

   Phase E retired the substring filter. The Task LLM boundary now receives
   every non-empty source value and decides whether prose is meaningful;
   local placeholder vocabulary is not execution authority. *)

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
  ; do_not_reclaim_reason = None
  }

let test_analysis_only_with_plain_notes_keeps_notes () =
  (* Pre Phase-E: empty result because notes had no substring tokens.
     Current: all non-empty notes reach the configured LLM. *)
  let task = dummy_task () in
  let refs =
    V.verification_submission_evidence_refs task ~notes:"investigated 24h log audit" None
  in
  Alcotest.(check (list string))
    "plain prose notes survive Phase E"
    [ "investigated 24h log audit" ]
    refs

let test_analysis_only_with_empty_notes_returns_empty () =
  let task = dummy_task () in
  let refs = V.verification_submission_evidence_refs task ~notes:"" None in
  Alcotest.(check (list string)) "empty notes -> empty refs" [] refs

let test_placeholder_like_notes_reach_llm_evidence () =
  let task = dummy_task () in
  let refs = V.verification_submission_evidence_refs task ~notes:"tbd" None in
  Alcotest.(check (list string)) "tbd is preserved for LLM judgment" [ "tbd" ] refs;
  let refs2 = V.verification_submission_evidence_refs task ~notes:"  DRAFT  " None in
  Alcotest.(check (list string)) "source whitespace is normalized only" [ "DRAFT" ] refs2

let test_contracted_task_includes_contract_refs () =
  let contract : Masc_domain.task_contract =
    { strict = false
    ; completion_contract = []
    ; required_evidence = [ "test_keeper_lifecycle PASS" ]
    ; inspect_gate_evidence = []
    ; verify_gate_evidence = [ "PR #18810 merged" ]
    ; evidence_claims = []
    ; stale_claim_timeout_sec = 0
    ; links = { operation_id = None; session_id = None }
    }
  in
  let task = dummy_task ~contract () in
  let refs = V.verification_submission_evidence_refs task ~notes:"" None in
  Alcotest.(check bool)
    "verify_gate_evidence included"
    true
    (List.mem "PR #18810 merged" refs);
  Alcotest.(check bool)
    "required_evidence included"
    true
    (List.mem "test_keeper_lifecycle PASS" refs)

let test_handoff_context_evidence_refs_survive_plain_string () =
  (* Every non-empty source value is preserved; the configured LLM judges its
     evidentiary value. *)
  let handoff_context : Masc_domain.task_handoff_context =
    { summary = "investigated repeat failure"
    ; reason = None
    ; next_step = None
    ; failure_mode = None
    ; reclaim_policy = None
    ; evidence_refs = [ "see retro"; "n/a"; "  " ]
    ; updated_at = None
    ; updated_by = None
    }
  in
  let task = dummy_task ~handoff_context () in
  let refs = V.verification_submission_evidence_refs task ~notes:"" None in
  Alcotest.(check bool)
    "plain handoff evidence_ref survives" true
    (List.mem "see retro" refs);
  Alcotest.(check bool)
    "n/a preserved for LLM judgment" true
    (List.mem "n/a" refs);
  Alcotest.(check bool)
    "non-empty summary survives" true
    (List.mem "investigated repeat failure" refs)

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
        ; Alcotest.test_case "contract refs included" `Quick
            test_contracted_task_includes_contract_refs
        ; Alcotest.test_case "handoff plain string survives" `Quick
            test_handoff_context_evidence_refs_survive_plain_string
        ] )
    ]
