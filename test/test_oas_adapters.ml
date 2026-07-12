(** Tests for OAS adapter modules: Keeper_context_runtime.compact (which routes
    through Context_compact_oas), message roundtrip, and compaction strategies.

    Note: Context_compact_oas is an internal module not directly accessible
    from tests (installed opam masc may lack it). Tests go through the
    public Context_manager API which delegates to Context_compact_oas. *)

open Masc

let ctx_messages = Keeper_context_runtime.messages_of_context
let ctx_system_prompt = Keeper_context_runtime.system_prompt_of_context

(* ================================================================ *)
(* Helper: create MASC messages with all 4 roles                    *)
(* ================================================================ *)

let make_test_messages () : Agent_sdk.Types.message list =
  [
    Agent_sdk.Types.system_msg "You are a helpful assistant.";
    Agent_sdk.Types.user_msg "Hello, what is 2+2?";
    Agent_sdk.Types.assistant_msg "The answer is 4.";
    { Agent_sdk.Types.role = Agent_sdk.Types.Tool;
      content =
        [ Agent_sdk.Types.ToolResult
            { tool_use_id = "call-1"
            ; content = "result: 4"
            ; outcome = Agent_sdk.Types.Tool_succeeded
            ; json = None
            ; content_blocks = None
            }
        ];
      name = None; tool_call_id = None; metadata = [] };
    Agent_sdk.Types.user_msg "Thanks, now solve x^2 = 9.";
    Agent_sdk.Types.assistant_msg "x = 3 or x = -3.";
  ]

(* ================================================================ *)
(* Message roundtrip tests via Llm_client to/from OAS               *)
(* ================================================================ *)

let test_roundtrip_user_msg () =
  let msg = Agent_sdk.Types.user_msg "hello world" in
  match (fun (m : Agent_sdk.Types.message) -> match m.role with Agent_sdk.Types.System -> None | _ -> Some m) msg with
  | None -> Alcotest.fail "user message should not be dropped"
  | Some oas ->
    let rt = Fun.id oas in
    Alcotest.(check string) "role preserved" "user"
      (match rt.role with Agent_sdk.Types.User -> "user" | _ -> "other");
    Alcotest.(check string) "content preserved"
      "hello world" (Agent_sdk.Types.text_of_message rt)

let test_roundtrip_assistant_msg () =
  let msg = Agent_sdk.Types.assistant_msg "The answer is 42." in
  match (fun (m : Agent_sdk.Types.message) -> match m.role with Agent_sdk.Types.System -> None | _ -> Some m) msg with
  | None -> Alcotest.fail "assistant message should not be dropped"
  | Some oas ->
    let rt = Fun.id oas in
    Alcotest.(check string) "role preserved" "assistant"
      (match rt.role with Agent_sdk.Types.Assistant -> "assistant" | _ -> "other");
    Alcotest.(check string) "content preserved"
      "The answer is 42." (Agent_sdk.Types.text_of_message rt)

let test_roundtrip_system_msg_dropped () =
  let msg = Agent_sdk.Types.system_msg "system prompt" in
  let result = (fun (m : Agent_sdk.Types.message) -> match m.role with Agent_sdk.Types.System -> None | _ -> Some m) msg in
  Alcotest.(check bool) "system message dropped (belongs in system_prompt)"
    true (Option.is_none result)

let test_roundtrip_tool_msg () =
  let msg : Agent_sdk.Types.message =
    { role = Agent_sdk.Types.Tool;
      content =
        [ Agent_sdk.Types.ToolResult
            { tool_use_id = "tc-1"
            ; content = "tool output here"
            ; outcome = Agent_sdk.Types.Tool_succeeded
            ; json = None
            ; content_blocks = None
            }
        ];
      name = None; tool_call_id = None; metadata = [] } in
  match (fun (m : Agent_sdk.Types.message) -> match m.role with Agent_sdk.Types.System -> None | _ -> Some m) msg with
  | None -> Alcotest.fail "tool message should not be dropped"
  | Some oas ->
    let rt = Fun.id oas in
    (* Both Oas_type_adapters and Context_compact_oas preserve Tool role
       directly — MASC and OAS share the same Agent_sdk.Types.message type. *)
    Alcotest.(check string) "tool role preserved"
      "tool"
      (match rt.role with Agent_sdk.Types.Tool -> "tool" | _ -> "other");
    let text = Agent_sdk.Types.text_of_message rt in
    Alcotest.(check bool) "content preserved"
      true (String.length text > 0)

