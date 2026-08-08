(** OpenAI-compatible API response parsing, message serialization,
    and request building.

    Pure functions operating on {!Llm_provider.Types}.
    {!build_request} uses {!Provider_config.t} (no agent_sdk coupling).

    @since 0.92.0 decomposed into Backend_openai_serialize,
    Backend_openai_parse *)

open Types

(* ── Re-exports from serialization ─────────────────────── *)

let tool_calls_to_openai_json = Backend_openai_serialize.tool_calls_to_openai_json

let openai_content_parts_of_blocks =
  Backend_openai_serialize.openai_content_parts_of_blocks
;;

let openai_messages_of_message = Backend_openai_serialize.openai_messages_of_message
let tool_choice_to_openai_json = Backend_openai_serialize.tool_choice_to_openai_json

(* ── Re-exports from parsing ──────────────────────────── *)

let usage_of_openai_json = Backend_openai_parse.usage_of_openai_json
let parse_openai_response_result = Backend_openai_parse.parse_openai_response_result

(* ── Re-exports from request building ─────────────────── *)

let warn_capability_drop = Backend_openai_request.warn_capability_drop
let effective_tool_choice = Backend_openai_request.effective_tool_choice
let effective_tools = Backend_openai_request.effective_tools
let structured_schema_of_config = Backend_openai_request.structured_schema_of_config
let openai_json_schema_payload = Backend_openai_request.openai_json_schema_payload
let response_format_to_openai_json = Backend_openai_request.response_format_to_openai_json
let response_format_of_config = Backend_openai_request.response_format_of_config

type request_artifact =
  | Openai_request_artifact of Backend_openai_request.request_artifact

let request_payload (Openai_request_artifact artifact) =
  Backend_openai_request.request_payload artifact
;;

let request_output_token_receipt (Openai_request_artifact artifact) =
  Backend_openai_request.request_output_token_receipt artifact
;;

let build_request_assoc ?stream ~config ~messages ?tools () =
  Backend_openai_request.build_request_assoc ?stream ~config ~messages ?tools ()
;;

let build_request_artifact ?stream ~config ~messages ?tools () =
  Openai_request_artifact
    (Backend_openai_request.build_request_artifact ?stream ~config ~messages ?tools ())
;;

let build_request ?stream ~config ~messages ?tools () =
  build_request_artifact ?stream ~config ~messages ?tools () |> request_payload
;;

[@@@coverage off]
(* === Inline tests === *)

let deepseek_v4_capabilities =
  { Capabilities.openai_compat_chat_capabilities with
    max_context_tokens = Some 1_000_000
  ; max_output_tokens = Some 384_000
  ; supports_tools = true
  ; supports_tool_choice = true
  ; supports_required_tool_choice = false
  ; supports_named_tool_choice = false
  ; supports_reasoning = true
  ; supports_extended_thinking = true
  ; supports_reasoning_budget = false
  ; accepted_reasoning_efforts = Some [ Reasoning_effort.High; Reasoning_effort.Max ]
  ; thinking_control_format = Capabilities.Thinking_object
  ; supports_response_format_json = true
  ; supports_native_streaming = true
  ; supports_caching = true
  ; supports_prompt_caching = false
  }
;;

let declared_deepseek_config ?enable_thinking ?reasoning_effort model_id =
  Provider_config.make
    ~kind:OpenAI_compat
    ~model_id
    ~base_url:"https://api.deepseek.com"
    ?enable_thinking
    ?reasoning_effort
    ~model_capabilities_override:deepseek_v4_capabilities
    ()
;;

let%test "tool_choice_to_openai_json Auto" =
  tool_choice_to_openai_json Auto = `String "auto"
;;

let%test "tool_choice_to_openai_json Any" =
  tool_choice_to_openai_json Any = `String "required"
;;

let%test "tool_choice_to_openai_json None_" =
  tool_choice_to_openai_json None_ = `String "none"
;;

let%test "tool_choice_to_openai_json Tool name" =
  let result = tool_choice_to_openai_json (Tool "my_tool") in
  let open Yojson.Safe.Util in
  result |> member "type" |> to_string = "function"
  && result |> member "function" |> member "name" |> to_string = "my_tool"
;;

let%test "glm rejects named forced tool_choice" =
  let cfg =
    Provider_config.make
      ~kind:Provider_config.Glm
      ~model_id:"glm-5"
      ~base_url:Zai_catalog.general_base_url
      ~tool_choice:(Tool "calculator")
      ()
  in
  match effective_tool_choice cfg with
  | exception Invalid_argument msg ->
    String.starts_with
      ~prefix:"Backend_openai_request.effective_tool_choice: glm model"
      msg
  | _ -> false
;;

let%test "glm passes tool_choice any through (no coerce)" =
  let cfg =
    Provider_config.make
      ~kind:Provider_config.Glm
      ~model_id:"glm-5"
      ~base_url:Zai_catalog.general_base_url
      ~tool_choice:Any
      ()
  in
  effective_tool_choice cfg = Some (`String "required")
;;

let%test "glm drops tool_choice none" =
  let cfg =
    Provider_config.make
      ~kind:Provider_config.Glm
      ~model_id:"glm-5"
      ~base_url:Zai_catalog.general_base_url
      ~tool_choice:None_
      ()
  in
  effective_tool_choice cfg = None
;;

