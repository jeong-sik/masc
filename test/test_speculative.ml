(** Test suite for Speculative_engine.

    Tests pure functions (parse, serialize, state machine, branch/abort)
    without requiring actual LLM calls.

    @since 2.80.0 *)

open Masc_mcp

(* ================================================================ *)
(* Test harness (same as test_mcts.ml)                              *)
(* ================================================================ *)

let passed = ref 0
let failed = ref 0

let check desc cond =
  if cond then begin
    incr passed;
    Printf.printf "  \xE2\x9C\x93 %s\n" desc
  end else begin
    incr failed;
    Printf.printf "  \xE2\x9C\x97 FAIL: %s\n" desc
  end

let run_test name f =
  Printf.printf "\n\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80 %s \xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\n" name;
  f ()

(* ================================================================ *)
(* Helpers                                                          *)
(* ================================================================ *)

(** Dummy model_spec for testing (no real LLM calls). *)
let dummy_model : Llm_client.model_spec = {
  provider = Ollama;
  model_id = "test-fast-model";
  max_context = 4096;
  api_url = "http://localhost:11434";
  api_key_env = None;
  cost_per_1k_input = 0.001;
  cost_per_1k_output = 0.002;
}

let make_engine ?(max_candidates = 4)
                ?(semantic_guard_enabled = false)
                ?(min_confidence = 0.6)
                () =
  Speculative_engine.create
    ~fast_model:dummy_model
    ~max_candidates
    ~semantic_guard_enabled
    ~min_confidence
    ()

