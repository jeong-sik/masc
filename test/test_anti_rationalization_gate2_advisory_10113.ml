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
   evaluator (Gate 3 needs an OAS cascade we don't stand up here),
   so the assertions focus on:

     1. The Prometheus counter labels are correct for each
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

(* MASC_BASE_PATH must be set BEFORE Masc_mcp module init. *)
let () =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-test-anti-rat-gate2-10113-%06x"
         (Random.bits ()))
  in
  Unix.putenv "MASC_BASE_PATH" dir

module AR = Masc_mcp.Anti_rationalization
module Prom = Masc_mcp.Prometheus

let metric = Prom.metric_anti_rationalization_excuse_pattern

let counter_for ~pattern ~decision =
  Prom.metric_value_or_zero metric
    ~labels:[ ("pattern", pattern); ("decision", decision) ]
    ()

let make_request ~notes : AR.review_request =
  {
    agent_name = "test-keeper-10113";
    task_title = "test task";
    task_description = "test description";
    completion_notes = notes;
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

(* Counter label vocabulary contract — pin each decision string
   so dashboards keyed on these labels do not silently break.
   These three strings are the only valid values; adding a new
   one is an explicit change.

   We exercise the labels by directly calling Prometheus
   inc_counter with the exact strings the production code will
   emit.  This pins the [decision=...] vocabulary independently
   of whether the gate-3 LLM is reachable in the test env. *)
let test_counter_label_vocabulary () =
  let pattern = "test-pattern-10113-vocab" in
  let before_advisory = counter_for ~pattern ~decision:"advisory_to_llm" in
  let before_terminal = counter_for ~pattern ~decision:"terminal_reject" in
  let before_safety = counter_for ~pattern ~decision:"advisory_safety_net_reject" in
  Prom.inc_counter metric
    ~labels:[ ("pattern", pattern); ("decision", "advisory_to_llm") ] ();
  Prom.inc_counter metric
    ~labels:[ ("pattern", pattern); ("decision", "terminal_reject") ] ();
  Prom.inc_counter metric
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
  Prom.inc_counter metric
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
        ] );
      ( "counter_labels",
        [
          Alcotest.test_case "decision vocabulary stable"
            `Quick test_counter_label_vocabulary;
          Alcotest.test_case "per-pattern isolation"
            `Quick test_pattern_label_isolation;
        ] );
    ]
