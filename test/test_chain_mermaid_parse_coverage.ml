(** Coverage tests for lib/chain/chain_mermaid_parse.ml
    Target: all pure functions in the module (472 bisect points, 13.35% covered).

    Functions tested:
    - strip_quotes
    - has_explicit_type_prefix
    - extract_tools_flag, make_tools_value
    - empty_meta
    - parse_input_mapping_json
    - parse_chain_meta, parse_chain_full, parse_node_meta
    - parse_meta_comment
    - infer_type_from_id (all shape branches)
    - parse_node_definition (all shape regexes)
*)

open Alcotest
open Masc_mcp
open Chain_types

(* All chain_mermaid_parse functions are re-exported via Chain_mermaid_node_content
   (which does `include Chain_mermaid_parse`), and also via Chain_mermaid_graph
   (which does `include Chain_mermaid_node_content`). *)

(* ============================================================
   Helpers
   ============================================================ *)

let check_ok msg = function
  | Ok _ -> ()
  | Error e -> fail (msg ^ ": " ^ e)

let check_ok_with msg f = function
  | Ok v -> f v
  | Error e -> fail (msg ^ ": " ^ e)

let _check_err msg = function
  | Error _ -> ()
  | Ok _ -> fail (msg ^ ": expected Error")

(* ============================================================
   1. strip_quotes
   ============================================================ *)

let test_strip_quotes_double () =
  let r = Chain_mermaid_parse.strip_quotes {|"hello"|} in
  check string "double quotes stripped" "hello" r

let test_strip_quotes_single () =
  let r = Chain_mermaid_parse.strip_quotes "'world'" in
  check string "single quotes stripped" "world" r

let test_strip_quotes_no_quotes () =
  let r = Chain_mermaid_parse.strip_quotes "plain" in
  check string "no quotes unchanged" "plain" r

