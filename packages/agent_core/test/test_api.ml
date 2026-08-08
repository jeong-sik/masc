(** Tests for the live re-exports formerly reached through the api.ml facade:
    content block JSON round-trips, Anthropic/OpenAI response parsing,
    message_to_json, SSE event parsing, and the api_common string helpers. *)

open Alcotest
open Agent_sdk

let rec find_repo_root dir =
  if Sys.file_exists (Filename.concat dir "dune-project")
  then dir
  else (
    let parent = Filename.dirname dir in
    if String.equal parent dir
    then fail "could not locate dune-project"
    else find_repo_root parent)
;;

let source_path path =
  if Filename.is_relative path
  then (
    match Sys.getenv_opt "DUNE_SOURCEROOT" with
    | Some root -> Filename.concat root path
    | None -> Filename.concat (find_repo_root (Sys.getcwd ())) path)
  else path
;;

let install_repo_model_catalog () =
  let path = source_path "models.toml" in
  match Llm_provider.Model_catalog.load_file path with
  | Ok catalog -> Llm_provider.Model_catalog.set_global catalog
  | Error message -> fail (Printf.sprintf "failed to load %s: %s" path message)
;;

(* Helper: compare content_block via show string *)
let check_block msg expected actual =
  check string msg (Types.show_content_block expected) (Types.show_content_block actual)
;;

(* ------------------------------------------------------------------ *)
(* content_block_to_json / content_block_of_json round-trips            *)
(* ------------------------------------------------------------------ *)

let test_text_round_trip () =
  let block = Types.Text "hello world" in
  let json = Llm_provider.Api_common.content_block_to_json block in
  match Llm_provider.Api_common.content_block_of_json json with
  | Some parsed -> check_block "text" block parsed
  | None -> fail "returned None"
;;

let test_thinking_round_trip () =
  let block =
    Types.Thinking { signature = Some "sig123"; content = "I think therefore I am" }
  in
  let json = Llm_provider.Api_common.content_block_to_json block in
  match Llm_provider.Api_common.content_block_of_json json with
  | Some parsed -> check_block "thinking" block parsed
  | None -> fail "returned None"
;;

let test_redacted_thinking_round_trip () =
  let block = Types.RedactedThinking "redacted_data_blob" in
  let json = Llm_provider.Api_common.content_block_to_json block in
  match Llm_provider.Api_common.content_block_of_json json with
  | Some parsed -> check_block "redacted_thinking" block parsed
  | None -> fail "returned None"
;;

let test_tool_use_round_trip () =
  let block =
    Types.ToolUse
      { id = "tu_001"; name = "calculator"; input = `Assoc [ "expr", `String "2+2" ] }
  in
  let json = Llm_provider.Api_common.content_block_to_json block in
  match Llm_provider.Api_common.content_block_of_json json with
  | Some parsed -> check_block "tool_use" block parsed
  | None -> fail "returned None"
;;

let test_tool_result_round_trip () =
  let block =
    Types.ToolResult
      { tool_use_id = "tu_001"
      ; content = "4"
      ; outcome = Tool_succeeded
      ; json = Types.try_parse_json "4"
      ; content_blocks = None
      }
  in
  let json = Llm_provider.Api_common.content_block_to_json block in
  match Llm_provider.Api_common.content_block_of_json json with
  | Some parsed -> check_block "tool_result" block parsed
  | None -> fail "returned None"
;;

let test_tool_result_error_round_trip () =
  let block =
    Types.ToolResult
      { tool_use_id = "tu_002"
      ; content = "failed"
      ; outcome = Tool_failed { failure_kind = Reported_tool_error; error_class = None }
      ; json = None
      ; content_blocks = None
      }
  in
  let json = Llm_provider.Api_common.content_block_to_json block in
  match Llm_provider.Api_common.content_block_of_json json with
  | Some parsed -> check_block "tool_result_error" block parsed
  | None -> fail "returned None"
;;

let test_image_round_trip () =
  let block =
    Types.Image { media_type = "image/png"; data = "abc"; source_type = Types.Base64 }
  in
  let json = Llm_provider.Api_common.content_block_to_json block in
  match Llm_provider.Api_common.content_block_of_json json with
  | Some parsed -> check_block "image" block parsed
  | None -> fail "returned None"
;;