let%test "glm drops tools when tool_choice none" =
  let cfg =
    Provider_config.make
      ~kind:Provider_config.Glm
      ~model_id:"glm-5"
      ~base_url:Zai_catalog.general_base_url
      ~tool_choice:None_
      ()
  in
  let tool_json =
    `Assoc
      [ "name", `String "calculator"
      ; "description", `String "math"
      ; "input_schema", `Assoc [ "type", `String "object" ]
      ]
  in
  let json =
    build_request ~config:cfg ~messages:[] ~tools:[ tool_json ] ()
    |> Yojson.Safe.from_string
  in
  let open Yojson.Safe.Util in
  let assoc = to_assoc json in
  (not (List.mem_assoc "tool_choice" assoc)) && not (List.mem_assoc "tools" assoc)
;;

(* === Capability-gated sampling param tests (oas#827) === *)

let%test "glm drops min_p when model does not support it" =
  (* Glm's glm_capabilities inherits supports_min_p = false from
     default_capabilities.  Even when the caller sets min_p explicitly
     (via higher-level config inheritance or agent default), backend_openai must
     omit it from the wire body — ZAI rejects the request with
     "property 'min_p' is unsupported". *)
  let cfg =
    Provider_config.make
      ~kind:Provider_config.Glm
      ~model_id:"glm-5.1"
      ~base_url:Zai_catalog.general_base_url
      ~min_p:0.05
      ()
  in
  let json = build_request ~config:cfg ~messages:[] () |> Yojson.Safe.from_string in
  let open Yojson.Safe.Util in
  not (List.mem_assoc "min_p" (to_assoc json))
;;

let%test "glm drops top_k when model does not support it" =
  let cfg =
    Provider_config.make
      ~kind:Provider_config.Glm
      ~model_id:"glm-5.1"
      ~base_url:Zai_catalog.general_base_url
      ~top_k:40
      ()
  in
  let json = build_request ~config:cfg ~messages:[] () |> Yojson.Safe.from_string in
  let open Yojson.Safe.Util in
  not (List.mem_assoc "top_k" (to_assoc json))
;;

let%test "ollama preserves min_p (llama.cpp supports it)" =
  (* qwen3 via Ollama has supports_min_p = true in provider_m_capabilities.
     The capability-gated path must still pass min_p through for
     providers that do support it. *)
  let cfg =
    Provider_config.make
      ~kind:Provider_config.Ollama
      ~model_id:"dashscope-3.5:35b-a3b-nvfp4"
      ~base_url:"http://127.0.0.1:11434"
      ~min_p:0.05
      ()
  in
  let json = build_request ~config:cfg ~messages:[] () |> Yojson.Safe.from_string in
  let open Yojson.Safe.Util in
  match json |> member "min_p" with
  | `Float f -> Float.abs (f -. 0.05) < 1e-6
  | _ -> false
;;

let%test "tool_calls_to_openai_json extracts ToolUse blocks" =
  let blocks =
    [ Text "hello"; ToolUse { id = "tc1"; name = "fn1"; input = `Assoc [ "x", `Int 1 ] } ]
  in
  let result = tool_calls_to_openai_json blocks in
  List.length result = 1
;;

let%test "tool_calls_to_openai_json empty for no tool_use" =
  tool_calls_to_openai_json [ Text "no tools" ] = []
;;

let%test "openai_content_parts_of_blocks filters text and image" =
  let blocks =
    [ Text "hello"
    ; Thinking { signature = None; content = "..." }
    ; ToolUse { id = "tc1"; name = "fn"; input = `Null }
    ]
  in
  let result = openai_content_parts_of_blocks blocks in
  List.length result = 1
;;

let%test "usage_of_openai_json parses usage" =
  let json =
    `Assoc [ "usage", `Assoc [ "prompt_tokens", `Int 100; "completion_tokens", `Int 50 ] ]
  in
  match usage_of_openai_json json with
  | Some u -> u.input_tokens = 100 && u.output_tokens = 50
  | None -> false
;;

let%test "usage_of_openai_json null usage returns None" =
  let json = `Assoc [ "usage", `Null ] in
  usage_of_openai_json json = None
;;

let%test "usage_of_openai_json missing usage returns None" =
  let json = `Assoc [] in
  usage_of_openai_json json = None
;;

let%test "usage_of_openai_json with cached_tokens" =
  let json =
    `Assoc
      [ ( "usage"
        , `Assoc
            [ "prompt_tokens", `Int 100
            ; "completion_tokens", `Int 50
            ; "prompt_tokens_details", `Assoc [ "cached_tokens", `Int 30 ]
            ] )
      ]
  in
  match usage_of_openai_json json with
  | Some u -> u.cache_read_input_tokens = 30
  | None -> false
;;

let%test "parse_openai_response_result basic text response" =
  let json_str =
    Yojson.Safe.to_string
      (`Assoc
          [ "id", `String "chatcmpl-1"
          ; "model", `String "gpt-4"
          ; ( "choices"
            , `List
                [ `Assoc
                    [ "finish_reason", `String "stop"
                    ; "message", `Assoc [ "content", `String "Hello world" ]
                    ]
                ] )
          ])
  in
  match parse_openai_response_result json_str with
  | Ok resp ->
    resp.id = "chatcmpl-1" && resp.model = "gpt-4" && resp.stop_reason = EndTurn
  | Error _ -> false
;;

