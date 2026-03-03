(** test_mdal.ml — Unit tests for MDAL (Metric-Driven Agent Loop) module.

    Tests cover:
    - ID generation format
    - Hearth name generation
    - Built-in profiles (5 profiles + unknown error)
    - Goal parsing (6 operators + error cases)
    - Stagnation detection and update
    - Worker result JSON parsing (valid + noisy + error)
    - Iteration evaluation (4 decision categories)
    - Board post formatting (state, iter, final)
    - Worker prompt rendering

    @since 2.70.0 *)

let () = Mirage_crypto_rng_unix.use_default ()
open Masc_mcp

(* ================================================================ *)
(* Helpers                                                          *)
(* ================================================================ *)

let dummy_profile ?(name = "test") ?(max_iter = 5) ?(stag_threshold = 0.01)
    ?(stag_count = 3) () : Mdal.profile =
  { name;
    metric_fn = "echo 0.5";
    goal = { Bounded.path = "metric"; condition = Bounded.Gte 0.95 };
    target = "test target";
    reference = None;
    agent = "claude";
    max_iterations = max_iter;
    max_time_seconds = None;
    stagnation_threshold = stag_threshold;
    stagnation_count = stag_count;
    heuristics = "test hints";
    tools_allow = [];
    tools_deny = [];
  }

let dummy_state ?(loop_id = "mdal-test") ?(baseline = 0.5)
    ?(status = `Running) ?(iteration = 0) ?(history = [])
    ?(stagnation = 0) () : Mdal.loop_state =
  { loop_id;
    profile = dummy_profile ();
    status;
    current_iteration = iteration;
    history;
    stagnation_streak = stagnation;
    baseline_metric = baseline;
    start_time = Time_compat.now ();
    state_post_id = "post-test";
  }

let dummy_record ?(iteration = 1) ?(before = 0.5) ?(after = 0.6) ?(delta = 0.1)
    ?(changes = "fixed stuff") ?(failed = "") ?(next = "more fixes")
    ?(elapsed = 1000) () : Mdal.iteration_record =
  { iteration; metric_before = before; metric_after = after; delta;
    changes; failed_attempts = failed; next_suggestion = next;
    elapsed_ms = elapsed; cost_usd = None;
  }

(* ================================================================ *)
(* ID Generation                                                    *)
(* ================================================================ *)

let test_generate_loop_id () =
  let id = Mdal.generate_loop_id () in
  Alcotest.(check bool) "starts with mdal-" true
    (String.length id > 5 && String.sub id 0 5 = "mdal-");
  (* 16 hex chars after "mdal-" *)
  let hex_part = String.sub id 5 (String.length id - 5) in
  Alcotest.(check int) "hex length is 16" 16 (String.length hex_part);
  (* All hex chars *)
  let all_hex = String.to_seq hex_part |> Seq.for_all (fun c ->
    (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')
  ) in
  Alcotest.(check bool) "all hex chars" true all_hex

let test_unique_ids () =
  let id1 = Mdal.generate_loop_id () in
  let id2 = Mdal.generate_loop_id () in
  Alcotest.(check bool) "two IDs differ" true (id1 <> id2)

(* ================================================================ *)
(* Hearth Names                                                     *)
(* ================================================================ *)

let test_iter_hearth () =
  let h = Mdal.iter_hearth "abc123" in
  Alcotest.(check string) "iter hearth" "mdal-iter-abc123" h

let test_state_hearth () =
  let h = Mdal.state_hearth "abc123" in
  Alcotest.(check string) "state hearth" "mdal-abc123" h

(* ================================================================ *)
(* Built-in Profiles                                                *)
(* ================================================================ *)

let test_builtin_ssim () =
  let p = Mdal.builtin_profile "ssim" in
  Alcotest.(check string) "name" "ssim" p.name;
  Alcotest.(check int) "max_iterations" 20 p.max_iterations;
  Alcotest.(check string) "agent" "claude" p.agent

let test_builtin_coverage () =
  let p = Mdal.builtin_profile "coverage" in
  Alcotest.(check string) "name" "coverage" p.name;
  Alcotest.(check int) "max_iterations" 15 p.max_iterations

let test_builtin_lint () =
  let p = Mdal.builtin_profile "lint" in
  Alcotest.(check string) "name" "lint" p.name;
  Alcotest.(check int) "max_iterations" 10 p.max_iterations

let test_builtin_review () =
  let p = Mdal.builtin_profile "review" in
  Alcotest.(check string) "name" "review" p.name;
  Alcotest.(check int) "max_iterations" 5 p.max_iterations

let test_builtin_docs () =
  let p = Mdal.builtin_profile "docs" in
  Alcotest.(check string) "name" "docs" p.name;
  Alcotest.(check int) "max_iterations" 10 p.max_iterations

let test_builtin_unknown () =
  let raised = ref false in
  (try ignore (Mdal.builtin_profile "nonexistent") with
   | Invalid_argument _ -> raised := true);
  Alcotest.(check bool) "raises Invalid_argument" true !raised

(* ================================================================ *)
(* Goal Parsing                                                     *)
(* ================================================================ *)

let test_parse_goal_gte () =
  let g = Mdal.parse_goal "ssim >= 0.95" in
  Alcotest.(check string) "path" "ssim" g.path;
  match g.condition with
  | Bounded.Gte v -> Alcotest.(check (float 0.001)) "value" 0.95 v
  | _ -> Alcotest.fail "expected Gte"

let test_parse_goal_lte () =
  let g = Mdal.parse_goal "errors <= 0" in
  Alcotest.(check string) "path" "errors" g.path;
  match g.condition with
  | Bounded.Lte v -> Alcotest.(check (float 0.001)) "value" 0.0 v
  | _ -> Alcotest.fail "expected Lte"

let test_parse_goal_gt () =
  let g = Mdal.parse_goal "score > 90" in
  match g.condition with
  | Bounded.Gt v -> Alcotest.(check (float 0.001)) "value" 90.0 v
  | _ -> Alcotest.fail "expected Gt"

let test_parse_goal_lt () =
  let g = Mdal.parse_goal "bugs < 5" in
  match g.condition with
  | Bounded.Lt v -> Alcotest.(check (float 0.001)) "value" 5.0 v
  | _ -> Alcotest.fail "expected Lt"

let test_parse_goal_eq () =
  let g = Mdal.parse_goal "count == 100" in
  match g.condition with
  | Bounded.Eq (`Float v) -> Alcotest.(check (float 0.001)) "value" 100.0 v
  | _ -> Alcotest.fail "expected Eq Float"