let test_document_round_trip () =
  let block =
    Types.Document
      { media_type = "application/pdf"; data = "pdf"; source_type = Types.Base64 }
  in
  let json = Llm_provider.Api_common.content_block_to_json block in
  match Llm_provider.Api_common.content_block_of_json json with
  | Some parsed -> check_block "document" block parsed
  | None -> fail "returned None"
;;

let test_unknown_type_returns_none () =
  let json = `Assoc [ "type", `String "future_block"; "data", `String "x" ] in
  match Llm_provider.Api_common.content_block_of_json json with
  | None -> ()
  | Some _ -> fail "expected None for unknown type"
;;

let test_reasoning_details_requires_details_list () =
  let cases =
    [ `Assoc [ "type", `String "reasoning_details" ]
    ; `Assoc [ "type", `String "reasoning_details"; "details", `Null ]
    ]
  in
  List.iter
    (fun json ->
       match Llm_provider.Api_common.content_block_of_json json with
       | None -> ()
       | Some _ -> fail "expected malformed reasoning_details to fail closed")
    cases
;;

let test_kimi_message_to_json_tool_result_uses_text_blocks () =
  let msg =
    { Types.role = Tool
    ; content =
        [ Types.ToolResult
            { tool_use_id = "tu_001"
            ; content = "5"
            ; outcome = Tool_succeeded
            ; json = Some (`Int 5)
            ; content_blocks = None
            }
        ]
    ; name = None
    ; tool_call_id = None
    ; metadata = []
    }
  in
  let json = Llm_provider.Api_common.kimi_message_to_json msg in
  let open Yojson.Safe.Util in
  let block = json |> member "content" |> index 0 in
  let nested = block |> member "content" |> to_list in
  check string "role serialized as user" "user" (json |> member "role" |> to_string);
  check string "tool_result type" "tool_result" (block |> member "type" |> to_string);
  check string "tool_use_id" "tu_001" (block |> member "tool_use_id" |> to_string);
  check int "nested content count" 1 (List.length nested);
  check
    string
    "nested text block type"
    "text"
    (List.hd nested |> member "type" |> to_string);
  check string "nested text block text" "5" (List.hd nested |> member "text" |> to_string)
;;

(* ------------------------------------------------------------------ *)
(* parse_response                                                       *)
(* ------------------------------------------------------------------ *)

let test_parse_response_complete () =
  let json =
    Yojson.Safe.from_string
      {|{
    "id": "msg_test",
    "model": "claude-sonnet-4-6-20250514",
    "stop_reason": "end_turn",
    "content": [
      {"type": "text", "text": "Hello there."},
      {"type": "thinking", "signature": "sig", "thinking": "Let me think..."}
    ],
    "usage": {"input_tokens": 100, "output_tokens": 50}
  }|}
  in
  let resp = Llm_provider.Backend_anthropic.parse_response json in
  check string "id" "msg_test" resp.id;
  check string "model" "claude-sonnet-4-6-20250514" resp.model;
  check int "content count" 2 (List.length resp.content);
  (match resp.stop_reason with
   | Types.EndTurn -> ()
   | sr -> fail (Printf.sprintf "expected EndTurn, got %s" (Types.show_stop_reason sr)));
  match resp.usage with
  | Some u when u.Types.input_tokens = 100 && u.output_tokens = 50 -> ()
  | _ -> fail "expected usage input=100 output=50"
;;

let test_parse_response_tool_use () =
  let json =
    Yojson.Safe.from_string
      {|{
    "id": "msg_tu",
    "model": "claude-sonnet-4-6-20250514",
    "stop_reason": "tool_use",
    "content": [
      {"type": "tool_use", "id": "tu_1", "name": "calc", "input": {"x": 1}}
    ],
    "usage": null
  }|}
  in
  let resp = Llm_provider.Backend_anthropic.parse_response json in
  (match resp.stop_reason with
   | Types.StopToolUse -> ()
   | sr ->
     fail (Printf.sprintf "expected StopToolUse, got %s" (Types.show_stop_reason sr)));
  check bool "usage is None" true (resp.usage = None);
  match resp.content with
  | [ Types.ToolUse { id = "tu_1"; name = "calc"; _ } ] -> ()
  | _ -> fail "expected single ToolUse"
;;

let test_parse_response_unknown_stop () =
  let json =
    Yojson.Safe.from_string
      {|{
    "id": "msg_unk",
    "model": "claude-sonnet-4-6-20250514",
    "stop_reason": "new_future_reason",
    "content": [],
    "usage": null
  }|}
  in
  let resp = Llm_provider.Backend_anthropic.parse_response json in
  match resp.stop_reason with
  | Types.Unknown "new_future_reason" -> ()
  | sr -> fail (Printf.sprintf "expected Unknown, got %s" (Types.show_stop_reason sr))
;;

let test_parse_openai_response_preserves_fenced_json () =
  let json_str =
    {|{
    "id": "chatcmpl_test",
    "model": "dashscope",
    "choices": [{
      "finish_reason": "stop",
      "index": 0,
      "message": {
        "role": "assistant",
        "content": "```json\n{\"engine\":\"default\",\"tool_calling\":false}\n```"
      }
    }]
  }|}
  in
  match Llm_provider.Backend_openai_parse.parse_openai_response_result json_str with
  | Error msg ->
    Alcotest.fail
      ("unexpected error: " ^ Llm_provider.Backend_openai_parse.parse_error_to_string msg)
  | Ok resp ->
    (match resp.content with
     | [ Types.Text text ] ->
       Alcotest.(check string)
         "fenced JSON preserved"
         "```json\n{\"engine\":\"default\",\"tool_calling\":false}\n```"
         text
     | _ -> Alcotest.fail "expected raw fenced text block")