let%test "parse_openai_response_result tool calls" =
  let json_str =
    Yojson.Safe.to_string
      (`Assoc
          [ "id", `String "cmpl-2"
          ; "model", `String "gpt-4"
          ; ( "choices"
            , `List
                [ `Assoc
                    [ "finish_reason", `String "tool_calls"
                    ; ( "message"
                      , `Assoc
                          [ "content", `Null
                          ; ( "tool_calls"
                            , `List
                                [ `Assoc
                                    [ "id", `String "call_1"
                                    ; "type", `String "function"
                                    ; ( "function"
                                      , `Assoc
                                          [ "name", `String "get_weather"
                                          ; "arguments", `String "{\"city\":\"Seoul\"}"
                                          ] )
                                    ]
                                ] )
                          ] )
                    ]
                ] )
          ])
  in
  match parse_openai_response_result json_str with
  | Ok resp -> resp.stop_reason = StopToolUse
  | Error _ -> false
;;

let%test "parse_openai_response_result max_tokens stop reason" =
  let json_str =
    Yojson.Safe.to_string
      (`Assoc
          [ "id", `String "cmpl-3"
          ; "model", `String "m"
          ; ( "choices"
            , `List
                [ `Assoc
                    [ "finish_reason", `String "length"
                    ; "message", `Assoc [ "content", `String "truncated" ]
                    ]
                ] )
          ])
  in
  match parse_openai_response_result json_str with
  | Ok resp -> resp.stop_reason = MaxTokens
  | Error _ -> false
;;

let%test "parse_openai_response_result error returns Error" =
  let json_str =
    Yojson.Safe.to_string
      (`Assoc [ "error", `Assoc [ "message", `String "rate limited" ] ])
  in
  match parse_openai_response_result json_str with
  | Error (Backend_openai_parse.Provider_error msg) -> msg = "rate limited"
  | Error (Backend_openai_parse.Empty_completion _) -> false
  | Ok _ -> false
;;

let%test "openai_messages_of_message user text" =
  let msg =
    { role = User
    ; content = [ Text "hello" ]
    ; name = None
    ; tool_call_id = None
    ; metadata = []
    }
  in
  let result = openai_messages_of_message msg in
  List.length result = 1
;;

let%test "openai_messages_of_message rejects user with tool_result" =
  let msg =
    { role = User
    ; content =
        [ Text "follow up"
        ; ToolResult
            { tool_use_id = "tc1"
            ; content = "result"
            ; outcome = Tool_succeeded
            ; json = None
            ; content_blocks = None
            }
        ]
    ; name = None
    ; tool_call_id = None
    ; metadata = []
    }
  in
  match openai_messages_of_message msg with
  | _ -> false
  | exception Invalid_argument message ->
    String.equal
      message
      "Backend_openai_serialize.openai_messages_of_message: ToolResult requires role tool"
;;

let%test "build_request rejects ToolResult outside role Tool" =
  let cfg =
    Provider_config.make
      ~kind:Provider_config.Glm
      ~model_id:"glm-5.1"
      ~base_url:Zai_catalog.general_base_url
      ()
  in
  let messages =
    [ { role = Assistant
      ; content = [ Text "hello" ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ; { role = User
      ; content =
          [ Text "follow up"
          ; ToolResult
              { tool_use_id = "orphan-id"
              ; content = "stale"
              ; outcome = Tool_succeeded
              ; json = None
              ; content_blocks = None
              }
          ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  match build_request ~config:cfg ~messages () with
  | _ -> false
  | exception Invalid_argument message ->
    String.equal
      message
      "Backend_openai_serialize.openai_messages_of_message: ToolResult requires role tool"
;;

let%test "openai_messages_of_message assistant with tool_calls" =
  let msg =
    { role = Assistant
    ; content = [ ToolUse { id = "tc1"; name = "fn"; input = `Assoc [] } ]
    ; name = None
    ; tool_call_id = None
    ; metadata = []
    }
  in
  let result = openai_messages_of_message msg in
  List.length result = 1
;;

let%test "openai_messages_of_message system" =
  let msg =
    { role = System
    ; content = [ Text "system prompt" ]
    ; name = None
    ; tool_call_id = None
    ; metadata = []
    }
  in
  let result = openai_messages_of_message msg in
  List.length result = 1
;;

let%test "openai_messages_of_message user empty content" =
  let msg =
    { role = User; content = []; name = None; tool_call_id = None; metadata = [] }
  in
  let result = openai_messages_of_message msg in
  result = []
;;

let%test "openai_messages_of_message user with image" =
  let msg =
    { role = User
    ; content =
        [ Image { media_type = "image/png"; data = "abc123"; source_type = Types.Base64 }
        ; Text "describe this"
        ]
    ; name = None
    ; tool_call_id = None
    ; metadata = []
    }
  in
  let result = openai_messages_of_message msg in
  List.length result = 1
;;

let%test "openai_messages_of_message user with document" =
  let msg =
    { role = User
    ; content =
        [ Document
            { media_type = "application/pdf"; data = "abc"; source_type = Types.Base64 }
        ]
    ; name = None
    ; tool_call_id = None
    ; metadata = []
    }
  in
  let result = openai_messages_of_message msg in
  List.length result = 1
;;

let%test "openai_messages_of_message user with audio" =
  let msg =
    { role = User
    ; content =
        [ Audio
            { media_type = "audio/wav"; data = "audiodata"; source_type = Types.Base64 }
        ]
    ; name = None
    ; tool_call_id = None
    ; metadata = []
    }
  in
  let result = openai_messages_of_message msg in
  List.length result = 1
;;

let%test "openai_messages_of_message assistant text only" =
  let msg =
    { role = Assistant
    ; content = [ Text "hello" ]
    ; name = None
    ; tool_call_id = None
    ; metadata = []
    }
  in
  let result = openai_messages_of_message msg in
  let json = List.hd result in
  let open Yojson.Safe.Util in
  json |> member "content" |> to_string = "hello"
;;

let%test "openai_messages_of_message assistant excludes reasoning from content" =
  let msg =
    { role = Assistant
    ; content =
        [ Thinking { signature = None; content = "hidden chain of thought" }
        ; Text "final answer"
        ]
    ; name = None
    ; tool_call_id = None
    ; metadata = []
    }
  in
  let result = openai_messages_of_message msg in
  let json = List.hd result in
  let open Yojson.Safe.Util in
  json |> member "content" |> to_string = "final answer"
  && json |> member "reasoning_content" = `Null
;;

let%test "openai_messages_of_message assistant blank text with tool_calls" =
  let msg =
    { role = Assistant
    ; content = [ Text ""; ToolUse { id = "tc1"; name = "fn"; input = `Assoc [] } ]
    ; name = None
    ; tool_call_id = None
    ; metadata = []
    }
  in
  let result = openai_messages_of_message msg in
  let json = List.hd result in
  let open Yojson.Safe.Util in
  json |> member "content" = `Null
;;

let%test "openai_messages_of_message Tool role with ToolResult" =
  let msg =
    { role = Tool
    ; content =
        [ ToolResult
            { tool_use_id = "tc1"
            ; content = "result data"
            ; outcome = Tool_succeeded
            ; json = None
            ; content_blocks = None
            }
        ]
    ; name = None
    ; tool_call_id = None
    ; metadata = []
    }
  in
  let result = openai_messages_of_message msg in
  List.length result = 1
  &&
  let json = List.hd result in
  let open Yojson.Safe.Util in
  json |> member "role" |> to_string = "tool"
;;

let%test "openai_messages_of_message rejects Tool role without ToolResult" =
  let msg =
    { role = Tool
    ; content = [ Text "fallback" ]
    ; name = None
    ; tool_call_id = None
    ; metadata = []
    }
  in
  match openai_messages_of_message msg with
  | _ -> false
  | exception Invalid_argument message ->
    String.equal
      message
      "Backend_openai_serialize.openai_messages_of_message: role tool requires one or \
       more ToolResult blocks and no other content"
;;

let%test "response_format_to_openai_json wraps raw json schema" =
  let schema =
    `Assoc
      [ "type", `String "object"
      ; "properties", `Assoc [ "answer", `Assoc [ "type", `String "string" ] ]
      ]
  in
  match response_format_to_openai_json (Types.JsonSchema schema) with
  | Some json ->
    let open Yojson.Safe.Util in
    json |> member "type" |> to_string = "json_schema"
    && json |> member "json_schema" |> member "name" |> to_string = "structured_output"
    && json
       |> member "json_schema"
       |> member "schema"
       |> member "type"
       |> to_string
       = "object"
  | None -> false
;;

let%test "response_format_to_openai_json preserves named schema envelope" =
  let schema =
    `Assoc
      [ "name", `String "math_response"
      ; "strict", `Bool true
      ; ( "schema"
        , `Assoc
            [ "type", `String "object"
            ; "properties", `Assoc [ "answer", `Assoc [ "type", `String "number" ] ]
            ] )
      ]
  in
  match response_format_to_openai_json (Types.JsonSchema schema) with
  | Some json ->
    let open Yojson.Safe.Util in
    json |> member "json_schema" |> member "name" |> to_string = "math_response"
    && json |> member "json_schema" |> member "strict" |> to_bool
    && json
       |> member "json_schema"
       |> member "schema"
       |> member "type"
       |> to_string
       = "object"
  | None -> false
;;

let%test "parse_openai_response_result unknown finish_reason" =
  let json_str =
    Yojson.Safe.to_string
      (`Assoc
          [ "id", `String "c1"
          ; "model", `String "m"
          ; ( "choices"
            , `List
                [ `Assoc
                    [ "finish_reason", `String "something_new"
                    ; "message", `Assoc [ "content", `String "text" ]
                    ]
                ] )
          ])
  in
  match parse_openai_response_result json_str with
  | Ok resp -> resp.stop_reason = Unknown "something_new"
  | Error _ -> false
;;

let%test "parse_openai_response_result end_turn finish_reason" =
  let json_str =
    Yojson.Safe.to_string
      (`Assoc
          [ "id", `String "c1"
          ; "model", `String "m"
          ; ( "choices"
            , `List
                [ `Assoc
                    [ "finish_reason", `String "end_turn"
                    ; "message", `Assoc [ "content", `String "done" ]
                    ]
                ] )
          ])
  in
  match parse_openai_response_result json_str with
  | Ok resp -> resp.stop_reason = EndTurn
  | Error _ -> false
;;

let%test "parse_openai_response_result null content fails closed (oas#2483)" =
  let json_str =
    Yojson.Safe.to_string
      (`Assoc
          [ "id", `String "c1"
          ; "model", `String "m"
          ; ( "choices"
            , `List
                [ `Assoc
                    [ "finish_reason", `String "stop"
                    ; "message", `Assoc [ "content", `Null ]
                    ]
                ] )
          ])
  in
  (* A 200 with null content and no tool_calls/reasoning is an all-empty
     completion: it now fails closed as [Empty_completion] instead of the old
     [Ok content=[]] that stormed downstream. *)
  match parse_openai_response_result json_str with
  | Error (Backend_openai_parse.Empty_completion e) -> e.stop_reason = EndTurn
  | Error (Backend_openai_parse.Provider_error _) | Ok _ -> false
;;

let%test "parse_openai_response_result blank content with tool_calls stays Ok (oas#2483)" =
  let json_str =
    Yojson.Safe.to_string
      (`Assoc
          [ "id", `String "c1"
          ; "model", `String "m"
          ; ( "choices"
            , `List
                [ `Assoc
                    [ "finish_reason", `String "tool_calls"
                    ; ( "message"
                      , `Assoc
                          [ "content", `Null
                          ; ( "tool_calls"
                            , `List
                                [ `Assoc
                                    [ "id", `String "call_1"
                                    ; "type", `String "function"
                                    ; ( "function"
                                      , `Assoc
                                          [ "name", `String "do_it"
                                          ; "arguments", `String "{}"
                                          ] )
                                    ]
                                ] )
                          ] )
                    ]
                ] )
          ])
  in
  (* Blank text WITH tool_calls has content=[ToolUse ..] (non-empty) and must
     NOT trip the empty-completion guard. *)
  match parse_openai_response_result json_str with
  | Ok { content = _ :: _; _ } -> true
  | Ok { content = []; _ } | Error _ -> false
;;

let%test "parse_openai_response_result list content" =
  let json_str =
    Yojson.Safe.to_string
      (`Assoc
          [ "id", `String "c1"
          ; "model", `String "m"
          ; ( "choices"
            , `List
                [ `Assoc
                    [ "finish_reason", `String "stop"
                    ; ( "message"
                      , `Assoc [ "content", `List [ `String "part1"; `String "part2" ] ] )
                    ]
                ] )
          ])
  in
  match parse_openai_response_result json_str with
  | Ok resp ->
    (match resp.content with
     | [ Text t ] -> String.length t > 0
     | _ -> false)
  | Error _ -> false
;;

let%test "parse_openai_response_result list content with assoc text blocks" =
  let json_str =
    Yojson.Safe.to_string
      (`Assoc
          [ "id", `String "c1"
          ; "model", `String "m"
          ; ( "choices"
            , `List
                [ `Assoc
                    [ "finish_reason", `String "stop"
                    ; ( "message"
                      , `Assoc
                          [ ( "content"
                            , `List
                                [ `Assoc [ "text", `String "block1" ]
                                ; `Assoc [ "text", `String "block2" ]
                                ] )
                          ] )
                    ]
                ] )
          ])
  in
  match parse_openai_response_result json_str with
  | Ok resp ->
    (match resp.content with
     | [ Text t ] -> t = "block1block2"
     | _ -> false)
  | Error _ -> false
;;

let%test "parse_openai_response_result with reasoning_content" =
  let json_str =
    Yojson.Safe.to_string
      (`Assoc
          [ "id", `String "c1"
          ; "model", `String "deepseek-r1"
          ; ( "choices"
            , `List
                [ `Assoc
                    [ "finish_reason", `String "stop"
                    ; ( "message"
                      , `Assoc
                          [ "content", `String "answer"
                          ; "reasoning_content", `String "I thought about it"
                          ] )
                    ]
                ] )
          ])
  in
  match parse_openai_response_result json_str with
  | Ok resp ->
    (* N-of-M followup to PR #1525 (backend_gemini.has_tool_use). Same
       content_block catch-all family — enumerate every variant so a
       future block type can't silently inherit "no thinking". *)
    List.exists
      (fun (block : Types.content_block) ->
         match block with
         | Thinking _ -> true
         | Text _
         | ReasoningDetails _
         | RedactedThinking _
         | ToolUse _
         | ToolResult _
         | Image _
         | Document _
         | Audio _ -> false)
      resp.content
  | Error _ -> false
;;

let%test "parse_openai_response_result JSON list wrapping" =
  let inner =
    `Assoc
      [ "id", `String "c1"
      ; "model", `String "m"
      ; ( "choices"
        , `List
            [ `Assoc
                [ "finish_reason", `String "stop"
                ; "message", `Assoc [ "content", `String "ok" ]
                ]
            ] )
      ]
  in
  let json_str = Yojson.Safe.to_string (`List [ inner ]) in
  match parse_openai_response_result json_str with
  | Ok resp -> resp.id = "c1"
  | Error _ -> false
;;

let%test "parse_openai_response_result error without message" =
  let json_str = Yojson.Safe.to_string (`Assoc [ "error", `Assoc [] ]) in
  match parse_openai_response_result json_str with
  | Error (Backend_openai_parse.Provider_error msg) -> msg = "Unknown API error"
  | Error (Backend_openai_parse.Empty_completion _) -> false
  | Ok _ -> false
;;

let%test "usage_of_openai_json prompt_tokens_details null" =
  let json =
    `Assoc
      [ ( "usage"
        , `Assoc
            [ "prompt_tokens", `Int 50
            ; "completion_tokens", `Int 25
            ; "prompt_tokens_details", `Null
            ] )
      ]
  in
  match usage_of_openai_json json with
  | Some u -> u.cache_read_input_tokens = 0
  | None -> false
;;

let%test "openai_content_parts_of_blocks image block" =
  let blocks =
    [ Image { media_type = "image/png"; data = "abc"; source_type = Types.Base64 } ]
  in
  let result = openai_content_parts_of_blocks blocks in
  List.length result = 1
;;

let%test "openai_content_parts_of_blocks document block" =
  let blocks =
    [ Document
        { media_type = "application/pdf"; data = "abc"; source_type = Types.Base64 }
    ]
  in
  let result = openai_content_parts_of_blocks blocks in
  List.length result = 1
;;

let%test "openai_content_parts_of_blocks audio block" =
  let blocks =
    [ Audio { media_type = "audio/wav"; data = "abc"; source_type = Types.Base64 } ]
  in
  let result = openai_content_parts_of_blocks blocks in
  List.length result = 1
;;

let%test "openai_content_parts_of_blocks redacted thinking filtered" =
  let blocks = [ RedactedThinking "secret"; Text "visible" ] in
  let result = openai_content_parts_of_blocks blocks in
  List.length result = 1
;;

let%test "openai_content_parts_of_blocks tool_result filtered" =
  let blocks =
    [ ToolResult
        { tool_use_id = "t1"
        ; content = "result"
        ; outcome = Tool_succeeded
        ; json = None
        ; content_blocks = None
        }
    ]
  in
  openai_content_parts_of_blocks blocks = []
;;

let%test "build_request includes tool_choice for model with supports_tool_choice=true" =
  let config =
    Provider_config.make
      ~kind:OpenAI_compat
      ~model_id:"gpt"
      ~base_url:"http://localhost"
      ~tool_choice:Any
      ~supports_tool_choice_override:true
      ()
  in
  let body = build_request ~config ~messages:[] () in
  let json = Yojson.Safe.from_string body in
  let open Yojson.Safe.Util in
  json |> member "tool_choice" |> to_string = "required"
;;

let json_object_missing_key key json =
  match Yojson.Safe.Util.to_assoc json with
  | fields -> not (List.exists (fun (k, _) -> k = key) fields)
  | exception Yojson.Safe.Util.Type_error _ -> false
;;

let%test "build_request rejects forced tool_choice for unknown model without override" =
  let config =
    Provider_config.make
      ~kind:OpenAI_compat
      ~model_id:"mystery-xyz-v1"
      ~base_url:"http://localhost"
      ~tool_choice:Any
      ()
  in
  match build_request ~config ~messages:[] () with
  | exception Invalid_argument msg ->
    String.starts_with
      ~prefix:"Backend_openai_request.effective_tool_choice: openai_compat model"
      msg
  | _ -> false
;;

let%test "build_request omits tool_choice when tool_choice=None" =
  let config =
    Provider_config.make
      ~kind:OpenAI_compat
      ~model_id:"gpt"
      ~base_url:"http://localhost"
      ()
  in
  let body = build_request ~config ~messages:[] () in
  let json = Yojson.Safe.from_string body in
  json_object_missing_key "tool_choice" json
;;

let%test "glm build_request rejects unsupported forced tool_choice" =
  let config =
    Provider_config.make
      ~kind:Provider_config.Glm
      ~model_id:"glm-5.1"
      ~base_url:Zai_catalog.coding_base_url
      ~tool_choice:(Tool "calc")
      ()
  in
  match build_request ~config ~messages:[] () with
  | exception Invalid_argument msg ->
    String.starts_with
      ~prefix:"Backend_openai_request.effective_tool_choice: glm model"
      msg
  | _ -> false
;;

let%test "build_request rejects named tool_choice when capability-false" =
  let config =
    Provider_config.make
      ~kind:OpenAI_compat
      ~model_id:"mystery-xyz-v1"
      ~base_url:"http://localhost"
      ~tool_choice:(Tool "calc")
      ()
  in
  match build_request ~config ~messages:[] () with
  | exception Invalid_argument msg ->
    String.starts_with
      ~prefix:"Backend_openai_request.effective_tool_choice: openai_compat model"
      msg
  | body ->
    Printf.eprintf
      "expected named tool_choice rejection for capability-false model, got body: %s\n"
      body;
    false
;;

let%test
    "glm build_request replays reasoning_content under preserved thinking without \
     leaking it into content"
  =
  let config =
    Provider_config.make
      ~kind:Provider_config.Glm
      ~model_id:"glm-5.1"
      ~base_url:Zai_catalog.coding_base_url
      ~enable_thinking:true
      ~preserve_thinking:true
      ()
  in
  let metadata =
    match Reasoning_dialect.reasoning_source_for_provider_config config with
    | Ok source -> Reasoning_source.metadata source
    | Error detail -> failwith detail
  in
  let messages =
    [ { role = Assistant
      ; content =
          [ Thinking { signature = None; content = "use calculator" }
          ; ToolUse
              { id = "call_1"; name = "calc"; input = `Assoc [ "expr", `String "2+2" ] }
          ]
      ; name = None
      ; tool_call_id = None
      ; metadata
      }
    ]
  in
  let body = build_request ~config ~messages () |> Yojson.Safe.from_string in
  let open Yojson.Safe.Util in
  let assistant = body |> member "messages" |> index 0 in
  assistant |> member "content" |> to_string = ""
  && assistant |> member "reasoning_content" |> to_string = "use calculator"
;;

let%test "build_request uses json_schema response_format" =
  let schema =
    `Assoc
      [ "title", `String "Math Response"
      ; "type", `String "object"
      ; "properties", `Assoc [ "answer", `Assoc [ "type", `String "string" ] ]
      ; "required", `List [ `String "answer" ]
      ]
  in
  let config =
    Provider_config.make
      ~kind:OpenAI_compat
      ~model_id:"gpt"
      ~base_url:"https://api.openai.com/v1"
      ~response_format:(JsonSchema schema)
      ()
  in
  let body = build_request ~config ~messages:[] () |> Yojson.Safe.from_string in
  let open Yojson.Safe.Util in
  body |> member "response_format" |> member "type" |> to_string = "json_schema"
  && body
     |> member "response_format"
     |> member "json_schema"
     |> member "name"
     |> to_string
     = "math_response"
  && body |> member "response_format" |> member "json_schema" |> member "schema" = schema
  && body
     |> member "response_format"
     |> member "json_schema"
     |> member "strict"
     |> to_bool
;;

let%test "explicit json_schema response_format overrides json mode compatibility flag" =
  let schema = `Assoc [ "type", `String "object" ] in
  let config =
    Provider_config.make
      ~kind:OpenAI_compat
      ~model_id:"gpt"
      ~base_url:"https://api.openai.com/v1"
      ~response_format:(JsonSchema schema)
      ()
  in
  let body = build_request ~config ~messages:[] () |> Yojson.Safe.from_string in
  let open Yojson.Safe.Util in
  body |> member "response_format" |> member "type" |> to_string = "json_schema"
;;

let%test "supports_tool_choice_override=Some false rejects forced tool_choice" =
  (* Unknown model_id defaults to supports_tool_choice=false. Override false
     keeps the fail-closed behavior explicit. *)
  let config =
    Provider_config.make
      ~kind:OpenAI_compat
      ~model_id:"mystery-xyz-v1"
      ~base_url:"http://localhost"
      ~tool_choice:Any
      ~supports_tool_choice_override:false
      ()
  in
  match build_request ~config ~messages:[] () with
  | exception Invalid_argument msg ->
    String.starts_with
      ~prefix:"Backend_openai_request.effective_tool_choice: openai_compat model"
      msg
  | _ -> false
;;

let%test
    "supports_tool_choice_override=Some true forces tool_choice on capability-false model"
  =
  (* Use an unknown model whose capability record defaults to
     supports_tool_choice=false, then force-enable it via override. *)
  let config =
    Provider_config.make
      ~kind:OpenAI_compat
      ~model_id:"mystery-xyz-v1"
      ~base_url:"http://localhost"
      ~tool_choice:Any
      ~supports_tool_choice_override:true
      ()
  in
  let body = build_request ~config ~messages:[] () in
  let json = Yojson.Safe.from_string body in
  let open Yojson.Safe.Util in
  json |> member "tool_choice" |> to_string = "required"
;;

let%test "build_request serializes thinking object for deepseek-v4-flash" =
  let config =
    declared_deepseek_config
      ~enable_thinking:true
      ~reasoning_effort:Reasoning_effort.High
      "deepseek-v4-flash"
  in
  let body = build_request ~config ~messages:[] () in
  let json = Yojson.Safe.from_string body in
  let open Yojson.Safe.Util in
  json |> member "thinking" |> member "type" |> to_string = "enabled"
  && json |> member "reasoning_effort" |> to_string = "high"
;;

let%test "build_request serializes disabled thinking for deepseek-v4-pro" =
  let config = declared_deepseek_config ~enable_thinking:false "deepseek-v4-pro" in
  let body = build_request ~config ~messages:[] () in
  let json = Yojson.Safe.from_string body in
  let open Yojson.Safe.Util in
  json |> member "thinking" |> member "type" |> to_string = "disabled"
  && json |> member "reasoning_effort" = `Null
;;

let%test "openai compat does not infer ZAI thinking from bare GLM model or URL" =
  let config =
    Provider_config.make
      ~kind:OpenAI_compat
      ~model_id:"glm-5"
      ~base_url:Zai_catalog.coding_base_url
      ~enable_thinking:true
      ~clear_thinking:false
      ()
  in
  let body = build_request ~config ~messages:[] () in
  let json = Yojson.Safe.from_string body in
  let open Yojson.Safe.Util in
  json |> member "thinking" = `Null && json |> member "reasoning_effort" = `Null
;;

let%test "openai compat does not infer ZAI preserve control from bare GLM model or URL" =
  let config =
    Provider_config.make
      ~kind:OpenAI_compat
      ~model_id:"glm-5"
      ~base_url:Zai_catalog.coding_base_url
      ~enable_thinking:true
      ~preserve_thinking:true
      ()
  in
  let body = build_request ~config ~messages:[] () in
  let json = Yojson.Safe.from_string body in
  let open Yojson.Safe.Util in
  json |> member "thinking" = `Null
;;

let%test "build_request emits reasoning_effort for Openai reasoning models" =
  let capabilities =
    { Capabilities.openai_compat_chat_extended_capabilities with
      accepted_reasoning_efforts = Some [ Reasoning_effort.Low ]
    }
  in
  let config =
    Provider_config.make
      ~kind:OpenAI_compat
      ~model_id:"gpt-5.1"
      ~base_url:"https://api.openai.com/v1"
      ~enable_thinking:true
      ~reasoning_effort:Reasoning_effort.Low
      ~model_capabilities_override:capabilities
      ()
  in
  let body = build_request ~config ~messages:[] () in
  let json = Yojson.Safe.from_string body in
  let open Yojson.Safe.Util in
  json |> member "reasoning_effort" |> to_string = "low"
  && json |> member "thinking" = `Null
  && json |> member "enable_thinking" = `Null
;;

let%test "build_request omits thinking request fields for latest native Kimi" =
  let config =
    Provider_config.make
      ~kind:Kimi
      ~model_id:"kimi-k2.7-code"
      ~base_url:"https://api.moonshot.ai/v1"
      ~enable_thinking:false
      ()
  in
  let body = build_request ~config ~messages:[] () in
  let json = Yojson.Safe.from_string body in
  let open Yojson.Safe.Util in
  json |> member "thinking" = `Null
  && json |> member "reasoning_effort" = `Null
  && json |> member "chat_template_kwargs" = `Null
;;

let%test "build_request emits enable_thinking for DashScope provider kind" =
  let config =
    Provider_config.make
      ~kind:DashScope
      ~model_id:"dashscope-plus"
      ~base_url:"https://dashscope.aliyuncs.com/compatible-mode/v1"
      ~enable_thinking:true
      ~thinking_budget:50
      ()
  in
  let body = build_request ~config ~messages:[] () in
  let json = Yojson.Safe.from_string body in
  let open Yojson.Safe.Util in
  json |> member "enable_thinking" |> to_bool = true
  && json |> member "thinking_budget" |> to_int = 50
  && json |> member "chat_template_kwargs" = `Null
;;

let%test "build_request emits preserve_thinking for DashScope provider kind" =
  let config =
    Provider_config.make
      ~kind:DashScope
      ~model_id:"dashscope-plus"
      ~base_url:"https://dashscope.aliyuncs.com/compatible-mode/v1"
      ~enable_thinking:true
      ~preserve_thinking:true
      ()
  in
  let body = build_request ~config ~messages:[] () in
  let json = Yojson.Safe.from_string body in
  let open Yojson.Safe.Util in
  json |> member "enable_thinking" |> to_bool = true
  && json |> member "preserve_thinking" |> to_bool = true
  && json |> member "chat_template_kwargs" = `Null
;;

let%test "build_request omits thinking params for No_thinking_control" =
  (* Generic unknown OpenAI-compatible model ids fall back to
     No_thinking_control and must not emit any provider-specific thinking
     parameter. *)
  let config =
    Provider_config.make
      ~kind:OpenAI_compat
      ~model_id:"llama-3.3-70b"
      ~base_url:"http://localhost"
      ~enable_thinking:true
      ()
  in
  let body = build_request ~config ~messages:[] () in
  let json = Yojson.Safe.from_string body in
  let open Yojson.Safe.Util in
  (* llama-3.3-70b resolves to default_capabilities (No_thinking_control),
     so neither thinking nor chat_template_kwargs should appear *)
  json |> member "thinking" = `Null && json |> member "chat_template_kwargs" = `Null
;;

let%test "max_tokens clamped to capability ceiling when caller exceeds cap" =
  (* glm-4-flash has max_output_tokens = Some 4_096 in for_model_id.
     When caller requests 8_000, backend must clamp to 4_096 to
     avoid server 400 rejection. Regression guard for S07. *)
  let config =
    Provider_config.make
      ~kind:Provider_config.Glm
      ~model_id:"glm-4-flash"
      ~base_url:Zai_catalog.general_base_url
      ~max_tokens:8_000
      ()
  in
  let body = build_request ~config ~messages:[] () in
  let json = Yojson.Safe.from_string body in
  let open Yojson.Safe.Util in
  json |> member "max_tokens" |> to_int = 4_096
;;

let%test "max_tokens passed through when within capability cap" =
  let config =
    Provider_config.make
      ~kind:Provider_config.Glm
      ~model_id:"glm-4-flash"
      ~base_url:Zai_catalog.general_base_url
      ~max_tokens:2_000
      ()
  in
  let body = build_request ~config ~messages:[] () in
  let json = Yojson.Safe.from_string body in
  let open Yojson.Safe.Util in
  json |> member "max_tokens" |> to_int = 2_000
;;

let%test "max_tokens omitted on caller None even when the catalog declares a cap" =
  (* #2517: the catalog cap is a validation ceiling, not a request
     default. glm-4-flash declares max_output_tokens = Some 4_096, but a
     caller that sends None wants the provider's own default policy — the
     field must be absent from the wire, not populated with the ceiling
     (on GLM the context window bounds input + reasoning + output jointly,
     so ceiling injection can overflow the contract on long prompts). *)
  let config =
    Provider_config.make
      ~kind:Provider_config.Glm
      ~model_id:"glm-4-flash"
      ~base_url:Zai_catalog.general_base_url
      ()
  in
  let body = build_request ~config ~messages:[] () in
  let json = Yojson.Safe.from_string body in
  match json with
  | `Assoc fields -> not (List.mem_assoc "max_tokens" fields)
  | _ -> false
;;

let%test
    "build_request emits chat_template_kwargs for declared nvidia (Chat_template_kwargs)"
  =
  (* The declared endpoint capability resolves to provider_l_capabilities, which has
     thinking_control_format = Chat_template_kwargs. The serializer
     must emit {"chat_template_kwargs": {"enable_thinking": true}}
     when enable_thinking is set. This is the only thinking branch
     that lacked a test — Thinking_object and No_thinking_control
     already have coverage. *)
  let config =
    Provider_config.make
      ~kind:OpenAI_compat
      ~model_id:"nvidia-ultra-253b"
      ~base_url:"https://integrate.api.nvidia.com"
      ~enable_thinking:true
      ~model_capabilities_override:Capabilities.provider_l_capabilities
      ()
  in
  let body = build_request ~config ~messages:[] () in
  let json = Yojson.Safe.from_string body in
  let open Yojson.Safe.Util in
  let ctk = json |> member "chat_template_kwargs" in
  ctk |> member "enable_thinking" |> to_bool = true && json |> member "thinking" = `Null
;;

let%test "build_request emits chat_template_kwargs for declared qwen3 endpoint" =
  let config =
    Provider_config.make
      ~kind:OpenAI_compat
      ~model_id:"dashscope-3.5-35b-a3b"
      ~base_url:"http://localhost"
      ~enable_thinking:true
      ~model_capabilities_override:Capabilities.provider_l_capabilities
      ()
  in
  let body = build_request ~config ~messages:[] () in
  let json = Yojson.Safe.from_string body in
  let open Yojson.Safe.Util in
  let ctk = json |> member "chat_template_kwargs" in
  ctk |> member "enable_thinking" |> to_bool = true && json |> member "thinking" = `Null
;;

let%test
    "build_request emits chat_template_kwargs preserve_thinking for declared qwen3 \
     endpoint"
  =
  let config =
    Provider_config.make
      ~kind:OpenAI_compat
      ~model_id:"dashscope-3.5-35b-a3b"
      ~base_url:"http://localhost"
      ~enable_thinking:true
      ~preserve_thinking:true
      ~model_capabilities_override:Capabilities.provider_l_capabilities
      ()
  in
  let body = build_request ~config ~messages:[] () in
  let json = Yojson.Safe.from_string body in
  let open Yojson.Safe.Util in
  let ctk = json |> member "chat_template_kwargs" in
  ctk |> member "enable_thinking" |> to_bool = true
  && ctk |> member "preserve_thinking" |> to_bool = true
  && json |> member "thinking" = `Null
;;

let%test "build_request rejects explicit seed when model does not support it" =
  let config =
    Provider_config.make
      ~kind:Provider_config.Glm
      ~model_id:"glm-5.1"
      ~base_url:Zai_catalog.general_base_url
      ~seed:42
      ()
  in
  match build_request ~config ~messages:[] () with
  | _ -> false
  | exception Invalid_argument message ->
    String.equal
      message
      "Backend_openai_request.build_request: model \"glm-5.1\" does not support seed"
;;

let%test "build_request emits only an explicit supported seed" =
  let capabilities = { Capabilities.default_capabilities with supports_seed = true } in
  let config =
    Provider_config.make
      ~kind:Provider_config.OpenAI_compat
      ~model_id:"seed-capable-model"
      ~base_url:"http://localhost"
      ~model_capabilities_override:capabilities
      ~seed:42
      ()
  in
  let body = build_request ~config ~messages:[] () in
  Yojson.Safe.Util.(body |> Yojson.Safe.from_string |> member "seed" |> to_int) = 42
;;