let test_parse_goal_neq () =
  let g = Mdal.parse_goal "status != 0" in
  match g.condition with
  | Bounded.Neq (`Float v) -> Alcotest.(check (float 0.001)) "value" 0.0 v
  | _ -> Alcotest.fail "expected Neq Float"

let test_parse_goal_bad_format () =
  let raised = ref false in
  (try ignore (Mdal.parse_goal "bad") with
   | Invalid_argument _ -> raised := true);
  Alcotest.(check bool) "raises on bad format" true !raised

let test_parse_goal_bad_op () =
  let raised = ref false in
  (try ignore (Mdal.parse_goal "metric <> 5") with
   | Invalid_argument _ -> raised := true);
  Alcotest.(check bool) "raises on bad operator" true !raised

let test_parse_goal_whitespace () =
  let g = Mdal.parse_goal "  metric   >=   0.5  " in
  Alcotest.(check string) "path" "metric" g.path;
  match g.condition with
  | Bounded.Gte v -> Alcotest.(check (float 0.001)) "value" 0.5 v
  | _ -> Alcotest.fail "expected Gte"

(* ================================================================ *)
(* Stagnation Detection                                             *)
(* ================================================================ *)

let test_stagnation_not_exceeded () =
  let state = dummy_state ~stagnation:1 () in
  Alcotest.(check bool) "not exceeded" false (Mdal.stagnation_exceeded state)

let test_stagnation_exceeded () =
  let state = dummy_state ~stagnation:3 () in
  Alcotest.(check bool) "exceeded" true (Mdal.stagnation_exceeded state)

let test_stagnation_exactly_at_limit () =
  let state = dummy_state ~stagnation:3 () in
  Alcotest.(check bool) "at limit" true (Mdal.stagnation_exceeded state)

let test_update_stagnation_below_threshold () =
  let state = dummy_state ~stagnation:0 () in
  let record = dummy_record ~delta:0.005 () in
  Mdal.update_stagnation state record;
  Alcotest.(check int) "streak incremented" 1 state.stagnation_streak

let test_update_stagnation_above_threshold () =
  let state = dummy_state ~stagnation:2 () in
  let record = dummy_record ~delta:0.05 () in
  Mdal.update_stagnation state record;
  Alcotest.(check int) "streak reset" 0 state.stagnation_streak

let test_update_stagnation_negative_delta () =
  let state = dummy_state ~stagnation:1 () in
  let record = dummy_record ~delta:(-0.005) () in
  Mdal.update_stagnation state record;
  Alcotest.(check int) "abs(delta) < threshold" 2 state.stagnation_streak

(* ================================================================ *)
(* Worker Result Parsing                                            *)
(* ================================================================ *)

let test_parse_valid_json () =
  let raw = {|{"changes": "added tests", "failed_attempts": "", "next_suggestion": "more edge cases"}|} in
  match Mdal.parse_worker_result raw with
  | Ok r ->
    Alcotest.(check string) "changes" "added tests" r.changes;
    Alcotest.(check string) "failed" "" r.failed_attempts;
    Alcotest.(check string) "next" "more edge cases" r.next_suggestion
  | Error e -> Alcotest.fail e

let test_parse_noisy_json () =
  let raw = "Some preamble text\n{\"changes\": \"fix\", \"failed_attempts\": \"\", \"next_suggestion\": \"done\"}\nMore text" in
  match Mdal.parse_worker_result raw with
  | Ok r -> Alcotest.(check string) "changes" "fix" r.changes
  | Error e -> Alcotest.fail e

let test_parse_invalid_json () =
  let raw = "totally not json at all" in
  match Mdal.parse_worker_result raw with
  | Ok _ -> Alcotest.fail "should have failed"
  | Error _ -> ()  (* expected *)

let test_parse_missing_fields () =
  let raw = {|{"changes": "stuff"}|} in
  match Mdal.parse_worker_result raw with
  | Ok r ->
    Alcotest.(check string) "changes" "stuff" r.changes;
    Alcotest.(check string) "missing failed defaults to empty" "" r.failed_attempts
  | Error e -> Alcotest.fail e

(* ================================================================ *)
(* Iteration Evaluation                                             *)
(* ================================================================ *)

let test_eval_regression () =
  let r = dummy_record ~delta:(-0.05) () in
  match Mdal.evaluate_iteration r with
  | `Revert_and_switch -> ()
  | _ -> Alcotest.fail "expected Revert_and_switch"

let test_eval_stagnation () =
  let r = dummy_record ~delta:0.0005 () in
  match Mdal.evaluate_iteration r with
  | `Stagnation -> ()
  | _ -> Alcotest.fail "expected Stagnation"

let test_eval_switch_area () =
  let r = dummy_record ~delta:0.003 () in
  match Mdal.evaluate_iteration r with
  | `Switch_area -> ()
  | _ -> Alcotest.fail "expected Switch_area"

let test_eval_continue () =
  let r = dummy_record ~delta:0.05 () in
  match Mdal.evaluate_iteration r with
  | `Continue_same_strategy -> ()
  | _ -> Alcotest.fail "expected Continue_same_strategy"

let test_eval_borderline_regression () =
  let r = dummy_record ~delta:(-0.005) () in
  (* delta > -0.01, abs_delta < 0.01, but delta < 0 and abs_delta >= 0.001 *)
  (* delta is negative but > -0.01, abs_delta = 0.005 which is >= 0.001 *)
  (* Since delta > -0.01 (not regression), and abs_delta >= 0.001 (not stagnation) *)
  (* delta > 0.0 is false, so it falls to Continue *)
  match Mdal.evaluate_iteration r with
  | `Continue_same_strategy -> ()
  | _ -> Alcotest.fail "expected Continue_same_strategy for small negative delta"

(* ================================================================ *)
(* Board Post Formatting                                            *)
(* ================================================================ *)

let test_format_iter_post () =
  let r = dummy_record ~iteration:3 ~before:0.5 ~after:0.65 ~delta:0.15
      ~changes:"added login test" ~failed:"tried mocking" ~next:"cover error path" () in
  let text = Mdal.format_iter_post r in
  Alcotest.(check bool) "contains MDAL_ITER" true
    (String.length text > 0 &&
     try ignore (Str.search_forward (Str.regexp_string "[MDAL_ITER]") text 0); true
     with Not_found -> false);
  Alcotest.(check bool) "contains iteration number" true
    (try ignore (Str.search_forward (Str.regexp_string "#3") text 0); true
     with Not_found -> false)

let test_format_iter_post_empty_fields () =
  let r = dummy_record ~changes:"" ~failed:"" ~next:"" () in
  let text = Mdal.format_iter_post r in
  Alcotest.(check bool) "contains (none)" true
    (try ignore (Str.search_forward (Str.regexp_string "(none)") text 0); true
     with Not_found -> false)

let test_format_state_post () =
  let state = dummy_state ~loop_id:"mdal-abc" ~baseline:0.3 () in
  let text = Mdal.format_state_post state in
  Alcotest.(check bool) "contains MDAL_STATE" true
    (try ignore (Str.search_forward (Str.regexp_string "[MDAL_STATE]") text 0); true
     with Not_found -> false);
  Alcotest.(check bool) "contains loop id" true
    (try ignore (Str.search_forward (Str.regexp_string "mdal-abc") text 0); true
     with Not_found -> false);
  Alcotest.(check bool) "contains RUNNING" true
    (try ignore (Str.search_forward (Str.regexp_string "RUNNING") text 0); true
     with Not_found -> false)

let test_format_final_post_completed () =
  let history = [dummy_record ~iteration:3 ~after:0.96 ~delta:0.05 ()] in
  let state = dummy_state ~loop_id:"mdal-xyz" ~baseline:0.5
      ~status:`Completed ~iteration:3 ~history () in
  let text = Mdal.format_final_post state in
  Alcotest.(check bool) "contains MDAL_FINAL" true
    (try ignore (Str.search_forward (Str.regexp_string "[MDAL_FINAL]") text 0); true
     with Not_found -> false);
  Alcotest.(check bool) "contains COMPLETED" true
    (try ignore (Str.search_forward (Str.regexp_string "COMPLETED") text 0); true
     with Not_found -> false)

let test_format_final_post_error () =
  let state = dummy_state ~status:(`Error "timeout") () in
  let text = Mdal.format_final_post state in
  Alcotest.(check bool) "contains ERROR" true
    (try ignore (Str.search_forward (Str.regexp_string "ERROR: timeout") text 0); true
     with Not_found -> false)

