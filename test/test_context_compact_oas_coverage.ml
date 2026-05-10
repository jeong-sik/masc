(** Tests for Context_compact_oas — strategy mapping,
    shared scoring consistency, and edge cases.

    Legacy roundtrip tests removed: roles are natively compatible
    (no masc_msg_to_oas/oas_msg_to_masc conversion needed). *)

open Alcotest

module Types = Agent_sdk.Types
module Compact = Masc_mcp.Context_compact_oas
module Scoring = Masc_mcp.Context_compact_oas

let msg role text : Agent_sdk.Types.message =
  { role; content = [Types.Text text]; name = None; tool_call_id = None; metadata = [] }

let tool_msg ?(id = "tool-1") text : Agent_sdk.Types.message =
  { role = Types.Tool;
    content = [Types.ToolResult { tool_use_id = id; content = text; is_error = false; json = None }];
    name = None; tool_call_id = None; metadata = [] }

let tool_use_msg ?(id = "tool-1") ?(name = "grep_search") () : Agent_sdk.Types.message =
  { role = Types.Assistant;
    content = [Types.ToolUse { id; name; input = `Assoc [("query", `String "lib/")] }];
    name = None; tool_call_id = None; metadata = [] }

(* ================================================================ *)
(* Merge Contiguous Tests                                           *)
(* ================================================================ *)

let test_merge_contiguous_still_merges_plain_user () =
  (* Regular User messages should still be merged *)
  let msgs = [
    msg Agent_sdk.Types.User "Hello";
    msg Agent_sdk.Types.User "World";
    msg Agent_sdk.Types.Assistant "Hi";
  ] in
  let result = Compact.compact
    ~messages:msgs
    ~strategies:[Compact.MergeContiguous] () in
  let user_msgs = List.filter (fun (m : Agent_sdk.Types.message) ->
    m.role = Agent_sdk.Types.User) result in
  check int "plain user messages merged" 1 (List.length user_msgs)

(* ================================================================ *)
(* Strategy Mapping Tests                                           *)
(* ================================================================ *)

let test_compact_prune_tool_outputs () =
  let long_output = String.make 2000 'x' in
  let msgs = [
    msg Agent_sdk.Types.User "query";
    tool_msg long_output;
    msg Agent_sdk.Types.Assistant "answer";
  ] in
  let result = Compact.compact
    ~messages:msgs
    ~strategies:[Compact.PruneToolOutputs] () in
  let tool_text = Agent_sdk.Types.text_of_message (List.nth result 1) in
  check bool "tool output was pruned" true
    (String.length tool_text < String.length long_output)

let test_compact_empty_messages () =
  let result = Compact.compact
    ~messages:[]
    ~strategies:[Compact.PruneToolOutputs; Compact.MergeContiguous] () in
  check int "empty input = empty output" 0 (List.length result)

let test_compact_single_message () =
  let msgs = [msg Agent_sdk.Types.User "hello"] in
  let result = Compact.compact
    ~messages:msgs
    ~strategies:[Compact.MergeContiguous; Compact.DropLowImportance] () in
  check bool "single message survives" true (List.length result >= 1)

let test_compact_drop_low_importance () =
  (* Many short assistant messages should get low scores and be dropped *)
  let msgs =
    (msg Agent_sdk.Types.System "important system prompt") ::
    List.init 10 (fun i ->
      msg Agent_sdk.Types.Assistant (Printf.sprintf "ok %d" i))
    @ [msg Agent_sdk.Types.User "latest question"]
  in
  let result = Compact.compact
    ~messages:msgs
    ~strategies:[Compact.DropLowImportance] () in
  check bool "some messages dropped" true
    (List.length result < List.length msgs)

let test_compact_summarize_old () =
  (* Use enough messages so keep_recent=5 compacts the older prefix. *)
  let msgs = List.init 12 (fun i ->
    msg (if i mod 2 = 0 then Agent_sdk.Types.User else Agent_sdk.Types.Assistant)
      (Printf.sprintf "message %d with enough content to be meaningful" i))
  in
  let result = Compact.compact
    ~messages:msgs
    ~strategies:[Compact.SummarizeOld] () in
  check bool "message count reduced" true
    (List.length result < List.length msgs)

(* ================================================================ *)
(* Shared Scoring Consistency Tests (C3)                            *)
(* ================================================================ *)

let test_scoring_ssot () =
  (* Scoring.score_messages is now the single source of truth.
     This test verifies the function exists and produces valid output. *)
  let msgs = [
    msg Agent_sdk.Types.System "system";
    msg Agent_sdk.Types.User "user input";
    msg Agent_sdk.Types.Assistant "response";
    tool_msg "tool result";
  ] in
  let scores = Scoring.score_messages msgs in
  check int "scores count matches messages" 4 (List.length scores);
  List.iter (fun (idx, score) ->
    check bool (Printf.sprintf "score[%d] in [0,1]" idx) true
      (score >= 0.0 && score <= 1.0)
  ) scores

