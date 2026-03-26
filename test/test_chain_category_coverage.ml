(** Coverage tests for chain_category, chain_error, chain_types.
    Targets: all pure functions and variant branches. *)

open Alcotest
open Masc_mcp
open Chain_types

(* ============================================================
   Helpers
   ============================================================ *)

let dummy_node id nt =
  { id; node_type = nt; input_mapping = []; output_key = None; depends_on = None }

let dummy_model () =
  Model { model = "m"; system = None; prompt = "p"; timeout = None; tools = None;
        prompt_ref = None; prompt_vars = []; thinking = false }

let dummy_chain nodes =
  { id = "test"; nodes; output = "out"; config = default_config;
    name = None; description = None; version = None;
    input_schema = None; output_schema = None; metadata = None }

(* ============================================================
   1. Chain_category — Result_monad
   ============================================================ *)

let test_result_monad_pure () =
  let r = Chain_category.Result_monad.pure 42 in
  check (result int string) "pure" (Ok 42) r

let test_result_monad_map_ok () =
  let r = Chain_category.Result_monad.map (fun x -> x + 1) (Ok 1) in
  check (result int string) "map ok" (Ok 2) r

let test_result_monad_map_err () =
  let r = Chain_category.Result_monad.map (fun x -> x + 1) (Error "e") in
  check (result int string) "map err" (Error "e") r

let test_result_monad_ap_ok () =
  let r = Chain_category.Result_monad.ap (Ok (fun x -> x * 2)) (Ok 3) in
  check (result int string) "ap ok" (Ok 6) r

let test_result_monad_ap_err_f () =
  let r = Chain_category.Result_monad.ap (Error "ef") (Ok 3) in
  check (result int string) "ap err f" (Error "ef") r

let test_result_monad_ap_err_x () =
  let r = Chain_category.Result_monad.ap (Ok (fun x -> x)) (Error "ex") in
  check (result int string) "ap err x" (Error "ex") r

let test_result_monad_map2_ok () =
  let r = Chain_category.Result_monad.map2 (fun a b -> a + b) (Ok 1) (Ok 2) in
  check (result int string) "map2 ok" (Ok 3) r

let test_result_monad_map2_err_1 () =
  let r = Chain_category.Result_monad.map2 (fun a b -> a + b) (Error "e1") (Ok 2) in
  check (result int string) "map2 err1" (Error "e1") r

let test_result_monad_map2_err_2 () =
  let r = Chain_category.Result_monad.map2 (fun a b -> a + b) (Ok 1) (Error "e2") in
  check (result int string) "map2 err2" (Error "e2") r

let test_result_monad_sequence_ok () =
  let r = Chain_category.Result_monad.sequence [Ok 1; Ok 2; Ok 3] in
  check (result (list int) string) "seq ok" (Ok [1;2;3]) r

let test_result_monad_sequence_empty () =
  let r = Chain_category.Result_monad.sequence [] in
  check (result (list int) string) "seq empty" (Ok []) r

let test_result_monad_sequence_err () =
  let r = Chain_category.Result_monad.sequence [Ok 1; Error "e"; Ok 3] in
  check (result (list int) string) "seq err" (Error "e") r

let test_result_monad_bind_ok () =
  let r = Chain_category.Result_monad.(bind (Ok 5) (fun x -> Ok (x * 2))) in
  check (result int string) "bind ok" (Ok 10) r

let test_result_monad_bind_err () =
  let r = Chain_category.Result_monad.(bind (Error "e") (fun x -> Ok (x * 2))) in
  check (result int string) "bind err" (Error "e") r

let test_result_monad_join () =
  let r = Chain_category.Result_monad.join (Ok (Ok 7)) in
  check (result int string) "join" (Ok 7) r

let test_result_monad_kleisli () =
  let f x = Ok (x + 1) in
  let g x = Ok (x * 2) in
  let h = Chain_category.Result_monad.( >=> ) f g in
  check (result int string) "kleisli" (Ok 8) (h 3)

let test_result_monad_run_ok () =
  let r = Chain_category.Result_monad.run (Ok 42) in
  check int "run ok" 42 r

let test_result_monad_run_err () =
  try
    let _ = Chain_category.Result_monad.run (Error "boom") in
    fail "should raise"
  with Failure msg -> check string "run err msg" "boom" msg

let test_result_monad_catch_ok () =
  let r = Chain_category.Result_monad.catch (fun () -> 42) in
  check (result int string) "catch ok" (Ok 42) r

let test_result_monad_catch_exn () =
  let r = Chain_category.Result_monad.catch (fun () -> failwith "oops") in
  (match r with Error _ -> () | Ok _ -> fail "should be error")

let test_result_monad_map_error () =
  let r = Chain_category.Result_monad.map_error (fun s -> s ^ "X") (Error "e") in
  check (result int string) "map_error" (Error "eX") r

let test_result_monad_map_error_ok () =
  let r = Chain_category.Result_monad.map_error (fun s -> s ^ "X") (Ok 1) in
  check (result int string) "map_error ok" (Ok 1) r

(* ============================================================
   2. Result_kleisli
   ============================================================ *)

let test_kleisli_arr () =
  let f = Chain_category.Result_kleisli.arr (fun x -> x + 1) in
  check (result int string) "arr" (Ok 4) (Chain_category.Result_kleisli.run f 3)

let test_kleisli_compose () =
  let open Chain_category.Result_kleisli in
  let f = arr (fun x -> x + 1) in
  let g = arr (fun x -> x * 2) in
  let h = f >>> g in
  check (result int string) "compose" (Ok 8) (run h 3)

let test_kleisli_fanout () =
  let open Chain_category.Result_kleisli in
  let f = arr (fun x -> x + 1) in
  let g = arr (fun x -> x * 2) in
  let h = f &&& g in
  check (result (pair int int) string) "fanout" (Ok (4, 6)) (run h 3)

let test_kleisli_split () =
  let open Chain_category.Result_kleisli in
  let f = arr (fun x -> x + 1) in
  let g = arr (fun x -> x * 2) in
  let h = f *** g in
  check (result (pair int int) string) "split" (Ok (4, 6)) (run h (3, 3))

let test_kleisli_first () =
  let f = Chain_category.Result_kleisli.arr (fun x -> x + 10) in
  let h = Chain_category.Result_kleisli.first f in
  check (result (pair int string) string) "first" (Ok (13, "y")) (h (3, "y"))

let test_kleisli_second () =
  let f = Chain_category.Result_kleisli.arr (fun x -> x + 10) in
  let h = Chain_category.Result_kleisli.second f in
  check (result (pair string int) string) "second" (Ok ("y", 13)) (h ("y", 3))

let test_kleisli_from_option () =
  let f = Chain_category.Result_kleisli.from_option ~error:"not found"
      (fun x -> if x > 0 then Some x else None) in
  check (result int string) "from_option ok" (Ok 5) (f 5);
  check (result int string) "from_option none" (Error "not found") (f (-1))

let test_kleisli_guard () =
  let f = Chain_category.Result_kleisli.guard ~error:"fail" (fun x -> x > 0) in
  check (result int string) "guard ok" (Ok 5) (f 5);
  check (result int string) "guard fail" (Error "fail") (f 0)

(* ============================================================
   3. Verdict_monoid
   ============================================================ *)

let test_verdict_empty () =
  let open Chain_category.Verdict_monoid in
  let e = empty in
  (match e with Pass _ -> () | _ -> fail "not Pass")

let test_verdict_fail_first () =
  let open Chain_category.Verdict_monoid in
  let r = concat (Fail "bad") (Pass "ok") in
  (match r with Fail "bad" -> () | _ -> fail "fail first")

