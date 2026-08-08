open Alcotest
open Llm_provider

(* ── Helpers ────────────────────────────────────────── *)

let gemini_config
      ?(model_id = "gemini-2.5-flash")
      ?enable_thinking
      ?thinking_budget
      ?reasoning_effort
      ?(tools = [])
      ?(response_format = Types.Off)
      ?(system = "")
      ()
  =
  ignore tools;
  Provider_config.make
    ~kind:Gemini
    ~model_id
    ~base_url:"https://generativelanguage.googleapis.com/v1beta"
    ~api_key:"test-key"
    ~request_path:""
    ~max_tokens:4096
    ~temperature:0.7
    ?enable_thinking
    ?thinking_budget
    ?reasoning_effort
    ~response_format
    ?system_prompt:(if system = "" then None else Some system)
    ()
;;

let parse_body str = Yojson.Safe.from_string str
let member k json = Yojson.Safe.Util.member k json
let to_string json = Yojson.Safe.Util.to_string json
let to_int json = Yojson.Safe.Util.to_int json
let to_list json = Yojson.Safe.Util.to_list json
let to_bool json = Yojson.Safe.Util.to_bool json

let parse_gemini_chunk data =
  match Streaming.parse_gemini_sse_chunk data with
  | Streaming.Gemini_chunk chunk -> Some chunk
  | Streaming.Gemini_unsupported_part _ -> None
  | Streaming.Gemini_unsupported_response _ -> None
  | Streaming.Gemini_parse_failed _ -> None
;;

let gemini_events state chunk =
  match Streaming.gemini_chunk_to_events state chunk with
  | Ok events -> events
  | Error { reason } -> fail ("unexpected Gemini stream decode failure: " ^ reason)
;;

let content_has_reasoning =
  List.exists (function
    | Types.Thinking _ | ReasoningDetails _ | RedactedThinking _ -> true
    | Text _ | ToolUse _ | ToolResult _ | Image _ | Document _ | Audio _ -> false)
;;

let stamp_reasoning_history config messages =
  let source =
    match Reasoning_dialect.reasoning_source_for_provider_config config with
    | Ok source -> source
    | Error detail -> fail ("invalid Gemini reasoning source fixture: " ^ detail)
  in
  List.map
    (fun (message : Types.message) ->
       match message.role, content_has_reasoning message.content with
       | Assistant, true ->
         let metadata =
           match Types.Reasoning_source.add source message.metadata with
           | Ok metadata -> metadata
           | Error detail -> fail ("invalid Gemini reasoning fixture metadata: " ^ detail)
         in
         { message with metadata }
       | (Assistant | System | User | Tool), false | (System | User | Tool), true ->
         message)
    messages
;;

(* ── build_request tests ────────────────────────────── *)

let test_basic_request () =
  let config = gemini_config () in
  let messages = [ Types.user_msg "Hello" ] in
  let body = Backend_gemini.build_request ~config ~messages () in
  let json = parse_body body in
  let contents = json |> member "contents" |> to_list in
  check int "one content" 1 (List.length contents);
  let first = List.hd contents in
  check string "role" "user" (first |> member "role" |> to_string);
  let parts = first |> member "parts" |> to_list in
  check int "one part" 1 (List.length parts);
  check string "text" "Hello" (List.hd parts |> member "text" |> to_string);
  (* generationConfig *)
  let gen = json |> member "generationConfig" in
  check int "maxOutputTokens" 4096 (gen |> member "maxOutputTokens" |> to_int);
  check
    (float 0.01)
    "temperature"
    0.7
    (gen |> member "temperature" |> Yojson.Safe.Util.to_float)
;;

let test_explicit_supported_seed () =
  let capabilities = { Capabilities.gemini_capabilities with supports_seed = true } in
  let config =
    Provider_config.make
      ~kind:Gemini
      ~model_id:"seed-capable-gemini"
      ~base_url:"https://generativelanguage.googleapis.com/v1beta"
      ~model_capabilities_override:capabilities
      ~seed:42
      ()
  in
  let body = Backend_gemini.build_request ~config ~messages:[ Types.user_msg "Hi" ] () in
  let seed = parse_body body |> member "generationConfig" |> member "seed" |> to_int in
  check int "explicit seed" 42 seed
;;

let test_omitted_seed_stays_omitted () =
  let capabilities = { Capabilities.gemini_capabilities with supports_seed = true } in
  let config =
    Provider_config.make
      ~kind:Gemini
      ~model_id:"seed-capable-gemini"
      ~base_url:"https://generativelanguage.googleapis.com/v1beta"
      ~model_capabilities_override:capabilities
      ()
  in
  let body = Backend_gemini.build_request ~config ~messages:[ Types.user_msg "Hi" ] () in
  let seed = parse_body body |> member "generationConfig" |> member "seed" in
  check bool "seed omitted" true (seed = `Null)
;;

let test_unsupported_explicit_seed_is_rejected () =
  let config =
    Provider_config.make
      ~kind:Gemini
      ~model_id:"seed-unsupported-gemini"
      ~base_url:"https://generativelanguage.googleapis.com/v1beta"
      ~model_capabilities_override:Capabilities.gemini_capabilities
      ~seed:42
      ()
  in
  match Backend_gemini.build_request ~config ~messages:[ Types.user_msg "Hi" ] () with
  | _ -> fail "expected unsupported seed rejection"
  | exception Invalid_argument message ->
    check
      string
      "rejection"
      "Backend_gemini.build_request: model \"seed-unsupported-gemini\" does not support \
       seed"
      message
;;

let test_system_instruction () =
  let config = gemini_config ~system:"You are helpful." () in
  let messages = [ Types.user_msg "Hi" ] in
  let body = Backend_gemini.build_request ~config ~messages () in
  let json = parse_body body in
  let si = json |> member "systemInstruction" in
  check bool "has systemInstruction" true (si <> `Null);
  let parts = si |> member "parts" |> to_list in
  check bool "non-empty parts" true (List.length parts > 0);
  check
    string
    "system text"
    "You are helpful."
    (List.hd parts |> member "text" |> to_string)
;;

let test_system_from_messages () =
  let config = gemini_config () in
  let messages = [ Types.system_msg "Be concise."; Types.user_msg "Hello" ] in
  let body = Backend_gemini.build_request ~config ~messages () in
  let json = parse_body body in
  (* System message should be in systemInstruction, not in contents *)
  let si = json |> member "systemInstruction" in
  check bool "has systemInstruction" true (si <> `Null);
  let contents = json |> member "contents" |> to_list in
  (* Only the user message should be in contents *)
  check int "one content (no system)" 1 (List.length contents)
;;

let test_thinking_config () =
  let config = gemini_config ~enable_thinking:true ~thinking_budget:8000 () in
  let messages = [ Types.user_msg "Think about this." ] in
  let body = Backend_gemini.build_request ~config ~messages () in
  let json = parse_body body in
  let gen = json |> member "generationConfig" in
  let tc = gen |> member "thinkingConfig" in
  check bool "has thinkingConfig" true (tc <> `Null);
  check int "thinkingBudget" 8000 (tc |> member "thinkingBudget" |> to_int);
  check bool "includeThoughts" true (tc |> member "includeThoughts" |> to_bool)
;;

let test_thinking_disabled_requires_exact_numeric_wire () =
  let config = gemini_config ~enable_thinking:false () in
  let messages = [ Types.user_msg "Keep it short." ] in
  match Backend_gemini.build_request ~config ~messages () with
  | _ -> fail "expected exact numeric-wire rejection"
  | exception Invalid_argument message ->
    check
      string
      "rejection"
      "Backend_gemini.build_request: enable_thinking=false has no exact Gemini boolean \
       wire; pass an explicit thinking_budget only when the selected model supports that \
       numeric value"
      message
;;

