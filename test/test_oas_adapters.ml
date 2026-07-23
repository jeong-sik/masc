(** Tests for OAS shared message types and response projections. *)

open Masc

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
    (* MASC and OAS share the same Agent_sdk.Types.message type. *)
    Alcotest.(check string) "tool role preserved"
      "tool"
      (match rt.role with Agent_sdk.Types.Tool -> "tool" | _ -> "other");
    let text = Agent_sdk.Types.text_of_message rt in
    Alcotest.(check bool) "content preserved"
      true (String.length text > 0)

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