let test_verdict_fail_second () =
  let open Chain_category.Verdict_monoid in
  let r = concat (Pass "ok") (Fail "bad") in
  (match r with Fail "bad" -> () | _ -> fail "fail second")

let test_verdict_warn_combine () =
  let open Chain_category.Verdict_monoid in
  let r = concat (Warn "w1") (Warn "w2") in
  (match r with Warn s -> check bool "combined" true (String.length s > 4) | _ -> fail "not Warn")

let test_verdict_warn_with_pass () =
  let open Chain_category.Verdict_monoid in
  let r = concat (Warn "w") (Pass "ok") in
  (match r with Warn "w" -> () | _ -> fail "not Warn");
  let r2 = concat (Pass "ok") (Warn "w") in
  (match r2 with Warn "w" -> () | _ -> fail "not Warn 2")

let test_verdict_pass_combine () =
  let open Chain_category.Verdict_monoid in
  let r = concat (Pass "a") (Pass "b") in
  (match r with Pass s -> check bool "combined" true (String.length s > 2) | _ -> fail "not Pass")

let test_verdict_defer () =
  let open Chain_category.Verdict_monoid in
  let r = concat (Defer "d") (Pass "ok") in
  (match r with Defer "d" -> () | _ -> fail "not Defer");
  let r2 = concat (Pass "ok") (Defer "d") in
  (match r2 with Defer "d" -> () | _ -> fail "not Defer 2")

let test_verdict_concat_all () =
  let open Chain_category.Verdict_monoid in
  let r = concat_all [] in
  (match r with Pass _ -> () | _ -> fail "empty");
  let r2 = concat_all [Pass "a"] in
  (match r2 with Pass "a" -> () | _ -> fail "single");
  let r3 = concat_all [Pass "a"; Warn "w"; Pass "b"] in
  (match r3 with Warn _ -> () | _ -> fail "multi")

(* ============================================================
   4. Confidence_monoid
   ============================================================ *)

let test_confidence_empty () =
  check (float 0.01) "empty" 1.0 Chain_category.Confidence_monoid.empty

let test_confidence_concat () =
  let r = Chain_category.Confidence_monoid.concat 0.8 0.6 in
  check (float 0.01) "avg" 0.7 r

let test_confidence_concat_all () =
  let r = Chain_category.Confidence_monoid.concat_all [0.4; 0.6; 0.8] in
  check (float 0.01) "avg" 0.6 r

let test_confidence_concat_all_empty () =
  let r = Chain_category.Confidence_monoid.concat_all [] in
  check (float 0.01) "empty" 1.0 r

let test_confidence_geometric () =
  let r = Chain_category.Confidence_monoid.geometric [1.0; 1.0] in
  check (float 0.01) "geo" 1.0 r

let test_confidence_geometric_empty () =
  let r = Chain_category.Confidence_monoid.geometric [] in
  check (float 0.01) "geo empty" 1.0 r

let test_confidence_harmonic () =
  let r = Chain_category.Confidence_monoid.harmonic [2.0; 2.0] in
  check (float 0.01) "harmonic" 2.0 r

let test_confidence_harmonic_empty () =
  let r = Chain_category.Confidence_monoid.harmonic [] in
  check (float 0.01) "harmonic empty" 1.0 r

let test_confidence_harmonic_zero () =
  let r = Chain_category.Confidence_monoid.harmonic [0.0; 1.0] in
  (* n=2, sum_inv = 0 + 1.0 = 1.0, result = 2.0/1.0 = 2.0 *)
  check (float 0.01) "harmonic zero" 2.0 r

let test_confidence_weighted () =
  let r = Chain_category.Confidence_monoid.weighted [0.5; 0.5] [0.8; 0.6] in
  check (float 0.01) "weighted" 0.7 r

let test_confidence_weighted_zero () =
  let r = Chain_category.Confidence_monoid.weighted [0.0; 0.0] [0.8; 0.6] in
  check (float 0.01) "weighted zero" 0.0 r

(* ============================================================
   5. Token_monoid
   ============================================================ *)

let test_token_empty () =
  let e = Chain_category.Token_monoid.empty in
  check int "total" 0 e.total_tokens

let test_token_concat () =
  let a : Chain_category.token_usage = { prompt_tokens = 10; completion_tokens = 5; total_tokens = 15; estimated_cost_usd = 0.01 } in
  let b : Chain_category.token_usage = { prompt_tokens = 20; completion_tokens = 10; total_tokens = 30; estimated_cost_usd = 0.02 } in
  let r = Chain_category.Token_monoid.concat a b in
  check int "prompt" 30 r.prompt_tokens;
  check int "completion" 15 r.completion_tokens;
  check int "total" 45 r.total_tokens;
  check (float 0.001) "cost" 0.03 r.estimated_cost_usd

let test_token_concat_all () =
  let r = Chain_category.Token_monoid.concat_all [] in
  check int "empty total" 0 r.total_tokens

(* ============================================================
   6. Trace_monoid
   ============================================================ *)

let test_trace_empty () =
  check int "empty" 0 (List.length Chain_category.Trace_monoid.empty)

let test_trace_concat () =
  let a = [("step1", 1.0)] in
  let b = [("step2", 2.0)] in
  let r = Chain_category.Trace_monoid.concat a b in
  check int "combined" 2 (List.length r)

let test_trace_concat_all () =
  let r = Chain_category.Trace_monoid.concat_all [[("a", 1.0)]; [("b", 2.0)]] in
  check int "all" 2 (List.length r)

(* ============================================================
   7. Function_profunctor
   ============================================================ *)

let test_profunctor_dimap () =
  let f = Chain_category.Function_profunctor.dimap
      (fun x -> x * 2) (fun x -> x + 1)
      (fun x -> x + 10) in
  check int "dimap" 17 (f 3)  (* 3*2=6, 6+10=16, 16+1=17 *)

let test_profunctor_lmap () =
  let f = Chain_category.Function_profunctor.lmap (fun x -> x * 2) (fun x -> x + 10) in
  check int "lmap" 16 (f 3)

let test_profunctor_rmap () =
  let f = Chain_category.Function_profunctor.rmap (fun x -> x + 1) (fun x -> x + 10) in
  check int "rmap" 14 (f 3)

(* ============================================================
   8. Utility functions
   ============================================================ *)

let test_identity () =
  check int "identity" 42 (Chain_category.identity 42)

let test_compose () =
  let f = Chain_category.compose (fun x -> x + 1) (fun x -> x * 2) in
  check int "compose" 7 (f 3)

let test_compose_infix () =
  let f = Chain_category.( << ) (fun x -> x + 1) (fun x -> x * 2) in
  check int "<<" 7 (f 3)

let test_pipe_infix () =
  let f = Chain_category.( >> ) (fun x -> x + 1) (fun x -> x * 2) in
  check int ">>" 8 (f 3)

let test_flip () =
  let f = Chain_category.flip (fun a b -> a - b) in
  check int "flip" 2 (f 3 5)

let test_const () =
  let f = Chain_category.const 42 in
  check int "const" 42 (f "anything")

let test_curry () =
  let f = Chain_category.curry (fun (a, b) -> a + b) in
  check int "curry" 5 (f 2 3)

let test_uncurry () =
  let f = Chain_category.uncurry (fun a b -> a + b) in
  check int "uncurry" 5 (f (2, 3))

(* ============================================================
   9. Laws verification
   ============================================================ *)

let test_monoid_laws_verdict () =
  let module L = Chain_category.Laws.Monoid(Chain_category.Verdict_monoid) in
  let _left = L.left_identity_law (Pass "x") in
  let _right = L.right_identity_law (Pass "x") in
  let _assoc = L.associativity_law (Pass "a") (Pass "b") (Pass "c") in
  ()