let test_strip_quotes_mismatched () =
  let r = Chain_mermaid_parse.strip_quotes {|"mismatch'|} in
  check string "mismatched unchanged" {|"mismatch'|} r

let test_strip_quotes_empty () =
  let r = Chain_mermaid_parse.strip_quotes "" in
  check string "empty unchanged" "" r

let test_strip_quotes_single_char () =
  let r = Chain_mermaid_parse.strip_quotes "x" in
  check string "single char unchanged" "x" r

let test_strip_quotes_whitespace () =
  let r = Chain_mermaid_parse.strip_quotes {|  "spaced"  |} in
  check string "whitespace trimmed and stripped" "spaced" r

(* ============================================================
   2. has_explicit_type_prefix
   ============================================================ *)

let test_prefix_llm () =
  check bool "LLM:" true (Chain_mermaid_parse.has_explicit_type_prefix "LLM:gemini")

let test_prefix_tool () =
  check bool "Tool:" true (Chain_mermaid_parse.has_explicit_type_prefix "Tool:eslint")

let test_prefix_ref () =
  check bool "Ref:" true (Chain_mermaid_parse.has_explicit_type_prefix "Ref:my_chain")

let test_prefix_quorum () =
  check bool "Quorum:" true (Chain_mermaid_parse.has_explicit_type_prefix "Quorum:2")

let test_prefix_gate () =
  check bool "Gate:" true (Chain_mermaid_parse.has_explicit_type_prefix "Gate:cond")

let test_prefix_merge () =
  check bool "Merge:" true (Chain_mermaid_parse.has_explicit_type_prefix "Merge:concat")

let test_prefix_pipeline () =
  check bool "Pipeline:" true (Chain_mermaid_parse.has_explicit_type_prefix "Pipeline:a,b")

let test_prefix_fanout () =
  check bool "Fanout:" true (Chain_mermaid_parse.has_explicit_type_prefix "Fanout:x,y")

let test_prefix_map () =
  check bool "Map:" true (Chain_mermaid_parse.has_explicit_type_prefix "Map:f,n")

let test_prefix_bind () =
  check bool "Bind:" true (Chain_mermaid_parse.has_explicit_type_prefix "Bind:f,n")

let test_prefix_cache () =
  check bool "Cache:" true (Chain_mermaid_parse.has_explicit_type_prefix "Cache:k,60,n")

let test_prefix_batch () =
  check bool "Batch:" true (Chain_mermaid_parse.has_explicit_type_prefix "Batch:10,true,n")

let test_prefix_spawn () =
  check bool "Spawn:" true (Chain_mermaid_parse.has_explicit_type_prefix "Spawn:task")

let test_prefix_threshold () =
  check bool "Threshold:" true (Chain_mermaid_parse.has_explicit_type_prefix "Threshold:0.5")

let test_prefix_evaluator () =
  check bool "Evaluator:" true (Chain_mermaid_parse.has_explicit_type_prefix "Evaluator:judge")

let test_prefix_goaldriven () =
  check bool "GoalDriven:" true (Chain_mermaid_parse.has_explicit_type_prefix "GoalDriven:metric")

let test_prefix_mcts () =
  check bool "MCTS:" true (Chain_mermaid_parse.has_explicit_type_prefix "MCTS:sim")

let test_prefix_streammerge () =
  check bool "StreamMerge:" true (Chain_mermaid_parse.has_explicit_type_prefix "StreamMerge:x")

let test_prefix_feedbackloop () =
  check bool "FeedbackLoop:" true (Chain_mermaid_parse.has_explicit_type_prefix "FeedbackLoop:x")

let test_prefix_none () =
  check bool "no prefix" false (Chain_mermaid_parse.has_explicit_type_prefix "hello world")

let test_prefix_empty () =
  check bool "empty" false (Chain_mermaid_parse.has_explicit_type_prefix "")

let test_prefix_short () =
  check bool "short" false (Chain_mermaid_parse.has_explicit_type_prefix "LLM")

(* ============================================================
   3. extract_tools_flag / make_tools_value
   ============================================================ *)

let test_extract_tools_present () =
  let (content, flag) = Chain_mermaid_parse.extract_tools_flag "hello prompt +tools" in
  check string "content without flag" "hello prompt" content;
  check bool "flag true" true flag

let test_extract_tools_absent () =
  let (content, flag) = Chain_mermaid_parse.extract_tools_flag "hello prompt" in
  check string "content unchanged" "hello prompt" content;
  check bool "flag false" false flag

let test_extract_tools_empty () =
  let (content, flag) = Chain_mermaid_parse.extract_tools_flag "" in
  check string "empty content" "" content;
  check bool "empty flag false" false flag

let test_extract_tools_only_flag () =
  (* "+tools" is exactly 6 chars, len > suffix_len (6) is false *)
  let (content, flag) = Chain_mermaid_parse.extract_tools_flag "+tools" in
  check string "just flag" "+tools" content;
  check bool "just flag false" false flag

let test_extract_tools_with_whitespace () =
  let (content, flag) = Chain_mermaid_parse.extract_tools_flag "  do something +tools  " in
  check string "trimmed content" "do something" content;
  check bool "flag true" true flag

let test_make_tools_true () =
  let r = Chain_mermaid_parse.make_tools_value true in
  check (option (of_pp Yojson.Safe.pp)) "tools Some []" (Some (`List [])) r

let test_make_tools_false () =
  let r = Chain_mermaid_parse.make_tools_value false in
  check (option (of_pp Yojson.Safe.pp)) "tools None" None r

(* ============================================================
   4. empty_meta
   ============================================================ *)

let test_empty_meta () =
  let m = Chain_mermaid_parse.empty_meta () in
  check (option string) "chain_id None" None m.chain_id;
  check (option string) "chain_output None" None m.chain_output;
  check (option int) "chain_timeout None" None m.chain_timeout;
  check (option bool) "chain_trace None" None m.chain_trace;
  check (option int) "chain_max_depth None" None m.chain_max_depth;
  check (option int) "chain_max_concurrency None" None m.chain_max_concurrency;
  check int "input_mappings empty" 0 (Hashtbl.length m.node_input_mappings);
  check int "goaldriven_meta empty" 0 (Hashtbl.length m.node_goaldriven_meta)

(* ============================================================
   5. parse_input_mapping_json
   ============================================================ *)

let test_parse_input_mapping_valid () =
  let json = `List [ `List [`String "a"; `String "b"]; `List [`String "c"; `String "d"] ] in
  let r = Chain_mermaid_parse.parse_input_mapping_json json in
  check int "2 pairs" 2 (List.length r);
  check (pair string string) "first" ("a", "b") (List.nth r 0);
  check (pair string string) "second" ("c", "d") (List.nth r 1)

let test_parse_input_mapping_empty_list () =
  let json = `List [] in
  let r = Chain_mermaid_parse.parse_input_mapping_json json in
  check int "empty" 0 (List.length r)

let test_parse_input_mapping_non_list () =
  let json = `String "not a list" in
  let r = Chain_mermaid_parse.parse_input_mapping_json json in
  check int "non-list returns empty" 0 (List.length r)

let test_parse_input_mapping_bad_pair () =
  let json = `List [ `List [`String "a"]; `Int 42 ] in
  let r = Chain_mermaid_parse.parse_input_mapping_json json in
  check int "bad pairs filtered" 0 (List.length r)

let test_parse_input_mapping_mixed () =
  let json = `List [ `List [`String "k"; `String "v"]; `Null; `List [`Int 1; `String "x"] ] in
  let r = Chain_mermaid_parse.parse_input_mapping_json json in
  check int "only valid pair" 1 (List.length r)

(* ============================================================
   6. parse_chain_meta
   ============================================================ *)

let test_parse_chain_meta_full () =
  let json_str = {|{"id":"test_chain","output":"result","timeout":30,"trace":true,"max_depth":5,"max_concurrency":4}|} in
  let m = Chain_mermaid_parse.parse_chain_meta json_str (Chain_mermaid_parse.empty_meta ()) in
  check (option string) "id" (Some "test_chain") m.chain_id;
  check (option string) "output" (Some "result") m.chain_output;
  check (option int) "timeout" (Some 30) m.chain_timeout;
  check (option bool) "trace" (Some true) m.chain_trace;
  check (option int) "max_depth" (Some 5) m.chain_max_depth;
  check (option int) "max_concurrency" (Some 4) m.chain_max_concurrency

let test_parse_chain_meta_partial () =
  let json_str = {|{"id":"partial"}|} in
  let m = Chain_mermaid_parse.parse_chain_meta json_str (Chain_mermaid_parse.empty_meta ()) in
  check (option string) "id set" (Some "partial") m.chain_id;
  check (option string) "output not set" None m.chain_output

let test_parse_chain_meta_invalid_json () =
  let m = Chain_mermaid_parse.parse_chain_meta "not json" (Chain_mermaid_parse.empty_meta ()) in
  check (option string) "unchanged on invalid" None m.chain_id

let test_parse_chain_meta_non_assoc () =
  let m = Chain_mermaid_parse.parse_chain_meta "[1,2,3]" (Chain_mermaid_parse.empty_meta ()) in
  check (option string) "non-assoc unchanged" None m.chain_id

let test_parse_chain_meta_preserves_existing () =
  let base = { (Chain_mermaid_parse.empty_meta ()) with chain_id = Some "existing" } in
  let m = Chain_mermaid_parse.parse_chain_meta {|{"output":"new_out"}|} base in
  check (option string) "existing id preserved" (Some "existing") m.chain_id;
  check (option string) "output set" (Some "new_out") m.chain_output

(* ============================================================
   7. parse_chain_full
   ============================================================ *)

let test_parse_chain_full () =
  let m = Chain_mermaid_parse.parse_chain_full "{\"full\":true}" (Chain_mermaid_parse.empty_meta ()) in
  check (option string) "chain_full_json set" (Some "{\"full\":true}") m.chain_full_json

(* ============================================================
   8. parse_node_meta
   ============================================================ *)

let test_parse_node_meta_input_mapping () =
  let json_str = {|{"input_mapping":[["prompt","{{input}}"],["ctx","{{context}}"]]}|} in
  let m = Chain_mermaid_parse.parse_node_meta "nodeA" json_str (Chain_mermaid_parse.empty_meta ()) in
  let mapping = Hashtbl.find m.node_input_mappings "nodeA" in
  check int "2 mappings" 2 (List.length mapping);
  check (pair string string) "first" ("prompt", "{{input}}") (List.nth mapping 0)

let test_parse_node_meta_goaldriven () =
  let json_str = {|{"action_node_id":"act","measure_func":"mfunc","strategy_hints":[["k","v"]],"conversational":true,"relay_models":["m1","m2"]}|} in
  let m = Chain_mermaid_parse.parse_node_meta "nodeB" json_str (Chain_mermaid_parse.empty_meta ()) in
  let gd = Hashtbl.find m.node_goaldriven_meta "nodeB" in
  check (option string) "action_node_id" (Some "act") gd.gd_action_node_id;
  check (option string) "measure_func" (Some "mfunc") gd.gd_measure_func;
  check int "strategy_hints" 1 (List.length gd.gd_strategy_hints);
  check bool "conversational" true gd.gd_conversational;
  check int "relay_models" 2 (List.length gd.gd_relay_models)

let test_parse_node_meta_no_goaldriven_fields () =
  let json_str = {|{"input_mapping":[["a","b"]]}|} in
  let m = Chain_mermaid_parse.parse_node_meta "nodeC" json_str (Chain_mermaid_parse.empty_meta ()) in
  check bool "no goaldriven" false (Hashtbl.mem m.node_goaldriven_meta "nodeC")

let test_parse_node_meta_invalid_json () =
  let m = Chain_mermaid_parse.parse_node_meta "nodeD" "bad json" (Chain_mermaid_parse.empty_meta ()) in
  check bool "no mapping on bad json" false (Hashtbl.mem m.node_input_mappings "nodeD")

let test_parse_node_meta_non_assoc () =
  let m = Chain_mermaid_parse.parse_node_meta "nodeE" "42" (Chain_mermaid_parse.empty_meta ()) in
  check bool "non-assoc no mapping" false (Hashtbl.mem m.node_input_mappings "nodeE")

let test_parse_node_meta_partial_goaldriven () =
  (* Only action_node_id set, others default/empty *)
  let json_str = {|{"action_node_id":"x"}|} in
  let m = Chain_mermaid_parse.parse_node_meta "nodeF" json_str (Chain_mermaid_parse.empty_meta ()) in
  let gd = Hashtbl.find m.node_goaldriven_meta "nodeF" in
  check (option string) "action set" (Some "x") gd.gd_action_node_id;
  check bool "not conversational" false gd.gd_conversational

let test_parse_node_meta_relay_non_string () =
  let json_str = {|{"relay_models":[1,2,"real"]}|} in
  let m = Chain_mermaid_parse.parse_node_meta "nodeG" json_str (Chain_mermaid_parse.empty_meta ()) in
  let gd = Hashtbl.find m.node_goaldriven_meta "nodeG" in
  check int "only string items" 1 (List.length gd.gd_relay_models)

let test_parse_node_meta_strategy_hints_bad () =
  let json_str = {|{"strategy_hints":[[1,2],["a","b"],["c"]]}|} in
  let m = Chain_mermaid_parse.parse_node_meta "nodeH" json_str (Chain_mermaid_parse.empty_meta ()) in
  let gd = Hashtbl.find m.node_goaldriven_meta "nodeH" in
  check int "only valid pair" 1 (List.length gd.gd_strategy_hints)

(* ============================================================
   9. parse_meta_comment
   ============================================================ *)

let test_meta_comment_chain () =
  let m = Chain_mermaid_parse.parse_meta_comment
    {|%% @chain {"id":"mychain","timeout":60}|}
    (Chain_mermaid_parse.empty_meta ()) in
  check (option string) "chain id parsed" (Some "mychain") m.chain_id;
  check (option int) "timeout parsed" (Some 60) m.chain_timeout

let test_meta_comment_chain_json () =
  let m = Chain_mermaid_parse.parse_meta_comment
    {|%% @chain_json {"nodes":[]}|}
    (Chain_mermaid_parse.empty_meta ()) in
  check (option string) "chain_full_json set" (Some {|{"nodes":[]}|}) m.chain_full_json;
  check bool "chain_json is Some" true (m.chain_json <> None)

let test_meta_comment_chain_json_invalid () =
  let m = Chain_mermaid_parse.parse_meta_comment
    "%% @chain_json not valid json"
    (Chain_mermaid_parse.empty_meta ()) in
  (* chain_full_json is set regardless, chain_json stays None *)
  check (option string) "full_json set" (Some "not valid json") m.chain_full_json;
  check bool "chain_json None" true (m.chain_json = None)

let test_meta_comment_chain_full () =
  let m = Chain_mermaid_parse.parse_meta_comment
    {|%% @chain_full {"full":"data"}|}
    (Chain_mermaid_parse.empty_meta ()) in
  check (option string) "chain_full" (Some {|{"full":"data"}|}) m.chain_full_json

let test_meta_comment_node () =
  let m = Chain_mermaid_parse.parse_meta_comment
    {|%% @node:mynode {"input_mapping":[["a","b"]]}|}
    (Chain_mermaid_parse.empty_meta ()) in
  check bool "node mapping exists" true (Hashtbl.mem m.node_input_mappings "mynode")

let test_meta_comment_node_no_space () =
  (* @node:id without space -> no JSON -> returns meta unchanged *)
  let m = Chain_mermaid_parse.parse_meta_comment
    "%% @node:nodelonly"
    (Chain_mermaid_parse.empty_meta ()) in
  check bool "no mapping without space" false (Hashtbl.mem m.node_input_mappings "nodelonly")

let test_meta_comment_not_comment () =
  let m = Chain_mermaid_parse.parse_meta_comment
    "graph LR"
    (Chain_mermaid_parse.empty_meta ()) in
  check (option string) "not a comment" None m.chain_id

let test_meta_comment_short () =
  let m = Chain_mermaid_parse.parse_meta_comment
    "%"
    (Chain_mermaid_parse.empty_meta ()) in
  check (option string) "too short" None m.chain_id

let test_meta_comment_unknown_directive () =
  let m = Chain_mermaid_parse.parse_meta_comment
    "%% @unknown stuff"
    (Chain_mermaid_parse.empty_meta ()) in
  check (option string) "unknown directive" None m.chain_id

(* ============================================================
   10. infer_type_from_id -- Diamond shape
   ============================================================ *)

let test_infer_diamond_quorum_id () =
  check_ok "quorum_3"
    (Chain_mermaid_parse.infer_type_from_id "quorum_3" `Diamond "text")

let test_infer_diamond_consensus_id () =
  check_ok "consensus_2"
    (Chain_mermaid_parse.infer_type_from_id "consensus_2" `Diamond "text")

let test_infer_diamond_gate_id () =
  check_ok_with "gate_ prefix" (fun nt ->
    match nt with Gate _ -> () | _ -> fail "expected Gate"
  ) (Chain_mermaid_parse.infer_type_from_id "gate_check" `Diamond "condition_text")

let test_infer_diamond_merge_id () =
  check_ok_with "merge_ prefix" (fun nt ->
    match nt with Merge _ -> () | _ -> fail "expected Merge"
  ) (Chain_mermaid_parse.infer_type_from_id "merge_results" `Diamond "text")

let test_infer_diamond_goal_with_pattern () =
  check_ok_with "goal_ with pattern" (fun nt ->
    match nt with
    | GoalDriven { goal_metric = "accuracy"; goal_operator = Gte; goal_value; max_iterations = 10; _ } ->
        check (float 0.01) "value" 0.90 goal_value
    | GoalDriven _ -> fail "wrong GoalDriven fields"
    | _ -> fail "expected GoalDriven"
  ) (Chain_mermaid_parse.infer_type_from_id "goal_accuracy" `Diamond "gte:0.90:10")

let test_infer_diamond_goal_gt () =
  check_ok_with "goal gt operator" (fun nt ->
    match nt with
    | GoalDriven { goal_operator = Gt; _ } -> ()
    | _ -> fail "expected GoalDriven Gt"
  ) (Chain_mermaid_parse.infer_type_from_id "goal_score" `Diamond "gt:0.80:5")

let test_infer_diamond_goal_lt () =
  check_ok_with "goal lt operator" (fun nt ->
    match nt with
    | GoalDriven { goal_operator = Lt; _ } -> ()
    | _ -> fail "expected GoalDriven Lt"
  ) (Chain_mermaid_parse.infer_type_from_id "goal_loss" `Diamond "lt:0.10:20")

let test_infer_diamond_goal_lte () =
  check_ok_with "goal lte operator" (fun nt ->
    match nt with
    | GoalDriven { goal_operator = Lte; _ } -> ()
    | _ -> fail "expected GoalDriven Lte"
  ) (Chain_mermaid_parse.infer_type_from_id "goal_err" `Diamond "lte:0.05:15")

let test_infer_diamond_goal_eq () =
  check_ok_with "goal eq operator" (fun nt ->
    match nt with
    | GoalDriven { goal_operator = Eq; _ } -> ()
    | _ -> fail "expected GoalDriven Eq"
  ) (Chain_mermaid_parse.infer_type_from_id "goal_exact" `Diamond "eq:1.00:3")

let test_infer_diamond_goal_neq () =
  check_ok_with "goal neq operator" (fun nt ->
    match nt with
    | GoalDriven { goal_operator = Neq; _ } -> ()
    | _ -> fail "expected GoalDriven Neq"
  ) (Chain_mermaid_parse.infer_type_from_id "goal_diff" `Diamond "neq:0.50:8")

let test_infer_diamond_goal_unknown_op () =
  (* Unknown op falls back to Gte *)
  check_ok_with "goal unknown op" (fun nt ->
    match nt with
    | GoalDriven { goal_operator = Gte; _ } -> ()
    | _ -> fail "expected GoalDriven Gte fallback"
  ) (Chain_mermaid_parse.infer_type_from_id "goal_x" `Diamond "xyz:0.50:8")

let test_infer_diamond_goal_fallback () =
  (* Text doesn't match pattern, uses defaults *)
  check_ok_with "goal fallback" (fun nt ->
    match nt with
    | GoalDriven { goal_operator = Gte; goal_value; max_iterations = 10; _ } ->
        check (float 0.01) "default value" 0.9 goal_value
    | _ -> fail "expected GoalDriven fallback"
  ) (Chain_mermaid_parse.infer_type_from_id "goal_metric" `Diamond "no-match")

let test_infer_diamond_eval_id () =
  check_ok_with "eval_ prefix" (fun nt ->
    match nt with Evaluator _ -> () | _ -> fail "expected Evaluator"
  ) (Chain_mermaid_parse.infer_type_from_id "eval_judge" `Diamond "some text")

let test_infer_diamond_evaluator_text_3parts () =
  check_ok_with "Evaluator: 3 parts" (fun nt ->
    match nt with
    | Evaluator { scoring_func = "custom"; select_strategy = Worst; min_score = Some _; _ } -> ()
    | Evaluator e -> fail (Printf.sprintf "wrong fields: func=%s" e.scoring_func)
    | _ -> fail "expected Evaluator"
  ) (Chain_mermaid_parse.infer_type_from_id "D" `Diamond "Evaluator:custom:worst:0.5")

let test_infer_diamond_evaluator_text_2parts () =
  check_ok_with "Evaluator: 2 parts" (fun nt ->
    match nt with
    | Evaluator { scoring_func = "judge"; select_strategy = Best; _ } -> ()
    | _ -> fail "expected Evaluator best"
  ) (Chain_mermaid_parse.infer_type_from_id "D" `Diamond "Evaluator:judge:best")

let test_infer_diamond_evaluator_text_1part () =
  check_ok_with "Evaluator: 1 part" (fun nt ->
    match nt with
    | Evaluator { scoring_func = "myfunc"; _ } -> ()
    | _ -> fail "expected Evaluator myfunc"
  ) (Chain_mermaid_parse.infer_type_from_id "D" `Diamond "Evaluator:myfunc")

let test_infer_diamond_evaluator_text_exact_boundary () =
  (* "Evaluator:" is exactly 10 chars, but the check is `String.length text > 10`
     (strictly greater). So "Evaluator:" alone falls through to Gate default. *)
  check_ok_with "Evaluator: boundary falls to Gate" (fun nt ->
    match nt with Gate _ -> () | _ -> fail "expected Gate (boundary)"
  ) (Chain_mermaid_parse.infer_type_from_id "D" `Diamond "Evaluator:")

let test_infer_diamond_evaluator_weighted () =
  check_ok_with "Evaluator weighted" (fun nt ->
    match nt with
    | Evaluator { select_strategy = WeightedRandom; _ } -> ()
    | _ -> fail "expected WeightedRandom"
  ) (Chain_mermaid_parse.infer_type_from_id "D" `Diamond "Evaluator:f:weighted")

let test_infer_diamond_evaluator_unknown_strategy () =
  check_ok_with "Evaluator unknown strategy" (fun nt ->
    match nt with
    | Evaluator { select_strategy = Best; _ } -> ()
    | _ -> fail "expected Best fallback"
  ) (Chain_mermaid_parse.infer_type_from_id "D" `Diamond "Evaluator:f:unknown")

let test_infer_diamond_quorum_text () =
  check_ok_with "Quorum: text" (fun nt ->
    match nt with Quorum _ -> () | _ -> fail "expected Quorum"
  ) (Chain_mermaid_parse.infer_type_from_id "D" `Diamond "Quorum:3")

let test_infer_diamond_quorum_majority () =
  check_ok_with "Quorum majority" (fun nt ->
    match nt with Quorum { consensus = Majority; _ } -> () | _ -> fail "expected Majority"
  ) (Chain_mermaid_parse.infer_type_from_id "D" `Diamond "Quorum:majority")

let test_infer_diamond_quorum_unanimous () =
  check_ok_with "Quorum unanimous" (fun nt ->
    match nt with Quorum { consensus = Unanimous; _ } -> () | _ -> fail "expected Unanimous"
  ) (Chain_mermaid_parse.infer_type_from_id "D" `Diamond "Quorum:unanimous")

let test_infer_diamond_default_gate () =
  check_ok_with "default diamond is Gate" (fun nt ->
    match nt with Gate _ -> () | _ -> fail "expected Gate"
  ) (Chain_mermaid_parse.infer_type_from_id "D" `Diamond "some condition")

(* ============================================================
   10b. infer_type_from_id -- Subroutine shape
   ============================================================ *)

let test_infer_subroutine_ref () =
  check_ok_with "ref_ prefix" (fun nt ->
    match nt with ChainRef "my_chain" -> () | _ -> fail "expected ChainRef my_chain"
  ) (Chain_mermaid_parse.infer_type_from_id "ref_my_chain" `Subroutine "text")

let test_infer_subroutine_seq () =
  check_ok_with "seq_ prefix" (fun nt ->
    match nt with Pipeline _ -> () | _ -> fail "expected Pipeline"
  ) (Chain_mermaid_parse.infer_type_from_id "seq_steps" `Subroutine "text")

let test_infer_subroutine_par () =
  check_ok_with "par_ prefix" (fun nt ->
    match nt with Fanout _ -> () | _ -> fail "expected Fanout"
  ) (Chain_mermaid_parse.infer_type_from_id "par_tasks" `Subroutine "text")

let test_infer_subroutine_map () =
  check_ok_with "map_ prefix" (fun nt ->
    match nt with Map _ -> () | _ -> fail "expected Map"
  ) (Chain_mermaid_parse.infer_type_from_id "map_items" `Subroutine "text")

let test_infer_subroutine_default_with_content () =
  check_ok_with "default subroutine with text" (fun nt ->
    match nt with ChainRef "some_chain" -> () | _ -> fail "expected ChainRef some_chain"
  ) (Chain_mermaid_parse.infer_type_from_id "X" `Subroutine "some_chain")

let test_infer_subroutine_default_empty () =
  check_ok_with "default subroutine empty text" (fun nt ->
    match nt with ChainRef "my_id" -> () | _ -> fail "expected ChainRef my_id"
  ) (Chain_mermaid_parse.infer_type_from_id "my_id" `Subroutine "")

(* ============================================================
   10c. infer_type_from_id -- Rect shape
   ============================================================ *)

let test_infer_rect_explicit_llm () =
  check_ok_with "explicit llm:" (fun nt ->
    match nt with
    | Llm { model = "gemini"; prompt = "hello world"; _ } -> ()
    | Llm l -> fail (Printf.sprintf "wrong: model=%s prompt=%s" l.model l.prompt)
    | _ -> fail "expected Llm"
  ) (Chain_mermaid_parse.infer_type_from_id "A" `Rect "LLM:gemini hello world")

let test_infer_rect_explicit_llm_tools () =
  check_ok_with "explicit llm with tools" (fun nt ->
    match nt with
    | Llm { model = "claude"; tools = Some _; _ } -> ()
    | _ -> fail "expected Llm with tools"
  ) (Chain_mermaid_parse.infer_type_from_id "A" `Rect "LLM:claude do stuff +tools")

let test_infer_rect_explicit_llm_no_prompt () =
  (* "LLM:gemini" (no space after model) does NOT match the explicit LLM regex
     because `[ \n\t]+` requires at least one whitespace after model name.
     Falls through to default path, still returns Ok (Llm ...). *)
  check_ok "LLM:gemini no prompt"
    (Chain_mermaid_parse.infer_type_from_id "A" `Rect "LLM:gemini")

let test_infer_rect_explicit_tool () =
  check_ok_with "explicit tool:" (fun nt ->
    match nt with
    | Tool { name = "eslint"; _ } -> ()
    | _ -> fail "expected Tool eslint"
  ) (Chain_mermaid_parse.infer_type_from_id "A" `Rect "Tool:eslint")

let test_infer_rect_explicit_tool_with_json_args () =
  check_ok_with "explicit tool with JSON args" (fun nt ->
    match nt with
    | Tool { name = "jest"; args = `Assoc _; _ } -> ()
    | _ -> fail "expected Tool with JSON args"
  ) (Chain_mermaid_parse.infer_type_from_id "A" `Rect {|Tool:jest {"verbose":true}|})

let test_infer_rect_explicit_tool_with_string_args () =
  check_ok_with "explicit tool with string args" (fun nt ->
    match nt with
    | Tool { name = "make"; args = `String "clean"; _ } -> ()
    | _ -> fail "expected Tool with string args"
  ) (Chain_mermaid_parse.infer_type_from_id "A" `Rect "Tool:make clean")

let test_infer_rect_explicit_tool_empty_args () =
  check_ok_with "explicit tool empty args" (fun nt ->
    match nt with
    | Tool { name = "tsc"; args = `Null; _ } -> ()
    | _ -> fail "expected Tool with null args"
  ) (Chain_mermaid_parse.infer_type_from_id "A" `Rect "Tool:tsc")

let test_infer_rect_id_llm_model () =
  (* ID starts with known model name *)
  check_ok_with "ID starts with gemini" (fun nt ->
    match nt with
    | Llm { model = "gemini"; _ } -> ()
    | _ -> fail "expected Llm gemini"
  ) (Chain_mermaid_parse.infer_type_from_id "gemini_parse" `Rect "do parsing")

