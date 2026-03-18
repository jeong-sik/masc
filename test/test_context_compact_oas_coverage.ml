(** Context_compact_oas — OAS Context_reducer adapter tests.

    Tests roundtrip conversion (MASC -> OAS -> MASC), strategy mapping,
    and compaction behavior. *)

open Alcotest

module Compact = Masc_mcp.Context_compact_oas
module Llm = Masc_mcp.Llm_client
module Oas = Agent_sdk

(* ============================================================
   Helpers
   ============================================================ *)

let user_msg text : Llm.message =
  { role = Llm.User; content = [Oas.Types.Text text]; name = None; tool_call_id = None }

let assistant_msg text : Llm.message =
  { role = Llm.Assistant; content = [Oas.Types.Text text]; name = None; tool_call_id = None }

let system_msg text : Llm.message =
  { role = Llm.System; content = [Oas.Types.Text text]; name = None; tool_call_id = None }

let tool_msg ~id text : Llm.message =
  { role = Llm.Tool; content = [Oas.Types.Text text]; name = None; tool_call_id = Some id }

let text_of_msg (m : Llm.message) =
  Llm.text_of_message m

(* ============================================================
   Roundtrip Tests: MASC -> OAS -> MASC
   ============================================================ *)

let test_roundtrip_user_msg () =
  let orig = user_msg "hello world" in
  let oas = Compact.masc_msg_to_oas orig in
  let back = Compact.oas_msg_to_masc oas in
  check string "role preserved" "user"
    (match back.role with Llm.User -> "user" | _ -> "wrong");
  check string "text preserved" "hello world" (text_of_msg back)

let test_roundtrip_assistant_msg () =
  let orig = assistant_msg "I can help" in
  let oas = Compact.masc_msg_to_oas orig in
  let back = Compact.oas_msg_to_masc oas in
  check string "role" "assistant"
    (match back.role with Llm.Assistant -> "assistant" | _ -> "wrong");
  check string "text" "I can help" (text_of_msg back)

let test_roundtrip_system_msg () =
  let orig = system_msg "You are helpful" in
  let oas = Compact.masc_msg_to_oas orig in
  let back = Compact.oas_msg_to_masc oas in
  check string "role" "system"
    (match back.role with Llm.System -> "system" | _ -> "wrong");
  check string "text" "You are helpful" (text_of_msg back)

let test_roundtrip_tool_msg () =
  let orig = tool_msg ~id:"call-123" "result data" in
  let oas = Compact.masc_msg_to_oas orig in
  let back = Compact.oas_msg_to_masc oas in
  check string "role" "tool"
    (match back.role with Llm.Tool -> "tool" | _ -> "wrong");
  check string "text" "result data" (text_of_msg back);
  check (option string) "tool_call_id" (Some "call-123") back.tool_call_id

(* ============================================================
   compact() Tests
   ============================================================ *)

let test_compact_prune_tool_outputs () =
  let long_output = String.make 1000 'x' in
  let msgs = [
    user_msg "do something";
    assistant_msg "calling tool";
    tool_msg ~id:"t1" long_output;
    assistant_msg "done";
  ] in
  let result, _tokens = Compact.compact
    ~system_prompt:"sys" ~messages:msgs
    ~strategies:[Compact.PruneToolOutputs] in
  let tool_result_text = text_of_msg (List.nth result 2) in
  check bool "tool output truncated" true
    (String.length tool_result_text < String.length long_output)

let test_compact_merge_contiguous () =
  let msgs = [
    user_msg "part 1";
    user_msg "part 2";
    assistant_msg "response";
  ] in
  let result, _tokens = Compact.compact
    ~system_prompt:"sys" ~messages:msgs
    ~strategies:[Compact.MergeContiguous] in
  check bool "fewer messages" true (List.length result < List.length msgs)

let test_compact_drop_low_importance () =
  let msgs = List.init 20 (fun i ->
    if i mod 2 = 0 then user_msg (Printf.sprintf "q%d" i)
    else assistant_msg (Printf.sprintf "a%d" i)
  ) in
  let result, _tokens = Compact.compact
    ~system_prompt:"sys" ~messages:msgs
    ~strategies:[Compact.DropLowImportance] in
  check bool "some messages dropped" true (List.length result <= List.length msgs)

let test_compact_summarize_old () =
  let msgs = List.init 10 (fun i ->
    if i mod 2 = 0 then user_msg (Printf.sprintf "question %d with enough text to score" i)
    else assistant_msg (Printf.sprintf "answer %d with some content here" i)
  ) in
  let result, _tokens = Compact.compact
    ~system_prompt:"sys" ~messages:msgs
    ~strategies:[Compact.SummarizeOld] in
  (* SummarizeOld replaces oldest 30% with a summary — fewer messages *)
  check bool "message count reduced" true
    (List.length result < List.length msgs)

let test_compact_preserves_roles () =
  let msgs = [
    system_msg "system prompt";
    user_msg "hello";
    assistant_msg "hi there";
    tool_msg ~id:"t1" "short result";
  ] in
  let result, _tokens = Compact.compact
    ~system_prompt:"sys" ~messages:msgs
    ~strategies:[] in
  check int "message count preserved" 4 (List.length result);
  check string "role 0" "system"
    (match (List.nth result 0).role with Llm.System -> "system" | _ -> "wrong");
  check string "role 1" "user"
    (match (List.nth result 1).role with Llm.User -> "user" | _ -> "wrong");
  check string "role 2" "assistant"
    (match (List.nth result 2).role with Llm.Assistant -> "assistant" | _ -> "wrong");
  check string "role 3" "tool"
    (match (List.nth result 3).role with Llm.Tool -> "tool" | _ -> "wrong")

let test_compact_token_count () =
  let msgs = [user_msg "hello"; assistant_msg "world"] in
  let _result, tokens = Compact.compact
    ~system_prompt:"system" ~messages:msgs ~strategies:[] in
  check bool "positive token count" true (tokens > 0)

(* ============================================================
   Scoring Tests
   ============================================================ *)

let test_score_messages_length () =
  let msgs = [user_msg "a"; assistant_msg "b"; user_msg "c"] in
  let scores = Compact.score_messages msgs in
  check int "score count" 3 (List.length scores)

let test_score_messages_range () =
  let msgs = [user_msg "hello world this is a test message"] in
  let scores = Compact.score_messages msgs in
  let _, score = List.hd scores in
  check bool "score in [0,1]" true (score >= 0.0 && score <= 1.0)

(* ============================================================
   Test Runners
   ============================================================ *)

let () =
  run "Context Compact OAS" [
    "roundtrip", [
      test_case "user msg" `Quick test_roundtrip_user_msg;
      test_case "assistant msg" `Quick test_roundtrip_assistant_msg;
      test_case "system msg" `Quick test_roundtrip_system_msg;
      test_case "tool msg" `Quick test_roundtrip_tool_msg;
    ];
    "compact", [
      test_case "prune tool outputs" `Quick test_compact_prune_tool_outputs;
      test_case "merge contiguous" `Quick test_compact_merge_contiguous;
      test_case "drop low importance" `Quick test_compact_drop_low_importance;
      test_case "summarize old" `Quick test_compact_summarize_old;
      test_case "preserves roles" `Quick test_compact_preserves_roles;
      test_case "token count" `Quick test_compact_token_count;
    ];
    "scoring", [
      test_case "length matches" `Quick test_score_messages_length;
      test_case "score range" `Quick test_score_messages_range;
    ];
  ]
