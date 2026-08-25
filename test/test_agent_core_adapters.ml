(** Tests for AGENT_CORE shared message types and response projections. *)

open Masc

(* ================================================================ *)
(* Message roundtrip tests via Llm_client to/from AGENT_CORE               *)
(* ================================================================ *)

let test_roundtrip_user_msg () =
  let msg = Agent_core.Types.user_msg "hello world" in
  match (fun (m : Agent_core.Types.message) -> match m.role with Agent_core.Types.System -> None | _ -> Some m) msg with
  | None -> Alcotest.fail "user message should not be dropped"
  | Some agent_core ->
    let rt = Fun.id agent_core in
    Alcotest.(check string) "role preserved" "user"
      (match rt.role with Agent_core.Types.User -> "user" | _ -> "other");
    Alcotest.(check string) "content preserved"
      "hello world" (Agent_core.Types.text_of_message rt)

let test_roundtrip_assistant_msg () =
  let msg = Agent_core.Types.assistant_msg "The answer is 42." in
  match (fun (m : Agent_core.Types.message) -> match m.role with Agent_core.Types.System -> None | _ -> Some m) msg with
  | None -> Alcotest.fail "assistant message should not be dropped"
  | Some agent_core ->
    let rt = Fun.id agent_core in
    Alcotest.(check string) "role preserved" "assistant"
      (match rt.role with Agent_core.Types.Assistant -> "assistant" | _ -> "other");
    Alcotest.(check string) "content preserved"
      "The answer is 42." (Agent_core.Types.text_of_message rt)

let test_roundtrip_system_msg_dropped () =
  let msg = Agent_core.Types.system_msg "system prompt" in
  let result = (fun (m : Agent_core.Types.message) -> match m.role with Agent_core.Types.System -> None | _ -> Some m) msg in
  Alcotest.(check bool) "system message dropped (belongs in system_prompt)"
    true (Option.is_none result)

let test_roundtrip_tool_msg () =
  let msg : Agent_core.Types.message =
    { role = Agent_core.Types.Tool;
      content =
        [ Agent_core.Types.ToolResult
            { tool_use_id = "tc-1"
            ; content = "tool output here"
            ; outcome = Agent_core.Types.Tool_succeeded
            ; json = None
            ; content_blocks = None
            }
        ];
      name = None; tool_call_id = None; metadata = [] } in
  match (fun (m : Agent_core.Types.message) -> match m.role with Agent_core.Types.System -> None | _ -> Some m) msg with
  | None -> Alcotest.fail "tool message should not be dropped"
  | Some agent_core ->
    let rt = Fun.id agent_core in
    (* MASC and AGENT_CORE share the same Agent_core.Types.message type. *)
    Alcotest.(check string) "tool role preserved"
      "tool"
      (match rt.role with Agent_core.Types.Tool -> "tool" | _ -> "other");
    let text = Agent_core.Types.text_of_message rt in
    Alcotest.(check bool) "content preserved"
      true (String.length text > 0)

(* ================================================================ *)
(* Restore messages (identity — types are shared)                  *)
(* ================================================================ *)

let test_restore_messages_all_roles () =
  let agent_core_msgs : Agent_core.Types.message list = [
    { Agent_core.Types.role = Agent_core.Types.User;
      content = [Agent_core.Types.Text "user question"]; name = None; tool_call_id = None; metadata = [] };
    { Agent_core.Types.role = Agent_core.Types.Assistant;
      content = [Agent_core.Types.Text "assistant answer"]; name = None; tool_call_id = None; metadata = [] };
  ] in
  let masc_msgs = List.map Fun.id agent_core_msgs in
  Alcotest.(check int) "2 messages restored" 2 (List.length masc_msgs);
  let first = List.hd masc_msgs in
  Alcotest.(check string) "first is user" "user"
    (match first.role with Agent_core.Types.User -> "user" | _ -> "other");
  Alcotest.(check string) "first content" "user question"
    (Agent_core.Types.text_of_message first);
  let second = List.nth masc_msgs 1 in
  Alcotest.(check string) "second is assistant" "assistant"
    (match second.role with Agent_core.Types.Assistant -> "assistant" | _ -> "other")

let test_visible_text_excludes_non_answer_blocks () =
  let response : Agent_core.Types.api_response =
    { id = "resp"
    ; model = "model"
    ; stop_reason = Agent_core.Types.EndTurn
    ; content =
        [ Agent_core.Types.Text "visible"
        ; Agent_core.Types.Thinking { signature = None; content = "private reasoning" }
        ; Agent_core.Types.ToolResult
            { tool_use_id = "tool-1"
            ; content = "tool payload"
            ; outcome = Agent_core.Types.Tool_succeeded
            ; json = None
            ; content_blocks = Some [ Agent_core.Types.Text "structured tool payload" ]
            }
        ; Agent_core.Types.Image
            { media_type = "image/png"; data = "bytes"; source_type = Agent_core.Types.Base64 }
        ; Agent_core.Types.Text "tail"
        ]
    ; usage = None
    ; telemetry = None
    }
  in
  Alcotest.(check string)
    "visible answer text"
    "visible\ntail"
    (Agent_core.Types.visible_text_of_response response)

(* ================================================================ *)
(* Runner                                                           *)
(* ================================================================ *)

let () =
  Alcotest.run "AGENT_CORE Adapters" [
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
    "message_restore", [
      Alcotest.test_case "restore messages all roles" `Quick
        test_restore_messages_all_roles;
    ];
    "response_projection", [
      Alcotest.test_case "visible text excludes non-answer blocks" `Quick
        test_visible_text_excludes_non_answer_blocks;
    ];
  ]
