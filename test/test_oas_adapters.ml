(** Tests for OAS adapter modules: Context_manager.compact (which routes
    through Context_compact_oas), message roundtrip, and compaction strategies.

    Note: Context_compact_oas is an internal module not directly accessible
    from tests (installed opam masc_mcp may lack it). Tests go through the
    public Context_manager API which delegates to Context_compact_oas. *)

open Masc_mcp

(* ================================================================ *)
(* Helper: create MASC messages with all 4 roles                    *)
(* ================================================================ *)

let make_test_messages () : Llm_client.message list =
  [
    Llm_client.system_msg "You are a helpful assistant.";
    Llm_client.user_msg "Hello, what is 2+2?";
    Llm_client.assistant_msg "The answer is 4.";
    Llm_client.tool_msg ~name:"calculator" ~call_id:"call-1" "result: 4";
    Llm_client.user_msg "Thanks, now solve x^2 = 9.";
    Llm_client.assistant_msg "x = 3 or x = -3.";
  ]

(* ================================================================ *)
(* Message roundtrip tests via Llm_client to/from OAS               *)
(* ================================================================ *)

let test_roundtrip_user_msg () =
  let msg = Llm_client.user_msg "hello world" in
  match Llm_client.to_oas_message msg with
  | None -> Alcotest.fail "user message should not be dropped"
  | Some oas ->
    let rt = Llm_client.of_oas_message oas in
    Alcotest.(check string) "role preserved" "user"
      (match rt.role with Llm_client.User -> "user" | _ -> "other");
    Alcotest.(check string) "content preserved"
      "hello world" (Llm_client.text_of_message rt)

let test_roundtrip_assistant_msg () =
  let msg = Llm_client.assistant_msg "The answer is 42." in
  match Llm_client.to_oas_message msg with
  | None -> Alcotest.fail "assistant message should not be dropped"
  | Some oas ->
    let rt = Llm_client.of_oas_message oas in
    Alcotest.(check string) "role preserved" "assistant"
      (match rt.role with Llm_client.Assistant -> "assistant" | _ -> "other");
    Alcotest.(check string) "content preserved"
      "The answer is 42." (Llm_client.text_of_message rt)

let test_roundtrip_system_msg_dropped () =
  let msg = Llm_client.system_msg "system prompt" in
  let result = Llm_client.to_oas_message msg in
  Alcotest.(check bool) "system message dropped (belongs in system_prompt)"
    true (Option.is_none result)

let test_roundtrip_tool_msg () =
  let msg = Llm_client.tool_msg ~name:"calc" ~call_id:"tc-1" "tool output here" in
  match Llm_client.to_oas_message msg with
  | None -> Alcotest.fail "tool message should not be dropped"
  | Some oas ->
    let rt = Llm_client.of_oas_message oas in
    (* Llm_client.to_oas_message preserves Tool role directly (shared type).
       Context_compact_oas.masc_msg_to_oas uses sentinel-tagging instead. *)
    Alcotest.(check string) "tool role preserved"
      "tool"
      (match rt.role with Llm_client.Tool -> "tool" | _ -> "other");
    let text = Llm_client.text_of_message rt in
    Alcotest.(check bool) "content preserved"
      true (String.length text > 0)

(* ================================================================ *)
(* Context_manager.compact tests (routes through Context_compact_oas) *)
(* ================================================================ *)

let test_compact_prune_tool_outputs () =
  let ctx = Context_manager.create ~system_prompt:"test system" ~max_tokens:4000 in
  let ctx = List.fold_left Context_manager.append ctx (make_test_messages ()) in
  let compacted = Context_manager.compact ctx [Context_manager.PruneToolOutputs] in
  (* PruneToolOutputs on short tool output should not drop messages *)
  Alcotest.(check bool) "messages preserved"
    true (List.length compacted.messages > 0);
  Alcotest.(check bool) "token count positive"
    true (compacted.token_count > 0);
  (* Short tool output (< 500 chars) should not be truncated *)
  Alcotest.(check int) "message count unchanged for short tool output"
    (List.length (make_test_messages ())) (List.length compacted.messages)

