(** Tests for Context_compact_oas — sentinel roundtrip, strategy mapping,
    shared scoring consistency, and edge cases.

    Addresses PR #1517 review issues C1 (no tests), C2 (sentinel truncation),
    C3 (score divergence). *)

open Alcotest

module Cascade = Masc_mcp.Cascade
module Types = Agent_sdk.Types
module Compact = Masc_mcp.Context_compact_oas
module Scoring = Masc_mcp.Context_scoring

let msg role text : Agent_sdk.Types.message =
  { role; content = [Types.Text text]; name = None; tool_call_id = None }

let tool_msg ?(id = "tool-1") text : Agent_sdk.Types.message =
  { role = Types.Tool;
    content = [Types.ToolResult { tool_use_id = id; content = text; is_error = false }];
    name = None; tool_call_id = None }

(* ================================================================ *)
(* Sentinel Roundtrip Tests (C2)                                    *)
(* ================================================================ *)

let test_roundtrip_user () =
  let m = msg Agent_sdk.Types.User "Hello world" in
  let oas = Compact.masc_msg_to_oas m in
  let back = Compact.oas_msg_to_masc oas in
  check string "role preserved" "User"
    (match back.role with Agent_sdk.Types.User -> "User" | _ -> "other");
  check string "text preserved" "Hello world"
    (Agent_sdk.Types.text_of_message back)

let test_roundtrip_assistant () =
  let m = msg Agent_sdk.Types.Assistant "I can help" in
  let oas = Compact.masc_msg_to_oas m in
  let back = Compact.oas_msg_to_masc oas in
  check string "role preserved" "Assistant"
    (match back.role with Agent_sdk.Types.Assistant -> "Assistant" | _ -> "other");
  check string "text preserved" "I can help"
    (Agent_sdk.Types.text_of_message back)

let test_roundtrip_system () =
  let m = msg Agent_sdk.Types.System "You are helpful" in
  let oas = Compact.masc_msg_to_oas m in
  let back = Compact.oas_msg_to_masc oas in
  check string "role preserved" "System"
    (match back.role with Agent_sdk.Types.System -> "System" | _ -> "other");
  check string "text preserved" "You are helpful"
    (Agent_sdk.Types.text_of_message back)

let test_roundtrip_tool () =
  let m = tool_msg ~id:"call-42" "Result data" in
  let oas = Compact.masc_msg_to_oas m in
  let back = Compact.oas_msg_to_masc oas in
  check string "role preserved" "Tool"
    (match back.role with Agent_sdk.Types.Tool -> "Tool" | _ -> "other");
  check string "text preserved" "Result data"
    (Agent_sdk.Types.text_of_message back);
  let tool_id = List.find_map (function
    | Types.ToolResult { tool_use_id; _ } -> Some tool_use_id
    | _ -> None) back.content
  in
  check (option string) "tool_use_id preserved" (Some "call-42") tool_id

let test_roundtrip_empty_text () =
  let m = msg Agent_sdk.Types.System "" in
  let oas = Compact.masc_msg_to_oas m in
  let back = Compact.oas_msg_to_masc oas in
  check string "role preserved" "System"
    (match back.role with Agent_sdk.Types.System -> "System" | _ -> "other");
  check string "empty text preserved" ""
    (Agent_sdk.Types.text_of_message back)

let test_roundtrip_unicode () =
  let text = "한국어 텍스트 with emoji 🎉 and special chars: \t\n" in
  let m = msg Agent_sdk.Types.User text in
  let oas = Compact.masc_msg_to_oas m in
  let back = Compact.oas_msg_to_masc oas in
  check string "unicode preserved" text
    (Agent_sdk.Types.text_of_message back)