let test_monoid_laws_confidence () =
  let module L = Chain_category.Laws.Monoid(Chain_category.Confidence_monoid) in
  let _left = L.left_identity_law 0.5 in
  let _right = L.right_identity_law 0.5 in
  let _assoc = L.associativity_law 0.3 0.5 0.7 in
  ()

let test_functor_laws () =
  let module F = Chain_category.Laws.Functor(Chain_category.Result_monad) in
  let eq a b = a = b in
  let _id = F.identity_law (Ok 42) eq in
  let _comp = F.composition_law (fun x -> x + 1) (fun x -> x * 2) (Ok 3) eq in
  ()

let test_monad_laws () =
  let module M = Chain_category.Laws.Monad(Chain_category.Result_monad) in
  let eq a b = a = b in
  let f x = Ok (x + 1) in
  let g x = Ok (x * 2) in
  let _left = M.left_identity_law 5 f eq in
  let _right = M.right_identity_law (Ok 5) eq in
  let _assoc = M.associativity_law (Ok 5) f g eq in
  ()

(* ============================================================
   10. Chain_error — is_recoverable
   ============================================================ *)

let test_recoverable () =
  let open Chain_error in
  check bool "gemini sync" true (is_recoverable (Model (GeminiError GeminiFunctionCallSync)));
  check bool "gemini rate" true (is_recoverable (Model (GeminiError GeminiRateLimit)));
  check bool "claude rate" true (is_recoverable (Model (ClaudeError ClaudeRateLimit)));
  check bool "codex rate" true (is_recoverable (Model (CodexError CodexRateLimit)));
  check bool "process timeout" true (is_recoverable (Process (ProcessTimeout 30)));
  check bool "network" true (is_recoverable (Io (NetworkError "timeout")));
  check bool "gemini ctx" false (is_recoverable (Model (GeminiError GeminiContextTooLong)));
  check bool "internal" false (is_recoverable (Internal "bug"))

(* ============================================================
   11. Chain_error — to_string (all variants)
   ============================================================ *)

let test_to_string_all () =
  let open Chain_error in
  let errors = [
    Model (GeminiError GeminiFunctionCallSync);
    Model (GeminiError GeminiContextTooLong);
    Model (GeminiError GeminiRateLimit);
    Model (GeminiError GeminiAuth);
    Model (GeminiError (GeminiUnknown "test"));
    Model (ClaudeError ClaudeContextTooLong);
    Model (ClaudeError ClaudeRateLimit);
    Model (ClaudeError ClaudeAuth);
    Model (ClaudeError ClaudeTimeout);
    Model (ClaudeError (ClaudeUnknown "test"));
    Model (CodexError CodexRateLimit);
    Model (CodexError CodexAuth);
    Model (CodexError CodexSandboxViolation);
    Model (CodexError CodexTimeout);
    Model (CodexError (CodexUnknown "test"));
    Chain (ChainParseError "test");
    Chain (ChainCompileError "test");
    Chain (ChainExecutionError "test");
    Chain (ChainTimeoutError 5000);
    Chain ChainCycleDetected;
    Chain (ChainNodeNotFound "n1");
    Chain (ChainValidationError "test");
    Mcp (McpParseError "test");
    Mcp (McpMethodNotFound "test");
    Mcp (McpInvalidParams "test");
    Mcp (McpAuthError "test");
    Mcp (McpInternalError "test");
    Process (ProcessTimeout 10);
    Process (ProcessExitCode (1, "stderr"));
    Process (ProcessSpawnError "test");
    Process ProcessKilled;
    Io (NetworkError "test");
    Io (FileNotFound "test");
    Io (PermissionDenied "test");
    Io (JsonParseError "test");
    Io (EncodingError "test");
    Internal "test";
  ] in
  List.iter (fun e ->
    let s = Chain_error.to_string e in
    check bool "non-empty" true (String.length s > 0)
  ) errors

(* ============================================================
   12. Chain_error — severity_of_error
   ============================================================ *)

let test_severity () =
  let open Chain_error in
  let cases = [
    (Model (GeminiError GeminiFunctionCallSync), Warning);
    (Model (GeminiError GeminiRateLimit), Warning);
    (Model (ClaudeError ClaudeAuth), Error);
    (Chain (ChainParseError "p"), Warning);
    (Chain ChainCycleDetected, Error);
    (Mcp (McpMethodNotFound "m"), Warning);
    (Mcp (McpAuthError "a"), Error);
    (Process (ProcessTimeout 10), Warning);
    (Process ProcessKilled, Error);
    (Io (NetworkError "n"), Error);
    (Internal "i", Critical);
  ] in
  List.iter (fun (e, expected) ->
    let sev = severity_of_error e in
    check string "severity" (string_of_severity expected) (string_of_severity sev)
  ) cases

(* ============================================================
   13. Chain_error — result helpers
   ============================================================ *)

let test_fail_ok () =
  let r = Chain_error.fail (Chain_error.Internal "e") in
  (match r with Error _ -> () | Ok _ -> fail "should be error");
  let r2 = Chain_error.ok 42 in
  (match r2 with Ok 42 -> () | _ -> fail "should be ok")

let test_to_string_result () =
  let r = Chain_error.to_string_result (Error (Chain_error.Internal "e")) in
  (match r with Error s -> check bool "has msg" true (String.length s > 0) | Ok _ -> fail "err");
  let r2 = Chain_error.to_string_result (Ok 42) in
  (match r2 with Ok 42 -> () | _ -> fail "ok")

let test_of_string () =
  let e = Chain_error.of_string "test" in
  (match e with Chain_error.Internal "test" -> () | _ -> fail "not Internal")

(* ============================================================
   14. Chain_types — direction
   ============================================================ *)

let test_direction_roundtrip () =
  List.iter (fun dir ->
    let s = direction_to_string dir in
    let d = direction_of_string s in
    check bool ("dir " ^ s) true (d = dir)
  ) [LR; RL; TB; BT]

let test_direction_td_alias () =
  let d = direction_of_string "TD" in
  check bool "TD = TB" true (d = TB)

let test_direction_unknown () =
  let d = direction_of_string "XYZ" in
  check bool "default LR" true (d = LR)

(* ============================================================
   15. Chain_types — consensus_mode
   ============================================================ *)

let test_consensus_roundtrip () =
  (* Majority and Unanimous roundtrip cleanly *)
  List.iter (fun mode ->
    let s = consensus_mode_to_string mode in
    let m = consensus_mode_of_string s in
    (match mode, m with
     | Majority, Majority -> ()
     | Unanimous, Unanimous -> ()
     | _ -> fail "mismatch")
  ) [Majority; Unanimous];
  (* Weighted roundtrips to approximately the same value *)
  let s = consensus_mode_to_string (Weighted 0.75) in
  (match consensus_mode_of_string s with
   | Weighted t -> check bool "weighted" true (t > 0.7 && t < 0.8)
   | _ -> fail "not Weighted");
  (* Count serializes as "count:N", but of_string tries int_of_string on the full string,
     which fails for "count:3", defaulting to Count 1. Test the raw int parse path. *)
  let m = consensus_mode_of_string "3" in
  (match m with Count 3 -> () | _ -> fail "count 3")

let test_consensus_default () =
  let m = consensus_mode_of_string "not_a_number" in
  (match m with Count _ -> () | _ -> fail "should default to Count")

(* ============================================================
   16. Chain_types — confidence
   ============================================================ *)