let make_candidates labels =
  List.map (fun label ->
    Speculative_engine.{ label; prompt = "test prompt for " ^ label; metadata = `Null }
  ) labels

(* ================================================================ *)
(* Tests: Engine creation                                           *)
(* ================================================================ *)

let () = run_test "engine creation" (fun () ->
  let engine = make_engine () in
  check "total_speculations = 0" (engine.total_speculations = 0);
  check "total_commits = 0" (engine.total_commits = 0);
  check "total_aborts = 0" (engine.total_aborts = 0);
  check "total_fast_calls = 0" (engine.total_fast_calls = 0);
  check "total_cost = 0.0" (engine.total_cost = 0.0);
  check "sessions empty" (engine.sessions = []);
  check "tree node_count = 1" (engine.tree.node_count = 1);
)

(* ================================================================ *)
(* Tests: Branch                                                    *)
(* ================================================================ *)

let () = run_test "branch: valid candidates" (fun () ->
  let engine = make_engine () in
  let candidates = make_candidates ["approach-A"; "approach-B"; "approach-C"] in
  let result = Speculative_engine.branch engine
    ~goal:"test goal"
    ~original_query:"test query"
    ~candidates in
  check "branch returns Ok" (Result.is_ok result);
  let session = Result.get_ok result in
  check "spec_id starts with spec-" (String.length session.spec_id >= 5
    && String.sub session.spec_id 0 5 = "spec-");
  check "state = Branching" (session.state = Branching);
  check "3 candidates stored" (List.length session.candidates = 3);
  check "no outcomes yet" (session.outcomes = []);
  check "best_candidate is None" (session.best_candidate = None);
  check "total_speculations incremented" (engine.total_speculations = 1);
  check "tree has 4 nodes (root + 3)" (engine.tree.node_count = 4);
)

let () = run_test "branch: empty candidates" (fun () ->
  let engine = make_engine () in
  let result = Speculative_engine.branch engine
    ~goal:"g" ~original_query:"q" ~candidates:[] in
  check "returns Error" (Result.is_error result);
  let err = Result.get_error result in
  check "error mentions 'no candidates'" (String.length err > 0
    && try ignore (Str.search_forward (Str.regexp "no candidates") err 0); true
    with Not_found -> false);
)

let () = run_test "branch: too many candidates" (fun () ->
  let engine = make_engine ~max_candidates:2 () in
  let candidates = make_candidates ["a"; "b"; "c"] in
  let result = Speculative_engine.branch engine
    ~goal:"g" ~original_query:"q" ~candidates in
  check "returns Error" (Result.is_error result);
  let err = Result.get_error result in
  check "error mentions 'too many'" (String.length err > 0
    && try ignore (Str.search_forward (Str.regexp "too many") err 0); true
    with Not_found -> false);
)

(* ================================================================ *)
(* Tests: Abort                                                     *)
(* ================================================================ *)

let () = run_test "abort: from Branching state" (fun () ->
  let engine = make_engine () in
  let candidates = make_candidates ["x"; "y"] in
  let session = Result.get_ok (Speculative_engine.branch engine
    ~goal:"g" ~original_query:"q" ~candidates) in
  let result = Speculative_engine.abort engine session.spec_id
    ~reason:"user cancelled" in
  check "abort returns Ok" (Result.is_ok result);
  let aborted = Result.get_ok result in
  (match aborted.state with
   | Aborted reason ->
     check "abort reason preserved" (reason = "user cancelled")
   | _ -> check "state is Aborted" false);
  check "completed_at is set" (aborted.completed_at <> None);
  check "total_aborts incremented" (engine.total_aborts = 1);
)

let () = run_test "abort: already aborted" (fun () ->
  let engine = make_engine () in
  let candidates = make_candidates ["x"] in
  let session = Result.get_ok (Speculative_engine.branch engine
    ~goal:"g" ~original_query:"q" ~candidates) in
  ignore (Speculative_engine.abort engine session.spec_id ~reason:"r1");
  let result = Speculative_engine.abort engine session.spec_id ~reason:"r2" in
  check "double abort returns Error" (Result.is_error result);
)

let () = run_test "abort: nonexistent session" (fun () ->
  let engine = make_engine () in
  let result = Speculative_engine.abort engine "spec-9999" ~reason:"r" in
  check "returns Error" (Result.is_error result);
)

(* ================================================================ *)
(* Tests: State machine                                             *)
(* ================================================================ *)

let () = run_test "state_to_string" (fun () ->
  check "Idle" (Speculative_engine.state_to_string Idle = "idle");
  check "Branching" (Speculative_engine.state_to_string Branching = "branching");
  check "Simulating" (Speculative_engine.state_to_string Simulating = "simulating");
  check "Verifying" (Speculative_engine.state_to_string Verifying = "verifying");
  check "Ready_to_commit"
    (Speculative_engine.state_to_string Ready_to_commit = "ready_to_commit");
  check "Committed" (Speculative_engine.state_to_string Committed = "committed");
  check "Aborted"
    (Speculative_engine.state_to_string (Aborted "test") = "aborted: test");
)

(* ================================================================ *)
(* Tests: Guard prompt building                                     *)
(* ================================================================ *)

let () = run_test "build_guard_prompt: short inputs" (fun () ->
  let prompt = Speculative_engine.build_guard_prompt
    ~original_query:"What is 2+2?"
    ~candidate_label:"arithmetic"
    ~fast_response:"The answer is 4." in
  check "contains original query" (try
    ignore (Str.search_forward (Str.regexp "What is 2") prompt 0); true
  with Not_found -> false);
  check "contains candidate label" (try
    ignore (Str.search_forward (Str.regexp "arithmetic") prompt 0); true
  with Not_found -> false);
  check "contains INTENT criterion" (try
    ignore (Str.search_forward (Str.regexp "INTENT") prompt 0); true
  with Not_found -> false);
  check "contains FORMAT criterion" (try
    ignore (Str.search_forward (Str.regexp "FORMAT") prompt 0); true
  with Not_found -> false);
  check "contains SAFETY criterion" (try
    ignore (Str.search_forward (Str.regexp "SAFETY") prompt 0); true
  with Not_found -> false);
)

let () = run_test "build_guard_prompt: long inputs truncated" (fun () ->
  let long_query = String.make 300 'x' in
  let long_response = String.make 600 'y' in
  let prompt = Speculative_engine.build_guard_prompt
    ~original_query:long_query
    ~candidate_label:"test"
    ~fast_response:long_response in
  check "query truncated (has ...)" (try
    ignore (Str.search_forward (Str.regexp "\\.\\.\\.") prompt 0); true
  with Not_found -> false);
  (* Truncation happened — the 300-char query is not fully embedded verbatim *)
  check "query not embedded verbatim" (not (try
    ignore (Str.search_forward (Str.regexp (String.make 300 'x')) prompt 0); true
  with Not_found -> false));
)

(* ================================================================ *)
(* Tests: Guard response parsing                                    *)
(* ================================================================ *)

let () = run_test "parse_guard_response: all YES" (fun () ->
  let text = "INTENT: YES\nFORMAT: YES\nSAFETY: YES\nREASON: looks good" in
  let guard = Speculative_engine.parse_guard_response text in
  check "intent_aligned" guard.intent_aligned;
  check "format_compliant" guard.format_compliant;
  check "side_effect_safe" guard.side_effect_safe;
  check "reason parsed" (guard.reason = "looks good");
)

let () = run_test "parse_guard_response: mixed results" (fun () ->
  let text = "INTENT: YES\nFORMAT: NO\nSAFETY: YES\nREASON: format wrong" in
  let guard = Speculative_engine.parse_guard_response text in
  check "intent_aligned" guard.intent_aligned;
  check "format NOT compliant" (not guard.format_compliant);
  check "side_effect_safe" guard.side_effect_safe;
  check "reason parsed" (guard.reason = "format wrong");
)

let () = run_test "parse_guard_response: all NO" (fun () ->
  let text = "INTENT: NO\nFORMAT: NO\nSAFETY: NO\nREASON: everything wrong" in
  let guard = Speculative_engine.parse_guard_response text in
  check "intent NOT aligned" (not guard.intent_aligned);
  check "format NOT compliant" (not guard.format_compliant);
  check "side_effect NOT safe" (not guard.side_effect_safe);
)

let () = run_test "parse_guard_response: missing REASON line" (fun () ->
  let text = "INTENT: YES\nFORMAT: YES\nSAFETY: YES" in
  let guard = Speculative_engine.parse_guard_response text in
  check "intent_aligned" guard.intent_aligned;
  check "reason is unparseable fallback" (guard.reason = "guard response unparseable");
)

let () = run_test "parse_guard_response: case insensitive" (fun () ->
  let text = "  intent: YES  \n  format: yes  \n  safety: Yes\nreason: ok" in
  let guard = Speculative_engine.parse_guard_response text in
  check "intent_aligned" guard.intent_aligned;
  check "format_compliant" guard.format_compliant;
  check "side_effect_safe" guard.side_effect_safe;
)

let () = run_test "parse_guard_response: garbage input" (fun () ->
  let text = "I don't understand the question." in
  let guard = Speculative_engine.parse_guard_response text in
  check "intent NOT aligned" (not guard.intent_aligned);
  check "format NOT compliant" (not guard.format_compliant);
  check "side_effect NOT safe" (not guard.side_effect_safe);
)

(* ================================================================ *)
(* Tests: Serialization                                             *)
(* ================================================================ *)

let () = run_test "session_to_yojson" (fun () ->
  let engine = make_engine () in
  let candidates = make_candidates ["alpha"; "beta"] in
  let session = Result.get_ok (Speculative_engine.branch engine
    ~goal:"serialize test" ~original_query:"q" ~candidates) in
  let json = Speculative_engine.session_to_yojson session in
  let json_str = Yojson.Safe.to_string json in
  check "contains spec_id" (try
    ignore (Str.search_forward (Str.regexp "spec_id") json_str 0); true
  with Not_found -> false);
  check "contains goal" (try
    ignore (Str.search_forward (Str.regexp "serialize test") json_str 0); true
  with Not_found -> false);
  check "state is branching" (try
    ignore (Str.search_forward (Str.regexp "branching") json_str 0); true
  with Not_found -> false);
  check "num_candidates = 2" (try
    ignore (Str.search_forward (Str.regexp "num_candidates") json_str 0); true
  with Not_found -> false);
)

let () = run_test "outcome_to_yojson" (fun () ->
  let outcome : Speculative_engine.simulation_outcome = {
    candidate_label = "test-approach";
    fast_response = "The result is 42.";
    verdict = Mcts_tree.Pass;
    verdict_reason = "correct answer";
    latency_ms = 150;
    cost_estimate = 0.0005;
  } in
  let json = Speculative_engine.outcome_to_yojson outcome in
  let json_str = Yojson.Safe.to_string json in
  check "contains candidate" (try
    ignore (Str.search_forward (Str.regexp "test-approach") json_str 0); true
  with Not_found -> false);
  check "contains PASS verdict" (try
    ignore (Str.search_forward (Str.regexp "PASS") json_str 0); true
  with Not_found -> false);
  check "contains latency_ms" (try
    ignore (Str.search_forward (Str.regexp "150") json_str 0); true
  with Not_found -> false);
)

let () = run_test "metrics_to_yojson: initial state" (fun () ->
  let engine = make_engine () in
  let json = Speculative_engine.metrics_to_yojson engine in
  let json_str = Yojson.Safe.to_string json in
  check "total_speculations present" (try
    ignore (Str.search_forward (Str.regexp "total_speculations") json_str 0); true
  with Not_found -> false);
  check "commit_rate present" (try
    ignore (Str.search_forward (Str.regexp "commit_rate") json_str 0); true
  with Not_found -> false);
  check "mcts_tree present" (try
    ignore (Str.search_forward (Str.regexp "mcts_tree") json_str 0); true
  with Not_found -> false);
)

let () = run_test "status: includes metrics and sessions" (fun () ->
  let engine = make_engine () in
  let candidates = make_candidates ["s1"; "s2"] in
  ignore (Speculative_engine.branch engine ~goal:"g" ~original_query:"q" ~candidates);
  let json = Speculative_engine.status engine in
  let json_str = Yojson.Safe.to_string json in
  check "has metrics key" (try
    ignore (Str.search_forward (Str.regexp "metrics") json_str 0); true
  with Not_found -> false);
  check "has recent_sessions key" (try
    ignore (Str.search_forward (Str.regexp "recent_sessions") json_str 0); true
  with Not_found -> false);
  check "has tree_summary key" (try
    ignore (Str.search_forward (Str.regexp "tree_summary") json_str 0); true
  with Not_found -> false);
)

(* ================================================================ *)
(* Tests: Session management                                        *)
(* ================================================================ *)

let () = run_test "multiple sessions on same engine (progressive widening)" (fun () ->
  let engine = make_engine () in
  let c1 = make_candidates ["a1"; "a2"] in
  let c2 = make_candidates ["b1"] in
  let s1 = Result.get_ok (Speculative_engine.branch engine
    ~goal:"goal1" ~original_query:"q1" ~candidates:c1) in
  let s2 = Result.get_ok (Speculative_engine.branch engine
    ~goal:"goal2" ~original_query:"q2" ~candidates:c2) in
  check "session 1 exists" (s1.spec_id <> "");
  check "session 2 exists" (s2.spec_id <> "");
  check "different spec_ids" (s1.spec_id <> s2.spec_id);
  check "engine has 2 sessions" (List.length engine.sessions = 2);
  check "session 1 has 2 child_node_ids" (List.length s1.child_node_ids = 2);
  check "session 2 has 1 child_node_id" (List.length s2.child_node_ids = 1);
  (* Tree should have root + 2 (expand) + 1 (add_child) = 4 nodes *)
  check "tree has 4 nodes" (engine.tree.node_count = 4);
  check "root has 3 children total" (List.length engine.tree.root.children = 3);
  check "total_speculations = 2" (engine.total_speculations = 2);
)

let () = run_test "tree accessor" (fun () ->
  let engine = make_engine () in
  let tree = Speculative_engine.tree engine in
  check "tree is the engine's tree" (tree.node_count = 1);
  check "tree root label is spec-root" (tree.root.label = "spec-root");
)

(* ================================================================ *)
(* Tests: MCTS tree integration after branch                        *)
(* ================================================================ *)

let () = run_test "branch creates MCTS children" (fun () ->
  let engine = make_engine () in
  let candidates = make_candidates ["opt-1"; "opt-2"; "opt-3"] in
  let session = Result.get_ok (Speculative_engine.branch engine
    ~goal:"test" ~original_query:"q" ~candidates) in
  let tree = Speculative_engine.tree engine in
  check "tree has 4 nodes" (tree.node_count = 4);
  check "root has 3 children" (List.length tree.root.children = 3);
  (* Children labels match candidate labels *)
  let child_labels = List.map (fun (c : Mcts_tree.node) -> c.label) tree.root.children in
  check "child labels match candidates"
    (List.mem "opt-1" child_labels
     && List.mem "opt-2" child_labels
     && List.mem "opt-3" child_labels);
  (* child_node_ids should match tree children *)
  check "3 child_node_ids" (List.length session.child_node_ids = 3);
)

(* ================================================================ *)
(* Tests: Config variations                                         *)
(* ================================================================ *)

let () = run_test "custom config" (fun () ->
  let engine = Speculative_engine.create
    ~fast_model:dummy_model
    ~max_candidates:2
    ~max_simulations:4
    ~semantic_guard_enabled:true
    ~min_confidence:0.8
    ~verify_model:dummy_model
    () in
  check "config max_candidates = 2" (engine.config.max_candidates = 2);
  check "config max_simulations = 4" (engine.config.max_simulations = 4);
  check "config semantic_guard_enabled" engine.config.semantic_guard_enabled;
  check "config min_confidence = 0.8" (engine.config.min_confidence = 0.8);
  check "config verify_model is Some" (engine.config.verify_model <> None);
)

(* ================================================================ *)
(* Tests: simulate_all state check                                  *)
(* ================================================================ *)

let () = run_test "simulate_all: wrong state" (fun () ->
  let engine = make_engine () in
  let candidates = make_candidates ["a"; "b"] in
  let session = Result.get_ok (Speculative_engine.branch engine
    ~goal:"g" ~original_query:"q" ~candidates) in
  (* Abort it first, then try simulate *)
  ignore (Speculative_engine.abort engine session.spec_id ~reason:"test");
  let result = Speculative_engine.simulate_all engine session.spec_id in
  check "simulate on aborted session fails" (Result.is_error result);
)

let () = run_test "simulate_all: nonexistent session" (fun () ->
  let engine = make_engine () in
  let result = Speculative_engine.simulate_all engine "spec-9999" in
  check "returns Error" (Result.is_error result);
)

(* ================================================================ *)
(* Tests: select_best state check                                   *)
(* ================================================================ *)

let () = run_test "select_best: wrong state" (fun () ->
  let engine = make_engine () in
  let candidates = make_candidates ["a"] in
  let session = Result.get_ok (Speculative_engine.branch engine
    ~goal:"g" ~original_query:"q" ~candidates) in
  let result = Speculative_engine.select_best engine session.spec_id in
  check "select_best on Branching state fails" (Result.is_error result);
)

let () = run_test "select_best: session-scoped MCTS choice" (fun () ->
  let engine = make_engine ~min_confidence:0.4 () in
  let global_session = Result.get_ok
    (Speculative_engine.branch engine
       ~goal:"g1" ~original_query:"q1"
       ~candidates:(make_candidates ["global-best"; "global-bad"])) in
  let global_outcomes = [
    Speculative_engine.{
      candidate_label = "global-best";
      fast_response = "global";
      verdict = Mcts_tree.Pass;
      verdict_reason = "ok";
      latency_ms = 1;
      cost_estimate = 0.0;
    };
    {
      candidate_label = "global-bad";
      fast_response = "bad";
      verdict = Mcts_tree.Fail;
      verdict_reason = "bad";
      latency_ms = 1;
      cost_estimate = 0.0;
    };
  ] in
  List.iter2 (fun child_id (outcome : Speculative_engine.simulation_outcome) ->
    let sim : Mcts_tree.simulation_result = {
      model_used = "test";
      output = outcome.fast_response;
      verdict = outcome.verdict;
      latency_ms = float_of_int outcome.latency_ms;
    } in
    ignore (Mcts_tree.record_simulation engine.tree child_id sim);
    Mcts_tree.backpropagate engine.tree child_id
      (Mcts_tree.reward_of_verdict outcome.verdict)
  ) global_session.child_node_ids global_outcomes;
  Speculative_engine.update_session engine
    { global_session with state = Verifying; outcomes = global_outcomes };
  let local_session = Result.get_ok
    (Speculative_engine.branch engine
       ~goal:"g2" ~original_query:"q2"
       ~candidates:(make_candidates ["local-best"; "local-bad"])) in
  let local_outcomes = [
    Speculative_engine.{
      candidate_label = "local-best";
      fast_response = "local";
      verdict = Mcts_tree.Warn;
      verdict_reason = "warn";
      latency_ms = 1;
      cost_estimate = 0.0;
    };
    {
      candidate_label = "local-bad";
      fast_response = "bad";
      verdict = Mcts_tree.Fail;
      verdict_reason = "bad";
      latency_ms = 1;
      cost_estimate = 0.0;
    };
  ] in
  List.iter2 (fun child_id (outcome : Speculative_engine.simulation_outcome) ->
    let sim : Mcts_tree.simulation_result = {
      model_used = "test";
      output = outcome.fast_response;
      verdict = outcome.verdict;
      latency_ms = float_of_int outcome.latency_ms;
    } in
    ignore (Mcts_tree.record_simulation engine.tree child_id sim);
    Mcts_tree.backpropagate engine.tree child_id
      (Mcts_tree.reward_of_verdict outcome.verdict)
  ) local_session.child_node_ids local_outcomes;
  Speculative_engine.update_session engine
    { local_session with state = Verifying; outcomes = local_outcomes };
  let selected =
    Result.get_ok (Speculative_engine.select_best engine local_session.spec_id)
  in
  check "local session reaches Ready_to_commit"
    (selected.state = Ready_to_commit);
  check "best candidate stays local"
    (selected.best_candidate = Some "local-best");
)

(* ================================================================ *)
(* Tests: commit state check                                        *)
(* ================================================================ *)

let () = run_test "commit: wrong state" (fun () ->
  let engine = make_engine () in
  let candidates = make_candidates ["a"] in
  let session = Result.get_ok (Speculative_engine.branch engine
    ~goal:"g" ~original_query:"q" ~candidates) in
  let result = Speculative_engine.commit engine session.spec_id in
  check "commit on Branching state fails" (Result.is_error result);
)

let () = run_test "commit: nonexistent session" (fun () ->
  let engine = make_engine () in
  let result = Speculative_engine.commit engine "spec-9999" in
  check "returns Error" (Result.is_error result);
)

(* ================================================================ *)
(* Tests: abort on committed (should fail)                          *)
(* ================================================================ *)

(* Cannot test commit→abort without LLM, but we can test double-abort *)
let () = run_test "abort: double abort idempotency" (fun () ->
  let engine = make_engine () in
  let candidates = make_candidates ["a"] in
  let session = Result.get_ok (Speculative_engine.branch engine
    ~goal:"g" ~original_query:"q" ~candidates) in
  let _first = Speculative_engine.abort engine session.spec_id ~reason:"r1" in
  let second = Speculative_engine.abort engine session.spec_id ~reason:"r2" in
  check "second abort returns Error" (Result.is_error second);
  check "total_aborts = 1 (not 2)" (engine.total_aborts = 1);
)

(* ================================================================ *)
(* Tests: Metrics after operations                                  *)
(* ================================================================ *)

let () = run_test "metrics after branch + abort" (fun () ->
  let engine = make_engine () in
  let candidates = make_candidates ["a"; "b"] in
  let session = Result.get_ok (Speculative_engine.branch engine
    ~goal:"g" ~original_query:"q" ~candidates) in
  ignore (Speculative_engine.abort engine session.spec_id ~reason:"test");
  check "total_speculations = 1" (engine.total_speculations = 1);
  check "total_aborts = 1" (engine.total_aborts = 1);
  check "total_commits = 0" (engine.total_commits = 0);
  let json = Speculative_engine.metrics_to_yojson engine in
  let json_str = Yojson.Safe.to_string json in
  check "commit_rate = 0" (try
    ignore (Str.search_forward (Str.regexp "commit_rate.*0") json_str 0); true
  with Not_found -> false);
)

(* ================================================================ *)
(* Report                                                           *)
(* ================================================================ *)

let () =
  Printf.printf "\n=== Results: %d passed, %d failed ===\n" !passed !failed;
  if !failed > 0 then exit 1
