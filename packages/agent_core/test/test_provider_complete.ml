(** Tests for Llm_provider.Complete — request JSON verification. *)

module PC = Llm_provider.Provider_config
module BA = Llm_provider.Backend_anthropic
module BO = Llm_provider.Backend_openai
module BOR = Llm_provider.Backend_openai_responses
module BGlm = Llm_provider.Backend_glm
module BOL = Llm_provider.Backend_ollama
module BGemini = Llm_provider.Backend_gemini
open Llm_provider.Types

let () =
  let candidates = [ "models.toml"; "../models.toml" ] in
  match List.find_opt Sys.file_exists candidates with
  | None -> Alcotest.fail "models.toml not found for provider_complete tests"
  | Some path ->
    (match Llm_provider.Model_catalog.load_file path with
     | Ok catalog -> Llm_provider.Model_catalog.set_global catalog
     | Error msg -> Alcotest.failf "failed to load %s: %s" path msg)
;;

let contains_substring ~sub text =
  let sub_len = String.length sub in
  let text_len = String.length text in
  let rec loop idx =
    if idx + sub_len > text_len
    then false
    else if String.sub text idx sub_len = sub
    then true
    else loop (idx + 1)
  in
  if sub_len = 0 then true else loop 0
;;

let catalog_capabilities ?provider_label model_id =
  let capabilities =
    match provider_label with
    | None -> Llm_provider.Capabilities.for_model_id model_id
    | Some provider_label ->
      Llm_provider.Capabilities.for_provider_model_id
        ~allow_bare_fallback:false
        ~provider_label
        ~model_id
  in
  match capabilities with
  | Some caps -> caps
  | None ->
    Alcotest.failf
      "expected catalog capabilities for %s%s"
      (match provider_label with
       | None -> ""
       | Some provider_label -> provider_label ^ "/")
      model_id
;;

let content_has_reasoning =
  List.exists (function
    | Thinking _ | ReasoningDetails _ | RedactedThinking _ -> true
    | Text _ | ToolUse _ | ToolResult _ | Image _ | Document _ | Audio _ -> false)
;;

let stamp_reasoning_history config messages =
  let source =
    match Llm_provider.Reasoning_dialect.reasoning_source_for_provider_config config with
    | Ok source -> source
    | Error detail -> Alcotest.fail ("invalid reasoning source fixture: " ^ detail)
  in
  List.map
    (fun (message : message) ->
       match message.role, content_has_reasoning message.content with
       | Assistant, true ->
         let metadata =
           match Reasoning_source.add source message.metadata with
           | Ok metadata -> metadata
           | Error detail -> Alcotest.fail ("invalid reasoning fixture: " ^ detail)
         in
         { message with metadata }
       | (Assistant | System | User | Tool), false | (System | User | Tool), true ->
         message)
    messages
;;

(* ── Anthropic build_request ─────────────────────────── *)

let test_anthropic_basic_body () =
  let config =
    PC.make
      ~kind:Anthropic
      ~model_id:"claude-sonnet-4-6"
      ~base_url:"https://api.anthropic.com"
      ~max_tokens:1024
      ()
  in
  let msgs = [ user_msg "hello" ] in
  let body = BA.build_request ~config ~messages:msgs () in
  let json = Yojson.Safe.from_string body in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "model" "claude-sonnet-4-6" (json |> member "model" |> to_string);
  Alcotest.(check int) "max_tokens" 1024 (json |> member "max_tokens" |> to_int);
  Alcotest.(check bool) "stream false" false (json |> member "stream" |> to_bool);
  let msgs_json = json |> member "messages" |> to_list in
  Alcotest.(check int) "1 message" 1 (List.length msgs_json)
;;

let test_anthropic_with_system () =
  let config =
    PC.make
      ~kind:Anthropic
      ~model_id:"claude-sonnet-4-6"
      ~base_url:""
      ~system_prompt:"You are helpful."
      ()
  in
  let body = BA.build_request ~config ~messages:[ user_msg "hi" ] () in
  let json = Yojson.Safe.from_string body in
  let open Yojson.Safe.Util in
  Alcotest.(check string)
    "system"
    "You are helpful."
    (json |> member "system" |> to_string)
;;

let test_anthropic_with_thinking () =
  let config =
    PC.make
      ~kind:Anthropic
      ~model_id:"claude-sonnet-4-6"
      ~base_url:""
      ~enable_thinking:true
      ~reasoning_effort:Llm_provider.Reasoning_effort.Medium
      ()
  in
  let body = BA.build_request ~config ~messages:[ user_msg "think" ] () in
  let json = Yojson.Safe.from_string body in
  let open Yojson.Safe.Util in
  let thinking = json |> member "thinking" in
  Alcotest.(check string)
    "thinking type"
    "adaptive"
    (thinking |> member "type" |> to_string);
  Alcotest.(check bool)
    "budget_tokens omitted"
    true
    (thinking |> member "budget_tokens" = `Null);
  Alcotest.(check string)
    "effort"
    "medium"
    (json |> member "output_config" |> member "effort" |> to_string)
;;

let test_anthropic_disabled_thinking_rejects_reasoning_effort () =
  let config =
    PC.make
      ~kind:Anthropic
      ~model_id:"claude-sonnet-4-6"
      ~base_url:""
      ~enable_thinking:false
      ~reasoning_effort:Llm_provider.Reasoning_effort.Medium
      ()
  in
  match BA.build_request ~config ~messages:[ user_msg "hi" ] () with
  | _ -> Alcotest.fail "expected disabled-thinking reasoning-effort rejection"
  | exception Invalid_argument message ->
    Alcotest.(check string)
      "rejection"
      "Backend_anthropic.build_request: model \"claude-sonnet-4-6\" cannot set \
       reasoning_effort \"medium\" when enable_thinking=false"
      message
;;

let test_anthropic_sonnet5_explicit_disable_is_serialized () =
  let config =
    PC.make
      ~kind:Anthropic
      ~model_id:"claude-sonnet-5"
      ~base_url:""
      ~enable_thinking:false
      ()
  in
  let body = BA.build_request ~config ~messages:[ user_msg "hi" ] () in
  let json = Yojson.Safe.from_string body in
  let open Yojson.Safe.Util in
  Alcotest.(check string)
    "Sonnet 5 explicit disable uses the provider disabled mode"
    "disabled"
    (json |> member "thinking" |> member "type" |> to_string)
;;

let test_anthropic_thinking_forced_tool_choice_rejected_before_request () =
  let config =
    PC.make
      ~kind:Anthropic
      ~model_id:"claude-sonnet-4-6"
      ~base_url:"https://api.anthropic.com"
      ~enable_thinking:true
      ~tool_choice:Any
      ()
  in
  Alcotest.check_raises
    "thinking + forced tool_choice fails before JSON body serialization"
    (Invalid_argument
       "Backend_anthropic.build_request: anthropic model \"claude-sonnet-4-6\" does not \
        support required forced tool_choice when thinking is enabled; use auto/none or \
        disable thinking")
    (fun () ->
       ignore (BA.build_request ~config ~messages:[ user_msg "think with a tool" ] ()))
;;

let test_anthropic_stream_flag () =
  let config = PC.make ~kind:Anthropic ~model_id:"m" ~base_url:"" ~max_tokens:128 () in
  let body = BA.build_request ~stream:true ~config ~messages:[ user_msg "hi" ] () in
  let json = Yojson.Safe.from_string body in
  let open Yojson.Safe.Util in
  Alcotest.(check bool) "stream" true (json |> member "stream" |> to_bool)
;;

let test_anthropic_output_schema () =
  let schema =
    `Assoc
      [ "type", `String "object"
      ; "properties", `Assoc [ "answer", `Assoc [ "type", `String "string" ] ]
      ; "required", `List [ `String "answer" ]
      ]
  in
  let config =
    PC.make
      ~kind:Anthropic
      ~model_id:"claude-sonnet-4-6"
      ~base_url:""
      ~response_format:(JsonSchema schema)
      ()
  in
  let body = BA.build_request ~config ~messages:[ user_msg "hi" ] () in
  let json = Yojson.Safe.from_string body in
  let open Yojson.Safe.Util in
  Alcotest.(check string)
    "output_config type"
    "json_schema"
    (json |> member "output_config" |> member "format" |> member "type" |> to_string);
  Alcotest.(check bool)
    "schema copied"
    true
    (json |> member "output_config" |> member "format" |> member "schema" = schema)
;;