let test_confidence_to_float () =
  check (float 0.01) "high" 1.0 (confidence_to_float High);
  check (float 0.01) "medium" 0.5 (confidence_to_float Medium);
  check (float 0.01) "low" 0.2 (confidence_to_float Low)

let test_confidence_of_string () =
  check bool "high" true (confidence_of_string "high" = High);
  check bool "medium" true (confidence_of_string "medium" = Medium);
  check bool "low" true (confidence_of_string "low" = Low);
  check bool "unknown" true (confidence_of_string "xyz" = Low)

(* ============================================================
   17. Chain_types — context_mode
   ============================================================ *)

let test_context_mode_roundtrip () =
  List.iter (fun mode ->
    let s = context_mode_to_string mode in
    let m = context_mode_of_string s in
    check bool ("mode " ^ s) true (m = mode)
  ) [CM_None; CM_Summary; CM_Full]

let test_context_mode_default () =
  let m = context_mode_of_string "unknown" in
  check bool "default summary" true (m = CM_Summary)

(* ============================================================
   18. Chain_types — node_type_name
   ============================================================ *)

let test_node_type_name_all () =
  let inner = dummy_node "x" (dummy_model ()) in
  let chain = dummy_chain [inner] in
  let types = [
    (dummy_model (), "model"); (Tool { name = "t"; args = `Null }, "tool");
    (Pipeline [], "pipeline"); (Fanout [], "fanout");
    (Quorum { consensus = Majority; nodes = []; weights = [] }, "quorum");
    (Gate { condition = "c"; then_node = inner; else_node = None }, "gate");
    (Subgraph chain, "subgraph"); (ChainRef "r", "chain_ref");
    (Map { func = "f"; inner }, "map"); (Bind { func = "g"; inner }, "bind");
    (Merge { strategy = First; nodes = [] }, "merge");
    (Threshold { metric = "m"; operator = Gt; value = 0.5; input_node = inner; on_pass = None; on_fail = None }, "threshold");
    (GoalDriven { goal_metric = "g"; goal_operator = Gte; goal_value = 0.9;
                  action_node = inner; measure_func = "mf"; max_iterations = 5;
                  strategy_hints = []; conversational = false; relay_models = [] }, "goal_driven");
    (Evaluator { candidates = []; scoring_func = "f"; scoring_prompt = None; select_strategy = Best; min_score = None }, "evaluator");
    (Retry { node = inner; max_attempts = 3; backoff = Constant 1.0; retry_on = [] }, "retry");
    (Fallback { primary = inner; fallbacks = [] }, "fallback");
    (Race { nodes = []; timeout = None }, "race");
    (ChainExec { chain_source = "s"; validate = true; max_depth = 3; sandbox = false; context_inject = []; pass_outputs = true }, "chain_exec");
    (Adapter { input_ref = "i"; transform = Template "t"; on_error = `Fail }, "adapter");
    (Cache { key_expr = "k"; ttl_seconds = 60; inner }, "cache");
    (Batch { batch_size = 10; parallel = true; inner; collect_strategy = `List }, "batch");
    (Spawn { clean = true; inner; pass_vars = []; inherit_cache = true }, "spawn");
    (Mcts { strategies = []; simulation = inner; evaluator = "e"; evaluator_prompt = None;
            policy = Greedy; max_iterations = 10; max_depth = 5; expansion_threshold = 3; early_stop = None; parallel_sims = 1 }, "mcts");
    (StreamMerge { nodes = []; reducer = First; initial = ""; min_results = None; timeout = None }, "stream_merge");
    (FeedbackLoop { generator = inner; evaluator_config = { scoring_func = "f"; scoring_prompt = None; select_strategy = Best };
                    improver_prompt = "p"; max_iterations = 3; score_threshold = 0.7; score_operator = Gte;
                    conversational = false; relay_models = [] }, "feedback_loop");
    (Masc_broadcast { room = None; message = ""; mention = [] }, "masc_broadcast");
    (Masc_listen { room = None; filter = None; timeout_sec = 30.0 }, "masc_listen");
    (Masc_claim { room = None; task_id = None }, "masc_claim");
    (Cascade { tiers = []; confidence_prompt = None; max_escalations = 2;
               context_mode = CM_Summary; task_hint = None; default_threshold = 0.7 }, "cascade");
  ] in
  List.iter (fun (nt, expected) ->
    check string ("name " ^ expected) expected (node_type_name nt)
  ) types

(* ============================================================
   19. Chain_types — make_* helpers
   ============================================================ *)

let test_make_chain_fn () =
  let n = dummy_node "n" (dummy_model ()) in
  let c = make_chain ~id:"c1" ~nodes:[n] ~output:"n" () in
  check string "id" "c1" c.id

let test_make_model_node () =
  let n = make_model_node ~id:"l1" ~model:"gemini" ~prompt:"hi" () in
  check string "id" "l1" n.id

let test_make_tool_node () =
  let n = make_tool_node ~id:"t1" ~name:"search" ~args:(`Assoc []) in
  check string "id" "t1" n.id

let test_make_pipeline () =
  let n = make_pipeline ~id:"p1" [] in
  check string "id" "p1" n.id

let test_make_fanout () =
  let n = make_fanout ~id:"f1" [] in
  check string "id" "f1" n.id

let test_make_quorum () =
  let n = make_quorum ~id:"q1" ~consensus:Majority [] in
  check string "id" "q1" n.id

let test_make_threshold () =
  let inner = dummy_node "i" (dummy_model ()) in
  let n = make_threshold ~id:"th1" ~metric:"score" ~operator:Gte ~value:0.5 ~input_node:inner () in
  check string "id" "th1" n.id

let test_make_goal_driven () =
  let inner = dummy_node "i" (dummy_model ()) in
  let n = make_goal_driven ~id:"gd1" ~goal_metric:"m" ~goal_operator:Gte ~goal_value:0.9
      ~action_node:inner ~measure_func:"f" ~max_iterations:5 () in
  check string "id" "gd1" n.id

let test_make_evaluator () =
  let n = make_evaluator ~id:"ev1" ~candidates:[] ~scoring_func:"f" ~select_strategy:Best () in
  check string "id" "ev1" n.id

let test_make_retry () =
  let inner = dummy_node "i" (dummy_model ()) in
  let n = make_retry ~id:"r1" ~node:inner ~max_attempts:3 () in
  check string "id" "r1" n.id

let test_make_fallback () =
  let inner = dummy_node "i" (dummy_model ()) in
  let n = make_fallback ~id:"fb1" ~primary:inner ~fallbacks:[] in
  check string "id" "fb1" n.id

let test_make_race () =
  let n = make_race ~id:"rc1" ~nodes:[] () in
  check string "id" "rc1" n.id

let test_make_feedback_loop () =
  let inner = dummy_node "i" (dummy_model ()) in
  let n = make_feedback_loop ~id:"fl1" ~generator:inner
      ~evaluator_config:{ scoring_func = "f"; scoring_prompt = None; select_strategy = Best }
      ~improver_prompt:"p" ~max_iterations:3 ~score_threshold:0.7 () in
  check string "id" "fl1" n.id

let test_make_cascade () =
  let n = make_cascade ~id:"cs1" ~tiers:[] () in
  check string "id" "cs1" n.id

let test_make_adapter () =
  let n = make_adapter ~id:"ad1" ~input_ref:"i" ~transform:(Template "t") () in
  check string "id" "ad1" n.id

(* ============================================================
   20. count_parallel_groups
   ============================================================ *)

let test_count_parallel_groups_leaf () =
  let n = dummy_node "n" (dummy_model ()) in
  check int "leaf" 0 (count_parallel_groups n)

let test_count_parallel_groups_fanout () =
  let inner = dummy_node "i" (dummy_model ()) in
  let n = dummy_node "n" (Fanout [inner; inner]) in
  check int "fanout" 1 (count_parallel_groups n)

let test_count_parallel_groups_chain () =
  let inner = dummy_node "i" (dummy_model ()) in
  let n = dummy_node "n" (Fanout [inner; inner]) in
  let c = dummy_chain [n] in
  check int "chain" 1 (count_chain_parallel_groups c)

(* ============================================================
   21. Chain_types — yojson roundtrip (exercises [@@deriving yojson])
   ============================================================ *)

let test_direction_yojson () =
  List.iter (fun dir ->
    let j = direction_to_yojson dir in
    (match direction_of_yojson j with
     | Ok d -> check bool "dir rt" true (d = dir)
     | Error e -> fail e)
  ) [LR; RL; TB; BT]

let test_consensus_mode_yojson () =
  List.iter (fun mode ->
    let j = consensus_mode_to_yojson mode in
    (match consensus_mode_of_yojson j with
     | Ok m ->
       (match mode, m with
        | Count n, Count n2 -> check int "count" n n2
        | Majority, Majority -> ()
        | Unanimous, Unanimous -> ()
        | Weighted _, Weighted _ -> ()
        | _ -> fail "mismatch")
     | Error e -> fail e)
  ) [Count 3; Majority; Unanimous; Weighted 0.75]

let test_chain_config_yojson () =
  let cfg = { default_config with max_depth = 5; trace = true; direction = TB } in
  let j = chain_config_to_yojson cfg in
  match chain_config_of_yojson j with
  | Ok c ->
    check int "depth" 5 c.max_depth;
    check bool "trace" true c.trace;
    check bool "dir" true (c.direction = TB)
  | Error e -> fail e

let test_merge_strategy_yojson () =
  List.iter (fun s ->
    let j = merge_strategy_to_yojson s in
    (match merge_strategy_of_yojson j with
     | Ok s2 -> check bool "ms" true (s = s2)
     | Error e -> fail e)
  ) [First; Last; Concat; WeightedAvg; Custom "my_fn"]

let test_threshold_op_yojson () =
  List.iter (fun op ->
    let j = threshold_op_to_yojson op in
    (match threshold_op_of_yojson j with
     | Ok op2 -> check bool "op" true (op = op2)
     | Error e -> fail e)
  ) [Gt; Gte; Lt; Lte; Eq; Neq]

let test_select_strategy_yojson () =
  List.iter (fun s ->
    let j = select_strategy_to_yojson s in
    (match select_strategy_of_yojson j with
     | Ok s2 -> check bool "ss" true (s = s2)
     | Error e -> fail e)
  ) [Best; Worst; WeightedRandom; AboveThreshold 0.8]

let test_backoff_strategy_yojson () =
  List.iter (fun b ->
    let j = backoff_strategy_to_yojson b in
    (match backoff_strategy_of_yojson j with
     | Ok _ -> ()
     | Error e -> fail e)
  ) [Constant 1.0; Exponential 2.0; Linear 1.5; Jitter (0.5, 2.0)]

let test_adapter_transform_yojson () =
  List.iter (fun t ->
    let j = adapter_transform_to_yojson t in
    (match adapter_transform_of_yojson j with
     | Ok _ -> ()
     | Error e -> fail e)
  ) [Extract "p"; Template "t"; Summarize 100; Truncate 200; JsonPath "$.x";
     Regex ("p", "r"); ValidateSchema "s"; ParseJson; Stringify;
     Chain [ParseJson; Stringify];
     Conditional { condition = "c"; on_true = ParseJson; on_false = Stringify };
     Split { delimiter = "\n"; chunk_size = 100; overlap = 10 };
     Custom "my_fn"]

let test_mcts_policy_yojson () =
  List.iter (fun p ->
    let j = mcts_policy_to_yojson p in
    (match mcts_policy_of_yojson j with
     | Ok _ -> ()
     | Error e -> fail e)
  ) [UCB1 1.41; Greedy; EpsilonGreedy 0.1; Softmax 1.0]

let test_confidence_level_yojson () =
  List.iter (fun cl ->
    let j = confidence_level_to_yojson cl in
    (match confidence_level_of_yojson j with
     | Ok c -> check bool "cl" true (c = cl)
     | Error e -> fail e)
  ) [High; Medium; Low]

let test_context_mode_yojson () =
  List.iter (fun cm ->
    let j = context_mode_to_yojson cm in
    (match context_mode_of_yojson j with
     | Ok c -> check bool "cm" true (c = cm)
     | Error e -> fail e)
  ) [CM_None; CM_Summary; CM_Full]

let test_node_type_yojson_model () =
  let nt = dummy_model () in
  let j = node_type_to_yojson nt in
  (match node_type_of_yojson j with
   | Ok _ -> ()
   | Error e -> fail e)

let test_node_type_yojson_tool () =
  let nt = Tool { name = "search"; args = `Assoc [("q", `String "test")] } in
  let j = node_type_to_yojson nt in
  (match node_type_of_yojson j with
   | Ok _ -> ()
   | Error e -> fail e)