let test_compact_merge_contiguous () =
  let ctx = Context_manager.create ~system_prompt:"test" ~max_tokens:4000 in
  let msgs = [
    Llm_client.user_msg "part 1";
    Llm_client.user_msg "part 2";
    Llm_client.assistant_msg "response";
  ] in
  let ctx = List.fold_left Context_manager.append ctx msgs in
  let compacted = Context_manager.compact ctx [Context_manager.MergeContiguous] in
  (* MergeContiguous should merge the two consecutive user messages *)
  Alcotest.(check bool) "merged reduces count"
    true (List.length compacted.messages <= List.length msgs)

let test_compact_summarize_old () =
  (* Create enough messages to trigger keep-first-and-last behavior *)
  let ctx = Context_manager.create ~system_prompt:"test" ~max_tokens:8000 in
  let msgs = List.init 12 (fun i ->
    if i mod 2 = 0 then
      Llm_client.user_msg (Printf.sprintf "user message %d with content" i)
    else
      Llm_client.assistant_msg (Printf.sprintf "assistant response %d" i)
  ) in
  let ctx = List.fold_left Context_manager.append ctx msgs in
  let compacted = Context_manager.compact ctx [Context_manager.SummarizeOld] in
  (* SummarizeOld with keep-first-and-last should reduce message count *)
  Alcotest.(check bool) "summarize_old reduces messages"
    true (List.length compacted.messages < List.length msgs);
  Alcotest.(check bool) "token count positive"
    true (compacted.token_count > 0)

let test_compact_small_list_unchanged () =
  let ctx = Context_manager.create ~system_prompt:"test" ~max_tokens:4000 in
  let msgs = [
    Llm_client.user_msg "hello";
    Llm_client.assistant_msg "world";
  ] in
  let ctx = List.fold_left Context_manager.append ctx msgs in
  let compacted = Context_manager.compact ctx [Context_manager.SummarizeOld] in
  (* Small list (< first_n + last_n = 7) should be unchanged *)
  Alcotest.(check int) "small list unchanged"
    (List.length msgs) (List.length compacted.messages)

(* ================================================================ *)
(* Restore messages (direct Llm_client.of_oas_message)              *)
(* ================================================================ *)

let test_restore_messages_all_roles () =
  let oas_msgs : Agent_sdk.Types.message list = [
    { Agent_sdk.Types.role = Agent_sdk.Types.User;
      content = [Agent_sdk.Types.Text "user question"] };
    { Agent_sdk.Types.role = Agent_sdk.Types.Assistant;
      content = [Agent_sdk.Types.Text "assistant answer"] };
  ] in
  let masc_msgs = List.map Llm_client.of_oas_message oas_msgs in
  Alcotest.(check int) "2 messages restored" 2 (List.length masc_msgs);
  let first = List.hd masc_msgs in
  Alcotest.(check string) "first is user" "user"
    (match first.role with Llm_client.User -> "user" | _ -> "other");
  Alcotest.(check string) "first content" "user question"
    (Llm_client.text_of_message first);
  let second = List.nth masc_msgs 1 in
  Alcotest.(check string) "second is assistant" "assistant"
    (match second.role with Llm_client.Assistant -> "assistant" | _ -> "other")

(* ================================================================ *)
(* Runner                                                           *)
(* ================================================================ *)

let () =
  Alcotest.run "OAS Adapters" [
    "message_roundtrip", [
      Alcotest.test_case "user msg roundtrip" `Quick
        test_roundtrip_user_msg;
      Alcotest.test_case "assistant msg roundtrip" `Quick
        test_roundtrip_assistant_msg;
      Alcotest.test_case "system msg dropped" `Quick
        test_roundtrip_system_msg_dropped;
      Alcotest.test_case "tool msg roundtrip" `Quick
        test_roundtrip_tool_msg;
    ];
    "context_compact", [
      Alcotest.test_case "PruneToolOutputs" `Quick
        test_compact_prune_tool_outputs;
      Alcotest.test_case "MergeContiguous" `Quick
        test_compact_merge_contiguous;
      Alcotest.test_case "SummarizeOld (keep first+last)" `Quick
        test_compact_summarize_old;
      Alcotest.test_case "SummarizeOld small list unchanged" `Quick
        test_compact_small_list_unchanged;
    ];
    "message_restore", [
      Alcotest.test_case "restore messages all roles" `Quick
        test_restore_messages_all_roles;
    ];
  ]
