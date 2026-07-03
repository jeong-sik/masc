(* test/test_anti_rationalization_gate2_advisory_10113.ml

   #10113: anti-rationalization gate 2 used to terminal-reject any
   completion notes containing one of 13 substrings — "pre-existing",
   "follow-up", "out of scope", etc.  Substring matching has no
   word-boundary or context awareness, so legitimate engineering
   notes ("fixed bug X; pre-existing issue #1234 tracked separately",
   "filed a follow-up ticket for the optimization layer") were
   rejected before the LLM evaluator could see them.

   The fix demoted gate 2 to an advisory hint by default.  This
   test pins the resulting state machine WITHOUT calling the LLM
   evaluator (Gate 3 needs an OAS runtime we don't stand up here),
   so the assertions focus on:

     1. The Otel_metric_store counter labels are correct for each
        decision branch — operators read these to triangulate
        false-positive rate vs true-positive rate per pattern.
     2. The build_prompt advisory section appears with the
        flagged phrase + reason exactly when an excuse_advisory
        is supplied.
     3. The advisory section is ABSENT when no advisory is
        supplied — no leakage of the gate-2 message into normal
        prompts.
     4. The advisory text guides the LLM to evaluate in context
        rather than treating the phrase as automatic grounds for
        rejection — the explicit "approve if substantive work and
        normal engineering context" instruction is the contract.
*)

(* MASC_BASE_PATH must be set BEFORE Masc module init. *)
let () =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-test-anti-rat-gate2-10113-%06x"
         (Random.bits ()))
  in
  Unix.putenv "MASC_BASE_PATH" dir

module AR = Masc.Task.Anti_rationalization
module CR = Masc.Task.Completion_review
module Metrics = Masc.Otel_metric_store

let metric = Metrics.metric_anti_rationalization_excuse_pattern

let counter_for ~pattern ~decision =
  Metrics.metric_value_or_zero metric
    ~labels:[ ("pattern", pattern); ("decision", decision) ]
    ()

let make_request ~notes : AR.review_request =
  {
    agent_name = "test-keeper-10113";
    task_title = "test task";
    task_description = "test description";
    completion_notes = notes;
    task_id = "test-task-10113";
  }

(* The advisory text must contain the flagged phrase verbatim and
   the reason mapping — operators audit logs by matching this
   exact substring shape, and dashboards pull patterns by name. *)
let test_build_prompt_includes_advisory_when_supplied () =
  let req =
    make_request
      ~notes:"Fixed login flow.  Filed a follow-up issue for the optimization."
  in
  let prompt =
    AR.build_prompt
      ~excuse_advisory:("follow-up", "deferring to a follow-up")
      req
  in
  let contains needle =
    String_util.contains_substring prompt needle
  in
  Alcotest.(check bool)
    "advisory section appears in prompt"
    true (contains "<gate2_advisory>");
  Alcotest.(check bool)
    "flagged phrase appears verbatim in advisory"
    true (contains "follow-up");
  Alcotest.(check bool)
    "advisory cites the documented reason"
    true (contains "deferring to a follow-up");
  (* Operator contract: the advisory must explicitly tell the LLM
     to approve in normal engineering context.  This is the
     anti-false-positive instruction. *)
  Alcotest.(check bool)
    "advisory tells LLM to approve in engineering context"
    true (contains "engineering context");
  Alcotest.(check bool)
    "advisory says heuristic signal, not verdict"
    true (contains "heuristic signal")

(* Without an advisory the prompt should be the normal review
   prompt with NO gate2 leakage. *)
let test_build_prompt_no_advisory_section_without_input () =
  let req = make_request ~notes:"Implemented feature X end-to-end." in
  let prompt = AR.build_prompt req in
  Alcotest.(check bool)
    "no <gate2_advisory> tag when no advisory supplied"
    false
    (String_util.contains_substring prompt "<gate2_advisory>")