let test_infer_rect_id_claude () =
  check_ok_with "ID starts with claude" (fun nt ->
    match nt with
    | Llm { model = "claude"; _ } -> ()
    | _ -> fail "expected Llm claude"
  ) (Chain_mermaid_parse.infer_type_from_id "claude_review" `Rect "review code")

let test_infer_rect_id_llm_with_tools () =
  check_ok_with "LLM by ID with tools" (fun nt ->
    match nt with
    | Llm { model = "gemini"; tools = Some _; _ } -> ()
    | _ -> fail "expected Llm gemini with tools"
  ) (Chain_mermaid_parse.infer_type_from_id "gemini_tool" `Rect "search +tools")

let test_infer_rect_id_llm_empty_text () =
  check_ok_with "LLM by ID empty text" (fun nt ->
    match nt with
    | Llm { prompt = "{{input}}"; _ } -> ()
    | _ -> fail "expected default prompt"
  ) (Chain_mermaid_parse.infer_type_from_id "gemini" `Rect "")

let test_infer_rect_known_tool () =
  check_ok_with "known tool ID" (fun nt ->
    match nt with
    | Tool { name = "eslint"; args = `Null } -> ()
    | _ -> fail "expected Tool eslint"
  ) (Chain_mermaid_parse.infer_type_from_id "eslint" `Rect "anything")

let test_infer_rect_default_llm () =
  (* Unknown ID, not a tool -> default gemini LLM *)
  check_ok_with "default rect is LLM gemini" (fun nt ->
    match nt with
    | Llm { model = "gemini"; prompt = "hello"; _ } -> ()
    | _ -> fail "expected default Llm gemini"
  ) (Chain_mermaid_parse.infer_type_from_id "A" `Rect "hello")

