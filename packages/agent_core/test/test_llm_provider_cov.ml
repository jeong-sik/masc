(** Tests for llm_provider sub-library modules:
    complete, api_common, backend_gemini,
    capability_filter, capabilities.

    Focuses on pure functions and data construction only. *)

open Llm_provider

(* ── Helpers ──────────────────────────────────────── *)

let make_config
      ?(kind = Provider_config.OpenAI_compat)
      ?(model_id = "test-model")
      ?(base_url = "http://127.0.0.1:8085")
      ?(api_key = "")
      ?(request_path = "/v1/chat/completions")
      ?(max_tokens = 1024)
      ?temperature
      ?system_prompt
      ?enable_thinking
      ?thinking_budget
      ?tool_choice
      ?(response_format = Types.Off)
      ()
  : Provider_config.t
  =
  Provider_config.make
    ~kind
    ~model_id
    ~base_url
    ~api_key
    ~request_path
    ~max_tokens
    ?temperature
    ?system_prompt
    ?enable_thinking
    ?thinking_budget
    ?tool_choice
    ~response_format
    ()
;;

let user_msg s : Types.message =
  { role = User; content = [ Text s ]; name = None; tool_call_id = None; metadata = [] }
;;

let assistant_msg s : Types.message =
  { role = Assistant
  ; content = [ Text s ]
  ; name = None
  ; tool_call_id = None
  ; metadata = []
  }
;;

let system_msg s : Types.message =
  { role = System; content = [ Text s ]; name = None; tool_call_id = None; metadata = [] }
;;

let gemini25_flash_model = "gemini-2.5-flash"

let gemini25_url ?api_key:_ ~stream () =
  let action = if stream then "streamGenerateContent" else "generateContent" in
  let base =
    Printf.sprintf
      "https://gen.googleapis.com/v1beta/models/%s:%s"
      gemini25_flash_model
      action
  in
  if stream then base ^ "?alt=sse" else base
;;

let mk_response
      ?(id = "r1")
      ?(model = "m1")
      ?(stop_reason = Types.EndTurn)
      ?(content = [ Types.Text "ok" ])
      ?usage
      ()
  : Types.api_response
  =
  { id; model; stop_reason; content; usage; telemetry = None }
;;

(* ═══════════════════════════════════════════════════
   1. Complete — Gemini URL construction
   ═══════════════════════════════════════════════════ *)

let test_gemini_url_sync_no_key () =
  let config =
    make_config
      ~kind:Gemini
      ~model_id:gemini25_flash_model
      ~base_url:"https://gen.googleapis.com/v1beta"
      ~api_key:""
      ()
  in
  let url = Complete_sampling.gemini_url ~config ~stream:false in
  Alcotest.(check string) "sync no key" (gemini25_url ~stream:false ()) url
;;

let test_gemini_url_sync_with_key () =
  let config =
    make_config
      ~kind:Gemini
      ~model_id:gemini25_flash_model
      ~base_url:"https://gen.googleapis.com/v1beta"
      ~api_key:"mykey"
      ()
  in
  let url = Complete_sampling.gemini_url ~config ~stream:false in
  Alcotest.(check string)
    "sync with key"
    (gemini25_url ~api_key:"mykey" ~stream:false ())
    url
;;

let test_gemini_url_stream_with_key () =
  let config =
    make_config
      ~kind:Gemini
      ~model_id:gemini25_flash_model
      ~base_url:"https://gen.googleapis.com/v1beta"
      ~api_key:"mykey"
      ()
  in
  let url = Complete_sampling.gemini_url ~config ~stream:true in
  Alcotest.(check string)
    "stream with key"
    (gemini25_url ~api_key:"mykey" ~stream:true ())
    url
;;

let test_gemini_url_stream_no_key () =
  let config =
    make_config
      ~kind:Gemini
      ~model_id:gemini25_flash_model
      ~base_url:"https://gen.googleapis.com/v1beta"
      ~api_key:""
      ()
  in
  let url = Complete_sampling.gemini_url ~config ~stream:true in
  Alcotest.(check string) "stream no key" (gemini25_url ~stream:true ()) url
;;

(* ═══════════════════════════════════════════════════
   2. Api_common — constants, helpers, content block JSON
   ═══════════════════════════════════════════════════ *)

let test_default_base_url () =
  Alcotest.(check string)
    "base url"
    "https://api.anthropic.com"
    Api_common.default_base_url
;;

let test_api_version () =
  Alcotest.(check string) "api version" "2023-06-01" Api_common.api_version
;;

let test_max_response_body () =
  Alcotest.(check int) "10 MB" (10 * 1024 * 1024) Api_common.max_response_body
;;

let test_max_stdio_buffer () =
  Alcotest.(check int) "16 MB" (16 * 1024 * 1024) Api_common.max_stdio_buffer
;;

let test_fresh_tool_use_id () =
  let id1 = Api_common.fresh_tool_use_id () in
  let id2 = Api_common.fresh_tool_use_id () in
  Alcotest.(check bool) "distinct allocations" true (id1 <> id2);
  Alcotest.(check bool)
    "starts with OAS namespace"
    true
    (String.starts_with ~prefix:"call_oas_" id1)
;;

let test_fresh_tool_use_id_domain_safe () =
  let domains =
    Array.init 4 (fun _ ->
      Domain.spawn (fun () -> List.init 64 (fun _ -> Api_common.fresh_tool_use_id ())))
  in
  let ids = domains |> Array.to_list |> List.concat_map Domain.join in
  let unique = Hashtbl.create (List.length ids) in
  List.iter (fun id -> Hashtbl.replace unique id ()) ids;
  Alcotest.(check int)
    "all domain allocations unique"
    (List.length ids)
    (Hashtbl.length unique)
;;

let test_string_is_blank () =
  Alcotest.(check bool) "empty" true (Api_common.string_is_blank "");
  Alcotest.(check bool) "spaces" true (Api_common.string_is_blank "   ");
  Alcotest.(check bool) "tab" true (Api_common.string_is_blank "\t");
  Alcotest.(check bool) "not blank" false (Api_common.string_is_blank "a");
  Alcotest.(check bool) "with spaces" false (Api_common.string_is_blank " a ")
;;