(* ================================================================ *)
(* Worker Prompt Rendering                                          *)
(* ================================================================ *)

let test_render_prompt_empty_history () =
  let profile = dummy_profile () in
  let prompt = Mdal.render_worker_prompt profile [] 0.5 in
  Alcotest.(check bool) "contains GOAL" true
    (try ignore (Str.search_forward (Str.regexp_string "GOAL:") prompt 0); true
     with Not_found -> false);
  Alcotest.(check bool) "contains CURRENT METRIC" true
    (try ignore (Str.search_forward (Str.regexp_string "CURRENT METRIC:") prompt 0); true
     with Not_found -> false);
  Alcotest.(check bool) "contains no previous iterations" true
    (try ignore (Str.search_forward (Str.regexp_string "No previous iterations") prompt 0); true
     with Not_found -> false)

let test_render_prompt_with_history () =
  let profile = dummy_profile () in
  let history = [dummy_record ~iteration:1 ~before:0.5 ~after:0.6 ()] in
  let prompt = Mdal.render_worker_prompt profile history 0.6 in
  Alcotest.(check bool) "contains Iter 1" true
    (try ignore (Str.search_forward (Str.regexp_string "Iter 1:") prompt 0); true
     with Not_found -> false)

let test_render_prompt_with_tool_rules () =
  let profile = { (dummy_profile ()) with
    tools_allow = ["read"; "write"];
    tools_deny = ["delete"];
  } in
  let prompt = Mdal.render_worker_prompt profile [] 0.5 in
  Alcotest.(check bool) "contains allowed tools" true
    (try ignore (Str.search_forward (Str.regexp_string "Allowed tools:") prompt 0); true
     with Not_found -> false);
  Alcotest.(check bool) "contains forbidden tools" true
    (try ignore (Str.search_forward (Str.regexp_string "Forbidden tools:") prompt 0); true
     with Not_found -> false)