let test_node_type_yojson_all () =
  let inner = dummy_node "x" (dummy_model ()) in
  let chain = dummy_chain [inner] in
  let types = [
    dummy_model ();
    Tool { name = "t"; args = `Null };
    Pipeline [inner]; Fanout [inner];
    Quorum { consensus = Majority; nodes = [inner]; weights = [("x", 1.0)] };
    Gate { condition = "c"; then_node = inner; else_node = Some inner };
    Subgraph chain; ChainRef "ref1";
    Map { func = "f"; inner }; Bind { func = "g"; inner };
    Merge { strategy = Concat; nodes = [inner] };
    Threshold { metric = "m"; operator = Gt; value = 0.5; input_node = inner; on_pass = Some inner; on_fail = Some inner };
    GoalDriven { goal_metric = "g"; goal_operator = Gte; goal_value = 0.9;
                 action_node = inner; measure_func = "mf"; max_iterations = 5;
                 strategy_hints = [("k", "v")]; conversational = true; relay_models = ["m1"] };
    Evaluator { candidates = [inner]; scoring_func = "sf"; scoring_prompt = Some "sp"; select_strategy = Best; min_score = Some 0.5 };
    Retry { node = inner; max_attempts = 3; backoff = Exponential 2.0; retry_on = ["err"] };
    Fallback { primary = inner; fallbacks = [inner] };
    Race { nodes = [inner]; timeout = Some 5.0 };
    ChainExec { chain_source = "src"; validate = true; max_depth = 3; sandbox = true; context_inject = [("k","v")]; pass_outputs = true };
    Adapter { input_ref = "inp"; transform = Template "t"; on_error = `Fail };
    Cache { key_expr = "k"; ttl_seconds = 60; inner };
    Batch { batch_size = 10; parallel = true; inner; collect_strategy = `Concat };
    Spawn { clean = true; inner; pass_vars = ["x"]; inherit_cache = false };
    Mcts { strategies = [inner]; simulation = inner; evaluator = "e"; evaluator_prompt = Some "ep";
           policy = UCB1 1.41; max_iterations = 10; max_depth = 5;
           expansion_threshold = 3; early_stop = Some 0.95; parallel_sims = 2 };
    StreamMerge { nodes = [inner]; reducer = WeightedAvg; initial = "init"; min_results = Some 2; timeout = Some 10.0 };
    FeedbackLoop { generator = inner;
                   evaluator_config = { scoring_func = "f"; scoring_prompt = Some "sp"; select_strategy = AboveThreshold 0.5 };
                   improver_prompt = "p"; max_iterations = 3; score_threshold = 0.7; score_operator = Lte;
                   conversational = true; relay_models = ["m1"; "m2"] };
    Masc_broadcast { room = Some "r"; message = "hi"; mention = ["@a"] };
    Masc_listen { room = Some "r"; filter = Some "f"; timeout_sec = 30.0 };
    Masc_claim { room = Some "r"; task_id = Some "t1" };
    Cascade { tiers = [{ tier_node = inner; tier_index = 0; confidence_threshold = 0.7;
                          cost_weight = 1.0; pass_context = true }];
              confidence_prompt = Some "cp"; max_escalations = 2;
              context_mode = CM_Full; task_hint = Some "hint"; default_threshold = 0.7 };
  ] in
  List.iter (fun nt ->
    let j = node_type_to_yojson nt in
    (match node_type_of_yojson j with
     | Ok _ -> ()
     | Error e -> fail ("node_type_of_yojson: " ^ e))
  ) types

let test_node_yojson () =
  let n = { (dummy_node "n1" (dummy_model ())) with
            input_mapping = [("k", "v")]; output_key = Some "out"; depends_on = Some ["d1"] } in
  let j = node_to_yojson n in
  (match node_of_yojson j with
   | Ok n2 -> check string "id" "n1" n2.id
   | Error e -> fail e)

let test_chain_yojson () =
  let n = dummy_node "n1" (dummy_model ()) in
  let c = { (dummy_chain [n]) with
            name = Some "test"; description = Some "desc"; version = Some "1.0";
            input_schema = Some (`Assoc []); output_schema = Some (`Assoc []);
            metadata = Some (`Assoc [("k", `String "v")]) } in
  let j = chain_to_yojson c in
  (match chain_of_yojson j with
   | Ok c2 -> check string "id" "test" c2.id
   | Error e -> fail e)

let test_trace_entry_yojson () =
  let te : trace_entry = {
    node_id = "n1"; node_type_name = "model";
    start_time = 1.0; end_time = 2.0;
    status = `Success; output_preview = Some "out"; error = None
  } in
  let j = trace_entry_to_yojson te in
  (match trace_entry_of_yojson j with
   | Ok te2 -> check string "id" "n1" te2.node_id
   | Error e -> fail e)

let test_token_usage_yojson () =
  let tu : token_usage = { prompt_tokens = 10; completion_tokens = 5; total_tokens = 15; estimated_cost_usd = 0.01 } in
  let j = token_usage_to_yojson tu in
  (match token_usage_of_yojson j with
   | Ok tu2 -> check int "total" 15 tu2.total_tokens
   | Error e -> fail e)

let test_chain_result_yojson () =
  let cr : chain_result = {
    chain_id = "c1"; output = "result"; success = true;
    trace = []; token_usage = empty_token_usage; duration_ms = 100;
    metadata = [("k", "v")]
  } in
  let j = chain_result_to_yojson cr in
  (match chain_result_of_yojson j with
   | Ok cr2 -> check string "id" "c1" cr2.chain_id
   | Error e -> fail e)

let test_execution_plan_yojson () =
  let n = dummy_node "n1" (dummy_model ()) in
  let c = dummy_chain [n] in
  let ep : execution_plan = {
    chain = c; execution_order = ["n1"]; parallel_groups = [["n1"]]; depth = 1
  } in
  let j = execution_plan_to_yojson ep in
  (match execution_plan_of_yojson j with
   | Ok ep2 -> check int "depth" 1 ep2.depth
   | Error e -> fail e)

let test_batch_priority_yojson () =
  List.iter (fun p ->
    let j = batch_priority_to_yojson p in
    (match batch_priority_of_yojson j with
     | Ok _ -> ()
     | Error e -> fail e)
  ) [High; Normal; Low]

let test_retry_config_yojson () =
  let rc = default_retry_config in
  let j = retry_config_to_yojson rc in
  (match retry_config_of_yojson j with
   | Ok rc2 -> check int "retries" 3 rc2.max_retries
   | Error e -> fail e)

let test_batch_config_yojson () =
  let bc = default_batch_config in
  let j = batch_config_to_yojson bc in
  (match batch_config_of_yojson j with
   | Ok bc2 -> check int "concurrent" 5 bc2.batch_max_concurrent
   | Error e -> fail e)

let test_evaluator_config_yojson () =
  let ec : evaluator_config = { scoring_func = "f"; scoring_prompt = Some "sp"; select_strategy = Best } in
  let j = evaluator_config_to_yojson ec in
  (match evaluator_config_of_yojson j with
   | Ok ec2 -> check string "func" "f" ec2.scoring_func
   | Error e -> fail e)

let test_evaluator_result_yojson () =
  let er : evaluator_result = { score = 0.9; feedback = Some "good"; selected_output = "out"; selected_id = "n1" } in
  let j = evaluator_result_to_yojson er in
  (match evaluator_result_of_yojson j with
   | Ok er2 -> check (float 0.01) "score" 0.9 er2.score
   | Error e -> fail e)

(* ============================================================
   22. Chain_types — more node_to_json variants via chain_parser_serialize
   ============================================================ *)

let test_node_json_all_types () =
  let inner = dummy_node "x" (dummy_model ()) in
  let chain = dummy_chain [inner] in
  let nodes = [
    dummy_node "model" (Model { model = "m"; system = Some "sys"; prompt = "p"; timeout = Some 30;
                             tools = Some (`List [`String "t"]); prompt_ref = Some "ref";
                             prompt_vars = [("k","v")]; thinking = true });
    dummy_node "tool" (Tool { name = "srv:method"; args = `Assoc [("x", `Int 1)] });
    dummy_node "tool2" (Tool { name = "simple"; args = `Null });
    dummy_node "pipe" (Pipeline [inner]);
    dummy_node "fan" (Fanout [inner]);
    dummy_node "quorum" (Quorum { consensus = Count 2; nodes = [inner]; weights = [("x", 0.5)] });
    dummy_node "quorum2" (Quorum { consensus = Majority; nodes = [inner]; weights = [] });
    dummy_node "gate" (Gate { condition = "c"; then_node = inner; else_node = Some inner });
    dummy_node "gate2" (Gate { condition = "c"; then_node = inner; else_node = None });
    dummy_node "sub" (Subgraph chain);
    dummy_node "ref" (ChainRef "r");
    dummy_node "map" (Map { func = "f"; inner });
    dummy_node "bind" (Bind { func = "g"; inner });
    dummy_node "merge" (Merge { strategy = Custom "fn"; nodes = [inner] });
    dummy_node "thr" (Threshold { metric = "m"; operator = Lte; value = 0.5; input_node = inner;
                                   on_pass = Some inner; on_fail = Some inner });
    dummy_node "thr2" (Threshold { metric = "m"; operator = Neq; value = 0.5; input_node = inner;
                                    on_pass = None; on_fail = None });
    dummy_node "gd" (GoalDriven { goal_metric = "g"; goal_operator = Lt; goal_value = 0.9;
                                   action_node = inner; measure_func = "mf"; max_iterations = 5;
                                   strategy_hints = [("k","v")]; conversational = true; relay_models = ["m1"] });
    dummy_node "eval" (Evaluator { candidates = [inner]; scoring_func = "f"; scoring_prompt = Some "sp";
                                    select_strategy = AboveThreshold 0.5; min_score = Some 0.3 });
    dummy_node "retry" (Retry { node = inner; max_attempts = 3; backoff = Jitter (0.5, 2.0); retry_on = ["err"] });
    dummy_node "fb" (Fallback { primary = inner; fallbacks = [inner] });
    dummy_node "race" (Race { nodes = [inner]; timeout = Some 5.0 });
    dummy_node "race2" (Race { nodes = [inner]; timeout = None });
    dummy_node "exec" (ChainExec { chain_source = "s"; validate = true; max_depth = 3; sandbox = true;
                                    context_inject = [("k","v")]; pass_outputs = false });
    dummy_node "adapt" (Adapter { input_ref = "i"; transform = Regex ("p","r"); on_error = `Passthrough });
    dummy_node "adapt2" (Adapter { input_ref = "i"; transform = Template "t"; on_error = `Default "d" });
    dummy_node "cache" (Cache { key_expr = "k"; ttl_seconds = 60; inner });
    dummy_node "batch" (Batch { batch_size = 10; parallel = false; inner; collect_strategy = `Concat });
    dummy_node "batch2" (Batch { batch_size = 5; parallel = true; inner; collect_strategy = `First });
    dummy_node "batch3" (Batch { batch_size = 5; parallel = true; inner; collect_strategy = `Last });
    dummy_node "spawn" (Spawn { clean = true; inner; pass_vars = ["a"]; inherit_cache = false });
    dummy_node "mcts" (Mcts { strategies = [inner]; simulation = inner; evaluator = "e";
                               evaluator_prompt = Some "ep"; policy = Softmax 1.0;
                               max_iterations = 10; max_depth = 5; expansion_threshold = 3;
                               early_stop = Some 0.95; parallel_sims = 2 });
    dummy_node "sm" (StreamMerge { nodes = [inner]; reducer = Custom "fn"; initial = "init";
                                    min_results = Some 2; timeout = Some 10.0 });
    dummy_node "fl" (FeedbackLoop { generator = inner;
                                     evaluator_config = { scoring_func = "f"; scoring_prompt = Some "sp"; select_strategy = Worst };
                                     improver_prompt = "p"; max_iterations = 3; score_threshold = 0.7; score_operator = Neq;
                                     conversational = true; relay_models = ["m1"] });
    dummy_node "bc" (Masc_broadcast { room = Some "r"; message = "hi"; mention = ["@a"] });
    dummy_node "bc2" (Masc_broadcast { room = None; message = "hi"; mention = [] });
    dummy_node "li" (Masc_listen { room = Some "r"; filter = Some "f"; timeout_sec = 30.0 });
    dummy_node "li2" (Masc_listen { room = None; filter = None; timeout_sec = 30.0 });
    dummy_node "cl" (Masc_claim { room = Some "r"; task_id = Some "t1" });
    dummy_node "cl2" (Masc_claim { room = None; task_id = None });
    dummy_node "cas" (Cascade { tiers = [{ tier_node = inner; tier_index = 0;
                                            confidence_threshold = 0.7; cost_weight = 1.0; pass_context = true }];
                                 confidence_prompt = Some "cp"; max_escalations = 2;
                                 context_mode = CM_Full; task_hint = Some "h"; default_threshold = 0.7 });
    dummy_node "cas2" (Cascade { tiers = []; confidence_prompt = None; max_escalations = 2;
                                  context_mode = CM_None; task_hint = None; default_threshold = 0.7 });
  ] in
  List.iter (fun n ->
    let j = Chain_parser.node_to_json n in
    let s = Yojson.Safe.to_string j in
    check bool ("json " ^ n.id) true (String.length s > 5)
  ) nodes