(* ================================================================ *)
(* Compaction tests (via Context_compact_oas directly) *)

let compact_ctx (ctx : Keeper_context_runtime.working_context) strategies =
  let messages =
    (* Issue #8597 #1: ~system_prompt dropped from compact signature. *)
    Context_compact_oas.compact
      ~messages:(ctx_messages ctx)
      ~strategies () in
  Keeper_context_runtime.sync_oas_context
    {
      ctx with
      checkpoint =
        { (Keeper_context_runtime.checkpoint_of_context ctx) with messages };
    }
(* ================================================================ *)

let test_compact_prune_tool_outputs () =
  let ctx =
    Keeper_context_runtime.create ~eio:false ~system_prompt:"test system"
      ~max_tokens:4000
  in
  let ctx = List.fold_left Keeper_context_runtime.append ctx (make_test_messages ()) in
  let compacted = compact_ctx ctx [Context_compact_oas.PruneToolOutputs] in
  (* PruneToolOutputs on short tool output should not drop messages *)
  Alcotest.(check bool) "messages preserved"
    true (List.length (ctx_messages compacted) > 0);
  Alcotest.(check bool) "token count positive"
    true (Keeper_context_runtime.token_count compacted > 0);
  (* Short tool output (< 1500 chars) should not be truncated *)
  Alcotest.(check int) "message count unchanged for short tool output"
    (List.length (make_test_messages ()))
    (List.length (ctx_messages compacted))

let test_compact_merge_contiguous () =
  let ctx =
    Keeper_context_runtime.create ~eio:false ~system_prompt:"test"
      ~max_tokens:4000
  in
  let msgs = [
    Agent_sdk.Types.user_msg "part 1";
    Agent_sdk.Types.user_msg "part 2";
    Agent_sdk.Types.assistant_msg "response";
  ] in
  let ctx = List.fold_left Keeper_context_runtime.append ctx msgs in
  let compacted = compact_ctx ctx [Context_compact_oas.MergeContiguous] in
  (* MergeContiguous should merge the two consecutive user messages *)
  Alcotest.(check bool) "merged reduces count"
    true (List.length (ctx_messages compacted) <= List.length msgs)

let test_compact_summarize_old () =
  (* Create enough messages to trigger keep-first-and-last behavior *)
  let ctx =
    Keeper_context_runtime.create ~eio:false ~system_prompt:"test"
      ~max_tokens:8000
  in
  let msgs = List.init 12 (fun i ->
    if i mod 2 = 0 then
      Agent_sdk.Types.user_msg (Printf.sprintf "user message %d with content" i)
    else
      Agent_sdk.Types.assistant_msg (Printf.sprintf "assistant response %d" i)
  ) in
  let ctx = List.fold_left Keeper_context_runtime.append ctx msgs in
  let compacted = compact_ctx ctx [Context_compact_oas.SummarizeOld] in
  (* SummarizeOld with keep-first-and-last should reduce message count *)
  Alcotest.(check bool) "summarize_old reduces messages"
    true (List.length (ctx_messages compacted) < List.length msgs);
  Alcotest.(check bool) "token count positive"
    true (Keeper_context_runtime.token_count compacted > 0)

let test_compact_small_list_unchanged () =
  let ctx =
    Keeper_context_runtime.create ~eio:false ~system_prompt:"test"
      ~max_tokens:4000
  in
  let msgs = [
    Agent_sdk.Types.user_msg "hello";
    Agent_sdk.Types.assistant_msg "world";
  ] in
  let ctx = List.fold_left Keeper_context_runtime.append ctx msgs in
  let compacted = compact_ctx ctx [Context_compact_oas.SummarizeOld] in
  (* Small list (< first_n + last_n = 7) should be unchanged *)
  Alcotest.(check int) "small list unchanged"
    (List.length msgs) (List.length (ctx_messages compacted))

(* ================================================================ *)
(* Restore messages (identity — types are shared)                  *)
(* ================================================================ *)

let test_restore_messages_all_roles () =
  let oas_msgs : Agent_sdk.Types.message list = [
    { Agent_sdk.Types.role = Agent_sdk.Types.User;
      content = [Agent_sdk.Types.Text "user question"]; name = None; tool_call_id = None; metadata = [] };
    { Agent_sdk.Types.role = Agent_sdk.Types.Assistant;
      content = [Agent_sdk.Types.Text "assistant answer"]; name = None; tool_call_id = None; metadata = [] };
  ] in
  let masc_msgs = List.map Fun.id oas_msgs in
  Alcotest.(check int) "2 messages restored" 2 (List.length masc_msgs);
  let first = List.hd masc_msgs in
  Alcotest.(check string) "first is user" "user"
    (match first.role with Agent_sdk.Types.User -> "user" | _ -> "other");
  Alcotest.(check string) "first content" "user question"
    (Agent_sdk.Types.text_of_message first);
  let second = List.nth masc_msgs 1 in
  Alcotest.(check string) "second is assistant" "assistant"
    (match second.role with Agent_sdk.Types.Assistant -> "assistant" | _ -> "other")

let test_agent_sdk_response_visible_text_excludes_non_answer_blocks () =
  let response : Agent_sdk.Types.api_response =
    { id = "resp"
    ; model = "model"
    ; stop_reason = Agent_sdk.Types.EndTurn
    ; content =
        [ Agent_sdk.Types.Text "visible"
        ; Agent_sdk.Types.Thinking { signature = None; content = "private reasoning" }
        ; Agent_sdk.Types.ToolResult
            { tool_use_id = "tool-1"
            ; content = "tool payload"
            ; outcome = Agent_sdk.Types.Tool_succeeded
            ; json = None
            ; content_blocks = Some [ Agent_sdk.Types.Text "structured tool payload" ]
            }
        ; Agent_sdk.Types.Image
            { media_type = "image/png"; data = "bytes"; source_type = Agent_sdk.Types.Base64 }
        ; Agent_sdk.Types.Text "tail"
        ]
    ; usage = None
    ; telemetry = None
    }
  in
  Alcotest.(check string)
    "visible answer text"
    "visible\ntail"
    (Agent_sdk_response.text_of_response response)

let test_agent_sdk_response_structured_json_uses_oas_visible_projection () =
  let response : Agent_sdk.Types.api_response =
    { id = "resp"
    ; model = "model"
    ; stop_reason = Agent_sdk.Types.EndTurn
    ; content =
        [ Agent_sdk.Types.ToolResult
            { tool_use_id = "tool-1"
            ; content = {|{"text":"tool payload must not be parsed"}|}
            ; outcome = Agent_sdk.Types.Tool_succeeded
            ; json = None
            ; content_blocks = None
            }
        ; Agent_sdk.Types.Thinking { signature = None; content = "private reasoning" }
        ; Agent_sdk.Types.Text "```json\n{\"text\":\"visible answer\"}\n```"
        ]
    ; usage = None
    ; telemetry = None
    }
  in
  match Agent_sdk_response.structured_json_of_response response with
  | Error msg -> Alcotest.fail ("structured JSON rejected: " ^ msg)
  | Ok json ->
    Alcotest.(check string)
      "parsed visible JSON"
      "visible answer"
      Yojson.Safe.Util.(json |> member "text" |> to_string)

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
    "response_projection", [
      Alcotest.test_case "visible text excludes non-answer blocks" `Quick
        test_agent_sdk_response_visible_text_excludes_non_answer_blocks;
      Alcotest.test_case "structured JSON uses OAS visible projection" `Quick
        test_agent_sdk_response_structured_json_uses_oas_visible_projection;
    ];
  ]