let test_infer_rect_default_llm_empty () =
  check_ok_with "default rect empty text uses ID" (fun nt ->
    match nt with
    | Llm { model = "gemini"; prompt = "my_node"; _ } -> ()
    | _ -> fail "expected prompt = ID"
  ) (Chain_mermaid_parse.infer_type_from_id "my_node" `Rect "")

let test_infer_rect_default_with_tools () =
  check_ok_with "default rect with tools" (fun nt ->
    match nt with
    | Llm { model = "gemini"; tools = Some _; _ } -> ()
    | _ -> fail "expected default Llm with tools"
  ) (Chain_mermaid_parse.infer_type_from_id "A" `Rect "do stuff +tools")

(* ============================================================
   10d. infer_type_from_id -- Trap shape
   ============================================================ *)

let test_infer_trap () =
  check_ok_with "trap = Adapter" (fun nt ->
    match nt with
    | Adapter { input_ref = "input"; transform = Template "my template"; _ } -> ()
    | _ -> fail "expected Adapter"
  ) (Chain_mermaid_parse.infer_type_from_id "A" `Trap "my template")

(* ============================================================
   10e. infer_type_from_id -- Stadium shape
   ============================================================ *)

let test_infer_stadium_retry () =
  check_ok_with "Retry:N" (fun nt ->
    match nt with
    | Retry { max_attempts = 5; _ } -> ()
    | _ -> fail "expected Retry 5"
  ) (Chain_mermaid_parse.infer_type_from_id "A" `Stadium "Retry:5")