;;

let test_parse_openai_response_reasoning_content () =
  let json_str =
    {|{
    "id": "chatcmpl_think",
    "model": "dashscope-3.5-35b",
    "choices": [{
      "finish_reason": "stop",
      "index": 0,
      "message": {
        "role": "assistant",
        "content": "The answer is 42.",
        "reasoning_content": "Let me think step by step about the meaning of life."
      }
    }],
    "usage": {"prompt_tokens": 10, "completion_tokens": 20, "total_tokens": 30}
  }|}
  in
  match Llm_provider.Backend_openai_parse.parse_openai_response_result json_str with
  | Error msg ->
    Alcotest.fail
      ("unexpected error: " ^ Llm_provider.Backend_openai_parse.parse_error_to_string msg)
  | Ok resp ->
    check int "2 content blocks" 2 (List.length resp.content);
    (match resp.content with
     | [ Types.Thinking { signature; content }; Types.Text text ] ->
       check bool "thinking unsigned" true (signature = None);
       check
         string
         "thinking content"
         "Let me think step by step about the meaning of life."
         content;
       check string "text" "The answer is 42." text
     | _ -> Alcotest.fail "expected [Thinking; Text]")
;;

let test_parse_openai_response_reasoning_with_tools () =
  let json_str =
    {|{
    "id": "chatcmpl_think_tool",
    "model": "dashscope-3.5-35b",
    "choices": [{
      "finish_reason": "tool_calls",
      "index": 0,
      "message": {
        "role": "assistant",
        "content": null,
        "reasoning_content": "I need to call the calculator.",
        "tool_calls": [{
          "id": "call_1",
          "type": "function",
          "function": { "name": "calc", "arguments": "{\"expr\":\"2+2\"}" }
        }]
      }
    }]
  }|}
  in
  match Llm_provider.Backend_openai_parse.parse_openai_response_result json_str with
  | Error msg ->
    Alcotest.fail
      ("unexpected error: " ^ Llm_provider.Backend_openai_parse.parse_error_to_string msg)
  | Ok resp ->
    check int "2 content blocks" 2 (List.length resp.content);
    (match resp.content with
     | [ Types.Thinking { content; _ }; Types.ToolUse { name; _ } ] ->
       check string "thinking" "I need to call the calculator." content;
       check string "tool name" "calc" name
     | _ -> Alcotest.fail "expected [Thinking; ToolUse]");
    (match resp.stop_reason with
     | Types.StopToolUse -> ()
     | sr ->
       Alcotest.fail
         (Printf.sprintf "expected StopToolUse, got %s" (Types.show_stop_reason sr)))
;;