let test_render_prompt_json_format () =
  let profile = dummy_profile () in
  let prompt = Mdal.render_worker_prompt profile [] 0.5 in
  Alcotest.(check bool) "contains JSON format instruction" true
    (try ignore (Str.search_forward (Str.regexp_string "OUTPUT FORMAT") prompt 0); true
     with Not_found -> false)

(* ================================================================ *)
(* Test Runner                                                      *)
(* ================================================================ *)

let () =
  Alcotest.run "MDAL" [
    "id_generation", [
      Alcotest.test_case "format" `Quick test_generate_loop_id;
      Alcotest.test_case "uniqueness" `Quick test_unique_ids;
    ];
    "hearth_names", [
      Alcotest.test_case "iter_hearth" `Quick test_iter_hearth;
      Alcotest.test_case "state_hearth" `Quick test_state_hearth;
    ];
    "builtin_profiles", [
      Alcotest.test_case "ssim" `Quick test_builtin_ssim;
      Alcotest.test_case "coverage" `Quick test_builtin_coverage;
      Alcotest.test_case "lint" `Quick test_builtin_lint;
      Alcotest.test_case "review" `Quick test_builtin_review;
      Alcotest.test_case "docs" `Quick test_builtin_docs;
      Alcotest.test_case "unknown raises" `Quick test_builtin_unknown;
    ];
    "goal_parsing", [
      Alcotest.test_case ">=" `Quick test_parse_goal_gte;
      Alcotest.test_case "<=" `Quick test_parse_goal_lte;
      Alcotest.test_case ">" `Quick test_parse_goal_gt;
      Alcotest.test_case "<" `Quick test_parse_goal_lt;
      Alcotest.test_case "==" `Quick test_parse_goal_eq;
      Alcotest.test_case "!=" `Quick test_parse_goal_neq;
      Alcotest.test_case "bad format" `Quick test_parse_goal_bad_format;
      Alcotest.test_case "bad operator" `Quick test_parse_goal_bad_op;
      Alcotest.test_case "whitespace" `Quick test_parse_goal_whitespace;
    ];
    "stagnation", [
      Alcotest.test_case "not exceeded" `Quick test_stagnation_not_exceeded;
      Alcotest.test_case "exceeded" `Quick test_stagnation_exceeded;
      Alcotest.test_case "at limit" `Quick test_stagnation_exactly_at_limit;
      Alcotest.test_case "below threshold" `Quick test_update_stagnation_below_threshold;
      Alcotest.test_case "above threshold" `Quick test_update_stagnation_above_threshold;
      Alcotest.test_case "negative delta" `Quick test_update_stagnation_negative_delta;
    ];
    "parse_worker_result", [
      Alcotest.test_case "valid json" `Quick test_parse_valid_json;
      Alcotest.test_case "noisy json" `Quick test_parse_noisy_json;
      Alcotest.test_case "invalid json" `Quick test_parse_invalid_json;
      Alcotest.test_case "missing fields" `Quick test_parse_missing_fields;
    ];
    "evaluate_iteration", [
      Alcotest.test_case "regression" `Quick test_eval_regression;
      Alcotest.test_case "stagnation" `Quick test_eval_stagnation;
      Alcotest.test_case "switch area" `Quick test_eval_switch_area;
      Alcotest.test_case "continue" `Quick test_eval_continue;
      Alcotest.test_case "borderline" `Quick test_eval_borderline_regression;
    ];
    "board_formatting", [
      Alcotest.test_case "iter post" `Quick test_format_iter_post;
      Alcotest.test_case "iter post empty" `Quick test_format_iter_post_empty_fields;
      Alcotest.test_case "state post" `Quick test_format_state_post;
      Alcotest.test_case "final completed" `Quick test_format_final_post_completed;
      Alcotest.test_case "final error" `Quick test_format_final_post_error;
    ];
    "worker_prompt", [
      Alcotest.test_case "empty history" `Quick test_render_prompt_empty_history;
      Alcotest.test_case "with history" `Quick test_render_prompt_with_history;
      Alcotest.test_case "tool rules" `Quick test_render_prompt_with_tool_rules;
      Alcotest.test_case "json format" `Quick test_render_prompt_json_format;
    ];
  ]