let test_infer_stadium_fallback () =
  check_ok_with "Fallback" (fun nt ->
    match nt with Fallback _ -> () | _ -> fail "expected Fallback"
  ) (Chain_mermaid_parse.infer_type_from_id "A" `Stadium "Fallback")

let test_infer_stadium_fallback_colon () =
  check_ok_with "Fallback:" (fun nt ->
    match nt with Fallback _ -> () | _ -> fail "expected Fallback"
  ) (Chain_mermaid_parse.infer_type_from_id "A" `Stadium "Fallback:some_detail")

let test_infer_stadium_race () =
  check_ok_with "Race" (fun nt ->
    match nt with Race _ -> () | _ -> fail "expected Race"
  ) (Chain_mermaid_parse.infer_type_from_id "A" `Stadium "Race")

let test_infer_stadium_race_colon () =
  check_ok_with "Race:" (fun nt ->
    match nt with Race _ -> () | _ -> fail "expected Race"
  ) (Chain_mermaid_parse.infer_type_from_id "A" `Stadium "Race:timeout")

let test_infer_stadium_cascade () =
  check_ok_with "Cascade" (fun nt ->
    match nt with Cascade _ -> () | _ -> fail "expected Cascade"
  ) (Chain_mermaid_parse.infer_type_from_id "A" `Stadium "Cascade")

let test_infer_stadium_cascade_threshold () =
  check_ok_with "Cascade:threshold" (fun nt ->
    match nt with
    | Cascade { default_threshold; _ } ->
        check (float 0.01) "threshold" 0.8 default_threshold
    | _ -> fail "expected Cascade"
  ) (Chain_mermaid_parse.infer_type_from_id "A" `Stadium "Cascade:0.8")

let test_infer_stadium_cascade_with_context_mode () =
  check_ok_with "Cascade:threshold:mode" (fun nt ->
    match nt with Cascade _ -> () | _ -> fail "expected Cascade"
  ) (Chain_mermaid_parse.infer_type_from_id "A" `Stadium "Cascade:0.7:full")

let test_infer_stadium_cascade_bad_threshold () =
  check_ok_with "Cascade:bad_number" (fun nt ->
    match nt with
    | Cascade { default_threshold; _ } ->
        check (float 0.01) "default threshold" 0.7 default_threshold
    | _ -> fail "expected Cascade"
  ) (Chain_mermaid_parse.infer_type_from_id "A" `Stadium "Cascade:notanumber")