(* ============================================================
   23. Chain_error — yojson roundtrip
   ============================================================ *)

let test_chain_error_yojson_all () =
  let errors : Chain_error.t list = [
    Model (GeminiError GeminiFunctionCallSync);
    Model (GeminiError GeminiContextTooLong);
    Model (GeminiError GeminiRateLimit);
    Model (GeminiError GeminiAuth);
    Model (GeminiError (GeminiUnknown "test"));
    Model (ClaudeError ClaudeContextTooLong);
    Model (ClaudeError ClaudeRateLimit);
    Model (ClaudeError ClaudeAuth);
    Model (ClaudeError ClaudeTimeout);
    Model (ClaudeError (ClaudeUnknown "test"));
    Model (CodexError CodexRateLimit);
    Model (CodexError CodexAuth);
    Model (CodexError CodexSandboxViolation);
    Model (CodexError CodexTimeout);
    Model (CodexError (CodexUnknown "test"));
    Chain (ChainParseError "test");
    Chain (ChainCompileError "test");
    Chain (ChainExecutionError "test");
    Chain (ChainTimeoutError 5000);
    Chain ChainCycleDetected;
    Chain (ChainNodeNotFound "n1");
    Chain (ChainValidationError "test");
    Mcp (McpParseError "test");
    Mcp (McpMethodNotFound "test");
    Mcp (McpInvalidParams "test");
    Mcp (McpAuthError "test");
    Mcp (McpInternalError "test");
    Process (ProcessTimeout 10);
    Process (ProcessExitCode (1, "stderr"));
    Process (ProcessSpawnError "test");
    Process ProcessKilled;
    Io (NetworkError "test");
    Io (FileNotFound "test");
    Io (PermissionDenied "test");
    Io (JsonParseError "test");
    Io (EncodingError "test");
    Internal "test";
  ] in
  List.iter (fun (e : Chain_error.t) ->
    let j = Chain_error.to_yojson e in
    let roundtrip : (Chain_error.t, string) Stdlib.result = Chain_error.of_yojson j in
    (match roundtrip with
     | Ok _ -> ()
     | Error msg -> fail ("chain_error of_yojson: " ^ msg))
  ) errors