let test_parse_openai_response_blank_reasoning () =
  let json_str =
    {|{
    "id": "chatcmpl_blank",
    "model": "dashscope-3.5-35b",
    "choices": [{
      "finish_reason": "stop",
      "index": 0,
      "message": {
        "role": "assistant",
        "content": "Just text",
        "reasoning_content": "   "
      }
    }]
  }|}
  in
  match Llm_provider.Backend_openai_parse.parse_openai_response_result json_str with
  | Error msg ->
    Alcotest.fail
      ("unexpected error: " ^ Llm_provider.Backend_openai_parse.parse_error_to_string msg)
  | Ok resp ->
    check int "1 content block (blank reasoning filtered)" 1 (List.length resp.content);
    (match resp.content with
     | [ Types.Text "Just text" ] -> ()
     | _ -> Alcotest.fail "expected [Text] only, blank reasoning should be filtered")
;;

let test_parse_openai_response_no_reasoning () =
  let json_str =
    {|{
    "id": "chatcmpl_no_think",
    "model": "dashscope-3.5-35b",
    "choices": [{
      "finish_reason": "stop",
      "index": 0,
      "message": {
        "role": "assistant",
        "content": "Hello world"
      }
    }]
  }|}
  in
  match Llm_provider.Backend_openai_parse.parse_openai_response_result json_str with
  | Error msg ->
    Alcotest.fail
      ("unexpected error: " ^ Llm_provider.Backend_openai_parse.parse_error_to_string msg)
  | Ok resp ->
    check int "1 content block" 1 (List.length resp.content);
    (match resp.content with
     | [ Types.Text "Hello world" ] -> ()
     | _ -> Alcotest.fail "expected [Text]")
;;

let test_parse_openai_response_ollama_reasoning () =
  let json_str =
    {|{
    "id": "chatcmpl_ollama",
    "model": "dashscope-3.5:35b-a3b-nvfp4",
    "choices": [{
      "finish_reason": "stop",
      "index": 0,
      "message": {
        "role": "assistant",
        "content": "The answer is 42.",
        "reasoning": "Ollama uses reasoning field instead of reasoning_content."
      }
    }],
    "usage": {"prompt_tokens": 10, "completion_tokens": 20, "total_tokens": 30}
  }|}
  in
  match Llm_provider.Backend_openai_parse.parse_openai_response_result json_str with
  | Error msg ->
    Alcotest.fail
      ("unexpected error: " ^ Llm_provider.Backend_openai_parse.parse_error_to_string msg)
  | Ok resp ->
    check int "2 content blocks (thinking + text)" 2 (List.length resp.content);
    (match resp.content with
     | [ Types.Thinking { content = t; _ }; Types.Text text ] ->
       check
         string
         "reasoning text"
         "Ollama uses reasoning field instead of reasoning_content."
         t;
       check string "content text" "The answer is 42." text;
       (* Token accounting is observation-only: without a provider-reported
          count OAS must not estimate one from text length. *)
       (match resp.telemetry with
        | Some tel ->
          check (option int) "reasoning_tokens absent" None tel.reasoning_tokens
        | None -> Alcotest.fail "telemetry should be present")
     | _ -> Alcotest.fail "expected [Thinking; Text]")
;;

let test_parse_openai_response_reasoning_content_preferred () =
  let json_str =
    {|{
    "id": "chatcmpl_both",
    "model": "dashscope-3.5-35b",
    "choices": [{
      "finish_reason": "stop",
      "index": 0,
      "message": {
        "role": "assistant",
        "content": "Answer.",
        "reasoning_content": "preferred field",
        "reasoning": "fallback field"
      }
    }],
    "usage": {"prompt_tokens": 5, "completion_tokens": 5, "total_tokens": 10}
  }|}
  in
  match Llm_provider.Backend_openai_parse.parse_openai_response_result json_str with
  | Error msg ->
    Alcotest.fail
      ("unexpected error: " ^ Llm_provider.Backend_openai_parse.parse_error_to_string msg)
  | Ok resp ->
    (match resp.content with
     | [ Types.Thinking { content = t; _ }; Types.Text text ] ->
       check string "reasoning_content wins" "preferred field" t;
       check string "content text" "Answer." text;
       (* Text shape does not synthesize token counts. *)
       (match resp.telemetry with
        | Some tel ->
          check (option int) "reasoning_tokens absent" None tel.reasoning_tokens
        | None -> Alcotest.fail "telemetry should be present")
     | _ -> Alcotest.fail "expected [Thinking; Text]")
;;

(* ------------------------------------------------------------------ *)
(* message_to_json                                                      *)
(* ------------------------------------------------------------------ *)