let test_gemini3_uses_thinking_level () =
  let config =
    gemini_config
      ~model_id:"gemini-3.5-flash"
      ~enable_thinking:true
      ~reasoning_effort:Reasoning_effort.Low
      ()
  in
  let body =
    Backend_gemini.build_request ~config ~messages:[ Types.user_msg "Think." ] ()
  in
  let tc = parse_body body |> member "generationConfig" |> member "thinkingConfig" in
  check string "thinkingLevel" "low" (tc |> member "thinkingLevel" |> to_string);
  check bool "thinkingBudget absent" true (tc |> member "thinkingBudget" = `Null);
  check bool "includeThoughts true" true (tc |> member "includeThoughts" |> to_bool)
;;

let test_gemini3_disable_is_rejected () =
  let config =
    gemini_config ~model_id:"gemini-3-flash-preview" ~enable_thinking:false ()
  in
  match Backend_gemini.build_request ~config ~messages:[ Types.user_msg "Hi." ] () with
  | _ -> fail "expected exact-representation rejection"
  | exception Invalid_argument message ->
    check
      string
      "rejection"
      "Backend_gemini.build_request: enable_thinking=false has no exact Gemini \
       thinkingLevel representation"
      message
;;

let test_tools () =
  let config = gemini_config () in
  let messages = [ Types.user_msg "What's the weather?" ] in
  let tools =
    [ `Assoc
        [ "name", `String "get_weather"
        ; "description", `String "Get weather for a city"
        ; ( "input_schema"
          , `Assoc
              [ "type", `String "object"
              ; "properties", `Assoc [ "city", `Assoc [ "type", `String "string" ] ]
              ] )
        ]
    ]
  in
  let body = Backend_gemini.build_request ~config ~messages ~tools () in
  let json = parse_body body in
  let tools_arr = json |> member "tools" |> to_list in
  check int "one tool group" 1 (List.length tools_arr);
  let func_decls = List.hd tools_arr |> member "functionDeclarations" |> to_list in
  check int "one declaration" 1 (List.length func_decls);
  check string "tool name" "get_weather" (List.hd func_decls |> member "name" |> to_string)
;;

let test_disable_parallel_tool_use_dropped () =
  (* The Gemini API has no parallel-disable; the request must omit it entirely
     even when the caller sets disable_parallel_tool_use. *)
  let config = { (gemini_config ()) with disable_parallel_tool_use = true } in
  let messages = [ Types.user_msg "What's the weather?" ] in
  let tools =
    [ `Assoc
        [ "name", `String "get_weather"
        ; "description", `String "Get weather"
        ; "input_schema", `Assoc [ "type", `String "object" ]
        ]
    ]
  in
  let body = Backend_gemini.build_request ~config ~messages ~tools () in
  let contains needle =
    let nl = String.length needle
    and hl = String.length body in
    let rec go i = i + nl <= hl && (String.sub body i nl = needle || go (i + 1)) in
    nl = 0 || go 0
  in
  check bool "no parallel_tool_calls on the wire" false (contains "parallel_tool_calls");
  check bool "no disable_parallel on the wire" false (contains "disable_parallel");
  let json = parse_body body in
  check int "tools still present" 1 (json |> member "tools" |> to_list |> List.length)
;;

let test_tool_result () =
  let config = gemini_config () in
  let messages =
    [ Types.user_msg "What's the weather?"
    ; { role = Assistant
      ; content =
          [ ToolUse
              { id = "call_123"
              ; name = "get_weather"
              ; input = `Assoc [ "city", `String "Seoul" ]
              }
          ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ; { role = Tool
      ; content =
          [ ToolResult
              { tool_use_id = "call_123"
              ; content = "Sunny, 25C"
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
  let body = Backend_gemini.build_request ~config ~messages () in
  let json = parse_body body in
  let contents = json |> member "contents" |> to_list in
  check int "three contents" 3 (List.length contents);
  (* Third content should have functionResponse *)
  let third = List.nth contents 2 in
  let parts = third |> member "parts" |> to_list in
  let fr = List.hd parts |> member "functionResponse" in
  check bool "has functionResponse" true (fr <> `Null);
  check string "function response id" "call_123" (fr |> member "id" |> to_string);
  (* Name should be resolved from tool_use_id to tool name *)
  check string "function name" "get_weather" (fr |> member "name" |> to_string);
  let assistant = List.nth contents 1 in
  let function_call =
    assistant |> member "parts" |> to_list |> List.hd |> member "functionCall"
  in
  check string "function call id" "call_123" (function_call |> member "id" |> to_string)
;;

let test_tool_result_missing_correlation_fails_closed () =
  let messages =
    [ ({ role = Types.Tool
       ; content =
           [ Types.ToolResult
               { tool_use_id = "missing-call"
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
       : Types.message)
    ]
  in
  match Backend_gemini.contents_of_messages messages with
  | _ -> fail "expected missing Gemini tool correlation to fail closed"
  | exception Invalid_argument message ->
    check
      string
      "missing correlation"
      "Backend_gemini.contents_of_messages: ToolResult identity \"missing-call\" has no \
       matching ToolUse in the active assistant batch"
      message
;;

let test_conflicting_tool_identity_fails_closed () =
  let message : Types.message =
    { role = Assistant
    ; content =
        [ ToolUse { id = "call-1"; name = "lookup"; input = `Assoc [] }
        ; ToolUse { id = "call-1"; name = "write"; input = `Assoc [] }
        ]
    ; name = None
    ; tool_call_id = None
    ; metadata = []
    }
  in
  match Backend_gemini.contents_of_messages [ message ] with
  | _ -> fail "expected conflicting Gemini tool identity to fail closed"
  | exception Invalid_argument message ->
    check
      string
      "conflicting identity"
      "Backend_gemini.contents_of_messages: conflicting ToolUse identity \"call-1\" \
       names \"lookup\" and \"write\" in one assistant batch"
      message
;;

let test_dangling_tool_use_is_not_synthetically_closed () =
  let config = gemini_config () in
  let messages =
    [ Types.user_msg "question"
    ; { role = Assistant
      ; content = [ ToolUse { id = "call_1"; name = "lookup"; input = `Null } ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ; Types.user_msg "continue"
    ]
  in
  let body = Backend_gemini.build_request ~config ~messages () in
  let json = parse_body body in
  let contents = json |> member "contents" |> to_list in
  check int "input turns preserved" 3 (List.length contents);
  let roles = List.map (fun content -> content |> member "role" |> to_string) contents in
  check (list string) "roles" [ "user"; "model"; "user" ] roles;
  let followup = List.nth contents 2 in
  let followup_parts = followup |> member "parts" |> to_list in
  check
    bool
    "no synthetic function response"
    true
    (List.for_all (fun part -> part |> member "functionResponse" = `Null) followup_parts);
  check
    string
    "follow-up text remains exact"
    "continue"
    (List.hd followup_parts |> member "text" |> to_string)
;;

let test_json_mode () =
  let config = gemini_config ~response_format:Types.JsonMode () in
  let messages = [ Types.user_msg "Return JSON." ] in
  let body = Backend_gemini.build_request ~config ~messages () in
  let json = parse_body body in
  let gen = json |> member "generationConfig" in
  check
    string
    "responseMimeType"
    "application/json"
    (gen |> member "responseMimeType" |> to_string)
;;

let test_output_schema () =
  let schema =
    `Assoc
      [ "type", `String "object"
      ; "properties", `Assoc [ "answer", `Assoc [ "type", `String "string" ] ]
      ; "required", `List [ `String "answer" ]
      ]
  in
  let config = gemini_config ~response_format:(Types.JsonSchema schema) () in
  let messages = [ Types.user_msg "Return structured JSON." ] in
  let body = Backend_gemini.build_request ~config ~messages () in
  let json = parse_body body in
  let gen = json |> member "generationConfig" in
  check
    string
    "responseMimeType"
    "application/json"
    (gen |> member "responseMimeType" |> to_string);
  check bool "responseJsonSchema copied" true (gen |> member "responseJsonSchema" = schema)
;;

let test_role_mapping () =
  let config = gemini_config () in
  let messages =
    [ Types.user_msg "Hi"; Types.assistant_msg "Hello"; Types.user_msg "How are you?" ]
  in
  let body = Backend_gemini.build_request ~config ~messages () in
  let json = parse_body body in
  let contents = json |> member "contents" |> to_list in
  check int "three contents" 3 (List.length contents);
  check string "first role" "user" (List.nth contents 0 |> member "role" |> to_string);
  check string "second role" "model" (List.nth contents 1 |> member "role" |> to_string);
  check string "third role" "user" (List.nth contents 2 |> member "role" |> to_string)
;;

(* ── parse_response tests ───────────────────────────── *)

let test_parse_text_response () =
  let json =
    Yojson.Safe.from_string
      {|{
    "candidates": [{
      "content": {
        "parts": [{"text": "Hello, world!"}],
        "role": "model"
      },
      "finishReason": "STOP"
    }],
    "usageMetadata": {
      "promptTokenCount": 10,
      "candidatesTokenCount": 5
    },
    "modelVersion": "gemini-2.5-flash"
  }|}
  in
  let resp = Backend_gemini.parse_response json in
  check string "model" "gemini-2.5-flash" resp.model;
  (match resp.stop_reason with
   | Types.EndTurn -> ()
   | _ -> fail "expected EndTurn");
  check int "one content block" 1 (List.length resp.content);
  (match List.hd resp.content with
   | Types.Text s -> check string "text" "Hello, world!" s
   | _ -> fail "expected Text");
  match resp.usage with
  | Some u ->
    check int "input tokens" 10 u.input_tokens;
    check int "output tokens" 5 u.output_tokens
  | None -> fail "expected usage"
;;

let test_parse_thinking_response () =
  let json =
    Yojson.Safe.from_string
      {|{
    "candidates": [{
      "content": {
        "parts": [
          {"thought": true, "text": "Let me think..."},
          {"text": "The answer is 42."}
        ],
        "role": "model"
      },
      "finishReason": "STOP"
    }],
    "usageMetadata": {"promptTokenCount": 5, "candidatesTokenCount": 20}
  }|}
  in
  let resp = Backend_gemini.parse_response json in
  check int "two content blocks" 2 (List.length resp.content);
  (match List.hd resp.content with
   | Types.Thinking { content; _ } -> check string "thinking" "Let me think..." content
   | _ -> fail "expected Thinking");
  match List.nth resp.content 1 with
  | Types.Text s -> check string "text" "The answer is 42." s
  | _ -> fail "expected Text"
;;

let test_parse_function_call () =
  let json =
    Yojson.Safe.from_string
      {|{
    "candidates": [{
      "content": {
        "parts": [{
          "functionCall": {
            "name": "get_weather",
            "args": {"city": "Tokyo"}
          }
        }],
        "role": "model"
      },
      "finishReason": "STOP"
    }],
    "usageMetadata": {"promptTokenCount": 15, "candidatesTokenCount": 8}
  }|}
  in
  let resp = Backend_gemini.parse_response json in
  check int "one content block" 1 (List.length resp.content);
  (match List.hd resp.content with
   | Types.ToolUse { id; name; input } ->
     check bool "allocated id" true (String.starts_with ~prefix:"call_oas_" id);
     check string "name" "get_weather" name;
     check
       string
       "city arg"
       "Tokyo"
       (Yojson.Safe.Util.member "city" input |> Yojson.Safe.Util.to_string)
   | _ -> fail "expected ToolUse");
  match resp.stop_reason with
  | Types.StopToolUse -> ()
  | _ -> fail "expected StopToolUse"
;;

let test_parse_function_call_preserves_native_id () =
  let json =
    Yojson.Safe.from_string
      {|{"candidates":[{"content":{"parts":[{"functionCall":{"id":"gemini-call-1","name":"lookup","args":{}}}]},"finishReason":"STOP"}]}|}
  in
  match (Backend_gemini.parse_response json).content with
  | [ Types.ToolUse { id; name = "lookup"; _ } ] ->
    check string "native Gemini function call id" "gemini-call-1" id
  | _ -> fail "expected one Gemini ToolUse"
;;

let function_call_with_thought_signature_json () =
  Yojson.Safe.from_string
    {|{
    "candidates": [{
      "content": {
        "parts": [{
          "functionCall": {
            "name": "search",
            "args": {"q": "test"}
          },
          "thoughtSignature": "sig-gemini-123"
        }],
        "role": "model"
      },
      "finishReason": "STOP"
    }],
    "usageMetadata": {"promptTokenCount": 15, "candidatesTokenCount": 8},
    "modelVersion": "gemini-2.5-flash"
  }|}
;;

let test_parse_function_call_preserves_thought_signature () =
  let resp =
    Backend_gemini.parse_response (function_call_with_thought_signature_json ())
  in
  check int "two content blocks" 2 (List.length resp.content);
  (match resp.content with
   | [ Types.RedactedThinking raw; Types.ToolUse { id; name; input } ] ->
     check string "name" "search" name;
     check string "query arg" "test" (input |> member "q" |> to_string);
     let carrier = Yojson.Safe.from_string raw in
     check string "carrier provider" "gemini" (carrier |> member "provider" |> to_string);
     check
       string
       "carrier kind"
       "gemini_thought_signature"
       (carrier |> member "kind" |> to_string);
     check string "carrier tool_use_id" id (carrier |> member "tool_use_id" |> to_string);
     check
       string
       "carrier thoughtSignature"
       "sig-gemini-123"
       (carrier |> member "thoughtSignature" |> to_string)
   | _ -> fail "expected RedactedThinking carrier followed by ToolUse");
  match resp.stop_reason with
  | Types.StopToolUse -> ()
  | _ -> fail "expected StopToolUse"
;;

let textual_parts_with_thought_signatures_json () =
  Yojson.Safe.from_string
    {|{
    "candidates": [{
      "content": {
        "parts": [
          {"text": "visible", "thoughtSignature": "sig-text-123"},
          {"thought": true, "text": "plan", "thoughtSignature": "sig-thought-456"}
        ],
        "role": "model"
      },
      "finishReason": "STOP"
    }],
    "modelVersion": "gemini-3.1-pro-preview"
  }|}
;;

let check_part_signature_carrier ~target ~signature raw =
  let carrier =
    match Provider_replay.decode raw with
    | Provider_replay.Replay { retention = Provider_replay.Exact_next_block; payload } ->
      payload
    | Provider_replay.Not_replay | Provider_replay.Malformed_replay _ ->
      fail "expected an exact-next-block provider replay envelope"
  in
  check string "carrier provider" "gemini" (carrier |> member "provider" |> to_string);
  check
    string
    "carrier kind"
    "gemini_part_thought_signature"
    (carrier |> member "kind" |> to_string);
  check string "carrier target" target (carrier |> member "target" |> to_string);
  check
    string
    "carrier thoughtSignature"
    signature
    (carrier |> member "thoughtSignature" |> to_string)
;;

let test_textual_part_thought_signatures_roundtrip () =
  let config = gemini_config () in
  let parsed =
    Backend_gemini.parse_response (textual_parts_with_thought_signatures_json ())
  in
  (match parsed.content with
   | [ Types.RedactedThinking text_carrier
     ; Types.Text "visible"
     ; Types.RedactedThinking thought_carrier
     ; Types.Thinking { content = "plan"; signature = None }
     ] ->
     check_part_signature_carrier ~target:"text" ~signature:"sig-text-123" text_carrier;
     check_part_signature_carrier
       ~target:"thought"
       ~signature:"sig-thought-456"
       thought_carrier
   | _ -> fail "expected exact carriers adjacent to text and thought parts");
  let messages =
    [ Types.user_msg "Continue."
    ; { Types.role = Assistant
      ; content = parsed.content
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
    |> stamp_reasoning_history config
  in
  let body = Backend_gemini.build_request ~config ~messages () in
  let contents = parse_body body |> member "contents" |> to_list in
  let parts = List.nth contents 1 |> member "parts" |> to_list in
  match parts with
  | [ text_part; thought_part ] ->
    check string "text" "visible" (text_part |> member "text" |> to_string);
    check
      string
      "text thoughtSignature"
      "sig-text-123"
      (text_part |> member "thoughtSignature" |> to_string);
    check bool "thought marker" true (thought_part |> member "thought" |> to_bool);
    check string "thought text" "plan" (thought_part |> member "text" |> to_string);
    check
      string
      "thought thoughtSignature"
      "sig-thought-456"
      (thought_part |> member "thoughtSignature" |> to_string)
  | _ -> fail "expected two replayed Gemini parts"
;;

let test_textual_part_signature_broken_adjacency_fails_closed () =
  let carrier =
    Backend_gemini.gemini_part_thought_signature_payload
      ~target:Backend_gemini.Gemini_text_part
      ~thought_signature:"sig-text-broken"
  in
  let messages =
    [ { Types.role = Assistant
      ; content =
          [ Types.RedactedThinking carrier
          ; Types.Thinking { content = "wrong target"; signature = None }
          ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  check_raises
    "broken carrier adjacency"
    (Backend_gemini.Gemini_api_error
       "Gemini thoughtSignature carrier targets text but its adjacent content block is \
        thought")
    (fun () -> ignore (Backend_gemini.contents_of_messages messages))
;;

let message_with_blocks role content : Types.message =
  { role; content; name = None; tool_call_id = None; metadata = [] }
;;

let test_textual_part_signature_non_assistant_fails_closed () =
  let carrier =
    Backend_gemini.gemini_part_thought_signature_payload
      ~target:Backend_gemini.Gemini_text_part
      ~thought_signature:"sig-user-injection"
  in
  let messages = [ message_with_blocks User [ RedactedThinking carrier; Text "user" ] ] in
  check_raises
    "model signature on user role"
    (Backend_gemini.Gemini_api_error
       "Gemini thoughtSignature carrier is only valid on an assistant/model message")
    (fun () -> ignore (Backend_gemini.contents_of_messages messages))
;;

let test_other_provider_replay_is_not_a_gemini_signature () =
  let carrier =
    Provider_replay.encode_exact_next_block
      ~payload:
        (`Assoc
            [ "provider", `String "another-provider"
            ; "kind", `String "opaque-state"
            ; "value", `String "opaque"
            ])
  in
  let contents, _ =
    Backend_gemini.contents_of_messages
      [ message_with_blocks Assistant [ RedactedThinking carrier; Text "visible" ] ]
  in
  match contents with
  | [ content ] ->
    (match content |> member "parts" |> to_list with
     | [ part ] ->
       check string "target survives" "visible" (part |> member "text" |> to_string);
       check
         bool
         "foreign signature omitted"
         true
         (part |> member "thoughtSignature" = `Null)
     | _ -> fail "expected one visible Gemini part")
  | _ -> fail "expected one assistant content"
;;

let check_gemini_replay_payload_rejected label payload =
  let carrier = Provider_replay.encode_exact_next_block ~payload in
  check_raises
    label
    (Backend_gemini.Gemini_api_error
       "Malformed Gemini thoughtSignature carrier in conversation history")
    (fun () ->
       ignore
         (Backend_gemini.contents_of_messages
            [ message_with_blocks Assistant [ RedactedThinking carrier; Text "visible" ] ]))
;;

let canonical_gemini_replay_payload_fields () =
  let carrier =
    Backend_gemini.gemini_part_thought_signature_payload
      ~target:Backend_gemini.Gemini_text_part
      ~thought_signature:"sig-a"
  in
  match Provider_replay.decode carrier with
  | Provider_replay.Replay
      { retention = Provider_replay.Exact_next_block; payload = `Assoc fields } -> fields
  | Provider_replay.Not_replay | Provider_replay.Malformed_replay _
  | Provider_replay.Replay
      { payload = `List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null
      ; _
      } -> fail "canonical Gemini replay encoder did not produce an object payload"
;;

let test_duplicate_gemini_replay_payload_fields_fail_closed () =
  let fields = canonical_gemini_replay_payload_fields () in
  [ "provider", `String "another-provider"
  ; "kind", `String "opaque-state"
  ; "target", `String "thought"
  ; "thoughtSignature", `String "sig-b"
  ]
  |> List.iter (fun (field, conflicting_value) ->
    check_gemini_replay_payload_rejected
      ("duplicate " ^ field)
      (`Assoc (fields @ [ field, conflicting_value ])))
;;

let test_unexpected_gemini_replay_payload_field_fails_closed () =
  let fields = canonical_gemini_replay_payload_fields () in
  check_gemini_replay_payload_rejected
    "unexpected Gemini replay field"
    (`Assoc (fields @ [ "unexpected", `Bool true ]))
;;

let test_malformed_provider_replay_fails_closed () =
  let carrier =
    Backend_gemini.gemini_part_thought_signature_payload
      ~target:Backend_gemini.Gemini_text_part
      ~thought_signature:"sig-truncated"
  in
  let carrier = String.sub carrier 0 (String.length carrier - 1) in
  (match Provider_replay.decode carrier with
   | Provider_replay.Malformed_replay Provider_replay.Invalid_json -> ()
   | Provider_replay.Not_replay
   | Provider_replay.Replay _
   | Provider_replay.Malformed_replay _ ->
     fail "expected truncated OAS replay envelope to remain recognizably malformed");
  check_raises
    "malformed replay carrier"
    (Backend_gemini.Gemini_api_error
       "Malformed Gemini thoughtSignature carrier in conversation history")
    (fun () ->
       ignore
         (Backend_gemini.contents_of_messages
            [ message_with_blocks Assistant [ RedactedThinking carrier; Text "visible" ] ]))
;;

let test_blank_part_thought_signature_fails_closed () =
  let response =
    Yojson.Safe.from_string
      {|{"candidates":[{"content":{"parts":[{"text":"visible","thoughtSignature":" "}]},"finishReason":"STOP"}]}|}
  in
  check_raises
    "blank response signature"
    (Backend_gemini.Gemini_api_error "Gemini response contains a blank thoughtSignature")
    (fun () -> ignore (Backend_gemini.parse_response response))
;;

let test_signed_inline_image_roundtrip () =
  let config = gemini_config () in
  let response =
    Yojson.Safe.from_string
      {|{"candidates":[{"content":{"role":"model","parts":[{"inlineData":{"mimeType":"image/png","data":"iVBORw0KGgo="},"thoughtSignature":"sig-image"}]},"finishReason":"STOP"}]}|}
  in
  let parsed = Backend_gemini.parse_response response in
  (match parsed.content with
   | [ RedactedThinking carrier
     ; Image { media_type = "image/png"; data = "iVBORw0KGgo="; source_type = Base64 }
     ] -> check_part_signature_carrier ~target:"image" ~signature:"sig-image" carrier
   | _ -> fail "expected signed inline image response pair");
  let messages =
    [ Types.user_msg "Continue editing."; message_with_blocks Assistant parsed.content ]
    |> stamp_reasoning_history config
  in
  let body = Backend_gemini.build_request ~config ~messages () in
  let parts =
    parse_body body
    |> member "contents"
    |> to_list
    |> fun contents -> List.nth contents 1 |> member "parts" |> to_list
  in
  match parts with
  | [ part ] ->
    check
      string
      "image signature"
      "sig-image"
      (part |> member "thoughtSignature" |> to_string);
    check
      string
      "image MIME"
      "image/png"
      (part |> member "inlineData" |> member "mimeType" |> to_string)
  | _ -> fail "expected one replayed image part"
;;

let test_thought_signature_roundtrip_request () =
  let parsed =
    Backend_gemini.parse_response (function_call_with_thought_signature_json ())
  in
  let tool_use_id =
    match parsed.content with
    | [ Types.RedactedThinking _; Types.ToolUse { id; _ } ] -> id
    | _ -> fail "expected parsed signed ToolUse"
  in
  let config = gemini_config () in
  let messages =
    [ Types.user_msg "Use the search tool."
    ; { Types.role = Assistant
      ; content = parsed.content
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ; { role = Tool
      ; content =
          [ ToolResult
              { tool_use_id
              ; content = "found"
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
    |> stamp_reasoning_history config
  in
  let body = Backend_gemini.build_request ~config ~messages () in
  let json = parse_body body in
  let contents = json |> member "contents" |> to_list in
  check int "three contents" 3 (List.length contents);
  let assistant_content = List.nth contents 1 in
  let function_part =
    assistant_content
    |> member "parts"
    |> to_list
    |> function
    | [ part ] -> part
    | _ -> fail "expected one assistant functionCall part"
  in
  check
    string
    "request thoughtSignature"
    "sig-gemini-123"
    (function_part |> member "thoughtSignature" |> to_string);
  let fc = function_part |> member "functionCall" in
  check string "function name" "search" (fc |> member "name" |> to_string);
  check string "function arg" "test" (fc |> member "args" |> member "q" |> to_string);
  let tool_response_content = List.nth contents 2 in
  let fr =
    tool_response_content
    |> member "parts"
    |> to_list
    |> List.hd
    |> member "functionResponse"
  in
  check string "response function name" "search" (fr |> member "name" |> to_string)
;;

let test_parse_usage () =
  let json =
    Yojson.Safe.from_string
      {|{
    "candidates": [{
      "content": {"parts": [{"text": "hi"}], "role": "model"},
      "finishReason": "STOP"
    }],
    "usageMetadata": {
      "promptTokenCount": 100,
      "candidatesTokenCount": 50,
      "cachedContentTokenCount": 30
    }
  }|}
  in
  let resp = Backend_gemini.parse_response json in
  match resp.usage with
  | Some u ->
    check int "input" 100 u.input_tokens;
    check int "output" 50 u.output_tokens;
    check int "cache read" 30 u.cache_read_input_tokens
  | None -> fail "expected usage"
;;

let test_parse_stop_reasons () =
  let test_reason finish expected =
    let json =
      Yojson.Safe.from_string
        (Printf.sprintf
           {|{
      "candidates": [{
        "content": {"parts": [{"text": "x"}], "role": "model"},
        "finishReason": "%s"
      }]
    }|}
           finish)
    in
    let resp = Backend_gemini.parse_response json in
    check
      bool
      (Printf.sprintf "stop_reason for %s" finish)
      true
      (resp.stop_reason = expected)
  in
  test_reason "STOP" Types.EndTurn;
  test_reason "MAX_TOKENS" Types.MaxTokens;
  test_reason "SAFETY" Types.Refusal
;;

let test_parse_error () =
  let json =
    Yojson.Safe.from_string
      {|{
    "error": {
      "code": 400,
      "message": "Invalid API key",
      "status": "INVALID_ARGUMENT"
    }
  }|}
  in
  match Backend_gemini.parse_response json with
  | exception Backend_gemini.Gemini_api_error msg ->
    check bool "error contains message" true (String.length msg > 0)
  | _ -> fail "expected Gemini_api_error"
;;

(* ── contents_of_messages tests ─────────────────────── *)

let test_contents_system_extraction () =
  let messages = [ Types.system_msg "Be brief."; Types.user_msg "Hi" ] in
  let contents, sys_instr = Backend_gemini.contents_of_messages messages in
  check int "one content" 1 (List.length contents);
  check bool "has system" true (Option.is_some sys_instr)
;;

let test_contents_role_mapping () =
  let messages = [ Types.user_msg "A"; Types.assistant_msg "B"; Types.user_msg "C" ] in
  let contents, sys_instr = Backend_gemini.contents_of_messages messages in
  check int "three contents" 3 (List.length contents);
  check bool "no system" true (Option.is_none sys_instr);
  check string "first role" "user" (List.nth contents 0 |> member "role" |> to_string);
  check string "second role" "model" (List.nth contents 1 |> member "role" |> to_string)
;;

let test_contents_multimodal () =
  let messages =
    [ { Types.role = User
      ; content =
          [ Text "Describe this image:"
          ; Image
              { media_type = "image/png"
              ; data = "base64data"
              ; source_type = Types.Base64
              }
          ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  let contents, _ = Backend_gemini.contents_of_messages messages in
  check int "one content" 1 (List.length contents);
  let parts = List.hd contents |> member "parts" |> to_list in
  check int "two parts" 2 (List.length parts);
  let img_part = List.nth parts 1 in
  let inline = img_part |> member "inlineData" in
  check string "mimeType" "image/png" (inline |> member "mimeType" |> to_string)
;;

(* ── Streaming tests ────────────────────────────────── *)

let test_gemini_stream_text () =
  let data =
    {|{
    "candidates": [{
      "content": {
        "parts": [{"text": "Hello "}],
        "role": "model"
      }
    }]
  }|}
  in
  match parse_gemini_chunk data with
  | Some chunk ->
    check int "one part" 1 (List.length chunk.gem_parts);
    let state = Streaming.create_openai_stream_state () in
    let events, _tel = gemini_events state chunk in
    check bool "has events" true (List.length events > 0)
  | None -> fail "expected Some chunk"
;;

let test_gemini_stream_thinking () =
  let data =
    {|{
    "candidates": [{
      "content": {
        "parts": [{"thought": true, "text": "reasoning..."}],
        "role": "model"
      }
    }]
  }|}
  in
  match parse_gemini_chunk data with
  | Some chunk ->
    let state = Streaming.create_openai_stream_state () in
    let events, _tel = gemini_events state chunk in
    let has_thinking =
      List.exists
        (function
          | Types.ContentBlockStart { content_type = "thinking"; _ } -> true
          | _ -> false)
        events
    in
    check bool "has thinking block start" true has_thinking
  | None -> fail "expected Some chunk"
;;

let test_gemini_stream_function_call () =
  let data =
    {|{
    "candidates": [{
      "content": {
        "parts": [{
          "functionCall": {"id": "gemini-stream-call-1", "name": "search", "args": {"q": "test"}}
        }],
        "role": "model"
      }
    }]
  }|}
  in
  match parse_gemini_chunk data with
  | Some chunk ->
    let state = Streaming.create_openai_stream_state () in
    let events, _tel = gemini_events state chunk in
    (match events with
     | [ Types.ContentBlockStart { content_type = "tool_use"; tool_id = Some id; _ }
       ; Types.ContentBlockDelta _
       ] -> check string "native stream id" "gemini-stream-call-1" id
     | _ -> fail "expected identified tool start and arguments")
  | None -> fail "expected Some chunk"
;;

let test_gemini_stream_repeated_idless_calls_stay_distinct () =
  let chunk =
    match
      parse_gemini_chunk
        {|{"candidates":[{"content":{"parts":[{"functionCall":{"name":"lookup","args":{"q":"same"}}}]}}]}|}
    with
    | Some chunk -> chunk
    | None -> fail "expected id-less Gemini chunk"
  in
  let state = Streaming.create_openai_stream_state () in
  let start_id () =
    match fst (gemini_events state chunk) with
    | ContentBlockStart { content_type = "tool_use"; tool_id = Some id; _ } :: _ -> id
    | _ -> fail "expected identified Gemini tool start"
  in
  let first = start_id () in
  let second = start_id () in
  check bool "complete id-less occurrences stay distinct" true (first <> second)
;;

let test_gemini_stream_finish () =
  let data =
    {|{
    "candidates": [{
      "content": {"parts": [{"text": "done"}], "role": "model"},
      "finishReason": "STOP"
    }],
    "usageMetadata": {"promptTokenCount": 10, "candidatesTokenCount": 3}
  }|}
  in
  match parse_gemini_chunk data with
  | Some chunk ->
    let state = Streaming.create_openai_stream_state () in
    let events, _tel = gemini_events state chunk in
    let has_delta =
      List.exists
        (function
          | Types.MessageDelta { stop_reason = Some Types.EndTurn; _ } -> true
          | _ -> false)
        events
    in
    check bool "has EndTurn delta" true has_delta
  | None -> fail "expected Some chunk"
;;

let test_gemini_capabilities_named () =
  let caps = Capabilities.gemini_capabilities in
  check bool "tools" true caps.supports_tools;
  check bool "thinking" true caps.supports_extended_thinking;
  check bool "audio" true caps.supports_audio_input;
  check bool "video" true caps.supports_video_input;
  check bool "code_execution" false caps.supports_code_execution;
  check bool "caching" true caps.supports_caching;
  match caps.max_context_tokens with
  | Some n -> check int "1M context" 1_000_000 n
  | None -> fail "expected max_context_tokens"
;;

let test_tool_choice_mapping () =
  let test_choice choice expected_mode =
    let config = { (gemini_config ()) with tool_choice = Some choice } in
    let tools =
      [ `Assoc [ "name", `String "test_tool"; "description", `String "A test tool" ] ]
    in
    let messages = [ Types.user_msg "test" ] in
    let body = Backend_gemini.build_request ~config ~messages ~tools () in
    let json = parse_body body in
    let tc = json |> member "toolConfig" in
    let fcc = tc |> member "functionCallingConfig" in
    let mode = fcc |> member "mode" |> to_string in
    check
      string
      (Printf.sprintf "tool_choice mode for %s" expected_mode)
      expected_mode
      mode
  in
  test_choice Types.Auto "AUTO";
  test_choice Types.Any "ANY";
  test_choice Types.None_ "NONE"
;;

let test_tool_choice_tool_name () =
  (* tool_choice = Tool "name" forces a function-call (mode ANY) restricted to
     that named function via allowedFunctionNames. *)
  let config =
    { (gemini_config ()) with tool_choice = Some (Types.Tool "get_weather") }
  in
  let tools =
    [ `Assoc [ "name", `String "get_weather"; "description", `String "Get weather" ] ]
  in
  let messages = [ Types.user_msg "What's the weather?" ] in
  let body = Backend_gemini.build_request ~config ~messages ~tools () in
  let json = parse_body body in
  let fcc = json |> member "toolConfig" |> member "functionCallingConfig" in
  check string "mode" "ANY" (fcc |> member "mode" |> to_string);
  let allowed = fcc |> member "allowedFunctionNames" |> to_list |> List.map to_string in
  check (list string) "allowedFunctionNames" [ "get_weather" ] allowed
;;

let test_thinking_part_roundtrip () =
  (* Test that Thinking content blocks become thought:true parts *)
  let config = gemini_config () in
  let messages =
    [ { Types.role = Assistant
      ; content =
          [ Thinking { signature = None; content = "Let me consider..." }
          ; Text "The answer is 42."
          ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ; Types.user_msg "Thanks"
    ]
    |> stamp_reasoning_history config
  in
  let body = Backend_gemini.build_request ~config ~messages () in
  let json = parse_body body in
  let contents = json |> member "contents" |> to_list in
  let first = List.hd contents in
  let parts = first |> member "parts" |> to_list in
  check int "two parts" 2 (List.length parts);
  let thought_part = List.hd parts in
  check bool "thought flag" true (thought_part |> member "thought" |> to_bool);
  check
    string
    "thought text"
    "Let me consider..."
    (thought_part |> member "text" |> to_string)
;;

(** Regression test for issue #332: Gemini thinking delta must use the
    assigned block index, not hardcoded 0. *)
let test_gemini_stream_thinking_delta_index () =
  (* First chunk: thinking part *)
  let data1 =
    {|{
    "candidates": [{
      "content": {
        "parts": [{"thought": true, "text": "step 1"}],
        "role": "model"
      }
    }]
  }|}
  in
  let state = Streaming.create_openai_stream_state () in
  (match parse_gemini_chunk data1 with
   | Some chunk ->
     let events, _tel = gemini_events state chunk in
     (* ContentBlockStart at index 0, ContentBlockDelta at index 0 *)
     (match events with
      | [ ContentBlockStart { index = start_idx; content_type = "thinking"; _ }
        ; ContentBlockDelta { index = delta_idx; delta = ThinkingDelta _; _ }
        ] ->
        check int "start index" 0 start_idx;
        check int "delta index matches start" start_idx delta_idx
      | _ -> fail "expected [ContentBlockStart; ContentBlockDelta]")
   | None -> fail "expected Some chunk");
  (* Second chunk: more thinking — delta must still use index 0 *)
  let data2 =
    {|{
    "candidates": [{
      "content": {
        "parts": [{"thought": true, "text": "step 2"}],
        "role": "model"
      }
    }]
  }|}
  in
  (match parse_gemini_chunk data2 with
   | Some chunk ->
     let events, _tel = gemini_events state chunk in
     (match events with
      | [ ContentBlockDelta { index; delta = ThinkingDelta _; _ } ] ->
        check int "subsequent thinking index" 0 index
      | _ -> fail "expected [ContentBlockDelta] only")
   | None -> fail "expected Some chunk");
  (* Third chunk: text — must get index 1 *)
  let data3 =
    {|{
    "candidates": [{
      "content": {
        "parts": [{"text": "answer"}],
        "role": "model"
      }
    }]
  }|}
  in
  match parse_gemini_chunk data3 with
  | Some chunk ->
    let events, _tel = gemini_events state chunk in
    (match events with
     | [ ContentBlockStart { index = start_idx; content_type = "text"; _ }
       ; ContentBlockDelta { index = delta_idx; delta = TextDelta "answer"; _ }
       ] ->
       check int "text start index" 1 start_idx;
       check int "text delta index matches start" start_idx delta_idx
     | _ -> fail "expected [ContentBlockStart text; ContentBlockDelta text]")
  | None -> fail "expected Some chunk"
;;

(** Regression test for issue #333: function call before text in Gemini
    must not collide block indices. *)
let test_gemini_stream_tool_first_then_text () =
  let state = Streaming.create_openai_stream_state () in
  (* Chunk 1: functionCall — gets block index 0 *)
  let data1 =
    {|{
    "candidates": [{
      "content": {
        "parts": [{"functionCall": {"name": "search", "args": {"q": "test"}}}],
        "role": "model"
      }
    }]
  }|}
  in
  (match parse_gemini_chunk data1 with
   | Some chunk ->
     let events, _tel = gemini_events state chunk in
     (match events with
      | [ ContentBlockStart { index; content_type = "tool_use"; _ }
        ; ContentBlockDelta { index = d_idx; delta = InputJsonSnapshot _; _ }
        ] ->
        check int "tool start index" 0 index;
        check int "tool delta index" 0 d_idx
      | _ -> fail "expected tool_use start + delta")
   | None -> fail "expected Some chunk");
  (* Chunk 2: text — must get index 1, not 0 *)
  let data2 =
    {|{
    "candidates": [{
      "content": {
        "parts": [{"text": "here are the results"}],
        "role": "model"
      }
    }]
  }|}
  in
  (match parse_gemini_chunk data2 with
   | Some chunk ->
     let events, _tel = gemini_events state chunk in
     (match events with
      | [ ContentBlockStart { index = s_idx; content_type = "text"; _ }
        ; ContentBlockDelta { index = d_idx; delta = TextDelta "here are the results"; _ }
        ] ->
        check int "text start index" 1 s_idx;
        check int "text delta index" 1 d_idx
      | _ -> fail "expected text start at index 1 + delta")
   | None -> fail "expected Some chunk");
  (* Chunk 3: more text — must reuse index 1 *)
  let data3 =
    {|{
    "candidates": [{
      "content": {
        "parts": [{"text": " for your query"}],
        "role": "model"
      }
    }]
  }|}
  in
  match parse_gemini_chunk data3 with
  | Some chunk ->
    let events, _tel = gemini_events state chunk in
    (match events with
     | [ ContentBlockDelta { index; delta = TextDelta " for your query"; _ } ] ->
       check int "subsequent text index" 1 index
     | _ -> fail "expected delta only at index 1")
  | None -> fail "expected Some chunk"
;;

let test_gemini_stream_function_call_preserves_thought_signature () =
  let state = Streaming.create_openai_stream_state () in
  let data =
    {|{
    "candidates": [{
      "content": {
        "parts": [{
          "functionCall": {"name": "search", "args": {"q": "test"}},
          "thoughtSignature": "sig-gemini-stream-123"
        }],
        "role": "model"
      },
      "finishReason": "STOP"
    }]
  }|}
  in
  match parse_gemini_chunk data with
  | None -> fail "expected Some chunk"
  | Some chunk ->
    let events, _tel = gemini_events state chunk in
    (match events with
     | [ ContentBlockStart
           { index = redacted_idx
           ; content_type = "redacted_thinking"
           ; tool_id = Some carrier_payload
           ; tool_name = None
           }
       ; ContentBlockStart
           { index = tool_idx
           ; content_type = "tool_use"
           ; tool_id = Some tool_id
           ; tool_name = Some "search"
           }
       ; ContentBlockDelta
           { index = delta_idx; delta = InputJsonSnapshot {|{"q":"test"}|} }
       ; MessageDelta { stop_reason = Some StopToolUse; _ }
       ] ->
       check int "redacted index" 0 redacted_idx;
       check int "tool index" 1 tool_idx;
       check int "tool delta index" 1 delta_idx;
       let carrier = Yojson.Safe.from_string carrier_payload in
       check string "carrier provider" "gemini" (carrier |> member "provider" |> to_string);
       check
         string
         "carrier kind"
         "gemini_thought_signature"
         (carrier |> member "kind" |> to_string);
       check
         string
         "carrier tool_use_id"
         tool_id
         (carrier |> member "tool_use_id" |> to_string);
       check
         string
         "carrier thoughtSignature"
         "sig-gemini-stream-123"
         (carrier |> member "thoughtSignature" |> to_string);
       let acc = Complete_stream_acc.create_stream_acc () in
       List.iter (Complete_stream_acc.accumulate_event acc) events;
       (match Complete_stream_acc.finalize_stream_acc acc with
        | Error _ -> fail "expected finalized stream response"
        | Ok response ->
          (match response.stop_reason with
           | StopToolUse -> ()
           | _ -> fail "expected StopToolUse");
          (match response.content with
           | [ RedactedThinking raw; ToolUse { id; name; input } ] ->
             check string "final carrier" carrier_payload raw;
             check string "final tool id" tool_id id;
             check string "final tool name" "search" name;
             check string "final tool input" "test" (input |> member "q" |> to_string)
           | _ -> fail "expected RedactedThinking carrier followed by ToolUse"))
     | _ -> fail "expected redacted carrier, tool_use, delta, and terminal event")
;;

let test_gemini_stream_textual_parts_preserve_thought_signatures () =
  let state = Streaming.create_openai_stream_state () in
  let data =
    {|{
    "candidates": [{
      "content": {
        "parts": [
          {"text": "visible", "thoughtSignature": "sig-stream-text"},
          {"thought": true, "text": "plan", "thoughtSignature": "sig-stream-thought"}
        ],
        "role": "model"
      },
      "finishReason": "STOP"
    }]
  }|}
  in
  match parse_gemini_chunk data with
  | None -> fail "expected Some chunk"
  | Some chunk ->
    let events, _tel = gemini_events state chunk in
    (match events with
     | [ ContentBlockStart
           { index = 0
           ; content_type = "redacted_thinking"
           ; tool_id = Some text_carrier
           ; _
           }
       ; ContentBlockStart { index = 1; content_type = "text"; _ }
       ; ContentBlockDelta { index = 1; delta = TextDelta "visible" }
       ; ContentBlockStart
           { index = 2
           ; content_type = "redacted_thinking"
           ; tool_id = Some thought_carrier
           ; _
           }
       ; ContentBlockStart { index = 3; content_type = "thinking"; _ }
       ; ContentBlockDelta { index = 3; delta = ThinkingDelta "plan" }
       ; MessageDelta { stop_reason = Some EndTurn; _ }
       ] ->
       check_part_signature_carrier
         ~target:"text"
         ~signature:"sig-stream-text"
         text_carrier;
       check_part_signature_carrier
         ~target:"thought"
         ~signature:"sig-stream-thought"
         thought_carrier
     | _ -> fail "expected signed text and thought event pairs");
    let acc = Complete_stream_acc.create_stream_acc () in
    List.iter (Complete_stream_acc.accumulate_event acc) events;
    (match Complete_stream_acc.finalize_stream_acc acc with
     | Error _ -> fail "expected finalized signed textual response"
     | Ok response ->
       (match response.content with
        | [ RedactedThinking text_carrier
          ; Text "visible"
          ; RedactedThinking thought_carrier
          ; Thinking { content = "plan"; signature = None }
          ] ->
          check_part_signature_carrier
            ~target:"text"
            ~signature:"sig-stream-text"
            text_carrier;
          check_part_signature_carrier
            ~target:"thought"
            ~signature:"sig-stream-thought"
            thought_carrier
        | _ -> fail "expected finalized signed text and thought blocks"))
;;

let test_gemini_stream_signed_inline_image () =
  let state = Streaming.create_openai_stream_state () in
  let data =
    {|{"candidates":[{"content":{"role":"model","parts":[{"inlineData":{"mimeType":"image/png","data":"iVBORw0KGgo="},"thoughtSignature":"sig-stream-image"}]},"finishReason":"STOP"}]}|}
  in
  match parse_gemini_chunk data with
  | None -> fail "expected signed image chunk"
  | Some chunk ->
    let events, _ = gemini_events state chunk in
    (match events with
     | [ ContentBlockStart
           { index = 0; content_type = "redacted_thinking"; tool_id = Some carrier; _ }
       ; ContentBlockStart { index = 1; content_type = "image"; _ }
       ; ContentBlockDelta
           { index = 1
           ; delta =
               MediaDelta
                 { media_type = "image/png"; source_type = Base64; data = "iVBORw0KGgo=" }
           }
       ; MessageDelta { stop_reason = Some EndTurn; _ }
       ] ->
       check_part_signature_carrier ~target:"image" ~signature:"sig-stream-image" carrier
     | _ -> fail "expected signed image carrier and media delta");
    let acc = Complete_stream_acc.create_stream_acc () in
    List.iter (Complete_stream_acc.accumulate_event acc) events;
    (match Complete_stream_acc.finalize_stream_acc acc with
     | Ok
         { content =
             [ RedactedThinking carrier
             ; Image
                 { media_type = "image/png"; source_type = Base64; data = "iVBORw0KGgo=" }
             ]
         ; _
         } ->
       check_part_signature_carrier ~target:"image" ~signature:"sig-stream-image" carrier
     | Ok _ | Error _ -> fail "expected finalized signed image response")
;;

let parse_gemini_chunk_exn data =
  match parse_gemini_chunk data with
  | Some chunk -> chunk
  | None -> fail "expected Gemini SSE chunk"
;;

let test_gemini_stream_interleaved_thinking_tool_text_finalizes () =
  let state =
    Streaming.create_openai_stream_state
      ~provider:"gemini"
      ~model:"gemini-3-flash-preview"
      ()
  in
  let acc = Complete_stream_acc.create_stream_acc () in
  let feed data =
    let chunk = parse_gemini_chunk_exn data in
    let events, _tel = gemini_events state chunk in
    List.iter (Complete_stream_acc.accumulate_event acc) events
  in
  feed
    {|{
    "modelVersion": "gemini-3-flash-preview",
    "candidates": [{
      "content": {
        "parts": [{"thought": true, "text": "plan-"}],
        "role": "model"
      }
    }]
  }|};
  feed
    {|{
    "modelVersion": "gemini-3-flash-preview",
    "candidates": [{
      "content": {
        "parts": [{
          "functionCall": {"name": "lookup", "args": {"city": "Seoul"}},
          "thoughtSignature": "sig-gemini-interleaved-123"
        }],
        "role": "model"
      }
    }]
  }|};
  feed
    {|{
    "modelVersion": "gemini-3-flash-preview",
    "candidates": [{
      "content": {
        "parts": [{"thought": true, "text": "done"}],
        "role": "model"
      }
    }]
  }|};
  feed
    {|{
    "modelVersion": "gemini-3-flash-preview",
    "candidates": [{
      "content": {
        "parts": [{"text": "visible"}],
        "role": "model"
      },
      "finishReason": "STOP"
    }],
    "usageMetadata": {"promptTokenCount": 13, "candidatesTokenCount": 8}
  }|};
  match Complete_stream_acc.finalize_stream_acc acc with
  | Error _ -> fail "expected finalized Gemini interleaved stream"
  | Ok response ->
    check bool "stop reason" true (response.stop_reason = Types.StopToolUse);
    (match response.usage with
     | Some usage ->
       check int "input tokens" 13 usage.input_tokens;
       check int "output tokens" 8 usage.output_tokens
     | None -> fail "expected usage");
    (match response.content with
     | [ Types.Thinking { content = "plan-done"; _ }
       ; Types.RedactedThinking raw
       ; Types.ToolUse { id; name = "lookup"; input }
       ; Types.Text "visible"
       ] ->
       check bool "tool args" true (input = `Assoc [ "city", `String "Seoul" ]);
       let carrier = Yojson.Safe.from_string raw in
       check string "carrier provider" "gemini" (carrier |> member "provider" |> to_string);
       check
         string
         "carrier kind"
         "gemini_thought_signature"
         (carrier |> member "kind" |> to_string);
       check string "carrier tool id" id (carrier |> member "tool_use_id" |> to_string);
       check
         string
         "carrier signature"
         "sig-gemini-interleaved-123"
         (carrier |> member "thoughtSignature" |> to_string)
     | _ -> fail "expected thinking, redacted carrier, tool use, and visible text")
;;

(* ── Suite ────────────────────────────────────────── *)

let () =
  run
    "backend_gemini"
    [ ( "build_request"
      , [ test_case "basic" `Quick test_basic_request
        ; test_case "explicit supported seed" `Quick test_explicit_supported_seed
        ; test_case "omitted seed stays omitted" `Quick test_omitted_seed_stays_omitted
        ; test_case
            "unsupported explicit seed is rejected"
            `Quick
            test_unsupported_explicit_seed_is_rejected
        ; test_case "system instruction from config" `Quick test_system_instruction
        ; test_case "system from messages" `Quick test_system_from_messages
        ; test_case "thinking config" `Quick test_thinking_config
        ; test_case
            "thinking disabled requires exact numeric wire"
            `Quick
            test_thinking_disabled_requires_exact_numeric_wire
        ; test_case "gemini 3 uses thinkingLevel" `Quick test_gemini3_uses_thinking_level
        ; test_case "gemini 3 disable is rejected" `Quick test_gemini3_disable_is_rejected
        ; test_case "tools" `Quick test_tools
        ; test_case
            "disable_parallel dropped"
            `Quick
            test_disable_parallel_tool_use_dropped
        ; test_case "tool result" `Quick test_tool_result
        ; test_case
            "tool result missing correlation"
            `Quick
            test_tool_result_missing_correlation_fails_closed
        ; test_case
            "conflicting tool identity"
            `Quick
            test_conflicting_tool_identity_fails_closed
        ; test_case
            "dangling tool use is not synthetically closed"
            `Quick
            test_dangling_tool_use_is_not_synthetically_closed
        ; test_case "json mode" `Quick test_json_mode
        ; test_case "output schema" `Quick test_output_schema
        ; test_case "role mapping" `Quick test_role_mapping
        ; test_case "tool choice" `Quick test_tool_choice_mapping
        ; test_case "tool choice tool name" `Quick test_tool_choice_tool_name
        ; test_case "thinking part roundtrip" `Quick test_thinking_part_roundtrip
        ; test_case
            "thought signature roundtrip"
            `Quick
            test_thought_signature_roundtrip_request
        ; test_case
            "textual part thought signatures roundtrip"
            `Quick
            test_textual_part_thought_signatures_roundtrip
        ; test_case
            "textual part signature broken adjacency"
            `Quick
            test_textual_part_signature_broken_adjacency_fails_closed
        ; test_case
            "textual part signature requires assistant role"
            `Quick
            test_textual_part_signature_non_assistant_fails_closed
        ; test_case
            "foreign replay is not a Gemini signature"
            `Quick
            test_other_provider_replay_is_not_a_gemini_signature
        ; test_case
            "duplicate Gemini replay fields fail closed"
            `Quick
            test_duplicate_gemini_replay_payload_fields_fail_closed
        ; test_case
            "unexpected Gemini replay field fails closed"
            `Quick
            test_unexpected_gemini_replay_payload_field_fails_closed
        ; test_case
            "malformed replay fails closed"
            `Quick
            test_malformed_provider_replay_fails_closed
        ] )
    ; ( "parse_response"
      , [ test_case "text" `Quick test_parse_text_response
        ; test_case "thinking parts" `Quick test_parse_thinking_response
        ; test_case "function call" `Quick test_parse_function_call
        ; test_case
            "function call native id"
            `Quick
            test_parse_function_call_preserves_native_id
        ; test_case
            "function call thought signature"
            `Quick
            test_parse_function_call_preserves_thought_signature
        ; test_case
            "blank part thought signature"
            `Quick
            test_blank_part_thought_signature_fails_closed
        ; test_case
            "signed inline image roundtrip"
            `Quick
            test_signed_inline_image_roundtrip
        ; test_case "usage" `Quick test_parse_usage
        ; test_case "stop reasons" `Quick test_parse_stop_reasons
        ; test_case "error" `Quick test_parse_error
        ] )
    ; ( "contents_of_messages"
      , [ test_case "system extraction" `Quick test_contents_system_extraction
        ; test_case "role mapping" `Quick test_contents_role_mapping
        ; test_case "multimodal" `Quick test_contents_multimodal
        ] )
    ; ( "streaming"
      , [ test_case "text chunk" `Quick test_gemini_stream_text
        ; test_case "thinking chunk" `Quick test_gemini_stream_thinking
        ; test_case "function call chunk" `Quick test_gemini_stream_function_call
        ; test_case
            "repeated id-less calls stay distinct"
            `Quick
            test_gemini_stream_repeated_idless_calls_stay_distinct
        ; test_case "finish reason" `Quick test_gemini_stream_finish
        ; test_case
            "thinking delta index (#332)"
            `Quick
            test_gemini_stream_thinking_delta_index
        ; test_case
            "tool-first then text (#333)"
            `Quick
            test_gemini_stream_tool_first_then_text
        ; test_case
            "function call thought signature"
            `Quick
            test_gemini_stream_function_call_preserves_thought_signature
        ; test_case
            "textual part thought signatures"
            `Quick
            test_gemini_stream_textual_parts_preserve_thought_signatures
        ; test_case "signed inline image" `Quick test_gemini_stream_signed_inline_image
        ; test_case
            "interleaved thinking/tool/text finalizes"
            `Quick
            test_gemini_stream_interleaved_thinking_tool_text_finalizes
        ] )
    ; ( "capabilities"
      , [ test_case "gemini capabilities" `Quick test_gemini_capabilities_named ] )
    ]
;;