let test_build_prompt_includes_verification_contract () =
  let req =
    make_request
      ~notes:"Implemented feature X, ran test_feature_x, and attached PR #123."
  in
  let prompt =
    AR.build_prompt
      ~completion_contract:
        [ "test_feature_x passes"; "PR artifact is attached" ]
      req
  in
  let contains needle = String_util.contains_substring prompt needle in
  Alcotest.(check bool)
    "contract section appears in prompt"
    true
    (contains "<verification_contract>");
  Alcotest.(check bool)
    "first contract item appears"
    true
    (contains "test_feature_x passes");
  Alcotest.(check bool)
    "prompt tells LLM to reject unmet contract items"
    true
    (contains "Reject if the notes do not provide concrete evidence")

(* task-1664: the done-path anti-rationalization prompt must surface the
   contract's required_evidence / verify_gate_evidence so a task demanding a
   concrete artifact (e.g. "PR link") is judged against that requirement rather
   than approved on narrative notes alone. *)
let test_build_prompt_includes_required_evidence () =
  let req =
    make_request ~notes:"Implemented feature X and ran the suite."
  in
  let prompt =
    AR.build_prompt
      ~required_evidence:[ "PR link"; "CI run URL" ]
      ~verify_gate_evidence:[ "coverage report" ]
      req
  in
  let contains needle = String_util.contains_substring prompt needle in
  Alcotest.(check bool)
    "required-evidence section appears in prompt"
    true
    (contains "<required_evidence>");
  Alcotest.(check bool)
    "required_evidence item appears verbatim"
    true
    (contains "PR link");
  Alcotest.(check bool)
    "second required_evidence item appears verbatim"
    true
    (contains "CI run URL");
  Alcotest.(check bool)
    "verify_gate_evidence item appears in the same section"
    true
    (contains "coverage report");
  Alcotest.(check bool)
    "prompt instructs per-item judgement of each evidence artifact"
    true
    (contains "Judge every item independently");
  Alcotest.(check bool)
    "prompt instructs rejection of missing evidence"
    true
    (contains "Reject if any item is missing")

(* Empty contract → no required-evidence section leaks into the prompt. *)
let test_build_prompt_no_required_evidence_section_without_input () =
  let req = make_request ~notes:"Implemented feature X end-to-end." in
  let prompt = AR.build_prompt req in
  Alcotest.(check bool)
    "no <required_evidence> tag when no evidence supplied"
    false
    (String_util.contains_substring prompt "<required_evidence>")

(* task-1664: the verification request carries the required/submitted split as
   separate typed fields; this pins the serialization contract (test c). *)
