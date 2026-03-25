(** Tests for Context_compact_oas — strategy mapping,
    shared scoring consistency, and edge cases.

    Sentinel roundtrip tests removed: roles are natively compatible
    (no masc_msg_to_oas/oas_msg_to_masc conversion needed). *)

open Alcotest

module Types = Agent_sdk.Types
module Compact = Masc_mcp.Context_compact_oas
module Scoring = Masc_mcp.Context_compact_oas

let msg role text : Agent_sdk.Types.message =
  { role; content = [Types.Text text]; name = None; tool_call_id = None }

let tool_msg ?(id = "tool-1") text : Agent_sdk.Types.message =
  { role = Types.Tool;
    content = [Types.ToolResult { tool_use_id = id; content = text; is_error = false }];
    name = None; tool_call_id = None }

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
  let result, _tokens = Compact.compact
    ~system_prompt:"sys" ~messages:msgs
    ~strategies:[Compact.MergeContiguous] () in
  let user_msgs = List.filter (fun (m : Agent_sdk.Types.message) ->
    m.role = Agent_sdk.Types.User) result in
  check int "plain user messages merged" 1 (List.length user_msgs)

(* ================================================================ *)
(* Strategy Mapping Tests                                           *)
(* ================================================================ *)

let test_compact_prune_tool_outputs () =
  let long_output = String.make 600 'x' in
  let msgs = [
    msg Agent_sdk.Types.User "query";
    tool_msg long_output;
    msg Agent_sdk.Types.Assistant "answer";
  ] in
  let result, _tokens = Compact.compact
    ~system_prompt:"sys" ~messages:msgs
    ~strategies:[Compact.PruneToolOutputs] () in
  let tool_text = Agent_sdk.Types.text_of_message (List.nth result 1) in
  check bool "tool output was pruned" true
    (String.length tool_text < String.length long_output)

let test_compact_empty_messages () =
  let result, tokens = Compact.compact
    ~system_prompt:"sys" ~messages:[]
    ~strategies:[Compact.PruneToolOutputs; Compact.MergeContiguous] () in
  check int "empty input = empty output" 0 (List.length result);
  check bool "tokens > 0 (system prompt)" true (tokens > 0)

let test_compact_single_message () =
  let msgs = [msg Agent_sdk.Types.User "hello"] in
  let result, _tokens = Compact.compact
    ~system_prompt:"sys" ~messages:msgs
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
  let result, _tokens = Compact.compact
    ~system_prompt:"sys" ~messages:msgs
    ~strategies:[Compact.DropLowImportance] () in
  check bool "some messages dropped" true
    (List.length result < List.length msgs)

let test_compact_summarize_old () =
  (* Summarize_old operates on turn groups, not raw message count.
     Use 6 user-led turns so keep_recent=5 actually compacts one old turn. *)
  let msgs = List.init 12 (fun i ->
    msg (if i mod 2 = 0 then Agent_sdk.Types.User else Agent_sdk.Types.Assistant)
      (Printf.sprintf "message %d with enough content to be meaningful" i))
  in
  let result, _tokens = Compact.compact
    ~system_prompt:"sys" ~messages:msgs
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
    msg Agent_sdk.Types.Assistant "[MASC_MEMORY_SUMMARY v1] important summary";
    msg Agent_sdk.Types.Assistant "normal message";
  ] in
  let scores = Scoring.score_messages msgs in
  let summary_score = List.assoc 0 scores in
  let normal_score = List.assoc 1 scores in
  check bool "memory summary has high score" true (summary_score >= 0.95);
  check bool "summary > normal" true (summary_score > normal_score)

let test_scoring_goal_sticky () =
  let msgs = [
    msg Agent_sdk.Types.User "[MASC_GOAL] Monitor CI";
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
    ];
  ]