let test_text_blocks_to_string () =
  let blocks : Types.content_block list =
    [ Text "hello"
    ; Thinking { signature = Some "t"; content = "reason" }
    ; ToolUse { id = "t1"; name = "tool"; input = `Null }
    ; Text "world"
    ]
  in
  let result = Api_common.text_blocks_to_string blocks in
  Alcotest.(check string) "text+thinking" "hello\nreason\nworld" result
;;

let test_text_blocks_to_string_empty () =
  Alcotest.(check string) "empty" "" (Api_common.text_blocks_to_string [])
;;

let test_text_blocks_to_string_redacted () =
  let blocks : Types.content_block list = [ Text "visible"; RedactedThinking "secret" ] in
  let result = Api_common.text_blocks_to_string blocks in
  Alcotest.(check string) "redacted excluded" "visible" result
;;

let test_json_of_string_or_raw_valid () =
  let result = Api_common.json_of_string_or_raw {|{"key":"val"}|} in
  match result with
  | `Assoc [ ("key", `String "val") ] -> ()
  | _ -> Alcotest.fail "expected valid JSON parse"
;;

let test_json_of_string_or_raw_invalid () =
  let result = Api_common.json_of_string_or_raw "not json" in
  match result with
  | `Assoc [ ("raw", `String "not json") ] -> ()
  | _ -> Alcotest.fail "expected raw fallback"
;;

let test_base64_media_data_url () =
  let result =
    Api_common.base64_media_data_url
      ~backend:"test_backend"
      ~block:"image"
      ~media_type:"image/png"
      ~data:"abc"
      Types.Base64
  in
  Alcotest.(check string) "data URL" "data:image/png;base64,abc" result
;;

let test_base64_media_payload () =
  let result =
    Api_common.base64_media_payload
      ~backend:"test_backend"
      ~block:"audio"
      ~data:"abc"
      Types.Base64
  in
  Alcotest.(check string) "payload" "abc" result
;;

let test_base64_media_source_rejects_url () =
  try
    ignore
      (Api_common.base64_media_data_url
         ~backend:"test_backend"
         ~block:"image"
         ~media_type:"image/png"
         ~data:"https://example.invalid/image.png"
         Types.Url);
    Alcotest.fail "expected Url media source to fail closed"
  with
  | Invalid_argument message ->
    Alcotest.(check string)
      "message"
      "test_backend does not support image media source kind url"
      message
;;

(* content_block_to_json *)
let test_content_block_to_json_text () =
  let json = Api_common.content_block_to_json (Text "hello") in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "type" "text" (json |> member "type" |> to_string);
  Alcotest.(check string) "text" "hello" (json |> member "text" |> to_string)
;;

let test_content_block_to_json_thinking () =
  let json =
    Api_common.content_block_to_json
      (Thinking { signature = Some "sig123"; content = "reason" })
  in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "type" "thinking" (json |> member "type" |> to_string);
  Alcotest.(check string) "signature" "sig123" (json |> member "signature" |> to_string);
  Alcotest.(check string) "thinking" "reason" (json |> member "thinking" |> to_string)
;;

let test_content_block_to_json_redacted () =
  let json = Api_common.content_block_to_json (RedactedThinking "secret") in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "type" "redacted_thinking" (json |> member "type" |> to_string);
  Alcotest.(check string) "data" "secret" (json |> member "data" |> to_string)
;;

let test_content_block_to_json_tool_use () =
  let json =
    Api_common.content_block_to_json
      (ToolUse { id = "tu1"; name = "fn1"; input = `Assoc [ "x", `Int 1 ] })
  in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "type" "tool_use" (json |> member "type" |> to_string);
  Alcotest.(check string) "id" "tu1" (json |> member "id" |> to_string);
  Alcotest.(check string) "name" "fn1" (json |> member "name" |> to_string)
;;

let test_content_block_to_json_tool_result () =
  let json =
    Api_common.content_block_to_json
      (ToolResult
         { tool_use_id = "tu1"
         ; content = "done"
         ; outcome =
             Tool_failed
               { failure_kind = Validation_error; error_class = Some Deterministic }
         ; json = None
         ; content_blocks = None
         })
  in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "type" "tool_result" (json |> member "type" |> to_string);
  Alcotest.(check bool) "is_error" true (json |> member "is_error" |> to_bool);
  Alcotest.(check bool)
    "failure_kind is SDK-only"
    true
    (json |> member "failure_kind" = `Null);
  Alcotest.(check bool)
    "error_class is SDK-only"
    true
    (json |> member "error_class" = `Null)
;;

let test_content_block_to_json_image () =
  let json =
    Api_common.content_block_to_json
      (Image { media_type = "image/png"; data = "abc"; source_type = Types.Base64 })
  in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "type" "image" (json |> member "type" |> to_string);
  let source = json |> member "source" in
  Alcotest.(check string)
    "media_type"
    "image/png"
    (source |> member "media_type" |> to_string)
;;

let test_content_block_to_json_document () =
  let json =
    Api_common.content_block_to_json
      (Document
         { media_type = "application/pdf"; data = "pdf"; source_type = Types.Base64 })
  in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "type" "document" (json |> member "type" |> to_string)
;;

let test_content_block_to_json_audio () =
  let json =
    Api_common.content_block_to_json
      (Audio { media_type = "audio/wav"; data = "wav"; source_type = Types.Base64 })
  in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "type" "audio" (json |> member "type" |> to_string)
;;

(* content_block_of_json roundtrip *)
let test_content_block_of_json_text () =
  let json = `Assoc [ "type", `String "text"; "text", `String "hello" ] in
  match Api_common.content_block_of_json json with
  | Some (Text "hello") -> ()
  | _ -> Alcotest.fail "text roundtrip"
;;

let test_content_block_of_json_thinking () =
  let json =
    `Assoc
      [ "type", `String "thinking"
      ; "signature", `String "sig"
      ; "thinking", `String "reason"
      ]
  in
  match Api_common.content_block_of_json json with
  | Some (Thinking { signature = Some "sig"; content = "reason" }) -> ()
  | _ -> Alcotest.fail "thinking roundtrip"
;;

let test_content_block_of_json_redacted_thinking () =
  let json = `Assoc [ "type", `String "redacted_thinking"; "data", `String "hidden" ] in
  match Api_common.content_block_of_json json with
  | Some (RedactedThinking "hidden") -> ()
  | _ -> Alcotest.fail "redacted_thinking roundtrip"
;;

let test_content_block_of_json_tool_use () =
  let json =
    `Assoc
      [ "type", `String "tool_use"
      ; "id", `String "tu1"
      ; "name", `String "fn"
      ; "input", `Assoc [ "k", `Int 1 ]
      ]
  in
  match Api_common.content_block_of_json json with
  | Some (ToolUse { id = "tu1"; name = "fn"; _ }) -> ()
  | _ -> Alcotest.fail "tool_use roundtrip"
;;

let test_content_block_of_json_tool_result () =
  let json =
    `Assoc
      [ "type", `String "tool_result"
      ; "tool_use_id", `String "tu1"
      ; "content", `String "done"
      ; "is_error", `Bool false
      ]
  in
  match Api_common.content_block_of_json json with
  | Some
      (ToolResult { tool_use_id = "tu1"; content = "done"; outcome = Tool_succeeded; _ })
    -> ()
  | _ -> Alcotest.fail "tool_result roundtrip"
;;

let test_content_block_of_json_tool_result_no_is_error () =
  let json =
    `Assoc
      [ "type", `String "tool_result"
      ; "tool_use_id", `String "tu1"
      ; "content", `String "done"
      ]
  in
  match Api_common.content_block_of_json json with
  | Some (ToolResult { outcome = Tool_succeeded; _ }) -> ()
  | _ -> Alcotest.fail "tool_result default is_error"
;;

let test_content_block_of_json_image () =
  let json =
    `Assoc
      [ "type", `String "image"
      ; ( "source"
        , `Assoc
            [ "type", `String "base64"
            ; "media_type", `String "image/png"
            ; "data", `String "abc"
            ] )
      ]
  in
  match Api_common.content_block_of_json json with
  | Some (Image { media_type = "image/png"; data = "abc"; source_type = Types.Base64 }) ->
    ()
  | _ -> Alcotest.fail "image roundtrip"
;;

let test_content_block_of_json_document () =
  let json =
    `Assoc
      [ "type", `String "document"
      ; ( "source"
        , `Assoc
            [ "type", `String "base64"
            ; "media_type", `String "application/pdf"
            ; "data", `String "pdf"
            ] )
      ]
  in
  match Api_common.content_block_of_json json with
  | Some (Document { media_type = "application/pdf"; _ }) -> ()
  | _ -> Alcotest.fail "document roundtrip"
;;

let test_content_block_of_json_audio () =
  let json =
    `Assoc
      [ "type", `String "audio"
      ; ( "source"
        , `Assoc
            [ "type", `String "base64"
            ; "media_type", `String "audio/wav"
            ; "data", `String "wav"
            ] )
      ]
  in
  match Api_common.content_block_of_json json with
  | Some (Audio { media_type = "audio/wav"; _ }) -> ()
  | _ -> Alcotest.fail "audio roundtrip"
;;

let test_content_block_of_json_unknown () =
  let json = `Assoc [ "type", `String "video"; "url", `String "x" ] in
  Alcotest.(check bool)
    "unknown -> None"
    true
    (Api_common.content_block_of_json json = None)
;;

let test_content_block_of_json_no_type () =
  let json = `Assoc [ "text", `String "hello" ] in
  Alcotest.(check bool)
    "no type -> None"
    true
    (Api_common.content_block_of_json json = None)
;;

(* message_to_json *)
let test_message_to_json_user () =
  let msg = user_msg "hi" in
  let json = Api_common.message_to_json msg in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "role" "user" (json |> member "role" |> to_string);
  match json |> member "content" with
  | `List [ _ ] -> ()
  | _ -> Alcotest.fail "expected content list"
;;

let test_message_to_json_assistant () =
  let msg = assistant_msg "hi" in
  let json = Api_common.message_to_json msg in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "role" "assistant" (json |> member "role" |> to_string)
;;

let test_message_to_json_system () =
  let msg = system_msg "prompt" in
  let json = Api_common.message_to_json msg in
  let open Yojson.Safe.Util in
  (* System maps to "user" in api_common *)
  Alcotest.(check string) "role" "user" (json |> member "role" |> to_string)
;;

let test_message_to_json_tool () =
  let msg : Types.message =
    { role = Tool
    ; content = [ Text "result" ]
    ; name = None
    ; tool_call_id = None
    ; metadata = []
    }
  in
  let json = Api_common.message_to_json msg in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "tool -> user" "user" (json |> member "role" |> to_string)
;;

let test_tool_result_followup_merge_preserves_internal_metadata () =
  let tool_result =
    Types.make_message
      ~role:Tool
      [ ToolResult
          { tool_use_id = "tu1"
          ; content = "failed"
          ; outcome =
              Tool_failed
                { failure_kind = Recoverable_tool_error
                ; error_class = Some Deterministic
                }
          ; json = None
          ; content_blocks = None
          }
      ]
  in
  let boundary = Types.Conversation_metadata.run_boundary_entry in
  let followup =
    Types.make_message ~metadata:[ boundary ] ~role:User [ Text "continue" ]
  in
  match Api_common.merge_tool_result_followup_user_messages [ tool_result; followup ] with
  | [ merged ] ->
    Alcotest.(check bool)
      "tool result retained"
      true
      (List.exists
         (function
           | Types.ToolResult { tool_use_id = "tu1"; _ } -> true
           | _ -> false)
         merged.content);
    Alcotest.(check bool)
      "follow-up retained"
      true
      (List.exists
         (function
           | Types.Text "continue" -> true
           | _ -> false)
         merged.content);
    Alcotest.(check bool)
      "internal metadata retained"
      true
      (List.mem boundary merged.metadata)
  | messages ->
    Alcotest.failf "expected one merged provider message, got %d" (List.length messages)
;;

(* ═══════════════════════════════════════════════════
   4. Backend_gemini — build_request, parse_response,
      contents_of_messages
   ═══════════════════════════════════════════════════ *)

let test_contents_of_messages_user () =
  let msgs = [ user_msg "hello" ] in
  let contents, sys = Backend_gemini.contents_of_messages msgs in
  Alcotest.(check int) "1 content" 1 (List.length contents);
  Alcotest.(check bool) "no system" true (sys = None)
;;

let test_contents_of_messages_system () =
  let msgs = [ system_msg "you are helpful"; user_msg "hi" ] in
  let contents, sys = Backend_gemini.contents_of_messages msgs in
  Alcotest.(check int) "1 user content" 1 (List.length contents);
  Alcotest.(check bool) "has system" true (sys <> None)
;;

let test_contents_of_messages_mixed () =
  let msgs =
    [ system_msg "system prompt"; user_msg "user question"; assistant_msg "model answer" ]
  in
  let contents, sys = Backend_gemini.contents_of_messages msgs in
  Alcotest.(check int) "user + model contents" 2 (List.length contents);
  Alcotest.(check bool) "has system" true (sys <> None)
;;

let test_contents_of_messages_tool_use () =
  let msgs : Types.message list =
    [ user_msg "call this tool"
    ; { role = Assistant
      ; content =
          [ ToolUse { id = "tu1"; name = "my_fn"; input = `Assoc [ "x", `Int 1 ] } ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ; { role = Tool
      ; content =
          [ ToolResult
              { tool_use_id = "tu1"
              ; content = "result42"
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
  let contents, _sys = Backend_gemini.contents_of_messages msgs in
  (* Should have 3 content entries: user, assistant with functionCall, tool with functionResponse *)
  Alcotest.(check int) "3 contents" 3 (List.length contents)
;;

let test_contents_of_messages_redacted_filtered () =
  let msgs : Types.message list =
    [ { role = Assistant
      ; content = [ RedactedThinking "secret"; Text "visible" ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  let contents, _sys = Backend_gemini.contents_of_messages msgs in
  Alcotest.(check int) "1 content" 1 (List.length contents);
  (* The redacted thinking should be filtered out, leaving only text *)
  let open Yojson.Safe.Util in
  match List.hd contents |> member "parts" with
  | `List parts -> Alcotest.(check int) "1 part (redacted filtered)" 1 (List.length parts)
  | _ -> Alcotest.fail "expected parts list"
;;

let test_build_request_basic () =
  let config =
    make_config
      ~kind:Gemini
      ~model_id:gemini25_flash_model
      ~max_tokens:100
      ~temperature:0.5
      ()
  in
  let body_str = Backend_gemini.build_request ~config ~messages:[ user_msg "hello" ] () in
  let json = Yojson.Safe.from_string body_str in
  let open Yojson.Safe.Util in
  (* Check contents exist *)
  (match json |> member "contents" with
   | `List (_ :: _) -> ()
   | _ -> Alcotest.fail "expected non-empty contents");
  (* Check generationConfig *)
  let gc = json |> member "generationConfig" in
  Alcotest.(check int) "maxOutputTokens" 100 (gc |> member "maxOutputTokens" |> to_int);
  Alcotest.(check (float 0.01)) "temperature" 0.5 (gc |> member "temperature" |> to_number)
;;

let test_build_request_with_system_prompt () =
  let config =
    make_config ~kind:Gemini ~model_id:gemini25_flash_model ~system_prompt:"be helpful" ()
  in
  let body_str = Backend_gemini.build_request ~config ~messages:[ user_msg "hello" ] () in
  let json = Yojson.Safe.from_string body_str in
  let open Yojson.Safe.Util in
  match json |> member "systemInstruction" with
  | `Null -> Alcotest.fail "expected systemInstruction"
  | si ->
    let parts = si |> member "parts" in
    (match parts with
     | `List (_ :: _) -> ()
     | _ -> Alcotest.fail "expected parts in systemInstruction")
;;

let test_build_request_with_thinking () =
  let config =
    make_config
      ~kind:Gemini
      ~model_id:gemini25_flash_model
      ~enable_thinking:true
      ~thinking_budget:5000
      ()
  in
  let body_str =
    Backend_gemini.build_request ~config ~messages:[ user_msg "reason about this" ] ()
  in
  let json = Yojson.Safe.from_string body_str in
  let open Yojson.Safe.Util in
  let gc = json |> member "generationConfig" in
  let tc = gc |> member "thinkingConfig" in
  Alcotest.(check int) "thinkingBudget" 5000 (tc |> member "thinkingBudget" |> to_int);
  Alcotest.(check bool) "includeThoughts" true (tc |> member "includeThoughts" |> to_bool)
;;

let test_build_request_with_thinking_rejects_unspecified_budget () =
  let config =
    make_config ~kind:Gemini ~model_id:gemini25_flash_model ~enable_thinking:true ()
  in
  match Backend_gemini.build_request ~config ~messages:[ user_msg "reason" ] () with
  | _ -> Alcotest.fail "expected explicit thinking budget rejection"
  | exception Invalid_argument message ->
    Alcotest.(check string)
      "rejection"
      "Backend_gemini.build_request: enable_thinking=true on a thinkingBudget wire \
       requires an explicit thinking_budget"
      message
;;

let test_constants_http_code_sets () =
  Alcotest.(check (list int))
    "cascadable"
    [ 401; 403; 429; 498; 500; 502; 503; 529 ]
    Constants.Http.cascadable_codes
;;

let test_constants_cache_truncation_and_endpoints () =
  Alcotest.(check int) "cache ttl" 300 Constants.Cache.default_ttl_sec;
  Alcotest.(check int) "truncate" 200 Constants.Truncation.max_error_body_length;
  Alcotest.(check int) "llama port" 8085 Constants.Endpoints.default_llama_port;
  Alcotest.(check string)
    "default url"
    "http://127.0.0.1:8085"
    Constants.Endpoints.default_url;
  Alcotest.(check string)
    "localhost url"
    "http://localhost:8085"
    Constants.Endpoints.default_url_localhost
;;

let test_build_request_json_mode () =
  let config =
    make_config
      ~kind:Gemini
      ~model_id:gemini25_flash_model
      ~response_format:Types.JsonMode
      ()
  in
  let body_str =
    Backend_gemini.build_request ~config ~messages:[ user_msg "json pls" ] ()
  in
  let json = Yojson.Safe.from_string body_str in
  let open Yojson.Safe.Util in
  let gc = json |> member "generationConfig" in
  Alcotest.(check string)
    "responseMimeType"
    "application/json"
    (gc |> member "responseMimeType" |> to_string)
;;

let test_build_request_with_tools () =
  let config = make_config ~kind:Gemini ~model_id:gemini25_flash_model () in
  let tool_schema =
    `Assoc
      [ "name", `String "get_weather"
      ; "description", `String "Get weather info"
      ; ( "input_schema"
        , `Assoc
            [ "type", `String "object"
            ; "properties", `Assoc [ "city", `Assoc [ "type", `String "string" ] ]
            ] )
      ]
  in
  let body_str =
    Backend_gemini.build_request
      ~config
      ~messages:[ user_msg "weather" ]
      ~tools:[ tool_schema ]
      ()
  in
  let json = Yojson.Safe.from_string body_str in
  let open Yojson.Safe.Util in
  match json |> member "tools" with
  | `List [ t ] ->
    (match t |> member "functionDeclarations" with
     | `List [ fd ] ->
       Alcotest.(check string) "name" "get_weather" (fd |> member "name" |> to_string)
     | _ -> Alcotest.fail "expected functionDeclarations")
  | _ -> Alcotest.fail "expected tools list"
;;

let test_build_request_tool_choice_auto () =
  let config =
    make_config ~kind:Gemini ~model_id:gemini25_flash_model ~tool_choice:Auto ()
  in
  let body_str =
    Backend_gemini.build_request
      ~config
      ~messages:[ user_msg "hi" ]
      ~tools:[ `Assoc [ "name", `String "t" ] ]
      ()
  in
  let json = Yojson.Safe.from_string body_str in
  let open Yojson.Safe.Util in
  let tc = json |> member "toolConfig" |> member "functionCallingConfig" in
  Alcotest.(check string) "mode" "AUTO" (tc |> member "mode" |> to_string)
;;

let test_build_request_tool_choice_any () =
  let config =
    make_config ~kind:Gemini ~model_id:gemini25_flash_model ~tool_choice:Any ()
  in
  let body_str =
    Backend_gemini.build_request
      ~config
      ~messages:[ user_msg "hi" ]
      ~tools:[ `Assoc [ "name", `String "t" ] ]
      ()
  in
  let json = Yojson.Safe.from_string body_str in
  let open Yojson.Safe.Util in
  let tc = json |> member "toolConfig" |> member "functionCallingConfig" in
  Alcotest.(check string) "mode" "ANY" (tc |> member "mode" |> to_string)
;;

let test_build_request_tool_choice_none () =
  let config =
    make_config ~kind:Gemini ~model_id:gemini25_flash_model ~tool_choice:None_ ()
  in
  let body_str = Backend_gemini.build_request ~config ~messages:[ user_msg "hi" ] () in
  let json = Yojson.Safe.from_string body_str in
  let open Yojson.Safe.Util in
  let tc = json |> member "toolConfig" |> member "functionCallingConfig" in
  Alcotest.(check string) "mode" "NONE" (tc |> member "mode" |> to_string)
;;

let test_build_request_tool_choice_specific () =
  let config =
    make_config
      ~kind:Gemini
      ~model_id:gemini25_flash_model
      ~tool_choice:(Tool "get_weather")
      ()
  in
  let body_str = Backend_gemini.build_request ~config ~messages:[ user_msg "hi" ] () in
  let json = Yojson.Safe.from_string body_str in
  let open Yojson.Safe.Util in
  let tc = json |> member "toolConfig" |> member "functionCallingConfig" in
  Alcotest.(check string) "mode" "ANY" (tc |> member "mode" |> to_string);
  match tc |> member "allowedFunctionNames" with
  | `List [ `String "get_weather" ] -> ()
  | _ -> Alcotest.fail "expected allowedFunctionNames"
;;

let test_build_request_top_p_top_k () =
  let config : Provider_config.t =
    Provider_config.make
      ~kind:Gemini
      ~model_id:gemini25_flash_model
      ~base_url:""
      ~top_p:0.9
      ~top_k:40
      ()
  in
  let body_str = Backend_gemini.build_request ~config ~messages:[ user_msg "hi" ] () in
  let json = Yojson.Safe.from_string body_str in
  let open Yojson.Safe.Util in
  let gc = json |> member "generationConfig" in
  Alcotest.(check (float 0.01)) "topP" 0.9 (gc |> member "topP" |> to_number);
  Alcotest.(check int) "topK" 40 (gc |> member "topK" |> to_int)
;;

(* parse_response *)
let test_parse_response_basic () =
  let json =
    Yojson.Safe.from_string
      (Printf.sprintf
         {|{
    "candidates": [{
      "content": {
        "parts": [{"text": "Hello world"}],
        "role": "model"
      },
      "finishReason": "STOP"
    }],
    "usageMetadata": {
      "promptTokenCount": 10,
      "candidatesTokenCount": 20
    },
    "modelVersion": "%s"
  }|}
         gemini25_flash_model)
  in
  let resp = Backend_gemini.parse_response json in
  Alcotest.(check string) "model" gemini25_flash_model resp.model;
  (match resp.content with
   | [ Text "Hello world" ] -> ()
   | _ -> Alcotest.fail "expected text block");
  match resp.stop_reason with
  | Types.EndTurn -> ()
  | _ -> Alcotest.fail "expected EndTurn"
;;

let test_parse_response_with_thinking () =
  let json =
    Yojson.Safe.from_string
      {|{
    "candidates": [{
      "content": {
        "parts": [
          {"thought": true, "text": "let me think"},
          {"text": "answer"}
        ]
      },
      "finishReason": "STOP"
    }]
  }|}
  in
  let resp = Backend_gemini.parse_response json in
  Alcotest.(check int) "2 blocks" 2 (List.length resp.content);
  match List.hd resp.content with
  | Types.Thinking { content = "let me think"; _ } -> ()
  | _ -> Alcotest.fail "expected thinking block"
;;

let test_parse_response_function_call () =
  let json =
    Yojson.Safe.from_string
      {|{
    "candidates": [{
      "content": {
        "parts": [{
          "functionCall": {
            "name": "get_weather",
            "args": {"city": "Seoul"}
          }
        }]
      },
      "finishReason": "STOP"
    }]
  }|}
  in
  let resp = Backend_gemini.parse_response json in
  (match resp.content with
   | [ Types.ToolUse { name = "get_weather"; _ } ] -> ()
   | _ -> Alcotest.fail "expected ToolUse");
  match resp.stop_reason with
  | Types.StopToolUse -> ()
  | _ -> Alcotest.fail "expected StopToolUse"
;;

let test_parse_response_truncated_function_call_is_not_executable () =
  let json =
    Yojson.Safe.from_string
      {|{
    "candidates": [{
      "content": {
        "parts": [{
          "functionCall": {
            "name": "get_weather",
            "args": {"city": "Seo"}
          }
        }]
      },
      "finishReason": "MAX_TOKENS"
    }]
  }|}
  in
  let resp = Backend_gemini.parse_response json in
  (match resp.content with
   | [ Types.ToolUse { name = "get_weather"; _ } ] -> ()
   | _ -> Alcotest.fail "expected observed ToolUse block");
  match resp.stop_reason with
  | Types.MaxTokens -> ()
  | _ -> Alcotest.fail "truncated function call must not execute"
;;

let test_parse_response_max_tokens () =
  let json =
    Yojson.Safe.from_string
      {|{
    "candidates": [{
      "content": {"parts": [{"text": "partial"}]},
      "finishReason": "MAX_TOKENS"
    }]
  }|}
  in
  let resp = Backend_gemini.parse_response json in
  match resp.stop_reason with
  | Types.MaxTokens -> ()
  | _ -> Alcotest.fail "expected MaxTokens"
;;

let test_parse_response_safety () =
  let json =
    Yojson.Safe.from_string
      {|{
    "candidates": [{
      "content": {"parts": []},
      "finishReason": "SAFETY"
    }]
  }|}
  in
  let resp = Backend_gemini.parse_response json in
  match resp.stop_reason with
  | Types.Refusal -> ()
  | _ -> Alcotest.fail "expected Refusal"
;;

let test_parse_response_recitation () =
  let json =
    Yojson.Safe.from_string
      {|{
    "candidates": [{
      "content": {"parts": []},
      "finishReason": "RECITATION"
    }]
  }|}
  in
  let resp = Backend_gemini.parse_response json in
  match resp.stop_reason with
  | Types.Refusal -> ()
  | _ -> Alcotest.fail "expected Refusal"
;;

let test_parse_response_unknown_reason () =
  let json =
    Yojson.Safe.from_string
      {|{
    "candidates": [{
      "content": {"parts": [{"text": "x"}]},
      "finishReason": "BLOCKLIST"
    }]
  }|}
  in
  let resp = Backend_gemini.parse_response json in
  match resp.stop_reason with
  | Types.Refusal -> ()
  | _ -> Alcotest.fail "expected BLOCKLIST refusal"
;;

let test_parse_response_no_finish_reason () =
  let json =
    Yojson.Safe.from_string
      {|{
    "candidates": [{
      "content": {"parts": [{"text": "x"}]}
    }]
  }|}
  in
  let resp = Backend_gemini.parse_response json in
  match resp.stop_reason with
  | Types.Unknown "FINISH_REASON_UNSPECIFIED" -> ()
  | _ -> Alcotest.fail "missing finishReason must not imply STOP"
;;

let test_parse_response_no_usage () =
  let json =
    Yojson.Safe.from_string
      {|{
    "candidates": [{
      "content": {"parts": [{"text": "x"}]},
      "finishReason": "STOP"
    }]
  }|}
  in
  let resp = Backend_gemini.parse_response json in
  Alcotest.(check bool) "no usage" true (resp.usage = None)
;;

let test_parse_response_error () =
  let json =
    Yojson.Safe.from_string
      {|{
    "error": {"message": "model not found", "code": 404}
  }|}
  in
  try
    let _ = Backend_gemini.parse_response json in
    Alcotest.fail "expected exception"
  with
  | Backend_gemini.Gemini_api_error msg ->
    Alcotest.(check string) "error msg" "model not found" msg
;;

let test_parse_response_error_no_message () =
  let json =
    Yojson.Safe.from_string
      {|{
    "error": {"code": 500}
  }|}
  in
  try
    let _ = Backend_gemini.parse_response json in
    Alcotest.fail "expected exception"
  with
  | Backend_gemini.Gemini_api_error msg ->
    Alcotest.(check string) "default msg" "Unknown Gemini API error" msg
;;

let test_parse_response_no_candidates () =
  (* Should fallback to json itself as candidate *)
  let json =
    Yojson.Safe.from_string
      {|{
    "content": {"parts": [{"text": "fallback"}]},
    "finishReason": "STOP"
  }|}
  in
  let resp = Backend_gemini.parse_response json in
  match resp.content with
  | [ Text "fallback" ] -> ()
  | _ -> Alcotest.fail "expected fallback parse"
;;

let test_parse_response_usage_with_cache () =
  let json =
    Yojson.Safe.from_string
      {|{
    "candidates": [{
      "content": {"parts": [{"text": "x"}]},
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
    Alcotest.(check int) "input" 100 u.input_tokens;
    Alcotest.(check int) "output" 50 u.output_tokens;
    Alcotest.(check int) "cache_read" 30 u.cache_read_input_tokens;
    Alcotest.(check int) "cache_creation" 0 u.cache_creation_input_tokens
  | None -> Alcotest.fail "expected usage"
;;

(* ═══════════════════════════════════════════════════
   5. Capabilities — presets, for_model_id, with_context_size
   ═══════════════════════════════════════════════════ *)

let test_default_capabilities () =
  let c = Capabilities.default_capabilities in
  Alcotest.(check bool) "no tools" false c.supports_tools;
  Alcotest.(check bool) "system_prompt" true c.supports_system_prompt;
  Alcotest.(check bool) "no context limit" true (c.max_context_tokens = None)
;;

let test_anthropic_capabilities () =
  let c = Capabilities.anthropic_capabilities in
  Alcotest.(check bool) "tools" true c.supports_tools;
  Alcotest.(check bool) "tool_choice" true c.supports_tool_choice;
  Alcotest.(check bool) "named tool_choice" true c.supports_named_tool_choice;
  Alcotest.(check bool) "parallel tools" true c.supports_parallel_tool_calls;
  Alcotest.(check bool) "reasoning" true c.supports_reasoning;
  Alcotest.(check bool) "extended_thinking" true c.supports_extended_thinking;
  Alcotest.(check bool) "structured output" true c.supports_structured_output;
  Alcotest.(check bool) "multimodal" true c.supports_multimodal_inputs;
  Alcotest.(check bool) "streaming" true c.supports_native_streaming;
  Alcotest.(check bool) "caching" true c.supports_caching;
  Alcotest.(check bool) "computer_use" true c.supports_computer_use;
  Alcotest.(check (option int)) "max_context" (Some 200_000) c.max_context_tokens
;;

let test_openai_compat_chat_capabilities () =
  let c = Capabilities.openai_compat_chat_capabilities in
  Alcotest.(check bool) "tools" true c.supports_tools;
  Alcotest.(check bool) "tool_choice" true c.supports_tool_choice;
  Alcotest.(check bool) "named tool_choice" true c.supports_named_tool_choice;
  Alcotest.(check bool) "json format" true c.supports_response_format_json;
  Alcotest.(check bool) "structured" true c.supports_structured_output;
  Alcotest.(check (option int)) "max_context" (Some 128_000) c.max_context_tokens
;;

let test_openai_compat_chat_extended_capabilities () =
  let c = Capabilities.openai_compat_chat_extended_capabilities in
  Alcotest.(check bool) "reasoning" true c.supports_reasoning;
  Alcotest.(check bool) "extended_thinking" true c.supports_extended_thinking;
  Alcotest.(check bool) "top_k" true c.supports_top_k;
  Alcotest.(check bool) "min_p" true c.supports_min_p
;;

let test_gemini_capabilities () =
  let c = Capabilities.gemini_capabilities in
  Alcotest.(check bool) "audio" true c.supports_audio_input;
  Alcotest.(check bool) "video" true c.supports_video_input;
  Alcotest.(check bool) "code_execution" false c.supports_code_execution;
  (* Gemini generationConfig accepts topK — pin so capability-gated
     consumers do not silently drop it for Gemini configs. *)
  Alcotest.(check bool) "top_k" true c.supports_top_k;
  Alcotest.(check bool) "no min_p" false c.supports_min_p;
  Alcotest.(check (option int)) "max_context" (Some 1_000_000) c.max_context_tokens;
  Alcotest.(check (option int)) "max_output" (Some 65_000) c.max_output_tokens
;;

let test_glm_capabilities () =
  let c = Capabilities.glm_capabilities in
  (* Tool descriptions are sent and the model can still emit tool_use blocks. *)
  Alcotest.(check bool) "supports_tools" true c.supports_tools;
  (* GLM accepts provider-level tool_choice modes such as auto/any, but does
     not support named forced tool_choice. Keep these axes separate so callers
     reject unsupported named forcing without dropping valid auto requests. *)
  Alcotest.(check bool) "supports tool_choice modes" true c.supports_tool_choice;
  Alcotest.(check bool)
    "rejects named forced tool_choice"
    false
    c.supports_named_tool_choice;
  Alcotest.(check bool) "structured output disabled" false c.supports_structured_output;
  Alcotest.(check (option int)) "200K context" (Some 200_000) c.max_context_tokens;
  Alcotest.(check (option int)) "40960 output cap" (Some 40_960) c.max_output_tokens
;;

let test_for_model_id_claude_opus_4 () =
  match Capabilities.for_model_id "claude-opus-4-20260101" with
  | Some c ->
    Alcotest.(check (option int)) "1M context" (Some 1_000_000) c.max_context_tokens;
    Alcotest.(check (option int)) "128K output" (Some 128_000) c.max_output_tokens
  | None -> Alcotest.fail "expected Some for claude-opus-4"
;;

let test_for_model_id_claude_sonnet_4 () =
  match Capabilities.for_model_id "claude-sonnet-4-latest" with
  | Some c ->
    Alcotest.(check (option int)) "1M context" (Some 1_000_000) c.max_context_tokens;
    Alcotest.(check (option int)) "64K output" (Some 64_000) c.max_output_tokens
  | None -> Alcotest.fail "expected Some for claude-sonnet-4"
;;

let test_for_model_id_claude_haiku_4 () =
  match Capabilities.for_model_id "claude-haiku-4-2026" with
  | Some c ->
    Alcotest.(check (option int)) "200K context" (Some 200_000) c.max_context_tokens;
    Alcotest.(check (option int)) "8K output" (Some 8_192) c.max_output_tokens
  | None -> Alcotest.fail "expected Some for claude-haiku-4"
;;

let test_for_model_id_gpt5 () =
  match Capabilities.for_model_id "gpt-5-latest" with
  | Some c ->
    Alcotest.(check bool) "computer_use" true c.supports_computer_use;
    Alcotest.(check (option int)) "1050K context" (Some 1_050_000) c.max_context_tokens
  | None -> Alcotest.fail "expected Some for gpt-5"
;;

let test_for_model_id_gpt41 () =
  match Capabilities.for_model_id "gpt-4.1-mini" with
  | Some c ->
    Alcotest.(check (option int)) "1M context" (Some 1_000_000) c.max_context_tokens
  | None -> Alcotest.fail "expected Some for gpt-4.1"
;;

let test_for_model_id_gpt4o () =
  match Capabilities.for_model_id "gpt-latest" with
  | Some c ->
    Alcotest.(check (option int)) "128K context" (Some 128_000) c.max_context_tokens
  | None -> Alcotest.fail "expected Some for gpt"
;;

let test_for_model_id_gemini25 () =
  match Capabilities.for_model_id gemini25_flash_model with
  | Some c -> Alcotest.(check bool) "code_execution" false c.supports_code_execution
  | None -> Alcotest.fail "expected Some for legacy gemini"
;;

let test_for_model_id_gemini3 () =
  match Capabilities.for_model_id "gemini-3-pro" with
  | Some _ -> ()
  | None -> Alcotest.fail "expected Some for gemini-3"
;;

let test_for_model_id_qwen3 () =
  match Capabilities.for_model_id "dashscope-3.5-35b" with
  | Some c ->
    Alcotest.(check bool) "tools" true c.supports_tools;
    Alcotest.(check bool) "reasoning" true c.supports_reasoning;
    Alcotest.(check bool) "top_k" true c.supports_top_k;
    Alcotest.(check bool) "min_p" true c.supports_min_p
  | None -> Alcotest.fail "expected Some for qwen3"
;;

let test_for_model_id_llama4 () =
  match Capabilities.for_model_id "llama-4-scout" with
  | Some c ->
    Alcotest.(check (option int)) "1M context" (Some 1_000_000) c.max_context_tokens;
    Alcotest.(check bool) "multimodal" true c.supports_multimodal_inputs
  | None -> Alcotest.fail "expected Some for llama-4"
;;

let test_for_model_id_llama4_alt () =
  match Capabilities.for_model_id "llama4-maverick" with
  | Some _ -> ()
  | None -> Alcotest.fail "expected Some for llama4"
;;

let provider_model_capabilities provider_label model_id =
  Capabilities.for_provider_model_id ~allow_bare_fallback:false ~provider_label ~model_id
;;

let test_for_provider_model_deepseek_v4_flash () =
  match provider_model_capabilities "deepseek" "deepseek-v4-flash" with
  | Some c ->
    Alcotest.(check (option int)) "1M context" (Some 1_000_000) c.max_context_tokens;
    Alcotest.(check (option int)) "384K output" (Some 384_000) c.max_output_tokens;
    Alcotest.(check bool) "tools" true c.supports_tools;
    Alcotest.(check bool) "reasoning" true c.supports_reasoning;
    Alcotest.(check bool)
      "thinking object"
      true
      (c.thinking_control_format = Capabilities.Thinking_object);
    Alcotest.(check bool) "caching" true c.supports_caching
  | None -> Alcotest.fail "expected Some for deepseek-v4-flash"
;;

let test_for_provider_model_deepseek_v4_pro () =
  match provider_model_capabilities "deepseek" "deepseek-v4-pro" with
  | Some c ->
    Alcotest.(check (option int)) "1M context" (Some 1_000_000) c.max_context_tokens;
    Alcotest.(check (option int)) "384K output" (Some 384_000) c.max_output_tokens;
    Alcotest.(check bool) "tools" true c.supports_tools;
    Alcotest.(check bool) "reasoning" true c.supports_reasoning;
    Alcotest.(check bool)
      "thinking object"
      true
      (c.thinking_control_format = Capabilities.Thinking_object);
    Alcotest.(check bool) "caching" true c.supports_caching
  | None -> Alcotest.fail "expected Some for deepseek-v4-pro"
;;

let test_for_provider_model_mistral_large () =
  match provider_model_capabilities "mistral" "mistral-large" with
  | Some c ->
    Alcotest.(check bool) "structured" true c.supports_structured_output;
    Alcotest.(check (option int)) "260K context" (Some 260_000) c.max_context_tokens
  | None -> Alcotest.fail "expected Some for mistral-large"
;;

let test_for_provider_model_mistral_small () =
  match provider_model_capabilities "mistral" "mistral-small" with
  | Some c ->
    Alcotest.(check bool) "reasoning" true c.supports_reasoning;
    Alcotest.(check (option int)) "256K context" (Some 256_000) c.max_context_tokens
  | None -> Alcotest.fail "expected Some for mistral-small"
;;

let test_for_provider_model_command () =
  match provider_model_capabilities "cohere" "command-r-plus" with
  | Some c ->
    Alcotest.(check (option int)) "256K context" (Some 256_000) c.max_context_tokens;
    Alcotest.(check (option int)) "32K output" (Some 32_000) c.max_output_tokens
  | None -> Alcotest.fail "expected Some for command"
;;

let test_for_provider_model_grok () =
  match provider_model_capabilities "xai" "grok-4.3" with
  | Some c ->
    Alcotest.(check (option int)) "1M context" (Some 1_000_000) c.max_context_tokens;
    Alcotest.(check bool) "reasoning" true c.supports_reasoning
  | None -> Alcotest.fail "expected Some for grok"
;;

let test_for_model_id_glm () =
  (* glm-4.5-flash matches current Z.AI GLM-4.5 thinking limits. *)
  (match Capabilities.for_model_id "glm-4.5-flash" with
   | Some c ->
     Alcotest.(check (option int)) "128K context" (Some 128_000) c.max_context_tokens;
     Alcotest.(check (option int)) "96K output" (Some 96_000) c.max_output_tokens;
     Alcotest.(check bool) "tools" true c.supports_tools;
     Alcotest.(check bool) "reasoning" true c.supports_reasoning;
     Alcotest.(check bool) "thinking" true c.supports_extended_thinking
   | None -> Alcotest.fail "expected Some for glm-4.5-flash");
  (* glm-5.1 should still get full capabilities *)
  match Capabilities.for_model_id "glm-5.1" with
  | Some c ->
    Alcotest.(check (option int)) "200K context" (Some 200_000) c.max_context_tokens;
    Alcotest.(check (option int)) "128K output" (Some 128_000) c.max_output_tokens;
    Alcotest.(check bool) "reasoning" true c.supports_reasoning
  | None -> Alcotest.fail "expected Some for glm-5.1"
;;

let test_for_model_id_unknown () =
  Alcotest.(check bool)
    "unknown -> None"
    true
    (Capabilities.for_model_id "totally-unknown-model" = None)
;;

let test_for_model_id_case_insensitive () =
  match Capabilities.for_model_id "Claude-Opus-4-Latest" with
  | Some _ -> ()
  | None -> Alcotest.fail "expected case-insensitive match"
;;

let test_with_context_size () =
  let c =
    Capabilities.with_context_size Capabilities.default_capabilities ~ctx_size:262144
  in
  Alcotest.(check (option int)) "set ctx" (Some 262144) c.max_context_tokens
;;

let test_with_context_size_overrides () =
  let c =
    Capabilities.with_context_size Capabilities.anthropic_capabilities ~ctx_size:1_000_000
  in
  Alcotest.(check (option int)) "overrides" (Some 1_000_000) c.max_context_tokens
;;

(* ── Complete_common.thinking_control_request_rejection ──
   Guards the pure, shared sync/stream admission decision for explicit thinking
   control. *)

let reasoning_no_control_caps =
  { Capabilities.openai_compat_chat_capabilities with supports_reasoning = true }
;;

let test_thinking_disable_unsatisfiable_when_reasoning_no_control () =
  let config = make_config ~model_id:"reasoner-no-control" ~enable_thinking:false () in
  Alcotest.(check bool)
    "reasoning model + No_thinking_control + disable -> unsatisfiable"
    true
    (Complete_common.thinking_control_request_rejection
       ~caps:reasoning_no_control_caps
       config
     = Some Complete_common.Disable_not_encodable)
;;

let test_thinking_enable_is_satisfied_by_declared_inherent_contract () =
  let config = make_config ~model_id:"reasoner-no-control" ~enable_thinking:true () in
  Alcotest.(check bool)
    "enable_thinking=true is satisfied by supports_reasoning + No_thinking_control"
    true
    (Complete_common.thinking_control_request_rejection
       ~caps:reasoning_no_control_caps
       config
     = None)
;;

let test_thinking_enable_rejects_without_dialect_or_inherent_contract () =
  let config = make_config ~model_id:"undeclared" ~enable_thinking:true () in
  Alcotest.(check bool)
    "enable_thinking=true without a dialect or inherent contract is rejected"
    true
    (Complete_common.thinking_control_request_rejection
       ~caps:Capabilities.openai_compat_chat_capabilities
       config
     = Some Complete_common.Enable_not_declared)
;;

let test_reasoning_effort_requires_an_explicit_wire_value () =
  let caps =
    { reasoning_no_control_caps with
      thinking_control_format = Capabilities.Reasoning_effort
    }
  in
  List.iter
    (fun (label, request_path) ->
       let config =
         make_config
           ~model_id:"reasoning-effort-model"
           ~request_path
           ~enable_thinking:true
           ()
       in
       Alcotest.(check bool)
         (label ^ " without an effort cannot encode explicit enable")
         true
         (Complete_common.thinking_control_request_rejection ~caps config
          = Some Complete_common.Enable_not_encodable);
       let config = { config with reasoning_effort = Some Reasoning_effort.Medium } in
       Alcotest.(check bool)
         (label ^ " with an effort encodes explicit enable")
         true
         (Complete_common.thinking_control_request_rejection ~caps config = None);
       let config = { config with reasoning_effort = Some Reasoning_effort.None_ } in
       Alcotest.(check bool)
         (label ^ " with effort=none cannot satisfy explicit enable")
         true
         (Complete_common.thinking_control_request_rejection ~caps config
          = Some Complete_common.Enable_not_encodable))
    [ "Chat Completions", "/v1/chat/completions"; "Responses", "/v1/responses" ]
;;

let test_thinking_unset_is_satisfiable () =
  let config = make_config ~model_id:"reasoner-no-control" () in
  Alcotest.(check bool)
    "enable_thinking unset -> nothing to satisfy"
    true
    (Complete_common.thinking_control_request_rejection
       ~caps:reasoning_no_control_caps
       config
     = None)
;;

let test_thinking_disable_noop_for_non_reasoning () =
  (* openai_compat_chat_capabilities has supports_reasoning = false *)
  let config = make_config ~model_id:"non-reasoner" ~enable_thinking:false () in
  Alcotest.(check bool)
    "non-reasoning model -> disable is a harmless no-op"
    true
    (Complete_common.thinking_control_request_rejection
       ~caps:Capabilities.openai_compat_chat_capabilities
       config
     = None)
;;

let test_thinking_disable_satisfiable_with_control_format () =
  let caps =
    { Capabilities.openai_compat_chat_capabilities with
      supports_reasoning = true
    ; thinking_control_format = Capabilities.Thinking_object
    }
  in
  let config = make_config ~model_id:"reasoner-with-control" ~enable_thinking:false () in
  Alcotest.(check bool)
    "reasoning model WITH a thinking_control_format -> satisfiable"
    true
    (Complete_common.thinking_control_request_rejection ~caps config = None)
;;

(* ── Json_util.decode_json_with (provider parse boundary) ────────── *)

let string_contains ~needle haystack =
  let nl = String.length needle in
  let hl = String.length haystack in
  let rec go i = i + nl <= hl && (String.sub haystack i nl = needle || go (i + 1)) in
  nl = 0 || go 0
;;

let test_decode_json_with_object () =
  match
    Json_util.decode_json_with
      (fun json -> Yojson.Safe.Util.(json |> member "data" |> to_list |> List.length))
      {|{"data":[1,2]}|}
  with
  | Ok n -> Alcotest.(check int) "decoded list length" 2 n
  | Error message -> Alcotest.failf "expected Ok, got Error %s" message
;;

let test_decode_json_with_syntax_error () =
  match Json_util.decode_json_with (fun json -> json) "{not-json" with
  | Error message ->
    Alcotest.(check bool)
      "syntax failure is labelled"
      true
      (string_contains ~needle:"invalid JSON:" message)
  | Ok _ -> Alcotest.fail "malformed body must not decode"
;;

let test_decode_json_with_null_body_contained () =
  (* 2xx + valid JSON that is not an object: [Util.member] raises
     [Type_error], which a [Json_error]-only guard lets escape the
     [result] contract. This boundary must contain it. *)
  match
    Json_util.decode_json_with (fun json -> Yojson.Safe.Util.member "data" json) "null"
  with
  | Error message ->
    Alcotest.(check bool)
      "shape failure names the offending type"
      true
      (string_contains ~needle:"unexpected JSON shape:" message
       && string_contains ~needle:"null" message)
  | Ok _ -> Alcotest.fail "non-object body must not decode through member"
;;

let test_decode_json_with_array_body_contained () =
  match
    Json_util.decode_json_with (fun json -> Yojson.Safe.Util.member "data" json) "[1,2]"
  with
  | Error message ->
    Alcotest.(check bool)
      "array body reported"
      true
      (string_contains ~needle:"array" message)
  | Ok _ -> Alcotest.fail "array body must not decode through member"
;;

let test_decode_json_with_undefined_contained () =
  match
    Json_util.decode_json_with (fun json -> Yojson.Safe.Util.index 5 json) "[1,2]"
  with
  | Error message ->
    Alcotest.(check bool)
      "out-of-bounds index reported"
      true
      (string_contains ~needle:"unexpected JSON shape:" message)
  | Ok _ -> Alcotest.fail "out-of-bounds index must not decode"
;;

let test_decode_json_with_foreign_exception_propagates () =
  (* Only Yojson boundary exceptions are contained: a decoder bug must
     surface as an exception, not dissolve into [Error]. *)
  Alcotest.check_raises "decoder bug propagates" (Failure "decoder bug") (fun () ->
    ignore (Json_util.decode_json_with (fun _ -> failwith "decoder bug") {|{"ok":true}|}))
;;

(* ═══════════════════════════════════════════════════
   Test runner
   ═══════════════════════════════════════════════════ *)

let () =
  Alcotest.run
    "llm_provider_cov"
    [ ( "json_util.decode_json_with"
      , [ Alcotest.test_case "object decodes" `Quick test_decode_json_with_object
        ; Alcotest.test_case
            "syntax error contained"
            `Quick
            test_decode_json_with_syntax_error
        ; Alcotest.test_case
            "null body contained"
            `Quick
            test_decode_json_with_null_body_contained
        ; Alcotest.test_case
            "array body contained"
            `Quick
            test_decode_json_with_array_body_contained
        ; Alcotest.test_case
            "out-of-bounds index contained"
            `Quick
            test_decode_json_with_undefined_contained
        ; Alcotest.test_case
            "foreign exception propagates"
            `Quick
            test_decode_json_with_foreign_exception_propagates
        ] )
    ; ( "complete.gemini_url"
      , [ Alcotest.test_case "sync no key" `Quick test_gemini_url_sync_no_key
        ; Alcotest.test_case "sync with key" `Quick test_gemini_url_sync_with_key
        ; Alcotest.test_case "stream with key" `Quick test_gemini_url_stream_with_key
        ; Alcotest.test_case "stream no key" `Quick test_gemini_url_stream_no_key
        ] )
    ; ( "api_common.constants"
      , [ Alcotest.test_case "default_base_url" `Quick test_default_base_url
        ; Alcotest.test_case "api_version" `Quick test_api_version
        ; Alcotest.test_case "max_response_body" `Quick test_max_response_body
        ; Alcotest.test_case "max_stdio_buffer" `Quick test_max_stdio_buffer
        ] )
    ; ( "api_common.helpers"
      , [ Alcotest.test_case "fresh_tool_use_id" `Quick test_fresh_tool_use_id
        ; Alcotest.test_case
            "fresh_tool_use_id domain-safe"
            `Quick
            test_fresh_tool_use_id_domain_safe
        ; Alcotest.test_case "string_is_blank" `Quick test_string_is_blank
        ; Alcotest.test_case "text_blocks_to_string" `Quick test_text_blocks_to_string
        ; Alcotest.test_case
            "text_blocks_to_string empty"
            `Quick
            test_text_blocks_to_string_empty
        ; Alcotest.test_case
            "text_blocks_to_string redacted"
            `Quick
            test_text_blocks_to_string_redacted
        ; Alcotest.test_case
            "json_of_string_or_raw valid"
            `Quick
            test_json_of_string_or_raw_valid
        ; Alcotest.test_case
            "json_of_string_or_raw invalid"
            `Quick
            test_json_of_string_or_raw_invalid
        ; Alcotest.test_case "base64_media_data_url" `Quick test_base64_media_data_url
        ; Alcotest.test_case "base64_media_payload" `Quick test_base64_media_payload
        ; Alcotest.test_case
            "base64_media_source rejects url"
            `Quick
            test_base64_media_source_rejects_url
        ] )
    ; ( "api_common.content_block_to_json"
      , [ Alcotest.test_case "text" `Quick test_content_block_to_json_text
        ; Alcotest.test_case "thinking" `Quick test_content_block_to_json_thinking
        ; Alcotest.test_case "redacted" `Quick test_content_block_to_json_redacted
        ; Alcotest.test_case "tool_use" `Quick test_content_block_to_json_tool_use
        ; Alcotest.test_case "tool_result" `Quick test_content_block_to_json_tool_result
        ; Alcotest.test_case "image" `Quick test_content_block_to_json_image
        ; Alcotest.test_case "document" `Quick test_content_block_to_json_document
        ; Alcotest.test_case "audio" `Quick test_content_block_to_json_audio
        ] )
    ; ( "api_common.content_block_of_json"
      , [ Alcotest.test_case "text" `Quick test_content_block_of_json_text
        ; Alcotest.test_case "thinking" `Quick test_content_block_of_json_thinking
        ; Alcotest.test_case
            "redacted_thinking"
            `Quick
            test_content_block_of_json_redacted_thinking
        ; Alcotest.test_case "tool_use" `Quick test_content_block_of_json_tool_use
        ; Alcotest.test_case "tool_result" `Quick test_content_block_of_json_tool_result
        ; Alcotest.test_case
            "tool_result no is_error"
            `Quick
            test_content_block_of_json_tool_result_no_is_error
        ; Alcotest.test_case "image" `Quick test_content_block_of_json_image
        ; Alcotest.test_case "document" `Quick test_content_block_of_json_document
        ; Alcotest.test_case "audio" `Quick test_content_block_of_json_audio
        ; Alcotest.test_case "unknown" `Quick test_content_block_of_json_unknown
        ; Alcotest.test_case "no type" `Quick test_content_block_of_json_no_type
        ] )
    ; ( "api_common.message_to_json"
      , [ Alcotest.test_case "user" `Quick test_message_to_json_user
        ; Alcotest.test_case "assistant" `Quick test_message_to_json_assistant
        ; Alcotest.test_case "system" `Quick test_message_to_json_system
        ; Alcotest.test_case "tool" `Quick test_message_to_json_tool
        ; Alcotest.test_case
            "tool follow-up internal metadata"
            `Quick
            test_tool_result_followup_merge_preserves_internal_metadata
        ] )
    ; ( "backend_gemini.contents_of_messages"
      , [ Alcotest.test_case "user" `Quick test_contents_of_messages_user
        ; Alcotest.test_case "system" `Quick test_contents_of_messages_system
        ; Alcotest.test_case "mixed" `Quick test_contents_of_messages_mixed
        ; Alcotest.test_case "tool_use" `Quick test_contents_of_messages_tool_use
        ; Alcotest.test_case
            "redacted filtered"
            `Quick
            test_contents_of_messages_redacted_filtered
        ] )
    ; ( "backend_gemini.build_request"
      , [ Alcotest.test_case "basic" `Quick test_build_request_basic
        ; Alcotest.test_case
            "with system_prompt"
            `Quick
            test_build_request_with_system_prompt
        ; Alcotest.test_case "with thinking" `Quick test_build_request_with_thinking
        ; Alcotest.test_case
            "thinking rejects unspecified budget"
            `Quick
            test_build_request_with_thinking_rejects_unspecified_budget
        ; Alcotest.test_case "json mode" `Quick test_build_request_json_mode
        ; Alcotest.test_case "with tools" `Quick test_build_request_with_tools
        ; Alcotest.test_case "tool_choice auto" `Quick test_build_request_tool_choice_auto
        ; Alcotest.test_case "tool_choice any" `Quick test_build_request_tool_choice_any
        ; Alcotest.test_case "tool_choice none" `Quick test_build_request_tool_choice_none
        ; Alcotest.test_case
            "tool_choice specific"
            `Quick
            test_build_request_tool_choice_specific
        ; Alcotest.test_case "top_p top_k" `Quick test_build_request_top_p_top_k
        ] )
    ; ( "constants"
      , [ Alcotest.test_case "http code sets" `Quick test_constants_http_code_sets
        ; Alcotest.test_case
            "cache truncation endpoints"
            `Quick
            test_constants_cache_truncation_and_endpoints
        ] )
    ; ( "backend_gemini.parse_response"
      , [ Alcotest.test_case "basic" `Quick test_parse_response_basic
        ; Alcotest.test_case "with thinking" `Quick test_parse_response_with_thinking
        ; Alcotest.test_case "function call" `Quick test_parse_response_function_call
        ; Alcotest.test_case
            "truncated function call"
            `Quick
            test_parse_response_truncated_function_call_is_not_executable
        ; Alcotest.test_case "max_tokens" `Quick test_parse_response_max_tokens
        ; Alcotest.test_case "safety" `Quick test_parse_response_safety
        ; Alcotest.test_case "recitation" `Quick test_parse_response_recitation
        ; Alcotest.test_case "unknown reason" `Quick test_parse_response_unknown_reason
        ; Alcotest.test_case
            "no finish reason"
            `Quick
            test_parse_response_no_finish_reason
        ; Alcotest.test_case "no usage" `Quick test_parse_response_no_usage
        ; Alcotest.test_case "error" `Quick test_parse_response_error
        ; Alcotest.test_case
            "error no message"
            `Quick
            test_parse_response_error_no_message
        ; Alcotest.test_case "no candidates" `Quick test_parse_response_no_candidates
        ; Alcotest.test_case
            "usage with cache"
            `Quick
            test_parse_response_usage_with_cache
        ] )
    ; ( "capabilities.presets"
      , [ Alcotest.test_case "default" `Quick test_default_capabilities
        ; Alcotest.test_case "anthropic" `Quick test_anthropic_capabilities
        ; Alcotest.test_case "openai_chat" `Quick test_openai_compat_chat_capabilities
        ; Alcotest.test_case
            "openai_chat_extended"
            `Quick
            test_openai_compat_chat_extended_capabilities
        ; Alcotest.test_case "gemini" `Quick test_gemini_capabilities
        ; Alcotest.test_case "glm" `Quick test_glm_capabilities
        ] )
    ; ( "capabilities.for_model_id"
      , [ Alcotest.test_case "claude-opus-4" `Quick test_for_model_id_claude_opus_4
        ; Alcotest.test_case "claude-sonnet-4" `Quick test_for_model_id_claude_sonnet_4
        ; Alcotest.test_case "claude-haiku-4" `Quick test_for_model_id_claude_haiku_4
        ; Alcotest.test_case "gpt-5" `Quick test_for_model_id_gpt5
        ; Alcotest.test_case "gpt-4.1" `Quick test_for_model_id_gpt41
        ; Alcotest.test_case "gpt" `Quick test_for_model_id_gpt4o
        ; Alcotest.test_case "gemini legacy" `Quick test_for_model_id_gemini25
        ; Alcotest.test_case "gemini-3" `Quick test_for_model_id_gemini3
        ; Alcotest.test_case "dashscope-3" `Quick test_for_model_id_qwen3
        ; Alcotest.test_case "llama-4" `Quick test_for_model_id_llama4
        ; Alcotest.test_case "llama4" `Quick test_for_model_id_llama4_alt
        ; Alcotest.test_case "glm" `Quick test_for_model_id_glm
        ; Alcotest.test_case "unknown" `Quick test_for_model_id_unknown
        ; Alcotest.test_case "case insensitive" `Quick test_for_model_id_case_insensitive
        ] )
    ; ( "capabilities.for_provider_model_id"
      , [ Alcotest.test_case
            "deepseek/deepseek-v4-flash"
            `Quick
            test_for_provider_model_deepseek_v4_flash
        ; Alcotest.test_case
            "deepseek/deepseek-v4-pro"
            `Quick
            test_for_provider_model_deepseek_v4_pro
        ; Alcotest.test_case
            "mistral/mistral-large"
            `Quick
            test_for_provider_model_mistral_large
        ; Alcotest.test_case
            "mistral/mistral-small"
            `Quick
            test_for_provider_model_mistral_small
        ; Alcotest.test_case "cohere/command" `Quick test_for_provider_model_command
        ; Alcotest.test_case "xai/grok" `Quick test_for_provider_model_grok
        ] )
    ; ( "capabilities.with_context_size"
      , [ Alcotest.test_case "set" `Quick test_with_context_size
        ; Alcotest.test_case "overrides" `Quick test_with_context_size_overrides
        ] )
    ; ( "complete_common.thinking_control"
      , [ Alcotest.test_case
            "reasoning+no-control disable unsatisfiable"
            `Quick
            test_thinking_disable_unsatisfiable_when_reasoning_no_control
        ; Alcotest.test_case
            "enable is satisfied by declared inherent contract"
            `Quick
            test_thinking_enable_is_satisfied_by_declared_inherent_contract
        ; Alcotest.test_case
            "enable rejects undeclared contract"
            `Quick
            test_thinking_enable_rejects_without_dialect_or_inherent_contract
        ; Alcotest.test_case
            "reasoning effort requires explicit wire value"
            `Quick
            test_reasoning_effort_requires_an_explicit_wire_value
        ; Alcotest.test_case
            "unset is satisfiable"
            `Quick
            test_thinking_unset_is_satisfiable
        ; Alcotest.test_case
            "non-reasoning no-op"
            `Quick
            test_thinking_disable_noop_for_non_reasoning
        ; Alcotest.test_case
            "with control format satisfiable"
            `Quick
            test_thinking_disable_satisfiable_with_control_format
        ] )
    ]
;;