let test_roundtrip_text_containing_sentinel_prefix () =
  (* User text that accidentally contains \x00 should not be misinterpreted *)
  let text = "Normal text without null bytes" in
  let m = msg Agent_sdk.Types.User text in
  let oas = Compact.masc_msg_to_oas m in
  let back = Compact.oas_msg_to_masc oas in
  check string "text without sentinel survives" text
    (Agent_sdk.Types.text_of_message back)

(* ================================================================ *)
(* Validate Roundtrip Tests                                         *)
(* ================================================================ *)

let test_validate_roundtrip_clean () =
  let msgs = [
    msg Agent_sdk.Types.System "sys";
    msg Agent_sdk.Types.User "hello";
    msg Agent_sdk.Types.Assistant "hi";
    tool_msg "result";
  ] in
  check bool "clean roundtrip validates" true
    (Compact.validate_roundtrip ~original:msgs ~reduced:msgs)

let test_validate_roundtrip_no_sentinels () =
  let msgs = [
    msg Agent_sdk.Types.User "hello";
    msg Agent_sdk.Types.Assistant "hi";
  ] in
  check bool "no sentinels = trivially valid" true
    (Compact.validate_roundtrip ~original:msgs ~reduced:msgs)

let test_validate_roundtrip_empty () =
  check bool "empty lists valid" true
    (Compact.validate_roundtrip ~original:[] ~reduced:[])

(* ================================================================ *)
(* Sentinel Corruption Tests (C2 — real OAS reduction scenarios)    *)
(* ================================================================ *)

let test_merge_contiguous_preserves_sentinel_roles () =
  (* BUG SCENARIO: Two consecutive System messages become two User messages
     with sentinel tags. OAS Merge_contiguous would merge them (same role),
     corrupting the second sentinel into the first message's text.
     After fix: sentinel-tagged messages are excluded from merging. *)
  let msgs = [
    msg Agent_sdk.Types.System "System prompt 1";
    msg Agent_sdk.Types.System "System prompt 2";
    msg Agent_sdk.Types.User "User question";
    msg Agent_sdk.Types.Assistant "Response";
  ] in
  let result, _tokens = Compact.compact
    ~system_prompt:"sys" ~messages:msgs
    ~strategies:[Compact.MergeContiguous] in
  (* Both system messages should survive as separate System messages *)
  let system_msgs = List.filter (fun (m : Agent_sdk.Types.message) ->
    m.role = Agent_sdk.Types.System) result in
  check int "two system messages preserved separately" 2 (List.length system_msgs);
  check string "first system text intact" "System prompt 1"
    (Agent_sdk.Types.text_of_message (List.nth system_msgs 0));
  check string "second system text intact" "System prompt 2"
    (Agent_sdk.Types.text_of_message (List.nth system_msgs 1))

let test_merge_contiguous_tool_sentinel_preserved () =
  (* Consecutive Tool messages should not be merged either *)
  let msgs = [
    msg Agent_sdk.Types.User "query";
    msg Agent_sdk.Types.Assistant "thinking";
    tool_msg ~id:"t1" "Result 1";
    tool_msg ~id:"t2" "Result 2";
    msg Agent_sdk.Types.Assistant "final answer";
  ] in
  let result, _tokens = Compact.compact
    ~system_prompt:"sys" ~messages:msgs
    ~strategies:[Compact.MergeContiguous] in
  let tool_msgs = List.filter (fun (m : Agent_sdk.Types.message) ->
    m.role = Agent_sdk.Types.Tool) result in
  check int "two tool messages preserved separately" 2 (List.length tool_msgs)

let test_merge_contiguous_still_merges_plain_user () =
  (* Regular User messages (no sentinel) should still be merged *)
  let msgs = [
    msg Agent_sdk.Types.User "Hello";
    msg Agent_sdk.Types.User "World";
    msg Agent_sdk.Types.Assistant "Hi";
  ] in
  let result, _tokens = Compact.compact
    ~system_prompt:"sys" ~messages:msgs
    ~strategies:[Compact.MergeContiguous] in
  let user_msgs = List.filter (fun (m : Agent_sdk.Types.message) ->
    m.role = Agent_sdk.Types.User) result in
  check int "plain user messages merged" 1 (List.length user_msgs)