let test_scoring_sticky_memory () =
  let msgs = [
    msg Agent_sdk.Types.Assistant "[MEMORY_SUMMARY] important summary";
    msg Agent_sdk.Types.Assistant "normal message";
  ] in
  let scores = Scoring.score_messages msgs in
  let summary_score = List.assoc 0 scores in
  let normal_score = List.assoc 1 scores in
  check bool "memory summary has high score" true (summary_score >= 0.95);
  check bool "summary > normal" true (summary_score > normal_score)

let test_scoring_goal_sticky () =
  let msgs = [
    msg Agent_sdk.Types.User "[GOAL] Monitor CI";
  ] in
  let scores = Scoring.score_messages msgs in
  let score = List.assoc 0 scores in
  check bool "goal prefix gets sticky score" true (score >= 0.95)

let test_scoring_empty () =
  let scores = Scoring.score_messages [] in
  check int "empty input = empty scores" 0 (List.length scores)

let test_scoring_single () =
  let msgs = [msg Agent_sdk.Types.User "solo"] in
  let scores = Scoring.score_messages msgs in
  check int "single message scored" 1 (List.length scores);
  let (_, score) = List.hd scores in
  check bool "score in range" true (score >= 0.0 && score <= 1.0)

(* ================================================================ *)
(* Backward Compatibility: Legacy Marker Tests                      *)
(* ================================================================ *)

let test_scoring_legacy_memory_summary () =
  let msgs = [
    msg Agent_sdk.Types.Assistant "[MASC_MEMORY_SUMMARY v1] old format summary";
    msg Agent_sdk.Types.Assistant "normal message";
  ] in
  let scores = Scoring.score_messages msgs in
  let legacy_score = List.assoc 0 scores in
  let normal_score = List.assoc 1 scores in
  check bool "legacy memory summary still sticky" true (legacy_score >= 0.95);
  check bool "legacy > normal" true (legacy_score > normal_score)

let test_scoring_legacy_goal () =
  let msgs = [
    msg Agent_sdk.Types.User "[MASC_GOAL] old format goal";
  ] in
  let scores = Scoring.score_messages msgs in
  let score = List.assoc 0 scores in
  check bool "legacy goal still sticky" true (score >= 0.95)