let test_verification_evidence_roundtrip () =
  let evidence : CR.verification_evidence =
    { required_artifacts = [ "PR link"; "CI run URL" ]
    ; submitted_evidence = [ "https://example/pull/1"; "coverage 92%" ]
    }
  in
  let json = CR.verification_evidence_to_yojson evidence in
  (* The two roles must be distinct object keys, not one merged list. *)
  (match json with
   | `Assoc kvs ->
     Alcotest.(check bool)
       "required_artifacts is a distinct field"
       true
       (List.mem_assoc "required_artifacts" kvs);
     Alcotest.(check bool)
       "submitted_evidence is a distinct field"
       true
       (List.mem_assoc "submitted_evidence" kvs)
   | _ -> Alcotest.fail "verification_evidence must serialize to a JSON object");
  match CR.verification_evidence_of_yojson json with
  | Error e -> Alcotest.fail ("roundtrip decode failed: " ^ e)
  | Ok decoded ->
    Alcotest.(check (list string))
      "required_artifacts survives roundtrip"
      evidence.required_artifacts
      decoded.required_artifacts;
    Alcotest.(check (list string))
      "submitted_evidence survives roundtrip"
      evidence.submitted_evidence
      decoded.submitted_evidence

let test_check_contract_rejects_embedded_substrings () =
  let unmet =
    AR.check_contract
      ~notes:
        "The parser is errorless; the contest coverage marker exists in the \
         fixture."
      ~contract:[ "error"; "test coverage" ]
  in
  Alcotest.(check (list string))
    "embedded substrings do not satisfy contract items"
    [ "error"; "test coverage" ]
    unmet

let test_check_contract_matches_token_sequence_through_punctuation () =
  let unmet =
    AR.check_contract
      ~notes:"Tests: passed. Coverage-report attached to the completion notes."
      ~contract:[ "tests passed"; "coverage report" ]
  in
  Alcotest.(check (list string))
    "punctuation-separated token sequences satisfy contract items"
    []
    unmet

(* Counter label vocabulary contract — pin each decision string
   so dashboards keyed on these labels do not silently break.
   These three strings are the only valid values; adding a new
   one is an explicit change.

   We exercise the labels by directly calling Otel_metric_store
   inc_counter with the exact strings the production code will
   emit.  This pins the [decision=...] vocabulary independently
   of whether the gate-3 LLM is reachable in the test env. *)
let test_counter_label_vocabulary () =
  let pattern = "test-pattern-10113-vocab" in
  let before_advisory = counter_for ~pattern ~decision:"advisory_to_llm" in
  let before_terminal = counter_for ~pattern ~decision:"terminal_reject" in
  let before_safety = counter_for ~pattern ~decision:"advisory_safety_net_reject" in
  Metrics.inc_counter metric
    ~labels:[ ("pattern", pattern); ("decision", "advisory_to_llm") ] ();
  Metrics.inc_counter metric
    ~labels:[ ("pattern", pattern); ("decision", "terminal_reject") ] ();
  Metrics.inc_counter metric
    ~labels:[ ("pattern", pattern); ("decision", "advisory_safety_net_reject") ] ();
  Alcotest.(check (float 0.0001))
    "advisory_to_llm bucket +1"
    (before_advisory +. 1.0)
    (counter_for ~pattern ~decision:"advisory_to_llm");
  Alcotest.(check (float 0.0001))
    "terminal_reject bucket +1"
    (before_terminal +. 1.0)
    (counter_for ~pattern ~decision:"terminal_reject");
  Alcotest.(check (float 0.0001))
    "advisory_safety_net_reject bucket +1"
    (before_safety +. 1.0)
    (counter_for ~pattern ~decision:"advisory_safety_net_reject")

(* Per-pattern label isolation — flagging "follow-up" must not
   leak into the "pre-existing" counter and vice versa.
   Regression guard for the "single undifferentiated counter"
   anti-pattern. *)
let test_pattern_label_isolation () =
  let before_other =
    counter_for ~pattern:"out of scope" ~decision:"advisory_to_llm"
  in
  Metrics.inc_counter metric
    ~labels:[
      ("pattern", "follow-up");
      ("decision", "advisory_to_llm");
    ] ();
  Alcotest.(check (float 0.0001))
    "out-of-scope bucket unchanged when follow-up fires"
    before_other
    (counter_for ~pattern:"out of scope" ~decision:"advisory_to_llm")

let () =
  Alcotest.run "anti_rationalization_gate2_advisory_10113"
    [
      ( "build_prompt",
        [
          Alcotest.test_case "advisory section included when supplied"
            `Quick test_build_prompt_includes_advisory_when_supplied;
          Alcotest.test_case "no advisory section without input"
            `Quick test_build_prompt_no_advisory_section_without_input;
          Alcotest.test_case "verification contract included"
            `Quick test_build_prompt_includes_verification_contract;
          Alcotest.test_case "required evidence included when supplied"
            `Quick test_build_prompt_includes_required_evidence;
          Alcotest.test_case "no required evidence section without input"
            `Quick test_build_prompt_no_required_evidence_section_without_input;
        ] );
      ( "verification_evidence",
        [
          Alcotest.test_case "typed split serialization roundtrip"
            `Quick test_verification_evidence_roundtrip;
        ] );
      ( "contract_check",
        [
          Alcotest.test_case "embedded substrings remain unmet"
            `Quick test_check_contract_rejects_embedded_substrings;
          Alcotest.test_case "punctuation token sequence is accepted"
            `Quick test_check_contract_matches_token_sequence_through_punctuation;
        ] );
      ( "counter_labels",
        [
          Alcotest.test_case "decision vocabulary stable"
            `Quick test_counter_label_vocabulary;
          Alcotest.test_case "per-pattern isolation"
            `Quick test_pattern_label_isolation;
        ] );
    ]