let test_infer_stadium_unknown () =
  check_ok_with "unknown stadium" (fun nt ->
    match nt with Llm _ -> () | _ -> fail "expected Llm fallback"
  ) (Chain_mermaid_parse.infer_type_from_id "A" `Stadium "something_else")

(* ============================================================
   10f. infer_type_from_id -- Circle shape
   ============================================================ *)

let test_infer_circle_broadcast () =
  check_ok_with "MASC:broadcast" (fun nt ->
    match nt with Masc_broadcast _ -> () | _ -> fail "expected Masc_broadcast"
  ) (Chain_mermaid_parse.infer_type_from_id "A" `Circle "MASC:broadcast hello")

let test_infer_circle_broadcast_no_msg () =
  check_ok_with "MASC:broadcast no msg" (fun nt ->
    match nt with Masc_broadcast { message = ""; _ } -> () | _ -> fail "expected empty broadcast"
  ) (Chain_mermaid_parse.infer_type_from_id "A" `Circle "MASC:broadcast")

let test_infer_circle_listen () =
  check_ok_with "MASC:listen" (fun nt ->
    match nt with Masc_listen _ -> () | _ -> fail "expected Masc_listen"
  ) (Chain_mermaid_parse.infer_type_from_id "A" `Circle "MASC:listen")

let test_infer_circle_listen_filter () =
  check_ok_with "MASC:listen with filter" (fun nt ->
    match nt with
    | Masc_listen { filter = Some "agent_x"; _ } -> ()
    | Masc_listen { filter; _ } ->
        fail (Printf.sprintf "wrong filter: %s" (Option.value ~default:"None" filter))
    | _ -> fail "expected Masc_listen"
  ) (Chain_mermaid_parse.infer_type_from_id "A" `Circle "MASC:listen agent_x")

let test_infer_circle_claim () =
  check_ok_with "MASC:claim" (fun nt ->
    match nt with Masc_claim _ -> () | _ -> fail "expected Masc_claim"
  ) (Chain_mermaid_parse.infer_type_from_id "A" `Circle "MASC:claim")

let test_infer_circle_claim_task () =
  check_ok_with "MASC:claim task_id" (fun nt ->
    match nt with
    | Masc_claim { task_id = Some "task_123"; _ } -> ()
    | _ -> fail "expected Masc_claim with task_id"
  ) (Chain_mermaid_parse.infer_type_from_id "A" `Circle "MASC:claim task_123")

let test_infer_circle_heuristic_broadcast () =
  (* Contains 'b' and 'r' *)
  check_ok_with "heuristic broadcast" (fun nt ->
    match nt with Masc_broadcast _ -> () | _ -> fail "expected heuristic broadcast"
  ) (Chain_mermaid_parse.infer_type_from_id "A" `Circle "bar")

let test_infer_circle_heuristic_listen () =
  (* Contains 'l' and 'i' but not 'b'+'r' *)
  check_ok_with "heuristic listen" (fun nt ->
    match nt with Masc_listen _ -> () | _ -> fail "expected heuristic listen"
  ) (Chain_mermaid_parse.infer_type_from_id "A" `Circle "li")

let test_infer_circle_heuristic_claim () =
  (* Need to avoid 'i' and 'b'+'r': just "cl" hits claim heuristic *)
  check_ok_with "heuristic claim" (fun nt ->
    match nt with Masc_claim _ -> () | _ -> fail "expected heuristic claim"
  ) (Chain_mermaid_parse.infer_type_from_id "A" `Circle "cl")

let test_infer_circle_default_broadcast () =
  (* No heuristic match -> default broadcast *)
  check_ok_with "default broadcast" (fun nt ->
    match nt with Masc_broadcast _ -> () | _ -> fail "expected default broadcast"
  ) (Chain_mermaid_parse.infer_type_from_id "A" `Circle "xyz")

let test_infer_circle_emoji_prefix () =
  check_ok_with "emoji prefix stripped" (fun nt ->
    match nt with Masc_broadcast _ -> () | _ -> fail "expected broadcast"
  ) (Chain_mermaid_parse.infer_type_from_id "A" `Circle "XX MASC:broadcast hello")

(* ============================================================
   11. parse_node_definition
   ============================================================ *)

let test_parse_node_def_rect () =
  match Chain_mermaid_parse.parse_node_definition "A[hello world]" with
  | Some (id, node) ->
      check string "id" "A" id;
      check string "content" "hello world" node.content;
      (match node.shape with `Rect -> () | _ -> fail "expected Rect")
  | None -> fail "expected Some"

let test_parse_node_def_diamond () =
  match Chain_mermaid_parse.parse_node_definition "D{condition}" with
  | Some (id, node) ->
      check string "id" "D" id;
      check string "content" "condition" node.content;
      (match node.shape with `Diamond -> () | _ -> fail "expected Diamond")
  | None -> fail "expected Some"

let test_parse_node_def_subroutine () =
  match Chain_mermaid_parse.parse_node_definition "S[[pipeline stuff]]" with
  | Some (id, node) ->
      check string "id" "S" id;
      check string "content" "pipeline stuff" node.content;
      (match node.shape with `Subroutine -> () | _ -> fail "expected Subroutine")
  | None -> fail "expected Some"

let test_parse_node_def_stadium_simple () =
  match Chain_mermaid_parse.parse_node_definition {|R("Retry:3")|} with
  | Some (id, node) ->
      check string "id" "R" id;
      check string "content" "Retry:3" node.content;
      (match node.shape with `Stadium -> () | _ -> fail "expected Stadium")
  | None -> fail "expected Some"

let test_parse_node_def_empty () =
  match Chain_mermaid_parse.parse_node_definition "" with
  | None -> ()
  | Some _ -> fail "expected None for empty"

let test_parse_node_def_no_match () =
  match Chain_mermaid_parse.parse_node_definition "just text no shape" with
  | None -> ()
  | Some _ -> fail "expected None for plain text"

let test_parse_node_def_kebab_case () =
  match Chain_mermaid_parse.parse_node_definition "vision-analyze[parse image]" with
  | Some (id, _) -> check string "kebab id" "vision-analyze" id
  | None -> fail "expected Some for kebab-case"

let test_parse_node_def_underscore () =
  match Chain_mermaid_parse.parse_node_definition "my_node[text]" with
  | Some (id, _) -> check string "underscore id" "my_node" id
  | None -> fail "expected Some for underscore"

(* ============================================================
   12. Additional LLM model ID tests
   ============================================================ *)

let test_infer_rect_codex () =
  check_ok_with "codex model" (fun nt ->
    match nt with Llm { model = "codex"; _ } -> () | _ -> fail "expected codex"
  ) (Chain_mermaid_parse.infer_type_from_id "codex_gen" `Rect "generate code")

let test_infer_rect_gpt () =
  check_ok_with "gpt model" (fun nt ->
    match nt with Llm { model = "gpt"; _ } -> () | _ -> fail "expected gpt"
  ) (Chain_mermaid_parse.infer_type_from_id "gpt_summarize" `Rect "summarize")