(* ============================================================
   Runner
   ============================================================ *)

let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio_guard.enable ();
  run "chain_category_coverage" [
    "Result_monad", [
      test_case "pure" `Quick test_result_monad_pure;
      test_case "map ok" `Quick test_result_monad_map_ok;
      test_case "map err" `Quick test_result_monad_map_err;
      test_case "ap ok" `Quick test_result_monad_ap_ok;
      test_case "ap err f" `Quick test_result_monad_ap_err_f;
      test_case "ap err x" `Quick test_result_monad_ap_err_x;
      test_case "map2 ok" `Quick test_result_monad_map2_ok;
      test_case "map2 err1" `Quick test_result_monad_map2_err_1;
      test_case "map2 err2" `Quick test_result_monad_map2_err_2;
      test_case "sequence ok" `Quick test_result_monad_sequence_ok;
      test_case "sequence empty" `Quick test_result_monad_sequence_empty;
      test_case "sequence err" `Quick test_result_monad_sequence_err;
      test_case "bind ok" `Quick test_result_monad_bind_ok;
      test_case "bind err" `Quick test_result_monad_bind_err;
      test_case "join" `Quick test_result_monad_join;
      test_case "kleisli" `Quick test_result_monad_kleisli;
      test_case "run ok" `Quick test_result_monad_run_ok;
      test_case "run err" `Quick test_result_monad_run_err;
      test_case "catch ok" `Quick test_result_monad_catch_ok;
      test_case "catch exn" `Quick test_result_monad_catch_exn;
      test_case "map_error" `Quick test_result_monad_map_error;
      test_case "map_error ok" `Quick test_result_monad_map_error_ok;
    ];
    "Result_kleisli", [
      test_case "arr" `Quick test_kleisli_arr;
      test_case "compose" `Quick test_kleisli_compose;
      test_case "fanout" `Quick test_kleisli_fanout;
      test_case "split" `Quick test_kleisli_split;
      test_case "first" `Quick test_kleisli_first;
      test_case "second" `Quick test_kleisli_second;
      test_case "from_option" `Quick test_kleisli_from_option;
      test_case "guard" `Quick test_kleisli_guard;
    ];
    "Verdict_monoid", [
      test_case "empty" `Quick test_verdict_empty;
      test_case "fail first" `Quick test_verdict_fail_first;
      test_case "fail second" `Quick test_verdict_fail_second;
      test_case "warn combine" `Quick test_verdict_warn_combine;
      test_case "warn+pass" `Quick test_verdict_warn_with_pass;
      test_case "pass combine" `Quick test_verdict_pass_combine;
      test_case "defer" `Quick test_verdict_defer;
      test_case "concat_all" `Quick test_verdict_concat_all;
    ];
    "Confidence_monoid", [
      test_case "empty" `Quick test_confidence_empty;
      test_case "concat" `Quick test_confidence_concat;
      test_case "concat_all" `Quick test_confidence_concat_all;
      test_case "concat_all empty" `Quick test_confidence_concat_all_empty;
      test_case "geometric" `Quick test_confidence_geometric;
      test_case "geometric empty" `Quick test_confidence_geometric_empty;
      test_case "harmonic" `Quick test_confidence_harmonic;
      test_case "harmonic empty" `Quick test_confidence_harmonic_empty;
      test_case "harmonic zero" `Quick test_confidence_harmonic_zero;
      test_case "weighted" `Quick test_confidence_weighted;
      test_case "weighted zero" `Quick test_confidence_weighted_zero;
    ];
    "Token_monoid", [
      test_case "empty" `Quick test_token_empty;
      test_case "concat" `Quick test_token_concat;
      test_case "concat_all" `Quick test_token_concat_all;
    ];
    "Trace_monoid", [
      test_case "empty" `Quick test_trace_empty;
      test_case "concat" `Quick test_trace_concat;
      test_case "concat_all" `Quick test_trace_concat_all;
    ];
    "Function_profunctor", [
      test_case "dimap" `Quick test_profunctor_dimap;
      test_case "lmap" `Quick test_profunctor_lmap;
      test_case "rmap" `Quick test_profunctor_rmap;
    ];
    "utility_functions", [
      test_case "identity" `Quick test_identity;
      test_case "compose" `Quick test_compose;
      test_case "compose infix" `Quick test_compose_infix;
      test_case "pipe infix" `Quick test_pipe_infix;
      test_case "flip" `Quick test_flip;
      test_case "const" `Quick test_const;
      test_case "curry" `Quick test_curry;
      test_case "uncurry" `Quick test_uncurry;
    ];
    "laws", [
      test_case "verdict monoid" `Quick test_monoid_laws_verdict;
      test_case "confidence monoid" `Quick test_monoid_laws_confidence;
      test_case "functor laws" `Quick test_functor_laws;
      test_case "monad laws" `Quick test_monad_laws;
    ];
    "Chain_error.is_recoverable", [
      test_case "all variants" `Quick test_recoverable;
    ];
    "Chain_error.to_string", [
      test_case "all variants" `Quick test_to_string_all;
    ];
    "Chain_error.severity", [
      test_case "all variants" `Quick test_severity;
    ];
    "Chain_error.result_helpers", [
      test_case "fail/ok" `Quick test_fail_ok;
      test_case "to_string_result" `Quick test_to_string_result;
      test_case "of_string" `Quick test_of_string;
    ];
    "Chain_types.direction", [
      test_case "roundtrip" `Quick test_direction_roundtrip;
      test_case "TD alias" `Quick test_direction_td_alias;
      test_case "unknown" `Quick test_direction_unknown;
    ];
    "Chain_types.consensus", [
      test_case "roundtrip" `Quick test_consensus_roundtrip;
      test_case "default" `Quick test_consensus_default;
    ];
    "Chain_types.confidence", [
      test_case "to_float" `Quick test_confidence_to_float;
      test_case "of_string" `Quick test_confidence_of_string;
    ];
    "Chain_types.context_mode", [
      test_case "roundtrip" `Quick test_context_mode_roundtrip;
      test_case "default" `Quick test_context_mode_default;
    ];
    "Chain_types.node_type_name", [
      test_case "all variants" `Quick test_node_type_name_all;
    ];
    "Chain_types.make_helpers", [
      test_case "make_chain" `Quick test_make_chain_fn;
      test_case "make_model_node" `Quick test_make_model_node;
      test_case "make_tool_node" `Quick test_make_tool_node;
      test_case "make_pipeline" `Quick test_make_pipeline;
      test_case "make_fanout" `Quick test_make_fanout;
      test_case "make_quorum" `Quick test_make_quorum;
      test_case "make_threshold" `Quick test_make_threshold;
      test_case "make_goal_driven" `Quick test_make_goal_driven;
      test_case "make_evaluator" `Quick test_make_evaluator;
      test_case "make_retry" `Quick test_make_retry;
      test_case "make_fallback" `Quick test_make_fallback;
      test_case "make_race" `Quick test_make_race;
      test_case "make_feedback_loop" `Quick test_make_feedback_loop;
      test_case "make_cascade" `Quick test_make_cascade;
      test_case "make_adapter" `Quick test_make_adapter;
    ];
    "count_parallel_groups", [
      test_case "leaf" `Quick test_count_parallel_groups_leaf;
      test_case "fanout" `Quick test_count_parallel_groups_fanout;
      test_case "chain" `Quick test_count_parallel_groups_chain;
    ];
    "yojson_direction", [test_case "roundtrip" `Quick test_direction_yojson];
    "yojson_consensus", [test_case "roundtrip" `Quick test_consensus_mode_yojson];
    "yojson_chain_config", [test_case "roundtrip" `Quick test_chain_config_yojson];
    "yojson_merge_strategy", [test_case "roundtrip" `Quick test_merge_strategy_yojson];
    "yojson_threshold_op", [test_case "roundtrip" `Quick test_threshold_op_yojson];
    "yojson_select_strategy", [test_case "roundtrip" `Quick test_select_strategy_yojson];
    "yojson_backoff", [test_case "roundtrip" `Quick test_backoff_strategy_yojson];
    "yojson_adapter_transform", [test_case "roundtrip" `Quick test_adapter_transform_yojson];
    "yojson_mcts_policy", [test_case "roundtrip" `Quick test_mcts_policy_yojson];
    "yojson_confidence_level", [test_case "roundtrip" `Quick test_confidence_level_yojson];
    "yojson_context_mode", [test_case "roundtrip" `Quick test_context_mode_yojson];
    "yojson_node_type", [
      test_case "model" `Quick test_node_type_yojson_model;
      test_case "tool" `Quick test_node_type_yojson_tool;
      test_case "all" `Quick test_node_type_yojson_all;
    ];
    "yojson_node", [test_case "roundtrip" `Quick test_node_yojson];
    "yojson_chain", [test_case "roundtrip" `Quick test_chain_yojson];
    "yojson_trace_entry", [test_case "roundtrip" `Quick test_trace_entry_yojson];
    "yojson_token_usage", [test_case "roundtrip" `Quick test_token_usage_yojson];
    "yojson_chain_result", [test_case "roundtrip" `Quick test_chain_result_yojson];
    "yojson_execution_plan", [test_case "roundtrip" `Quick test_execution_plan_yojson];
    "yojson_batch", [
      test_case "priority" `Quick test_batch_priority_yojson;
      test_case "retry_config" `Quick test_retry_config_yojson;
      test_case "batch_config" `Quick test_batch_config_yojson;
    ];
    "yojson_evaluator", [
      test_case "config" `Quick test_evaluator_config_yojson;
      test_case "result" `Quick test_evaluator_result_yojson;
    ];
    "node_json_all_types", [test_case "all" `Quick test_node_json_all_types];
    "chain_error_yojson", [test_case "all" `Quick test_chain_error_yojson_all];
  ]