let test_message_to_json () =
  let msg =
    { Types.role = Types.User
    ; content = [ Types.Text "hi" ]
    ; name = None
    ; tool_call_id = None
    ; metadata = []
    }
  in
  let json = Llm_provider.Api_common.message_to_json msg in
  let open Yojson.Safe.Util in
  check string "role" "user" (json |> member "role" |> to_string);
  let content = json |> member "content" |> to_list in
  check int "1 block" 1 (List.length content)
;;

let test_message_to_json_ignores_metadata () =
  let msg =
    { Types.role = Types.Assistant
    ; content = [ Types.Text "visible" ]
    ; name = Some "assistant"
    ; tool_call_id = Some "call_1"
    ; metadata =
        [ ( "replay.namespace"
          , `Assoc
              [ "kind", `String "state_snapshot"
              ; "version", `Int 1
              ; "payload", `Assoc [ "goal", `String "finish" ]
              ] )
        ]
    }
  in
  let json = Llm_provider.Api_common.message_to_json msg in
  let open Yojson.Safe.Util in
  let assoc = to_assoc json in
  check
    bool
    "metadata omitted from provider payload"
    false
    (List.mem_assoc "metadata" assoc);
  check
    string
    "text still serialized"
    "visible"
    (json |> member "content" |> index 0 |> member "text" |> to_string)
;;

(* ------------------------------------------------------------------ *)
(* parse_response: cache tokens in usage                               *)
(* ------------------------------------------------------------------ *)

let test_parse_response_with_cache_tokens () =
  let json =
    Yojson.Safe.from_string
      {|{
    "id": "msg_cache",
    "model": "claude-sonnet-4-6-20250514",
    "stop_reason": "end_turn",
    "content": [{"type": "text", "text": "cached"}],
    "usage": {
      "input_tokens": 50,
      "output_tokens": 25,
      "cache_creation_input_tokens": 1000,
      "cache_read_input_tokens": 800
    }
  }|}
  in
  let resp = Llm_provider.Backend_anthropic.parse_response json in
  match resp.usage with
  | Some u ->
    check int "input" 50 u.Types.input_tokens;
    check int "output" 25 u.output_tokens;
    check int "cache_creation" 1000 u.cache_creation_input_tokens;
    check int "cache_read" 800 u.cache_read_input_tokens
  | None -> fail "expected usage"
;;

(* ------------------------------------------------------------------ *)
(* parse_sse_event                                                      *)
(* ------------------------------------------------------------------ *)

let test_parse_sse_message_start () =
  let data =
    {|{"message":{"id":"msg_1","model":"claude-sonnet-4-6","usage":{"input_tokens":10}}}|}
  in
  match Llm_provider.Streaming.parse_sse_event (Some "message_start") data with
  | Some (Types.MessageStart { id; model; usage }) ->
    check string "id" "msg_1" id;
    check string "model" "claude-sonnet-4-6" model;
    (match usage with
     | Some u -> check int "input" 10 u.Types.input_tokens
     | None -> fail "expected usage")
  | _ -> fail "expected MessageStart"
;;

let test_parse_sse_content_block_delta_text () =
  let data = {|{"index":0,"delta":{"type":"text_delta","text":"hello"}}|} in
  match Llm_provider.Streaming.parse_sse_event (Some "content_block_delta") data with
  | Some (Types.ContentBlockDelta { index; delta = Types.TextDelta t }) ->
    check int "index" 0 index;
    check string "text" "hello" t
  | _ -> fail "expected ContentBlockDelta TextDelta"
;;

let test_parse_sse_content_block_delta_thinking () =
  let data = {|{"index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}|} in
  match Llm_provider.Streaming.parse_sse_event (Some "content_block_delta") data with
  | Some (Types.ContentBlockDelta { delta = Types.ThinkingDelta t; _ }) ->
    check string "thinking" "hmm" t
  | _ -> fail "expected ThinkingDelta"
;;

let test_parse_sse_content_block_delta_input_json () =
  let data =
    {|{"index":1,"delta":{"type":"input_json_delta","partial_json":"{\"x\":1"}}|}
  in
  match Llm_provider.Streaming.parse_sse_event (Some "content_block_delta") data with
  | Some (Types.ContentBlockDelta { delta = Types.InputJsonDelta j; _ }) ->
    check string "partial json" {|{"x":1|} j
  | _ -> fail "expected InputJsonDelta"
;;

let test_parse_sse_content_block_start () =
  let data =
    {|{"index":0,"content_block":{"type":"tool_use","id":"tu_1","name":"calc"}}|}
  in
  match Llm_provider.Streaming.parse_sse_event (Some "content_block_start") data with
  | Some (Types.ContentBlockStart { index; content_type; tool_id; tool_name }) ->
    check int "index" 0 index;
    check string "type" "tool_use" content_type;
    check (option string) "tool_id" (Some "tu_1") tool_id;
    check (option string) "tool_name" (Some "calc") tool_name
  | _ -> fail "expected ContentBlockStart"
;;

let test_parse_sse_message_delta () =
  let data = {|{"delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":42}}|} in
  match Llm_provider.Streaming.parse_sse_event (Some "message_delta") data with
  | Some (Types.MessageDelta { stop_reason; usage }) ->
    (match stop_reason with
     | Some Types.EndTurn -> ()
     | _ -> fail "expected EndTurn");
    (match usage with
     | Some u -> check int "output" 42 u.Types.output_tokens
     | None -> fail "expected usage")
  | _ -> fail "expected MessageDelta"
;;

let test_parse_sse_message_stop () =
  match Llm_provider.Streaming.parse_sse_event (Some "message_stop") "{}" with
  | Some Types.MessageStop -> ()
  | _ -> fail "expected MessageStop"
;;

let test_parse_sse_ping () =
  match Llm_provider.Streaming.parse_sse_event (Some "ping") "{}" with
  | Some Types.Ping -> ()
  | _ -> fail "expected Ping"
;;

let test_parse_sse_error () =
  let data = {|{"error":{"message":"rate limited","type":"rate_limit_exceeded"}}|} in
  match Llm_provider.Streaming.parse_sse_event (Some "error") data with
  | Some (Types.SSEError { message; error_type; _ }) ->
    check string "error msg" "rate limited" message;
    check (option string) "error type" (Some "rate_limit_exceeded") error_type
  | _ -> fail "expected SSEError"
;;

let test_parse_sse_unknown_type () =
  match Llm_provider.Streaming.parse_sse_event (Some "future_event") "{}" with
  | Some (Types.SSEUnknownEventType { event_type; raw }) ->
    check string "event_type" "future_event" event_type;
    check string "raw" "{}" raw
  | _ -> fail "expected SSEUnknownEventType for unknown type"
;;

let test_parse_sse_malformed_json () =
  match Llm_provider.Streaming.parse_sse_event (Some "message_start") "not json" with
  | Some (Types.SSEParseFailed { raw; reason }) ->
    check string "raw" "not json" raw;
    check bool "reason present" true (String.length reason > 0)
  | _ -> fail "expected SSEParseFailed for malformed JSON"
;;

(* ------------------------------------------------------------------ *)
(* message_to_json: assistant + mixed content                           *)
(* ------------------------------------------------------------------ *)

let test_message_to_json_assistant () =
  let msg =
    { Types.role = Types.Assistant
    ; content =
        [ Types.Text "hi"; Types.ToolUse { id = "t1"; name = "calc"; input = `Null } ]
    ; name = None
    ; tool_call_id = None
    ; metadata = []
    }
  in
  let json = Llm_provider.Api_common.message_to_json msg in
  let open Yojson.Safe.Util in
  check string "role" "assistant" (json |> member "role" |> to_string);
  let content = json |> member "content" |> to_list in
  check int "2 blocks" 2 (List.length content)
;;

(* ------------------------------------------------------------------ *)
(* openai_messages_of_message: multimodal user content                  *)
(* ------------------------------------------------------------------ *)

let test_openai_messages_text_only () =
  let msg =
    { Types.role = Types.User
    ; content = [ Types.Text "hello" ]
    ; name = None
    ; tool_call_id = None
    ; metadata = []
    }
  in
  let msgs = Llm_provider.Backend_openai.openai_messages_of_message msg in
  check int "1 message" 1 (List.length msgs);
  let open Yojson.Safe.Util in
  let content = List.hd msgs |> member "content" in
  (* text-only should be a plain string, not an array *)
  check string "plain string" "hello" (to_string content)
;;

let test_openai_messages_with_image () =
  let msg =
    { Types.role = Types.User
    ; content =
        [ Types.Text "describe this"
        ; Types.Image
            { media_type = "image/png"; data = "abc123"; source_type = Types.Base64 }
        ]
    ; name = None
    ; tool_call_id = None
    ; metadata = []
    }
  in
  let msgs = Llm_provider.Backend_openai.openai_messages_of_message msg in
  check int "1 message" 1 (List.length msgs);
  let open Yojson.Safe.Util in
  let content = List.hd msgs |> member "content" |> to_list in
  check int "2 content parts" 2 (List.length content);
  let first_type = List.nth content 0 |> member "type" |> to_string in
  let second_type = List.nth content 1 |> member "type" |> to_string in
  check string "text part" "text" first_type;
  check string "image part" "image_url" second_type
;;

(* ------------------------------------------------------------------ *)
(* F1: Openai API error → Openai_api_error exception                    *)
(* ------------------------------------------------------------------ *)

let test_openai_api_error_returns_error () =
  let error_json =
    {|{"error":{"message":"Invalid API key","type":"invalid_request_error"}}|}
  in
  match Llm_provider.Backend_openai_parse.parse_openai_response_result error_json with
  | Error msg ->
    check
      string
      "error message"
      "Invalid API key"
      (Llm_provider.Backend_openai_parse.parse_error_to_string msg)
  | Ok _ -> Alcotest.fail "expected Error on API error"
;;

let test_openai_api_error_unknown_message () =
  let error_json = {|{"error":{}}|} in
  match Llm_provider.Backend_openai_parse.parse_openai_response_result error_json with
  | Error msg ->
    check
      string
      "unknown error"
      "Unknown API error"
      (Llm_provider.Backend_openai_parse.parse_error_to_string msg)
  | Ok _ -> Alcotest.fail "expected Error on empty error"
;;

(* ------------------------------------------------------------------ *)
(* F2: Openai error returns structured Error, not exception              *)
(* ------------------------------------------------------------------ *)

let test_openai_error_returns_result () =
  let error_json = {|{"error":{"message":"bad request"}}|} in
  match Llm_provider.Backend_openai_parse.parse_openai_response_result error_json with
  | Error msg ->
    check
      string
      "error (Llm_provider.Backend_openai_parse.parse_error_to_string msg)"
      "bad request"
      (Llm_provider.Backend_openai_parse.parse_error_to_string msg)
  | Ok _ -> Alcotest.fail "expected Error result"
;;

(* ------------------------------------------------------------------ *)
(* Phase 6: additional api_common helpers                               *)
(* ------------------------------------------------------------------ *)

let test_text_blocks_to_string () =
  let blocks =
    [ Types.Text "hello"
    ; Types.Thinking { signature = Some "s"; content = "hmm" }
    ; Types.RedactedThinking "r"
    ; Types.ToolUse { id = "t"; name = "n"; input = `Null }
    ; Types.ToolResult
        { tool_use_id = "t"
        ; content = "ok"
        ; outcome = Tool_succeeded
        ; json = None
        ; content_blocks = None
        }
    ; Types.Image { media_type = "image/png"; data = ""; source_type = Types.Base64 }
    ; Types.Text "world"
    ]
  in
  let result = Llm_provider.Api_common.text_blocks_to_string blocks in
  check string "text+thinking" "hello\nhmm\nworld" result
;;

let test_string_is_blank () =
  check bool "empty is blank" true (Llm_provider.Api_common.string_is_blank "");
  check bool "spaces is blank" true (Llm_provider.Api_common.string_is_blank "   ");
  check bool "text not blank" false (Llm_provider.Api_common.string_is_blank "hi");
  check bool "tabs blank" true (Llm_provider.Api_common.string_is_blank "\t\n ")
;;

let test_json_of_string_or_raw_valid () =
  let result = Llm_provider.Api_common.json_of_string_or_raw {|{"key":"value"}|} in
  let open Yojson.Safe.Util in
  check string "parsed" "value" (result |> member "key" |> to_string)
;;

let test_json_of_string_or_raw_invalid () =
  let result = Llm_provider.Api_common.json_of_string_or_raw "not json" in
  let open Yojson.Safe.Util in
  check string "fallback raw" "not json" (result |> member "raw" |> to_string)
;;

(* ------------------------------------------------------------------ *)
(* Test runner                                                          *)
(* ------------------------------------------------------------------ *)

let () =
  install_repo_model_catalog ();
  run
    "Api"
    [ ( "content_block_round_trip"
      , [ test_case "text" `Quick test_text_round_trip
        ; test_case "thinking" `Quick test_thinking_round_trip
        ; test_case "redacted_thinking" `Quick test_redacted_thinking_round_trip
        ; test_case "tool_use" `Quick test_tool_use_round_trip
        ; test_case "tool_result" `Quick test_tool_result_round_trip
        ; test_case "tool_result_error" `Quick test_tool_result_error_round_trip
        ; test_case "image" `Quick test_image_round_trip
        ; test_case "document" `Quick test_document_round_trip
        ; test_case "unknown type" `Quick test_unknown_type_returns_none
        ; test_case
            "reasoning_details requires details"
            `Quick
            test_reasoning_details_requires_details_list
        ] )
    ; ( "parse_response"
      , [ test_case "complete response" `Quick test_parse_response_complete
        ; test_case "tool_use response" `Quick test_parse_response_tool_use
        ; test_case "unknown stop_reason" `Quick test_parse_response_unknown_stop
        ; test_case
            "preserve fenced json"
            `Quick
            test_parse_openai_response_preserves_fenced_json
        ; test_case "cache tokens in usage" `Quick test_parse_response_with_cache_tokens
        ; test_case
            "reasoning_content"
            `Quick
            test_parse_openai_response_reasoning_content
        ; test_case
            "reasoning_content with tools"
            `Quick
            test_parse_openai_response_reasoning_with_tools
        ; test_case
            "blank reasoning_content"
            `Quick
            test_parse_openai_response_blank_reasoning
        ; test_case "no reasoning_content" `Quick test_parse_openai_response_no_reasoning
        ; test_case
            "ollama reasoning field"
            `Quick
            test_parse_openai_response_ollama_reasoning
        ; test_case
            "reasoning_content preferred over reasoning"
            `Quick
            test_parse_openai_response_reasoning_content_preferred
        ] )
    ; ( "error_handling"
      , [ test_case
            "openai api error returns Error"
            `Quick
            test_openai_api_error_returns_error
        ; test_case
            "openai api error unknown message"
            `Quick
            test_openai_api_error_unknown_message
        ; test_case "openai error returns result" `Quick test_openai_error_returns_result
        ] )
    ; ( "parse_sse_event"
      , [ test_case "message_start" `Quick test_parse_sse_message_start
        ; test_case
            "content_block_delta text"
            `Quick
            test_parse_sse_content_block_delta_text
        ; test_case
            "content_block_delta thinking"
            `Quick
            test_parse_sse_content_block_delta_thinking
        ; test_case
            "content_block_delta input_json"
            `Quick
            test_parse_sse_content_block_delta_input_json
        ; test_case "content_block_start" `Quick test_parse_sse_content_block_start
        ; test_case "message_delta" `Quick test_parse_sse_message_delta
        ; test_case "message_stop" `Quick test_parse_sse_message_stop
        ; test_case "ping" `Quick test_parse_sse_ping
        ; test_case "error" `Quick test_parse_sse_error
        ; test_case "unknown event type" `Quick test_parse_sse_unknown_type
        ; test_case "malformed JSON" `Quick test_parse_sse_malformed_json
        ] )
    ; ( "message_to_json"
      , [ test_case "user message" `Quick test_message_to_json
        ; test_case "ignores metadata" `Quick test_message_to_json_ignores_metadata
        ; test_case "assistant mixed content" `Quick test_message_to_json_assistant
        ] )
    ; ( "openai_messages"
      , [ test_case "text only user" `Quick test_openai_messages_text_only
        ; test_case "user with image" `Quick test_openai_messages_with_image
        ] )
    ; ( "api_common_helpers"
      , [ test_case "text_blocks_to_string" `Quick test_text_blocks_to_string
        ; test_case "string_is_blank" `Quick test_string_is_blank
        ; test_case "json_of_string_or_raw valid" `Quick test_json_of_string_or_raw_valid
        ; test_case
            "json_of_string_or_raw invalid"
            `Quick
            test_json_of_string_or_raw_invalid
        ; test_case
            "kimi tool_result uses text blocks"
            `Quick
            test_kimi_message_to_json_tool_result_uses_text_blocks
        ] )
    ]
;;