let test_infer_rect_o1 () =
  check_ok_with "o1 model" (fun nt ->
    match nt with Llm { model = "o1"; _ } -> () | _ -> fail "expected o1"
  ) (Chain_mermaid_parse.infer_type_from_id "o1_reason" `Rect "reason")

let test_infer_rect_o3 () =
  check_ok_with "o3 model" (fun nt ->
    match nt with Llm { model = "o3"; _ } -> () | _ -> fail "expected o3"
  ) (Chain_mermaid_parse.infer_type_from_id "o3_think" `Rect "think")

let test_infer_rect_sonnet () =
  check_ok_with "sonnet model" (fun nt ->
    match nt with Llm { model = "sonnet"; _ } -> () | _ -> fail "expected sonnet"
  ) (Chain_mermaid_parse.infer_type_from_id "sonnet_write" `Rect "write")

let test_infer_rect_opus () =
  check_ok_with "opus model" (fun nt ->
    match nt with Llm { model = "opus"; _ } -> () | _ -> fail "expected opus"
  ) (Chain_mermaid_parse.infer_type_from_id "opus_analyze" `Rect "analyze")

let test_infer_rect_haiku () =
  check_ok_with "haiku model" (fun nt ->
    match nt with Llm { model = "haiku"; _ } -> () | _ -> fail "expected haiku"
  ) (Chain_mermaid_parse.infer_type_from_id "haiku_fast" `Rect "fast")

let test_infer_rect_stub () =
  check_ok_with "stub model" (fun nt ->
    match nt with Llm { model = "stub"; _ } -> () | _ -> fail "expected stub"
  ) (Chain_mermaid_parse.infer_type_from_id "stub_test" `Rect "test")

(* Test known tools *)
let test_infer_rect_tsc () =
  check_ok_with "tsc tool" (fun nt ->
    match nt with Tool { name = "tsc"; _ } -> () | _ -> fail "expected tsc"
  ) (Chain_mermaid_parse.infer_type_from_id "tsc" `Rect "check types")

let test_infer_rect_prettier () =
  check_ok_with "prettier tool" (fun nt ->
    match nt with Tool { name = "prettier"; _ } -> () | _ -> fail "expected prettier"
  ) (Chain_mermaid_parse.infer_type_from_id "prettier" `Rect "format")

let test_infer_rect_jest () =
  check_ok_with "jest tool" (fun nt ->
    match nt with Tool { name = "jest"; _ } -> () | _ -> fail "expected jest"
  ) (Chain_mermaid_parse.infer_type_from_id "jest" `Rect "test")

let test_infer_rect_dune () =
  check_ok_with "dune tool" (fun nt ->
    match nt with Tool { name = "dune"; _ } -> () | _ -> fail "expected dune"
  ) (Chain_mermaid_parse.infer_type_from_id "dune" `Rect "build")

(* ============================================================
   Runner
   ============================================================ *)