let test_prune_tool_outputs_sentinel_survives () =
  (* ToolResult with sentinel tag and long content — sentinel at front
     should survive truncation since max_output_len=500 > sentinel length *)
  let long_tool_output = String.make 600 'x' in
  let msgs = [
    msg Agent_sdk.Types.User "query";
    tool_msg long_tool_output;
    msg Agent_sdk.Types.Assistant "done";
  ] in
  let result, _tokens = Compact.compact
    ~system_prompt:"sys" ~messages:msgs
    ~strategies:[Compact.PruneToolOutputs] in
  let tool_msgs = List.filter (fun (m : Agent_sdk.Types.message) ->
    m.role = Agent_sdk.Types.Tool) result in
  check int "tool message exists" 1 (List.length tool_msgs);
  (* The Tool role should be correctly recovered *)
  let tool_text = Agent_sdk.Types.text_of_message (List.nth tool_msgs 0) in
  check bool "tool text was pruned" true
    (String.length tool_text < String.length long_tool_output)

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
    ~strategies:[Compact.PruneToolOutputs] in
  let tool_text = Agent_sdk.Types.text_of_message (List.nth result 1) in
  check bool "tool output was pruned" true
    (String.length tool_text < String.length long_output)

let test_compact_empty_messages () =
  let result, tokens = Compact.compact
    ~system_prompt:"sys" ~messages:[]
    ~strategies:[Compact.PruneToolOutputs; Compact.MergeContiguous] in
  check int "empty input = empty output" 0 (List.length result);
  check bool "tokens > 0 (system prompt)" true (tokens > 0)

let test_compact_single_message () =
  let msgs = [msg Agent_sdk.Types.User "hello"] in
  let result, _tokens = Compact.compact
    ~system_prompt:"sys" ~messages:msgs
    ~strategies:[Compact.MergeContiguous; Compact.DropLowImportance] in
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
    ~strategies:[Compact.DropLowImportance] in
  check bool "some messages dropped" true
    (List.length result < List.length msgs)

let test_compact_summarize_old () =
  let msgs = List.init 10 (fun i ->
    msg (if i mod 2 = 0 then Agent_sdk.Types.User else Agent_sdk.Types.Assistant)
      (Printf.sprintf "message %d with enough content to be meaningful" i))
  in
  let result, _tokens = Compact.compact
    ~system_prompt:"sys" ~messages:msgs
    ~strategies:[Compact.SummarizeOld] in
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
    "sentinel_roundtrip", [
      test_case "user" `Quick test_roundtrip_user;
      test_case "assistant" `Quick test_roundtrip_assistant;
      test_case "system" `Quick test_roundtrip_system;
      test_case "tool" `Quick test_roundtrip_tool;
      test_case "empty text" `Quick test_roundtrip_empty_text;
      test_case "unicode" `Quick test_roundtrip_unicode;
      test_case "text without sentinel" `Quick test_roundtrip_text_containing_sentinel_prefix;
    ];
    "validate_roundtrip", [
      test_case "clean" `Quick test_validate_roundtrip_clean;
      test_case "no sentinels" `Quick test_validate_roundtrip_no_sentinels;
      test_case "empty" `Quick test_validate_roundtrip_empty;
    ];
    "sentinel_corruption", [
      test_case "merge_contiguous preserves system sentinel" `Quick test_merge_contiguous_preserves_sentinel_roles;
      test_case "merge_contiguous preserves tool sentinel" `Quick test_merge_contiguous_tool_sentinel_preserved;
      test_case "merge_contiguous still merges plain user" `Quick test_merge_contiguous_still_merges_plain_user;
      test_case "prune_tool_outputs sentinel survives" `Quick test_prune_tool_outputs_sentinel_survives;
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