(* ================================================================ *)
(* Dynamic Strategy Resolution Tests (#3164)                        *)
(* ================================================================ *)

let strategy_names strategies =
  List.map (function
    | Compact.PruneToolOutputs -> "PruneToolOutputs"
    | Compact.MergeContiguous -> "MergeContiguous"
    | Compact.DropLowImportance -> "DropLowImportance"
    | Compact.SummarizeOld -> "SummarizeOld"
    | Compact.Dynamic _ -> "Dynamic") strategies

let test_dynamic_high_pressure_multi_agent () =
  let obs : Compact.observation_context = {
    context_ratio = 0.85; active_agent_count = 3;
    unclaimed_task_count = 2; is_single_focused_task = false;
    context_window = 200_000; is_local_model = false } in
  let msgs = [msg Agent_sdk.Types.User "test"] in
  let _result = Compact.compact
    ~messages:msgs
    ~strategies:[Compact.Dynamic Compact.default_dynamic_selector]
    ~observation:obs () in
  (* Verify high-pressure path: PruneToolOutputs + DropLowImportance + MergeContiguous *)
  let resolved = Compact.resolve_strategies ~obs:(Some obs)
    [Compact.Dynamic Compact.default_dynamic_selector] in
  let names = strategy_names resolved in
  check (list string) "high pressure strategies"
    ["PruneToolOutputs"; "DropLowImportance"; "MergeContiguous"] names

let test_dynamic_single_focused_task () =
  let obs : Compact.observation_context = {
    context_ratio = 0.75; active_agent_count = 1;
    unclaimed_task_count = 0; is_single_focused_task = true;
    context_window = 1_000_000; is_local_model = false } in
  let resolved = Compact.resolve_strategies ~obs:(Some obs)
    [Compact.Dynamic Compact.default_dynamic_selector] in
  let names = strategy_names resolved in
  check (list string) "single focus strategies"
    ["PruneToolOutputs"; "SummarizeOld"] names

let test_dynamic_small_local_model () =
  let obs : Compact.observation_context = {
    context_ratio = 0.50; active_agent_count = 1;
    unclaimed_task_count = 1; is_single_focused_task = true;
    context_window = 8_192; is_local_model = true } in
  let resolved = Compact.resolve_strategies ~obs:(Some obs)
    [Compact.Dynamic Compact.default_dynamic_selector] in
  let names = strategy_names resolved in
  check (list string) "small local strategies"
    ["PruneToolOutputs"; "MergeContiguous"] names

let test_dynamic_local_at_64k_boundary () =
  (* Local model at exactly the small_local_ctx_floor: NOT small — gets standard compaction *)
  let obs : Compact.observation_context = {
    context_ratio = 0.50; active_agent_count = 1;
    unclaimed_task_count = 0; is_single_focused_task = false;
    context_window = Compact.small_local_ctx_floor; is_local_model = true } in
  let resolved = Compact.resolve_strategies ~obs:(Some obs)
    [Compact.Dynamic Compact.default_dynamic_selector] in
  let names = strategy_names resolved in
  check (list string) "local 64K gets default strategies"
    ["DropLowImportance"] names

let test_dynamic_local_below_64k () =
  (* Local model at 63,999 (just below small_local_ctx_floor): small — lightweight compaction *)
  let obs : Compact.observation_context = {
    context_ratio = 0.50; active_agent_count = 1;
    unclaimed_task_count = 0; is_single_focused_task = false;
    context_window = Compact.small_local_ctx_floor - 1; is_local_model = true } in
  let resolved = Compact.resolve_strategies ~obs:(Some obs)
    [Compact.Dynamic Compact.default_dynamic_selector] in
  let names = strategy_names resolved in
  check (list string) "local below 64K gets small local strategies"
    ["PruneToolOutputs"; "MergeContiguous"] names

let test_dynamic_large_context_cloud () =
  let obs : Compact.observation_context = {
    context_ratio = 0.50; active_agent_count = 1;
    unclaimed_task_count = 0; is_single_focused_task = false;
    context_window = 1_000_000; is_local_model = false } in
  let resolved = Compact.resolve_strategies ~obs:(Some obs)
    [Compact.Dynamic Compact.default_dynamic_selector] in
  let names = strategy_names resolved in
  check (list string) "large context cloud strategies"
    ["DropLowImportance"; "SummarizeOld"] names

let test_dynamic_medium_cloud_default () =
  let obs : Compact.observation_context = {
    context_ratio = 0.50; active_agent_count = 1;
    unclaimed_task_count = 0; is_single_focused_task = false;
    context_window = 128_000; is_local_model = false } in
  let resolved = Compact.resolve_strategies ~obs:(Some obs)
    [Compact.Dynamic Compact.default_dynamic_selector] in
  let names = strategy_names resolved in
  check (list string) "medium cloud default strategies"
    ["DropLowImportance"] names

let test_dynamic_no_observation () =
  let resolved = Compact.resolve_strategies ~obs:None
    [Compact.Dynamic Compact.default_dynamic_selector] in
  let names = strategy_names resolved in
  check (list string) "default (no observation)"
    ["DropLowImportance"] names

(* ================================================================ *)
(* Test Suite                                                       *)
(* ================================================================ *)

let () =
  run "context_compact_oas" [
    "merge_contiguous", [
      test_case "still merges plain user" `Quick test_merge_contiguous_still_merges_plain_user;
    ];
    "strategy_mapping", [
      test_case "prune_tool_outputs" `Quick test_compact_prune_tool_outputs;
      test_case "empty messages" `Quick test_compact_empty_messages;
      test_case "single message" `Quick test_compact_single_message;
      test_case "drop_low_importance" `Quick test_compact_drop_low_importance;
      test_case "summarize_old" `Quick test_compact_summarize_old;
    ];
    "scoring_ssot", [
      test_case "scores match messages" `Quick test_scoring_ssot;
      test_case "sticky memory summary" `Quick test_scoring_sticky_memory;
      test_case "sticky goal" `Quick test_scoring_goal_sticky;
      test_case "empty input" `Quick test_scoring_empty;
      test_case "single message" `Quick test_scoring_single;
      test_case "legacy memory summary compat" `Quick test_scoring_legacy_memory_summary;
      test_case "legacy goal compat" `Quick test_scoring_legacy_goal;
    ];
    "dynamic_strategy", [
      test_case "high pressure multi-agent" `Quick test_dynamic_high_pressure_multi_agent;
      test_case "single focused task" `Quick test_dynamic_single_focused_task;
      test_case "small local model" `Quick test_dynamic_small_local_model;
      test_case "local at 64K boundary" `Quick test_dynamic_local_at_64k_boundary;
      test_case "local below 64K" `Quick test_dynamic_local_below_64k;
      test_case "large context cloud" `Quick test_dynamic_large_context_cloud;
      test_case "medium cloud default" `Quick test_dynamic_medium_cloud_default;
      test_case "no observation fallback" `Quick test_dynamic_no_observation;
    ];
  ]