let () =
  run "Chain_mermaid_parse coverage" [
    "strip_quotes", [
      test_case "double quotes" `Quick test_strip_quotes_double;
      test_case "single quotes" `Quick test_strip_quotes_single;
      test_case "no quotes" `Quick test_strip_quotes_no_quotes;
      test_case "mismatched" `Quick test_strip_quotes_mismatched;
      test_case "empty" `Quick test_strip_quotes_empty;
      test_case "single char" `Quick test_strip_quotes_single_char;
      test_case "whitespace" `Quick test_strip_quotes_whitespace;
    ];
    "has_explicit_type_prefix", [
      test_case "LLM:" `Quick test_prefix_llm;
      test_case "Tool:" `Quick test_prefix_tool;
      test_case "Ref:" `Quick test_prefix_ref;
      test_case "Quorum:" `Quick test_prefix_quorum;
      test_case "Gate:" `Quick test_prefix_gate;
      test_case "Merge:" `Quick test_prefix_merge;
      test_case "Pipeline:" `Quick test_prefix_pipeline;
      test_case "Fanout:" `Quick test_prefix_fanout;
      test_case "Map:" `Quick test_prefix_map;
      test_case "Bind:" `Quick test_prefix_bind;
      test_case "Cache:" `Quick test_prefix_cache;
      test_case "Batch:" `Quick test_prefix_batch;
      test_case "Spawn:" `Quick test_prefix_spawn;
      test_case "Threshold:" `Quick test_prefix_threshold;
      test_case "Evaluator:" `Quick test_prefix_evaluator;
      test_case "GoalDriven:" `Quick test_prefix_goaldriven;
      test_case "MCTS:" `Quick test_prefix_mcts;
      test_case "StreamMerge:" `Quick test_prefix_streammerge;
      test_case "FeedbackLoop:" `Quick test_prefix_feedbackloop;
      test_case "no prefix" `Quick test_prefix_none;
      test_case "empty" `Quick test_prefix_empty;
      test_case "short" `Quick test_prefix_short;
    ];
    "extract_tools_flag", [
      test_case "present" `Quick test_extract_tools_present;
      test_case "absent" `Quick test_extract_tools_absent;
      test_case "empty" `Quick test_extract_tools_empty;
      test_case "only flag" `Quick test_extract_tools_only_flag;
      test_case "whitespace" `Quick test_extract_tools_with_whitespace;
    ];
    "make_tools_value", [
      test_case "true" `Quick test_make_tools_true;
      test_case "false" `Quick test_make_tools_false;
    ];
    "empty_meta", [
      test_case "all fields None/empty" `Quick test_empty_meta;
    ];
    "parse_input_mapping_json", [
      test_case "valid" `Quick test_parse_input_mapping_valid;
      test_case "empty list" `Quick test_parse_input_mapping_empty_list;
      test_case "non-list" `Quick test_parse_input_mapping_non_list;
      test_case "bad pair" `Quick test_parse_input_mapping_bad_pair;
      test_case "mixed" `Quick test_parse_input_mapping_mixed;
    ];
    "parse_chain_meta", [
      test_case "full" `Quick test_parse_chain_meta_full;
      test_case "partial" `Quick test_parse_chain_meta_partial;
      test_case "invalid json" `Quick test_parse_chain_meta_invalid_json;
      test_case "non-assoc" `Quick test_parse_chain_meta_non_assoc;
      test_case "preserves existing" `Quick test_parse_chain_meta_preserves_existing;
    ];
    "parse_chain_full", [
      test_case "basic" `Quick test_parse_chain_full;
    ];
    "parse_node_meta", [
      test_case "input_mapping" `Quick test_parse_node_meta_input_mapping;
      test_case "goaldriven" `Quick test_parse_node_meta_goaldriven;
      test_case "no goaldriven fields" `Quick test_parse_node_meta_no_goaldriven_fields;
      test_case "invalid json" `Quick test_parse_node_meta_invalid_json;
      test_case "non-assoc" `Quick test_parse_node_meta_non_assoc;
      test_case "partial goaldriven" `Quick test_parse_node_meta_partial_goaldriven;
      test_case "relay non-string" `Quick test_parse_node_meta_relay_non_string;
      test_case "strategy hints bad" `Quick test_parse_node_meta_strategy_hints_bad;
    ];
    "parse_meta_comment", [
      test_case "@chain" `Quick test_meta_comment_chain;
      test_case "@chain_json" `Quick test_meta_comment_chain_json;
      test_case "@chain_json invalid" `Quick test_meta_comment_chain_json_invalid;
      test_case "@chain_full" `Quick test_meta_comment_chain_full;
      test_case "@node:" `Quick test_meta_comment_node;
      test_case "@node: no space" `Quick test_meta_comment_node_no_space;
      test_case "not a comment" `Quick test_meta_comment_not_comment;
      test_case "short" `Quick test_meta_comment_short;
      test_case "unknown directive" `Quick test_meta_comment_unknown_directive;
    ];
    "infer_type_from_id:diamond", [
      test_case "quorum_N" `Quick test_infer_diamond_quorum_id;
      test_case "consensus_N" `Quick test_infer_diamond_consensus_id;
      test_case "gate_ prefix" `Quick test_infer_diamond_gate_id;
      test_case "merge_ prefix" `Quick test_infer_diamond_merge_id;
      test_case "goal_ with pattern" `Quick test_infer_diamond_goal_with_pattern;
      test_case "goal gt" `Quick test_infer_diamond_goal_gt;
      test_case "goal lt" `Quick test_infer_diamond_goal_lt;
      test_case "goal lte" `Quick test_infer_diamond_goal_lte;
      test_case "goal eq" `Quick test_infer_diamond_goal_eq;
      test_case "goal neq" `Quick test_infer_diamond_goal_neq;
      test_case "goal unknown op" `Quick test_infer_diamond_goal_unknown_op;
      test_case "goal fallback" `Quick test_infer_diamond_goal_fallback;
      test_case "eval_ prefix" `Quick test_infer_diamond_eval_id;
      test_case "Evaluator: 3 parts" `Quick test_infer_diamond_evaluator_text_3parts;
      test_case "Evaluator: 2 parts" `Quick test_infer_diamond_evaluator_text_2parts;
      test_case "Evaluator: 1 part" `Quick test_infer_diamond_evaluator_text_1part;
      test_case "Evaluator: boundary" `Quick test_infer_diamond_evaluator_text_exact_boundary;
      test_case "Evaluator weighted" `Quick test_infer_diamond_evaluator_weighted;
      test_case "Evaluator unknown strategy" `Quick test_infer_diamond_evaluator_unknown_strategy;
      test_case "Quorum: text" `Quick test_infer_diamond_quorum_text;
      test_case "Quorum majority" `Quick test_infer_diamond_quorum_majority;
      test_case "Quorum unanimous" `Quick test_infer_diamond_quorum_unanimous;
      test_case "default Gate" `Quick test_infer_diamond_default_gate;
    ];
    "infer_type_from_id:subroutine", [
      test_case "ref_" `Quick test_infer_subroutine_ref;
      test_case "seq_" `Quick test_infer_subroutine_seq;
      test_case "par_" `Quick test_infer_subroutine_par;
      test_case "map_" `Quick test_infer_subroutine_map;
      test_case "default with content" `Quick test_infer_subroutine_default_with_content;
      test_case "default empty" `Quick test_infer_subroutine_default_empty;
    ];
    "infer_type_from_id:rect", [
      test_case "explicit llm" `Quick test_infer_rect_explicit_llm;
      test_case "explicit llm tools" `Quick test_infer_rect_explicit_llm_tools;
      test_case "explicit llm no prompt" `Quick test_infer_rect_explicit_llm_no_prompt;
      test_case "explicit tool" `Quick test_infer_rect_explicit_tool;
      test_case "explicit tool json args" `Quick test_infer_rect_explicit_tool_with_json_args;
      test_case "explicit tool string args" `Quick test_infer_rect_explicit_tool_with_string_args;
      test_case "explicit tool empty args" `Quick test_infer_rect_explicit_tool_empty_args;
      test_case "ID llm model" `Quick test_infer_rect_id_llm_model;
      test_case "ID claude" `Quick test_infer_rect_id_claude;
      test_case "ID llm with tools" `Quick test_infer_rect_id_llm_with_tools;
      test_case "ID llm empty text" `Quick test_infer_rect_id_llm_empty_text;
      test_case "known tool eslint" `Quick test_infer_rect_known_tool;
      test_case "default llm" `Quick test_infer_rect_default_llm;
      test_case "default llm empty" `Quick test_infer_rect_default_llm_empty;
      test_case "default with tools" `Quick test_infer_rect_default_with_tools;
      test_case "codex" `Quick test_infer_rect_codex;
      test_case "gpt" `Quick test_infer_rect_gpt;
      test_case "o1" `Quick test_infer_rect_o1;
      test_case "o3" `Quick test_infer_rect_o3;
      test_case "sonnet" `Quick test_infer_rect_sonnet;
      test_case "opus" `Quick test_infer_rect_opus;
      test_case "haiku" `Quick test_infer_rect_haiku;
      test_case "stub" `Quick test_infer_rect_stub;
      test_case "tsc" `Quick test_infer_rect_tsc;
      test_case "prettier" `Quick test_infer_rect_prettier;
      test_case "jest" `Quick test_infer_rect_jest;
      test_case "dune" `Quick test_infer_rect_dune;
    ];
    "infer_type_from_id:trap", [
      test_case "adapter" `Quick test_infer_trap;
    ];
    "infer_type_from_id:stadium", [
      test_case "Retry" `Quick test_infer_stadium_retry;
      test_case "Fallback" `Quick test_infer_stadium_fallback;
      test_case "Fallback:" `Quick test_infer_stadium_fallback_colon;
      test_case "Race" `Quick test_infer_stadium_race;
      test_case "Race:" `Quick test_infer_stadium_race_colon;
      test_case "Cascade" `Quick test_infer_stadium_cascade;
      test_case "Cascade:threshold" `Quick test_infer_stadium_cascade_threshold;
      test_case "Cascade:threshold:mode" `Quick test_infer_stadium_cascade_with_context_mode;
      test_case "Cascade:bad" `Quick test_infer_stadium_cascade_bad_threshold;
      test_case "unknown" `Quick test_infer_stadium_unknown;
    ];
    "infer_type_from_id:circle", [
      test_case "MASC:broadcast" `Quick test_infer_circle_broadcast;
      test_case "MASC:broadcast no msg" `Quick test_infer_circle_broadcast_no_msg;
      test_case "MASC:listen" `Quick test_infer_circle_listen;
      test_case "MASC:listen filter" `Quick test_infer_circle_listen_filter;
      test_case "MASC:claim" `Quick test_infer_circle_claim;
      test_case "MASC:claim task" `Quick test_infer_circle_claim_task;
      test_case "heuristic broadcast" `Quick test_infer_circle_heuristic_broadcast;
      test_case "heuristic listen" `Quick test_infer_circle_heuristic_listen;
      test_case "heuristic claim" `Quick test_infer_circle_heuristic_claim;
      test_case "default broadcast" `Quick test_infer_circle_default_broadcast;
      test_case "emoji prefix" `Quick test_infer_circle_emoji_prefix;
    ];
    "parse_node_definition", [
      test_case "rect" `Quick test_parse_node_def_rect;
      test_case "diamond" `Quick test_parse_node_def_diamond;
      test_case "subroutine" `Quick test_parse_node_def_subroutine;
      test_case "stadium simple" `Quick test_parse_node_def_stadium_simple;
      test_case "empty" `Quick test_parse_node_def_empty;
      test_case "no match" `Quick test_parse_node_def_no_match;
      test_case "kebab case" `Quick test_parse_node_def_kebab_case;
      test_case "underscore" `Quick test_parse_node_def_underscore;
    ];
  ]