let test_anthropic_json_schema_response_format () =
  let schema =
    `Assoc
      [ "type", `String "object"
      ; "properties", `Assoc [ "answer", `Assoc [ "type", `String "string" ] ]
      ; "required", `List [ `String "answer" ]
      ]
  in
  let config =
    { (PC.make ~kind:Anthropic ~model_id:"claude-sonnet-4-6" ~base_url:"" ()) with
      response_format = JsonSchema schema
    }
  in
  let body = BA.build_request ~config ~messages:[ user_msg "hi" ] () in
  let json = Yojson.Safe.from_string body in
  let open Yojson.Safe.Util in
  Alcotest.(check bool)
    "schema copied from response_format"
    true
    (json |> member "output_config" |> member "format" |> member "schema" = schema)
;;

let test_anthropic_build_request_preserves_multiturn_thinking_tool_order () =
  let msg role content = make_message ~role content in
  let signed_thinking signature content =
    Thinking { signature = Some signature; content }
  in
  let tool_call id city =
    ToolUse { id; name = "lookup_weather"; input = `Assoc [ "city", `String city ] }
  in
  let tool_result id content =
    ToolResult
      { tool_use_id = id
      ; content
      ; outcome = Tool_succeeded
      ; json = Some (`Assoc [ "content", `String content ])
      ; content_blocks = None
      }
  in
  let config =
    PC.make
      ~kind:Anthropic
      ~model_id:"claude-sonnet-4-6"
      ~base_url:"https://api.anthropic.com"
      ~max_tokens:1024
      ()
  in
  let messages =
    [ msg User [ Text "User message 1" ]
    ; msg
        Assistant
        [ signed_thinking "sig_1_1" "Thinking 1.1"; tool_call "call_1_1" "Seoul" ]
    ; msg Tool [ tool_result "call_1_1" "Tool result 1.1" ]
    ; msg
        Assistant
        [ signed_thinking "sig_1_2" "Thinking 1.2"; tool_call "call_1_2" "Busan" ]
    ; msg Tool [ tool_result "call_1_2" "Tool result 1.2" ]
    ; msg Assistant [ signed_thinking "sig_1_3" "Thinking 1.3"; Text "Answer 1" ]
    ; msg User [ Text "User message 2" ]
    ]
    |> stamp_reasoning_history config
  in
  let body = BA.build_request ~config ~messages () |> Yojson.Safe.from_string in
  let open Yojson.Safe.Util in
  let require_string_field key json =
    match member key json with
    | `String value -> value
    | `Assoc _ | `List _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null ->
      Alcotest.failf "expected string field %s in %s" key (Yojson.Safe.to_string json)
  in
  let marker message =
    let role = require_string_field "role" message in
    message
    |> member "content"
    |> to_list
    |> List.map (fun block ->
      match require_string_field "type" block with
      | "text" -> role ^ ":text:" ^ require_string_field "text" block
      | "thinking" ->
        role
        ^ ":thinking:"
        ^ require_string_field "signature" block
        ^ ":"
        ^ require_string_field "thinking" block
      | "tool_use" -> role ^ ":tool_use:" ^ require_string_field "id" block
      | "tool_result" -> role ^ ":tool_result:" ^ require_string_field "tool_use_id" block
      | other -> role ^ ":" ^ other)
  in
  let markers = body |> member "messages" |> to_list |> List.concat_map marker in
  Alcotest.(check (list string))
    "Anthropic Turn 2.1 input keeps signed thinking/tool groups in order"
    [ "user:text:User message 1"
    ; "assistant:thinking:sig_1_1:Thinking 1.1"
    ; "assistant:tool_use:call_1_1"
    ; "user:tool_result:call_1_1"
    ; "assistant:thinking:sig_1_2:Thinking 1.2"
    ; "assistant:tool_use:call_1_2"
    ; "user:tool_result:call_1_2"
    ; "assistant:thinking:sig_1_3:Thinking 1.3"
    ; "assistant:text:Answer 1"
    ; "user:text:User message 2"
    ]
    markers
;;

let test_anthropic_parse_response_initializes_telemetry () =
  let json =
    Yojson.Safe.from_string
      {|{
    "id": "msg_test",
    "model": "claude-sonnet-4-6-20250514",
    "stop_reason": "end_turn",
    "content": [
      {"type": "text", "text": "Hello there."}
    ],
    "usage": {"input_tokens": 100, "output_tokens": 50}
  }|}
  in
  let resp = BA.parse_response json in
  match resp.telemetry with
  | Some t ->
    Alcotest.(check (option int))
      "request_latency_ms defaults to unknown"
      None
      t.request_latency_ms;
    let provider_kind_t = Alcotest.testable PC.pp_provider_kind ( = ) in
    Alcotest.(check (option provider_kind_t))
      "provider_kind placeholder"
      None
      t.provider_kind;
    Alcotest.(check (option string))
      "canonical model placeholder"
      None
      t.canonical_model_id
  | None -> Alcotest.fail "expected telemetry placeholder"
;;

let test_anthropic_parse_response_rejects_unknown_content_block () =
  let json =
    Yojson.Safe.from_string
      {|{
    "id": "msg_future",
    "model": "claude-sonnet-4-6-20250514",
    "stop_reason": "end_turn",
    "content": [
      {"type": "future_block", "payload": {"text": "do not drop me"}}
    ],
    "usage": {"input_tokens": 1, "output_tokens": 1}
  }|}
  in
  Alcotest.check_raises
    "unknown Anthropic content block fails closed"
    (Invalid_argument
       "Backend_anthropic.parse_response: unsupported_content_block_type:future_block")
    (fun () -> ignore (BA.parse_response json))
;;

let test_anthropic_parse_response_rejects_unknown_media_source_kind () =
  let json =
    Yojson.Safe.from_string
      {|{
    "id": "msg_future_media",
    "model": "claude-sonnet-4-6-20250514",
    "stop_reason": "end_turn",
    "content": [
      {
        "type": "image",
        "source": {
          "type": "bytes",
          "media_type": "image/png",
          "data": "abc"
        }
      }
    ],
    "usage": {"input_tokens": 1, "output_tokens": 1}
  }|}
  in
  Alcotest.check_raises
    "unknown Anthropic media source kind fails closed"
    (Invalid_argument
       "Backend_anthropic.parse_response: unsupported_media_source_kind:image:bytes")
    (fun () -> ignore (BA.parse_response json))
;;

(* ── Openai build_request ────────────────────────────── *)

let test_openai_basic_body () =
  let config =
    PC.make
      ~kind:OpenAI_compat
      ~model_id:"gpt-4"
      ~base_url:"https://api.openai.com/v1"
      ~max_tokens:2048
      ()
  in
  let msgs = [ user_msg "hello" ] in
  let body = BO.build_request ~config ~messages:msgs () in
  let json = Yojson.Safe.from_string body in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "model" "gpt-4" (json |> member "model" |> to_string);
  Alcotest.(check int) "max_tokens" 2048 (json |> member "max_tokens" |> to_int);
  let msgs_json = json |> member "messages" |> to_list in
  Alcotest.(check int) "1 message" 1 (List.length msgs_json)
;;

let test_openai_with_system () =
  let config =
    PC.make
      ~kind:OpenAI_compat
      ~model_id:"gpt-4"
      ~base_url:""
      ~system_prompt:"Be helpful."
      ()
  in
  let body = BO.build_request ~config ~messages:[ user_msg "hi" ] () in
  let json = Yojson.Safe.from_string body in
  let open Yojson.Safe.Util in
  let msgs = json |> member "messages" |> to_list in
  (* First message should be system *)
  let first = List.hd msgs in
  Alcotest.(check string) "system role" "system" (first |> member "role" |> to_string);
  Alcotest.(check string)
    "system content"
    "Be helpful."
    (first |> member "content" |> to_string)
;;

let test_openai_with_tools () =
  let config = PC.make ~kind:OpenAI_compat ~model_id:"gpt-4" ~base_url:"" () in
  let tool =
    `Assoc
      [ "name", `String "calc"
      ; "description", `String "calculator"
      ; "input_schema", `Assoc [ "type", `String "object" ]
      ]
  in
  let body =
    BO.build_request ~config ~messages:[ user_msg "add 1+1" ] ~tools:[ tool ] ()
  in
  let json = Yojson.Safe.from_string body in
  let open Yojson.Safe.Util in
  let tools = json |> member "tools" |> to_list in
  Alcotest.(check int) "1 tool" 1 (List.length tools)
;;

let openai_responses_config () =
  PC.make
    ~kind:OpenAI_compat
    ~model_id:"gpt-5.5"
    ~base_url:"https://api.openai.com/v1"
    ~request_path:"/v1/responses"
    ()
;;

let test_openai_responses_replays_assistant_phase_metadata () =
  let config = openai_responses_config () in
  let messages =
    [ { role = User
      ; content = [ Text "continue" ]
      ; name = None
      ; tool_call_id = None
      ; metadata = [ BOR.response_phase_metadata BOR.Final_answer ]
      }
    ; { role = Assistant
      ; content = [ Text "I will check." ]
      ; name = None
      ; tool_call_id = None
      ; metadata = [ BOR.response_phase_metadata BOR.Commentary ]
      }
    ]
  in
  let body = BOR.build_request ~config ~messages () in
  let json = Yojson.Safe.from_string body in
  let open Yojson.Safe.Util in
  let input = json |> member "input" |> to_list in
  let user_item = List.nth input 0 in
  let assistant_item = List.nth input 1 in
  Alcotest.(check bool) "user phase omitted" true (user_item |> member "phase" = `Null);
  Alcotest.(check string)
    "assistant type"
    "message"
    (assistant_item |> member "type" |> to_string);
  Alcotest.(check string)
    "assistant phase"
    "commentary"
    (assistant_item |> member "phase" |> to_string)
;;

let unsupported_openai_responses_phase_message phase =
  Printf.sprintf
    "Backend_openai_responses.phase: unsupported %s=%S"
    BOR.response_phase_metadata_key
    phase
;;

let check_openai_responses_phase_metadata_rejected ~name ~metadata ~message =
  let config = openai_responses_config () in
  let messages =
    [ { role = Assistant
      ; content = [ Text "drafting" ]
      ; name = None
      ; tool_call_id = None
      ; metadata = [ metadata ]
      }
    ]
  in
  Alcotest.check_raises name (Invalid_argument message) (fun () ->
    ignore (BOR.build_request ~config ~messages ()))
;;

let check_openai_responses_phase_rejected ~name ~phase =
  check_openai_responses_phase_metadata_rejected
    ~name
    ~metadata:(BOR.response_phase_metadata_key, `String phase)
    ~message:(unsupported_openai_responses_phase_message phase)
;;

let test_openai_responses_rejects_unknown_assistant_phase () =
  check_openai_responses_phase_rejected
    ~name:"unknown Responses phase rejected"
    ~phase:"analysis"
;;

let test_openai_responses_rejects_padded_assistant_phase () =
  check_openai_responses_phase_rejected
    ~name:"padded Responses phase rejected"
    ~phase:" commentary "
;;

let test_openai_responses_rejects_blank_assistant_phase () =
  check_openai_responses_phase_rejected
    ~name:"blank Responses phase rejected"
    ~phase:"   "
;;

let test_openai_responses_rejects_non_string_assistant_phase () =
  check_openai_responses_phase_metadata_rejected
    ~name:"non-string Responses phase rejected"
    ~metadata:(BOR.response_phase_metadata_key, `Int 1)
    ~message:"Backend_openai_responses.phase: openai.responses.phase must be a string"
;;

let test_openai_stream_flag () =
  let config = PC.make ~kind:OpenAI_compat ~model_id:"m" ~base_url:"" () in
  let body = BO.build_request ~stream:true ~config ~messages:[ user_msg "hi" ] () in
  let json = Yojson.Safe.from_string body in
  let open Yojson.Safe.Util in
  Alcotest.(check bool) "stream" true (json |> member "stream" |> to_bool)
;;

let test_ollama_output_schema () =
  let schema =
    `Assoc
      [ "type", `String "object"
      ; "properties", `Assoc [ "answer", `Assoc [ "type", `String "string" ] ]
      ; "required", `List [ `String "answer" ]
      ]
  in
  let config =
    PC.make
      ~kind:Ollama
      ~model_id:"dashscope-3.5:9b"
      ~base_url:"http://localhost:11434"
      ~response_format:(JsonSchema schema)
      ()
  in
  let body = BOL.build_request ~config ~messages:[ user_msg "hi" ] () in
  let json = Yojson.Safe.from_string body in
  let open Yojson.Safe.Util in
  Alcotest.(check bool) "format copied" true (json |> member "format" = schema)
;;

let test_ollama_gemma4_thinking_uses_template_token () =
  let config =
    PC.make
      ~kind:Ollama
      ~model_id:"hf.co/unsloth/gemma-4-26B-A4B-it-qat-GGUF:UD-Q4_K_XL"
      ~base_url:"http://localhost:11434"
      ~system_prompt:"You are a helpful assistant."
      ~enable_thinking:true
      ()
  in
  let body = BOL.build_request ~config ~messages:[ user_msg "solve 19*21" ] () in
  let json = Yojson.Safe.from_string body in
  let open Yojson.Safe.Util in
  Alcotest.(check bool)
    "omits top-level think for Gemma 4"
    true
    (json |> member "think" = `Null);
  let first_message = json |> member "messages" |> index 0 in
  Alcotest.(check string)
    "system role"
    "system"
    (first_message |> member "role" |> to_string);
  Alcotest.(check bool)
    "system prompt starts with Gemma 4 think token"
    true
    (String.starts_with
       ~prefix:"<|think|>\n"
       (first_message |> member "content" |> to_string))
;;

let test_ollama_native_multimodal_request_body () =
  (* Ollama native /api/chat rejects an array-valued content field and expects
     images in a separate images array of base64 payloads. *)
  let config =
    PC.make ~kind:Ollama ~model_id:"gemma4:9b" ~base_url:"http://localhost:11434" ()
  in
  let messages =
    [ { role = User
      ; content =
          [ Text "What is in this image?"
          ; Image { media_type = "image/png"; data = "base64img"; source_type = Base64 }
          ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  let body = BOL.build_request ~config ~messages () in
  let json = Yojson.Safe.from_string body in
  let open Yojson.Safe.Util in
  let user_msg = json |> member "messages" |> index 0 in
  Alcotest.(check string) "role" "user" (user_msg |> member "role" |> to_string);
  Alcotest.(check string)
    "content is plain string"
    "What is in this image?"
    (user_msg |> member "content" |> to_string);
  let images = user_msg |> member "images" |> to_list in
  Alcotest.(check int) "images count" 1 (List.length images);
  Alcotest.(check string) "image payload" "base64img" (List.nth images 0 |> to_string);
  (* Verify the overall body still carries model/stream/keep_alive as before. *)
  Alcotest.(check string) "model" "gemma4:9b" (json |> member "model" |> to_string);
  Alcotest.(check bool) "stream" false (json |> member "stream" |> to_bool)
;;

let test_ollama_parse_parallel_tool_calls_object_arguments () =
  let body =
    {|{"model":"dashscope-3:8b","done":true,"done_reason":"tool_calls",
       "message":{"role":"assistant","content":"",
         "tool_calls":[
           {"function":{"index":0,"name":"get_temperature","arguments":{"city":"New York"}}},
           {"function":{"index":1,"name":"get_conditions","arguments":{"city":"London"}}}
         ]}}|}
  in
  match BOL.parse_ollama_response body with
  | Error msg -> Alcotest.fail msg
  | Ok resp ->
    Alcotest.(check bool) "stop tool use" true (resp.stop_reason = StopToolUse);
    (match resp.content with
     | [ ToolUse first; ToolUse second ] ->
       Alcotest.(check string) "first name" "get_temperature" first.name;
       Alcotest.(check string) "second name" "get_conditions" second.name;
       Alcotest.(check bool) "distinct synthetic ids" true (first.id <> second.id);
       Alcotest.(check bool)
         "first input object"
         true
         (first.input = `Assoc [ "city", `String "New York" ]);
       Alcotest.(check bool)
         "second input object"
         true
         (second.input = `Assoc [ "city", `String "London" ])
     | _ -> Alcotest.fail "expected two ToolUse blocks")
;;

let test_ollama_parse_tool_call_preserves_explicit_id_and_string_arguments () =
  let body =
    {|{"model":"dashscope-3:8b","done":true,"done_reason":"tool_calls",
       "message":{"role":"assistant","content":"",
         "tool_calls":[
           {"id":"call_explicit","function":{"name":"get_weather","arguments":"{\"city\":\"Seoul\"}"}}
         ]}}|}
  in
  match BOL.parse_ollama_response body with
  | Error msg -> Alcotest.fail msg
  | Ok resp ->
    (match resp.content with
     | [ ToolUse tool_use ] ->
       Alcotest.(check string) "id" "call_explicit" tool_use.id;
       Alcotest.(check string) "name" "get_weather" tool_use.name;
       Alcotest.(check bool)
         "input"
         true
         (tool_use.input = `Assoc [ "city", `String "Seoul" ])
     | _ -> Alcotest.fail "expected one ToolUse block")
;;

let test_ollama_parse_rejects_malformed_tool_call () =
  let body =
    {|{"model":"dashscope-3:8b","done":true,"done_reason":"tool_calls",
       "message":{"role":"assistant","content":"",
         "tool_calls":[
           {"function":{"name":"ok_tool","arguments":{"city":"Seoul"}}},
           {"function":{"arguments":{"city":"Missing name"}}}
         ]}}|}
  in
  match BOL.parse_ollama_response body with
  | Error msg ->
    Alcotest.(check string)
      "malformed tool call rejected"
      "malformed_ollama_tool_call:index:1:missing_name"
      msg
  | Ok _ -> Alcotest.fail "expected malformed Ollama tool_call to fail closed"
;;

let test_ollama_parse_rejects_non_object_tool_arguments () =
  let body =
    {|{"model":"dashscope-3:8b","done":true,"done_reason":"tool_calls",
       "message":{"role":"assistant","content":"",
         "tool_calls":[
           {"function":{"name":"get_weather","arguments":"42"}}
         ]}}|}
  in
  match BOL.parse_ollama_response body with
  | Error msg ->
    Alcotest.(check string)
      "non-object arguments rejected"
      "malformed_ollama_tool_call_arguments:index:0:not_object"
      msg
  | Ok _ -> Alcotest.fail "expected non-object Ollama tool arguments to fail closed"
;;

let ollama_tool_correlation_config () =
  PC.make
    ~kind:Ollama
    ~model_id:"native-tool-correlation-test"
    ~base_url:"http://127.0.0.1:11434"
    ()
;;

let tool_result_message tool_use_id : message =
  { role = Tool
  ; content =
      [ ToolResult
          { tool_use_id
          ; content = "ok"
          ; outcome = Tool_succeeded
          ; json = None
          ; content_blocks = None
          }
      ]
  ; name = None
  ; tool_call_id = None
  ; metadata = []
  }
;;

let tool_use_message id name : message =
  { role = Assistant
  ; content = [ ToolUse { id; name; input = `Assoc [] } ]
  ; name = None
  ; tool_call_id = None
  ; metadata = []
  }
;;

let check_ollama_correlation_rejected ~expected messages =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let config = ollama_tool_correlation_config () in
  let check_result label = function
    | Error (Llm_provider.Http_client.AcceptRejected { reason }) ->
      Alcotest.(check string) label expected reason
    | Ok _ -> Alcotest.failf "%s: expected AcceptRejected" label
    | Error _ -> Alcotest.failf "%s: expected typed AcceptRejected" label
  in
  check_result
    "sync correlation rejection"
    (Llm_provider.Complete.complete ~sw ~net ~config ~messages ());
  check_result
    "stream correlation rejection"
    (Llm_provider.Complete.complete_stream
       ~sw
       ~net
       ~config
       ~messages
       ~on_event:(fun _ -> ())
       ())
;;

let test_ollama_missing_tool_correlation_rejected_sync_and_stream () =
  check_ollama_correlation_rejected
    ~expected:
      "Backend_ollama.build_request: ToolResult identity \"missing-call\" has no \
       matching ToolUse in the active assistant batch"
    [ tool_result_message "missing-call" ]
;;

let test_ollama_conflicting_tool_correlation_rejected_sync_and_stream () =
  let conflicting_batch : message =
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
  check_ollama_correlation_rejected
    ~expected:
      "Backend_ollama.build_request: conflicting ToolUse identity \"call-1\" names \
       \"lookup\" and \"write\" in one assistant batch"
    [ conflicting_batch; tool_result_message "call-1" ]
;;

let test_ollama_reused_tool_id_resolves_by_turn_occurrence () =
  let messages =
    [ user_msg "first turn"
    ; tool_use_message "reused-call" "lookup"
    ; tool_result_message "reused-call"
    ; user_msg "second turn"
    ; tool_use_message "reused-call" "write"
    ; tool_result_message "reused-call"
    ]
  in
  let body =
    BOL.build_request ~config:(ollama_tool_correlation_config ()) ~messages ()
    |> Yojson.Safe.from_string
  in
  let tool_names =
    Yojson.Safe.Util.(body |> member "messages" |> to_list)
    |> List.filter_map (fun message ->
      match Yojson.Safe.Util.(message |> member "role" |> to_string_option) with
      | Some "tool" ->
        Yojson.Safe.Util.(message |> member "tool_name" |> to_string_option)
      | Some _ | None -> None)
  in
  Alcotest.(check (list string))
    "provider id reuse is scoped to each canonical turn occurrence"
    [ "lookup"; "write" ]
    tool_names
;;

let test_ollama_native_tool_role_rejects_legacy_shapes () =
  let cases =
    [ ( "User/ToolResult"
      , [ tool_use_message "call-1" "lookup"
        ; { (tool_result_message "call-1") with role = User }
        ]
      , "Backend_ollama.build_request: Ollama native ToolResult must use role Tool, got \
         role user" )
    ; ( "Tool/Text"
      , [ make_message ~role:Tool [ Text "legacy fallback" ] ]
      , "Backend_ollama.build_request: Ollama native role Tool accepts only ToolResult \
         blocks" )
    ; ( "empty Tool"
      , [ make_message ~role:Tool [] ]
      , "Backend_ollama.build_request: Ollama native role Tool requires at least one \
         ToolResult" )
    ; ( "User/ToolUse"
      , [ { (tool_use_message "call-1" "lookup") with role = User } ]
      , "Backend_ollama.build_request: Ollama native ToolUse must use role Assistant, \
         got role user" )
    ; ( "System/ToolUse"
      , [ { (tool_use_message "call-1" "lookup") with role = System } ]
      , "Backend_ollama.build_request: Ollama native ToolUse must use role Assistant, \
         got role system" )
    ]
  in
  List.iter
    (fun (label, messages, expected) ->
       match
         BOL.build_request ~config:(ollama_tool_correlation_config ()) ~messages ()
       with
       | _ -> Alcotest.failf "expected legacy Ollama native shape %s to be rejected" label
       | exception Invalid_argument message ->
         Alcotest.(check string) label expected message)
    cases
;;

let test_openai_with_json_schema () =
  let schema =
    `Assoc
      [ "type", `String "object"
      ; "properties", `Assoc [ "answer", `Assoc [ "type", `String "string" ] ]
      ]
  in
  let config =
    PC.make
      ~kind:OpenAI_compat
      ~model_id:"gpt-mini"
      ~base_url:"https://api.openai.com/v1"
      ~response_format:(JsonSchema schema)
      ()
  in
  let body = BO.build_request ~config ~messages:[ user_msg "Return JSON." ] () in
  let json = Yojson.Safe.from_string body in
  let open Yojson.Safe.Util in
  let response_format = json |> member "response_format" in
  Alcotest.(check string)
    "response_format.type"
    "json_schema"
    (response_format |> member "type" |> to_string);
  Alcotest.(check string)
    "json_schema.name"
    "structured_output"
    (response_format |> member "json_schema" |> member "name" |> to_string);
  Alcotest.(check string)
    "json_schema.schema.type"
    "object"
    (response_format
     |> member "json_schema"
     |> member "schema"
     |> member "type"
     |> to_string)
;;

let test_gemini_with_json_schema () =
  let schema =
    `Assoc
      [ "type", `String "object"
      ; "properties", `Assoc [ "answer", `Assoc [ "type", `String "string" ] ]
      ; "required", `List [ `String "answer" ]
      ]
  in
  let config =
    PC.make
      ~kind:Gemini
      ~model_id:"gemini-2.5-flash"
      ~base_url:"https://generativelanguage.googleapis.com/v1beta"
      ~api_key:"test-key"
      ~response_format:(JsonSchema schema)
      ()
  in
  let body = BGemini.build_request ~config ~messages:[ user_msg "Return JSON." ] () in
  let json = Yojson.Safe.from_string body in
  let open Yojson.Safe.Util in
  let generation_config = json |> member "generationConfig" in
  Alcotest.(check string)
    "responseMimeType"
    "application/json"
    (generation_config |> member "responseMimeType" |> to_string);
  Alcotest.(check string)
    "responseJsonSchema.type"
    "object"
    (generation_config |> member "responseJsonSchema" |> member "type" |> to_string);
  Alcotest.(check string)
    "responseJsonSchema.required[0]"
    "answer"
    (generation_config
     |> member "responseJsonSchema"
     |> member "required"
     |> to_list
     |> List.hd
     |> to_string)
;;

let test_kimi_direct_with_tools_and_thinking () =
  let config =
    PC.make
      ~kind:Kimi
      ~model_id:"kimi-for-coding"
      ~base_url:"https://api.kimi.com/coding"
      ~enable_thinking:true
      ~thinking_budget:4096
      ()
  in
  let tool =
    `Assoc
      [ "name", `String "shell"
      ; "description", `String "run shell command"
      ; "input_schema", `Assoc [ "type", `String "object" ]
      ]
  in
  let body =
    BA.build_request ~config ~messages:[ user_msg "inspect repo" ] ~tools:[ tool ] ()
  in
  let json = Yojson.Safe.from_string body in
  let open Yojson.Safe.Util in
  let tools = json |> member "tools" |> to_list in
  let thinking = json |> member "thinking" in
  Alcotest.(check string) "model" "kimi-for-coding" (json |> member "model" |> to_string);
  Alcotest.(check int) "tool count" 1 (List.length tools);
  Alcotest.(check string)
    "thinking type"
    "enabled"
    (thinking |> member "type" |> to_string)
;;

let test_kimi_direct_tool_result_uses_text_blocks () =
  let config =
    PC.make
      ~kind:Kimi
      ~model_id:"kimi-for-coding"
      ~base_url:"https://api.kimi.com/coding"
      ()
  in
  let messages =
    [ { role = Assistant
      ; content =
          [ Thinking
              { signature = Some "sig_1"; content = "I should call the calculator." }
          ; ToolUse
              { id = "tool_1"
              ; name = "calculator"
              ; input = `Assoc [ "a", `Int 2; "b", `Int 3 ]
              }
          ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ; { role = Tool
      ; content =
          [ ToolResult
              { tool_use_id = "tool_1"
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
    ]
    |> stamp_reasoning_history config
  in
  let body = BA.build_request ~config ~messages () in
  let json = Yojson.Safe.from_string body in
  let open Yojson.Safe.Util in
  let replay = json |> member "messages" |> index 1 in
  let block = replay |> member "content" |> index 0 in
  Alcotest.(check string)
    "tool result role serialized as user"
    "user"
    (replay |> member "role" |> to_string);
  Alcotest.(check string)
    "tool_result type"
    "tool_result"
    (block |> member "type" |> to_string);
  Alcotest.(check string)
    "tool_use id preserved"
    "tool_1"
    (block |> member "tool_use_id" |> to_string);
  let result_content = block |> member "content" |> to_list in
  Alcotest.(check int) "tool_result content block count" 1 (List.length result_content);
  let text_block = List.hd result_content in
  Alcotest.(check string)
    "tool_result content type"
    "text"
    (text_block |> member "type" |> to_string);
  Alcotest.(check string)
    "tool_result content"
    "5"
    (text_block |> member "text" |> to_string)
;;

let test_glm_preserved_reasoning_replay_and_preserves_auto_tool_choice () =
  let config =
    PC.make
      ~kind:Glm
      ~model_id:"glm-5.1"
      ~base_url:"https://api.z.ai/api/coding/paas/v4"
      ~enable_thinking:true
      ~clear_thinking:false
      ~tool_stream:true
      ~tool_choice:Auto
      ~supports_tool_choice_override:true
      ()
  in
  let messages =
    [ { role = Assistant
      ; content =
          [ Thinking { signature = None; content = "I need the calculator result." }
          ; ToolUse
              { id = "call_1"
              ; name = "calculator"
              ; input = `Assoc [ "expr", `String "2+2" ]
              }
          ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ; { role = Tool
      ; content =
          [ ToolResult
              { tool_use_id = "call_1"
              ; content = "{\"value\":4}"
              ; outcome = Tool_succeeded
              ; json = Some (`Assoc [ "value", `Int 4 ])
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
  let body = BGlm.build_request ~stream:true ~config ~messages () in
  let json = Yojson.Safe.from_string body in
  let open Yojson.Safe.Util in
  let assistant = json |> member "messages" |> index 0 in
  Alcotest.(check string)
    "glm auto tool_choice preserved"
    "auto"
    (json |> member "tool_choice" |> to_string);
  Alcotest.(check string)
    "assistant content remains text channel"
    ""
    (assistant |> member "content" |> to_string);
  Alcotest.(check string)
    "reasoning replayed separately"
    "I need the calculator result."
    (assistant |> member "reasoning_content" |> to_string);
  Alcotest.(check bool)
    "clear_thinking false preserved"
    true
    (json |> member "thinking" |> member "clear_thinking" |> to_bool = false);
  Alcotest.(check bool)
    "tool_stream enabled"
    true
    (json |> member "tool_stream" |> to_bool)
;;

let test_complete_rejects_glm_named_forced_tool_choice_before_request () =
  let config =
    PC.make
      ~kind:Glm
      ~model_id:"glm-5.1"
      ~base_url:"https://api.z.ai/api/coding/paas/v4"
      ~enable_thinking:true
      ~tool_choice:(Tool "calculator")
      ()
  in
  let assert_rejected label result =
    match result with
    | Error (Llm_provider.Http_client.AcceptRejected { reason }) ->
      Alcotest.(check bool)
        label
        true
        (contains_substring ~sub:"tool_choice" reason
         && contains_substring ~sub:"calculator" reason)
    | Ok _ -> Alcotest.failf "%s: expected AcceptRejected" label
    | Error _ -> Alcotest.failf "%s: expected AcceptRejected" label
  in
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let net = Eio.Stdenv.net env in
  assert_rejected
    "sync completion rejects before request"
    (Llm_provider.Complete.complete ~sw ~net ~config ~messages:[] ());
  assert_rejected
    "stream completion rejects before request"
    (Llm_provider.Complete.complete_stream
       ~sw
       ~net
       ~config
       ~messages:[]
       ~on_event:(fun _ -> ())
       ())
;;

(* ── Provider_config.make ────────────────────────────── *)

let test_config_default_paths () =
  let anth = PC.make ~kind:Anthropic ~model_id:"m" ~base_url:"" () in
  Alcotest.(check string) "anthropic path" "/v1/messages" anth.request_path;
  let kimi = PC.make ~kind:Kimi ~model_id:"m" ~base_url:"" () in
  Alcotest.(check string) "kimi path" "/v1/messages" kimi.request_path;
  let oai = PC.make ~kind:OpenAI_compat ~model_id:"m" ~base_url:"" () in
  Alcotest.(check string) "openai path" "/v1/chat/completions" oai.request_path
;;

let test_config_custom_path () =
  let cfg =
    PC.make ~kind:OpenAI_compat ~model_id:"m" ~base_url:"" ~request_path:"/custom" ()
  in
  Alcotest.(check string) "custom path" "/custom" cfg.request_path
;;

let usage =
  Some
    { input_tokens = 1
    ; output_tokens = 1
    ; cache_creation_input_tokens = 0
    ; cache_read_input_tokens = 0
    ; cost_usd = None
    }
;;

let fake_transport response : Llm_provider.Llm_transport.t =
  { complete_sync = (fun _request -> { response = Ok response; latency_ms = Some 1 })
  ; complete_stream = (fun ?on_telemetry:_ ~on_event:_ _request -> Ok response)
  }
;;

let successful_response model : api_response =
  { id = "response-ok"
  ; model
  ; stop_reason = EndTurn
  ; content = [ Text "ok" ]
  ; usage
  ; telemetry = None
  }
;;

let rejected_before_transport : Llm_provider.Llm_transport.t =
  { complete_sync = (fun _ -> Alcotest.fail "sync transport must not be called")
  ; complete_stream =
      (fun ?on_telemetry:_ ~on_event:_ _ ->
        Alcotest.fail "stream transport must not be called")
  }
;;

let complete_sync_and_stream ~config ~transport =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let sync =
    Llm_provider.Complete.complete
      ~sw
      ~net
      ~config
      ~messages:[ user_msg "hi" ]
      ~transport
      ()
  in
  let stream =
    Llm_provider.Complete.complete_stream
      ~sw
      ~net
      ~config
      ~messages:[ user_msg "hi" ]
      ~on_event:(fun _ -> ())
      ~transport
      ()
  in
  sync, stream
;;

let expect_complete_ok label = function
  | Ok _ -> ()
  | Error _ -> Alcotest.failf "%s: expected completion success" label
;;

let accept_rejected_reason label = function
  | Error (Llm_provider.Http_client.AcceptRejected { reason }) -> reason
  | Ok _ -> Alcotest.failf "%s: expected AcceptRejected" label
  | Error _ -> Alcotest.failf "%s: expected typed AcceptRejected" label
;;

let enable_thinking_field body =
  body |> Yojson.Safe.from_string |> Yojson.Safe.Util.member "enable_thinking"
;;

let test_unknown_openai_compat_enable_rejected_sync_and_stream () =
  let rejected_reasons request_path =
    let config =
      PC.make
        ~kind:OpenAI_compat
        ~model_id:"unknown-openai-compatible-model"
        ~base_url:"https://unknown-openai-compatible.example/v1"
        ~request_path
        ~enable_thinking:true
        ()
    in
    let sync, stream =
      complete_sync_and_stream ~config ~transport:rejected_before_transport
    in
    accept_rejected_reason "sync" sync, accept_rejected_reason "stream" stream
  in
  let chat_sync, chat_stream = rejected_reasons "/v1/chat/completions" in
  let responses_sync, responses_stream = rejected_reasons "/v1/responses" in
  List.iter
    (Alcotest.check Alcotest.string "same typed rejection payload" chat_sync)
    [ chat_stream; responses_sync; responses_stream ];
  List.iter
    (fun fragment ->
       Alcotest.(check bool)
         ("rejection contains " ^ fragment)
         true
         (contains_substring ~sub:fragment chat_sync))
    [ "enable_thinking=true"
    ; "thinking_control_format=No_thinking_control"
    ; "supports_reasoning=false"
    ]
;;

let test_declared_enable_dialect_passes_sync_stream_and_wire () =
  let caps =
    { Llm_provider.Capabilities.openai_compat_chat_capabilities with
      supports_reasoning = true
    ; supports_extended_thinking = true
    ; thinking_control_format = Llm_provider.Capabilities.Enable_thinking
    }
  in
  let config =
    PC.make
      ~kind:OpenAI_compat
      ~model_id:"declared-enable-dialect"
      ~base_url:"https://declared-openai-compatible.example/v1"
      ~model_capabilities_override:caps
      ~enable_thinking:true
      ()
  in
  let transport = fake_transport (successful_response config.model_id) in
  let sync, stream = complete_sync_and_stream ~config ~transport in
  expect_complete_ok "sync declared dialect" sync;
  expect_complete_ok "stream declared dialect" stream;
  Alcotest.(check bool)
    "sync wire carries enable_thinking=true"
    true
    (enable_thinking_field (BO.build_request ~config ~messages:[ user_msg "hi" ] ())
     = `Bool true);
  Alcotest.(check bool)
    "stream wire carries enable_thinking=true"
    true
    (enable_thinking_field
       (BO.build_request ~stream:true ~config ~messages:[ user_msg "hi" ] ())
     = `Bool true)
;;

let test_declared_responses_effort_passes_sync_stream_and_wire () =
  let caps =
    { Llm_provider.Capabilities.openai_compat_chat_capabilities with
      supports_reasoning = true
    ; supports_extended_thinking = true
    ; thinking_control_format = Llm_provider.Capabilities.Reasoning_effort
    ; accepted_reasoning_efforts = Some [ Llm_provider.Reasoning_effort.Medium ]
    }
  in
  let config =
    PC.make
      ~kind:OpenAI_compat
      ~model_id:"declared-responses-effort"
      ~base_url:"https://declared-openai-compatible.example/v1"
      ~request_path:"/v1/responses"
      ~model_capabilities_override:caps
      ~enable_thinking:true
      ~reasoning_effort:Llm_provider.Reasoning_effort.Medium
      ()
  in
  let transport = fake_transport (successful_response config.model_id) in
  let sync, stream = complete_sync_and_stream ~config ~transport in
  expect_complete_ok "sync declared Responses effort" sync;
  expect_complete_ok "stream declared Responses effort" stream;
  [ BOR.build_request ~config ~messages:[ user_msg "hi" ] ()
  ; BOR.build_request ~stream:true ~config ~messages:[ user_msg "hi" ] ()
  ]
  |> List.iter (fun body ->
    Alcotest.(check string)
      "Responses wire carries the typed reasoning effort"
      "medium"
      Yojson.Safe.Util.(
        body
        |> Yojson.Safe.from_string
        |> member "reasoning"
        |> member "effort"
        |> to_string))
;;

let test_declared_chat_template_token_receipt_matches_wire () =
  let caps =
    { Llm_provider.Capabilities.openai_compat_chat_capabilities with
      supports_reasoning = true
    ; supports_extended_thinking = true
    ; thinking_control_format =
        Llm_provider.Capabilities.Chat_template_token "<DECLARED_THINK>"
    }
  in
  let config =
    PC.make
      ~kind:OpenAI_compat
      ~model_id:"declared-chat-template-token"
      ~base_url:"https://declared-openai-compatible.example/v1"
      ~system_prompt:"Base prompt."
      ~model_capabilities_override:caps
      ~enable_thinking:true
      ()
  in
  let transport = fake_transport (successful_response config.model_id) in
  let sync, stream = complete_sync_and_stream ~config ~transport in
  expect_complete_ok "sync declared chat-template token" sync;
  expect_complete_ok "stream declared chat-template token" stream;
  [ BO.build_request ~config ~messages:[ user_msg "hi" ] ()
  ; BO.build_request ~stream:true ~config ~messages:[ user_msg "hi" ] ()
  ]
  |> List.iter (fun body ->
    let system_content =
      Yojson.Safe.Util.(
        body
        |> Yojson.Safe.from_string
        |> member "messages"
        |> index 0
        |> member "content"
        |> to_string)
    in
    Alcotest.(check bool)
      "chat-template receipt corresponds to injected wire token"
      true
      (String.starts_with ~prefix:"<DECLARED_THINK>\n" system_content))
;;

let test_declared_inherent_thinking_passes_without_wire_toggle () =
  let caps =
    { Llm_provider.Capabilities.openai_compat_chat_capabilities with
      supports_reasoning = true
    ; thinking_control_format = Llm_provider.Capabilities.No_thinking_control
    }
  in
  let config =
    PC.make
      ~kind:OpenAI_compat
      ~model_id:"declared-inherent-reasoner"
      ~base_url:"https://declared-openai-compatible.example/v1"
      ~model_capabilities_override:caps
      ~enable_thinking:true
      ()
  in
  let transport = fake_transport (successful_response config.model_id) in
  let sync, stream = complete_sync_and_stream ~config ~transport in
  expect_complete_ok "sync inherent" sync;
  expect_complete_ok "stream inherent" stream;
  Alcotest.(check bool)
    "inherent contract needs no wire toggle"
    true
    (enable_thinking_field (BO.build_request ~config ~messages:[ user_msg "hi" ] ())
     = `Null)
;;

let test_explicit_false_semantics_remain_typed () =
  let no_reasoning =
    PC.make
      ~kind:OpenAI_compat
      ~model_id:"declared-non-reasoner"
      ~base_url:"https://unknown-openai-compatible.example/v1"
      ~enable_thinking:false
      ()
  in
  let transport = fake_transport (successful_response no_reasoning.model_id) in
  let sync, stream = complete_sync_and_stream ~config:no_reasoning ~transport in
  expect_complete_ok "sync non-reasoning disable no-op" sync;
  expect_complete_ok "stream non-reasoning disable no-op" stream;
  let inherent_caps =
    { Llm_provider.Capabilities.openai_compat_chat_capabilities with
      supports_reasoning = true
    ; thinking_control_format = Llm_provider.Capabilities.No_thinking_control
    }
  in
  let inherent =
    { no_reasoning with
      model_id = "declared-inherent-reasoner"
    ; model_capabilities_override = Some inherent_caps
    }
  in
  let sync, stream =
    complete_sync_and_stream ~config:inherent ~transport:rejected_before_transport
  in
  let sync_reason = accept_rejected_reason "sync inherent disable" sync in
  let stream_reason = accept_rejected_reason "stream inherent disable" stream in
  Alcotest.(check string)
    "inherent disable has sync/stream parity"
    sync_reason
    stream_reason;
  let encodable_caps =
    { inherent_caps with
      thinking_control_format = Llm_provider.Capabilities.Enable_thinking
    }
  in
  let encodable =
    { inherent with
      model_id = "declared-disable-dialect"
    ; model_capabilities_override = Some encodable_caps
    }
  in
  let transport = fake_transport (successful_response encodable.model_id) in
  let sync, stream = complete_sync_and_stream ~config:encodable ~transport in
  expect_complete_ok "sync encodable disable" sync;
  expect_complete_ok "stream encodable disable" stream;
  Alcotest.(check bool)
    "encodable false reaches wire"
    true
    (enable_thinking_field
       (BO.build_request ~config:encodable ~messages:[ user_msg "hi" ] ())
     = `Bool false)
;;

let test_standard_openai_request_without_toggle_is_unchanged () =
  let config =
    PC.make
      ~kind:OpenAI_compat
      ~model_id:"gpt-4o"
      ~base_url:"https://api.openai.com/v1"
      ()
  in
  let transport = fake_transport (successful_response config.model_id) in
  let sync, stream = complete_sync_and_stream ~config ~transport in
  expect_complete_ok "sync standard OpenAI" sync;
  expect_complete_ok "stream standard OpenAI" stream;
  Alcotest.(check bool)
    "standard request does not invent enable_thinking"
    true
    (enable_thinking_field (BO.build_request ~config ~messages:[ user_msg "hi" ] ())
     = `Null)
;;

let with_model_catalog_toml contents f =
  let original = Llm_provider.Model_catalog.global () in
  match
    Llm_provider.Model_catalog.of_toml_string
      ~source:"test_provider_complete provider pricing"
      contents
  with
  | Error message -> Alcotest.fail message
  | Ok catalog ->
    Llm_provider.Model_catalog.set_global catalog;
    Fun.protect
      ~finally:(fun () ->
        match original with
        | Some catalog -> Llm_provider.Model_catalog.set_global catalog
        | None -> Llm_provider.Model_catalog.clear_global ())
      f
;;

let complete_with_captured_diag ~config ~response =
  let entries = ref [] in
  let run () =
    Eio_main.run
    @@ fun env ->
    Eio.Switch.run
    @@ fun sw ->
    let net = Eio.Stdenv.net env in
    let transport = fake_transport response in
    match
      Llm_provider.Complete.complete
        ~sw
        ~net
        ~config
        ~messages:[ user_msg "hi" ]
        ~transport
        ()
    with
    | Ok _ -> ()
    | Error _ -> Alcotest.fail "fake completion should succeed"
  in
  Llm_provider.Diag.with_sink
    (fun level ~ctx message -> entries := (level, ctx, message) :: !entries)
    run;
  List.rev !entries
;;

let response_with_thinking =
  { id = "resp-thinking"
  ; model = "auto"
  ; stop_reason = EndTurn
  ; content = [ Thinking { signature = None; content = "reasoning" } ]
  ; usage
  ; telemetry = None
  }
;;

let test_provider_default_thinking_drift_is_info () =
  let config =
    PC.make ~kind:OpenAI_compat ~model_id:"auto" ~base_url:"https://example.invalid/v1" ()
  in
  let entries = complete_with_captured_diag ~config ~response:response_with_thinking in
  Alcotest.(check bool)
    "no warn for provider-default thinking observation"
    false
    (List.exists (fun (level, _, _) -> level = Llm_provider.Diag.Warn) entries);
  Alcotest.(check bool)
    "low-confidence info is recorded"
    true
    (List.exists
       (fun (level, ctx, message) ->
          level = Llm_provider.Diag.Info
          && ctx = "complete"
          && contains_substring ~sub:"capability_observation" message
          && contains_substring ~sub:"provider_default" message
          && contains_substring ~sub:"low" message)
       entries)
;;

let test_model_capability_thinking_drift_remains_warn () =
  let config =
    PC.make
      ~kind:OpenAI_compat
      ~model_id:"glm-4-flash"
      ~base_url:"https://declared-openai-compat.example/v1"
      ~model_capabilities_override:
        (catalog_capabilities ~provider_label:"glm" "glm-4-flash")
      ()
  in
  let entries = complete_with_captured_diag ~config ~response:response_with_thinking in
  Alcotest.(check bool)
    "model-specific mismatch remains warn"
    true
    (List.exists
       (fun (level, ctx, message) ->
          level = Llm_provider.Diag.Warn
          && ctx = "complete"
          && contains_substring ~sub:"capability_drift" message
          && contains_substring ~sub:"model" message
          && contains_substring ~sub:"high" message)
       entries)
;;

let test_declared_glm_model_thinking_uses_model_capability () =
  let config =
    PC.make
      ~kind:Glm
      ~model_id:"glm-5"
      ~base_url:"https://api.z.ai/api/coding/paas/v4"
      ~model_capabilities_override:(catalog_capabilities "glm-5")
      ()
  in
  let entries = complete_with_captured_diag ~config ~response:response_with_thinking in
  Alcotest.(check bool)
    "declared glm-5 thinking does not emit capability drift"
    false
    (List.exists
       (fun (_level, ctx, message) ->
          ctx = "complete"
          && (contains_substring ~sub:"capability_observation" message
              || contains_substring ~sub:"capability_drift" message))
       entries)
;;

let test_complete_rejects_output_schema_for_glm () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let config =
    PC.make
      ~kind:Glm
      ~model_id:"glm-5"
      ~base_url:"https://api.z.ai/api/coding/paas/v4"
      ~response_format:(JsonSchema (`Assoc [ "type", `String "object" ]))
      ()
  in
  match
    Llm_provider.Complete.complete ~sw ~net ~config ~messages:[ user_msg "hi" ] ()
  with
  | Error (Llm_provider.Http_client.AcceptRejected { reason }) ->
    Alcotest.(check bool)
      "mentions glm json mode"
      true
      (contains_substring ~sub:"json mode" (String.lowercase_ascii reason))
  | Ok _ -> Alcotest.fail "expected AcceptRejected for glm output_schema"
  | Error _ -> Alcotest.fail "expected AcceptRejected for glm output_schema"
;;

let test_complete_stream_rejects_output_schema_for_glm () =
  (* The streaming entry must run the same pre-wire validation as sync: a
     regression that skipped validate_all in complete_stream would turn this
     red before any transport I/O happens. *)
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let config =
    PC.make
      ~kind:Glm
      ~model_id:"glm-5"
      ~base_url:"https://api.z.ai/api/coding/paas/v4"
      ~response_format:(JsonSchema (`Assoc [ "type", `String "object" ]))
      ()
  in
  match
    Llm_provider.Complete.complete_stream
      ~sw
      ~net
      ~config
      ~messages:[ user_msg "hi" ]
      ~on_event:(fun _ -> ())
      ()
  with
  | Error (Llm_provider.Http_client.AcceptRejected { reason }) ->
    Alcotest.(check bool)
      "mentions glm json mode"
      true
      (contains_substring ~sub:"json mode" (String.lowercase_ascii reason))
  | Ok _ -> Alcotest.fail "expected stream AcceptRejected for glm output_schema"
  | Error _ -> Alcotest.fail "expected stream AcceptRejected for glm output_schema"
;;

let test_annotate_response_cost () =
  let response : api_response =
    { id = "resp-1"
    ; model = "claude-sonnet-4-6"
    ; stop_reason = EndTurn
    ; content = [ Text "ok" ]
    ; usage =
        Some
          { input_tokens = 1_000
          ; output_tokens = 500
          ; cache_creation_input_tokens = 0
          ; cache_read_input_tokens = 0
          ; cost_usd = None
          }
    ; telemetry = None
    }
  in
  match Llm_provider.Pricing.annotate_response_cost response with
  | { usage = Some { cost_usd = Some cost; _ }; _ } ->
    Alcotest.(check bool) "annotated cost" true (cost > 0.0)
  | _ -> Alcotest.fail "expected annotated response cost"
;;

let test_annotate_response_cost_gpt55 () =
  let response : api_response =
    { id = "resp-gpt55"
    ; model = "gpt-5.5"
    ; stop_reason = EndTurn
    ; content = [ Text "ok" ]
    ; usage =
        Some
          { input_tokens = 1_000_000
          ; output_tokens = 1_000_000
          ; cache_creation_input_tokens = 0
          ; cache_read_input_tokens = 0
          ; cost_usd = None
          }
    ; telemetry = None
    }
  in
  match Llm_provider.Pricing.annotate_response_cost response with
  | { usage = Some { cost_usd = Some cost; _ }; _ } ->
    Alcotest.(check (float 0.001)) "gpt-5.5 cost" 35.0 cost
  | _ -> Alcotest.fail "expected gpt-5.5 annotated response cost"
;;

let test_complete_propagates_exact_provider_to_cost_annotation () =
  let catalog =
    {|
[[models]]
id_prefix = "shared-priced-model"
base = "openai_chat"
input_per_million = 9.0
output_per_million = 90.0
cache_write_multiplier = 1.0
cache_read_multiplier = 1.0

[[models]]
id_prefix = "shared-priced-model"
provider_name = "pricing-provider"
base = "openai_chat"
input_per_million = 1.0
output_per_million = 2.0
cache_write_multiplier = 1.0
cache_read_multiplier = 1.0
|}
  in
  let response : api_response =
    { id = "provider-priced-response"
    ; model = "shared-priced-model"
    ; stop_reason = EndTurn
    ; content = [ Text "ok" ]
    ; usage =
        Some
          { input_tokens = 1_000_000
          ; output_tokens = 1_000_000
          ; cache_creation_input_tokens = 0
          ; cache_read_input_tokens = 0
          ; cost_usd = None
          }
    ; telemetry = None
    }
  in
  let config =
    PC.make
      ~kind:OpenAI_compat
      ~provider_id:"pricing-provider"
      ~model_id:"shared-priced-model"
      ~base_url:"https://example.invalid/v1"
      ()
  in
  let check_cost label = function
    | Ok { usage = Some { cost_usd = Some cost; _ }; _ } ->
      Alcotest.(check (float 0.001)) label 3.0 cost
    | Ok _ -> Alcotest.failf "%s: expected annotated cost" label
    | Error _ -> Alcotest.failf "%s: fake completion should succeed" label
  in
  with_model_catalog_toml catalog (fun () ->
    Eio_main.run
    @@ fun env ->
    Eio.Switch.run
    @@ fun sw ->
    let net = Eio.Stdenv.net env in
    let transport = fake_transport response in
    check_cost
      "sync exact provider price"
      (Llm_provider.Complete.complete
         ~sw
         ~net
         ~transport
         ~config
         ~messages:[ user_msg "hi" ]
         ());
    check_cost
      "stream exact provider price"
      (Llm_provider.Complete.complete_stream
         ~sw
         ~net
         ~transport
         ~config
         ~messages:[ user_msg "hi" ]
         ~on_event:(fun _ -> ())
         ()))
;;

(* ── Stream accumulator ──────────────────────────────── *)

let test_stream_acc_text () =
  (* Simulate a minimal Anthropic SSE event sequence *)
  let events =
    [ MessageStart
        { id = "msg_123"
        ; model = "claude-sonnet-4-6"
        ; usage =
            Some
              { input_tokens = 10
              ; output_tokens = 0
              ; cache_creation_input_tokens = 0
              ; cache_read_input_tokens = 0
              ; cost_usd = None
              }
        }
    ; ContentBlockStart
        { index = 0; content_type = "text"; tool_id = None; tool_name = None }
    ; ContentBlockDelta { index = 0; delta = TextDelta "Hello " }
    ; ContentBlockDelta { index = 0; delta = TextDelta "world" }
    ; ContentBlockStop { index = 0 }
    ; MessageDelta
        { stop_reason = Some EndTurn
        ; usage =
            Some
              { input_tokens = 0
              ; output_tokens = 5
              ; cache_creation_input_tokens = 0
              ; cache_read_input_tokens = 0
              ; cost_usd = None
              }
        }
    ; MessageStop
    ]
  in
  (* We can't call the internal functions directly, but we can test
     that the event types compose correctly *)
  Alcotest.(check int) "7 events" 7 (List.length events)
;;

let test_stream_acc_tool_use () =
  let events =
    [ MessageStart { id = "msg_456"; model = "gpt-4"; usage = None }
    ; ContentBlockStart
        { index = 0
        ; content_type = "tool_use"
        ; tool_id = Some "tu_1"
        ; tool_name = Some "calc"
        }
    ; ContentBlockDelta { index = 0; delta = InputJsonDelta "{\"x\":1}" }
    ; ContentBlockStop { index = 0 }
    ; MessageDelta { stop_reason = Some StopToolUse; usage = None }
    ; MessageStop
    ]
  in
  Alcotest.(check int) "6 events" 6 (List.length events)
;;

(* ── Prompt caching ───────────────────────────────── *)

(* A long prompt exercises the explicit cache breakpoint serialization. *)
let long_prompt =
  String.concat
    ""
    (List.init 200 (fun i ->
       Printf.sprintf "Rule %d: follow this guideline carefully. " i))
;;

let test_cache_system_prompt () =
  let config =
    PC.make
      ~kind:Anthropic
      ~model_id:"claude-sonnet-4-6"
      ~base_url:""
      ~system_prompt:long_prompt
      ~cache_system_prompt:true
      ()
  in
  let body = BA.build_request ~config ~messages:[ user_msg "hi" ] () in
  let json = Yojson.Safe.from_string body in
  let open Yojson.Safe.Util in
  let system = json |> member "system" |> to_list in
  Alcotest.(check int) "1 system block" 1 (List.length system);
  let block = List.hd system in
  Alcotest.(check string) "type" "text" (block |> member "type" |> to_string);
  let cc = block |> member "cache_control" in
  Alcotest.(check string)
    "cache_control type"
    "ephemeral"
    (cc |> member "type" |> to_string)
;;

let test_cache_short_prompt_preserves_opt_in () =
  let config =
    PC.make
      ~kind:Anthropic
      ~model_id:"m"
      ~base_url:""
      ~max_tokens:128
      ~system_prompt:"Short."
      ~cache_system_prompt:true
      ()
  in
  let body = BA.build_request ~config ~messages:[ user_msg "hi" ] () in
  let json = Yojson.Safe.from_string body in
  let open Yojson.Safe.Util in
  let system = json |> member "system" |> to_list in
  Alcotest.(check int) "1 system block" 1 (List.length system);
  let block = List.hd system in
  Alcotest.(check string) "type" "text" (block |> member "type" |> to_string);
  Alcotest.(check string)
    "cache_control type"
    "ephemeral"
    (block |> member "cache_control" |> member "type" |> to_string)
;;

let test_cache_no_system_no_cache () =
  let config =
    PC.make
      ~kind:Anthropic
      ~model_id:"m"
      ~base_url:""
      ~max_tokens:128
      ~system_prompt:"Hello."
      ~cache_system_prompt:false
      ()
  in
  let body = BA.build_request ~config ~messages:[ user_msg "hi" ] () in
  let json = Yojson.Safe.from_string body in
  let open Yojson.Safe.Util in
  (* system should be a plain string when caching disabled *)
  Alcotest.(check string)
    "system is string"
    "Hello."
    (json |> member "system" |> to_string)
;;

let test_cache_tools () =
  let config =
    PC.make
      ~kind:Anthropic
      ~model_id:"m"
      ~base_url:""
      ~max_tokens:128
      ~cache_system_prompt:true
      ()
  in
  let tool1 = `Assoc [ "name", `String "a"; "description", `String "tool a" ] in
  let tool2 = `Assoc [ "name", `String "b"; "description", `String "tool b" ] in
  let body =
    BA.build_request ~config ~messages:[ user_msg "hi" ] ~tools:[ tool1; tool2 ] ()
  in
  let json = Yojson.Safe.from_string body in
  let open Yojson.Safe.Util in
  let tools = json |> member "tools" |> to_list in
  Alcotest.(check int) "2 tools" 2 (List.length tools);
  (* First tool should NOT have cache_control *)
  let first = List.hd tools in
  Alcotest.(check bool)
    "first tool no cache"
    true
    (first |> member "cache_control" = `Null);
  (* Last tool SHOULD have cache_control *)
  let last = List.nth tools 1 in
  let cc = last |> member "cache_control" in
  Alcotest.(check string)
    "last tool cache_control"
    "ephemeral"
    (cc |> member "type" |> to_string)
;;

let test_cache_default_false () =
  let cfg = PC.make ~kind:Anthropic ~model_id:"m" ~base_url:"" () in
  Alcotest.(check bool) "default cache off" false cfg.cache_system_prompt
;;

let () =
  let open Alcotest in
  run
    "provider_complete"
    [ ( "anthropic_build_request"
      , [ test_case "basic body" `Quick test_anthropic_basic_body
        ; test_case "with system" `Quick test_anthropic_with_system
        ; test_case "with thinking" `Quick test_anthropic_with_thinking
        ; test_case
            "disabled thinking rejects reasoning effort"
            `Quick
            test_anthropic_disabled_thinking_rejects_reasoning_effort
        ; test_case
            "Sonnet 5 explicit disable is serialized"
            `Quick
            test_anthropic_sonnet5_explicit_disable_is_serialized
        ; test_case
            "thinking forced tool_choice rejected before request"
            `Quick
            test_anthropic_thinking_forced_tool_choice_rejected_before_request
        ; test_case "with output schema" `Quick test_anthropic_output_schema
        ; test_case
            "with json schema response_format"
            `Quick
            test_anthropic_json_schema_response_format
        ; test_case
            "multi-turn signed thinking/tool order"
            `Quick
            test_anthropic_build_request_preserves_multiturn_thinking_tool_order
        ; test_case "stream flag" `Quick test_anthropic_stream_flag
        ; test_case
            "parse response initializes telemetry"
            `Quick
            test_anthropic_parse_response_initializes_telemetry
        ; test_case
            "parse response rejects unknown content block"
            `Quick
            test_anthropic_parse_response_rejects_unknown_content_block
        ; test_case
            "parse response rejects unknown media source kind"
            `Quick
            test_anthropic_parse_response_rejects_unknown_media_source_kind
        ] )
    ; ( "openai_build_request"
      , [ test_case "basic body" `Quick test_openai_basic_body
        ; test_case "with system" `Quick test_openai_with_system
        ; test_case "with tools" `Quick test_openai_with_tools
        ; test_case
            "kimi direct tools + thinking"
            `Quick
            test_kimi_direct_with_tools_and_thinking
        ; test_case
            "kimi direct tool_result uses scalar text"
            `Quick
            test_kimi_direct_tool_result_uses_text_blocks
        ; test_case "stream flag" `Quick test_openai_stream_flag
        ; test_case "with json schema" `Quick test_openai_with_json_schema
        ; test_case
            "Responses assistant phase metadata"
            `Quick
            test_openai_responses_replays_assistant_phase_metadata
        ; test_case
            "Responses unknown phase rejected"
            `Quick
            test_openai_responses_rejects_unknown_assistant_phase
        ; test_case
            "Responses padded phase rejected"
            `Quick
            test_openai_responses_rejects_padded_assistant_phase
        ; test_case
            "Responses blank phase rejected"
            `Quick
            test_openai_responses_rejects_blank_assistant_phase
        ; test_case
            "Responses non-string phase rejected"
            `Quick
            test_openai_responses_rejects_non_string_assistant_phase
        ; test_case "ollama output schema" `Quick test_ollama_output_schema
        ; test_case
            "ollama gemma4 thinking uses template token"
            `Quick
            test_ollama_gemma4_thinking_uses_template_token
        ; test_case
            "ollama native multimodal request body"
            `Quick
            test_ollama_native_multimodal_request_body
        ; test_case
            "ollama parse parallel tool calls object args"
            `Quick
            test_ollama_parse_parallel_tool_calls_object_arguments
        ; test_case
            "ollama parse explicit id string args"
            `Quick
            test_ollama_parse_tool_call_preserves_explicit_id_and_string_arguments
        ; test_case
            "ollama malformed tool call rejected"
            `Quick
            test_ollama_parse_rejects_malformed_tool_call
        ; test_case
            "ollama non-object tool arguments rejected"
            `Quick
            test_ollama_parse_rejects_non_object_tool_arguments
        ; test_case
            "ollama missing correlation rejects sync and stream"
            `Quick
            test_ollama_missing_tool_correlation_rejected_sync_and_stream
        ; test_case
            "ollama conflicting correlation rejects sync and stream"
            `Quick
            test_ollama_conflicting_tool_correlation_rejected_sync_and_stream
        ; test_case
            "ollama reused tool id resolves by turn occurrence"
            `Quick
            test_ollama_reused_tool_id_resolves_by_turn_occurrence
        ; test_case
            "ollama native legacy tool shapes rejected"
            `Quick
            test_ollama_native_tool_role_rejects_legacy_shapes
        ; test_case
            "glm preserved reasoning replay"
            `Quick
            test_glm_preserved_reasoning_replay_and_preserves_auto_tool_choice
        ; test_case
            "glm named forced tool_choice rejected at completion boundary"
            `Quick
            test_complete_rejects_glm_named_forced_tool_choice_before_request
        ] )
    ; ( "gemini_build_request"
      , [ test_case "with json schema" `Quick test_gemini_with_json_schema ] )
    ; ( "provider_config"
      , [ test_case "default paths" `Quick test_config_default_paths
        ; test_case "custom path" `Quick test_config_custom_path
        ] )
    ; ( "thinking_control_admission"
      , [ test_case
            "unknown compat enable rejects sync and stream"
            `Quick
            test_unknown_openai_compat_enable_rejected_sync_and_stream
        ; test_case
            "declared enable dialect passes sync stream and wire"
            `Quick
            test_declared_enable_dialect_passes_sync_stream_and_wire
        ; test_case
            "declared Responses effort passes sync stream and wire"
            `Quick
            test_declared_responses_effort_passes_sync_stream_and_wire
        ; test_case
            "declared chat-template token receipt matches wire"
            `Quick
            test_declared_chat_template_token_receipt_matches_wire
        ; test_case
            "declared inherent thinking passes without wire toggle"
            `Quick
            test_declared_inherent_thinking_passes_without_wire_toggle
        ; test_case
            "explicit false semantics remain typed"
            `Quick
            test_explicit_false_semantics_remain_typed
        ; test_case
            "standard OpenAI request without toggle unchanged"
            `Quick
            test_standard_openai_request_without_toggle_is_unchanged
        ] )
    ; ( "cli_transport_guard"
      , [ test_case
            "glm output schema rejected before request"
            `Quick
            test_complete_rejects_output_schema_for_glm
        ; test_case
            "glm output schema rejected before stream request"
            `Quick
            test_complete_stream_rejects_output_schema_for_glm
        ] )
    ; ( "capability_drift"
      , [ test_case
            "provider-default thinking observation is info"
            `Quick
            test_provider_default_thinking_drift_is_info
        ; test_case
            "model-specific thinking drift remains warn"
            `Quick
            test_model_capability_thinking_drift_remains_warn
        ; test_case
            "declared glm thinking uses model capability"
            `Quick
            test_declared_glm_model_thinking_uses_model_capability
        ] )
    ; ( "cost"
      , [ test_case "annotate response cost" `Quick test_annotate_response_cost
        ; test_case
            "annotate gpt-5.5 response cost"
            `Quick
            test_annotate_response_cost_gpt55
        ; test_case
            "complete propagates exact provider to cost annotation"
            `Quick
            test_complete_propagates_exact_provider_to_cost_annotation
        ] )
    ; ( "stream_acc"
      , [ test_case "text events" `Quick test_stream_acc_text
        ; test_case "tool_use events" `Quick test_stream_acc_tool_use
        ] )
    ; ( "prompt_caching"
      , [ test_case "system block with cache_control" `Quick test_cache_system_prompt
        ; test_case "no cache when disabled" `Quick test_cache_no_system_no_cache
        ; test_case "last tool gets cache_control" `Quick test_cache_tools
        ; test_case "default cache off" `Quick test_cache_default_false
        ; test_case
            "short prompt preserves opt-in"
            `Quick
            test_cache_short_prompt_preserves_opt_in
        ] )
    ]
;;
