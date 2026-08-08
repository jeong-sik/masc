open Alcotest
module K = Llm_provider.Backend_glm
module PC = Llm_provider.Provider_config
module RD = Llm_provider.Reasoning_dialect
module S = Llm_provider.Streaming
module T = Llm_provider.Types

let member key json = Yojson.Safe.Util.member key json
let to_bool json = Yojson.Safe.Util.to_bool json
let to_string json = Yojson.Safe.Util.to_string json

let assoc_fields label = function
  | `Assoc fields -> fields
  | json ->
    fail (Printf.sprintf "expected %s object, got %s" label (Yojson.Safe.to_string json))
;;

let field_count key json =
  json
  |> assoc_fields "request body"
  |> List.fold_left
       (fun count (field, _) -> if String.equal field key then count + 1 else count)
       0
;;

let glm_config ?enable_thinking ?clear_thinking ?(tool_stream = false) () =
  PC.make
    ~kind:PC.Glm
    ~model_id:"glm-5.1"
    ~base_url:"https://api.z.ai/api/paas/v4"
    ?enable_thinking
    ?clear_thinking
    ~tool_stream
    ()
;;

let check_class label expected actual = check bool label true (actual = expected)

let check_classification label code expected retryable =
  let actual, retry = K.classify_glm_error ~code in
  check_class (label ^ " class") expected actual;
  check bool (label ^ " retryable") retryable retry
;;

let response_json ?(reasoning = Some "step by step") ?(content = "answer") () =
  let message_fields =
    [ "role", `String "assistant"; "content", `String content ]
    @
    match reasoning with
    | Some r -> [ "reasoning_content", `String r ]
    | None -> []
  in
  Yojson.Safe.to_string
    (`Assoc
        [ "id", `String "chatcmpl-provider-k"
        ; "model", `String "glm-5.1"
        ; ( "choices"
          , `List
              [ `Assoc
                  [ "finish_reason", `String "stop"; "message", `Assoc message_fields ]
              ] )
        ; ( "usage"
          , `Assoc
              [ "prompt_tokens", `Int 7
              ; "completion_tokens", `Int 3
              ; "total_tokens", `Int 10
              ] )
        ])
;;

let test_classification_matrix () =
  check_classification "auth" "1001" K.Glm_auth_error false;
  check_classification "rate" "1305" K.Glm_rate_limited true;
  check_classification "quota" "1308" K.Glm_quota_exceeded false;
  check_classification "server" "1234" K.Glm_server_error true;
  check_classification "invalid" "1210" K.Glm_invalid_request false;
  check_classification "context overflow (oas#2947)" "1261" K.Glm_context_overflow false;
  check_classification "unknown" "9999" K.Glm_invalid_request false
;;

(* oas#2947: the streaming path classifies a non-200 rejection by the
   envelope's documented code field. 1261 must parse to the overflow class;
   prose alone (no code) must not. *)
let test_check_glm_error_1261_envelope () =
  (match
     K.check_glm_error {|{"error":{"code":"1261","message":"Prompt exceeds max length"}}|}
   with
   | Some err ->
     check_class "envelope 1261 class" K.Glm_context_overflow err.K.error_class;
     check
       bool
       "envelope 1261 message"
       true
       (String.equal err.K.message "Prompt exceeds max length")
   | None -> fail "expected a parsed glm error envelope");
  (match K.check_glm_error {|{"error":{"message":"Prompt exceeds max length"}}|} with
   | Some err ->
     check
       bool
       "codeless envelope is not overflow"
       true
       (err.K.error_class <> K.Glm_context_overflow)
   | None -> fail "expected a parsed codeless glm error envelope");
  check
    bool
    "non-json body parses to none"
    true
    (Option.is_none (K.check_glm_error "Prompt exceeds max length"))
;;

let test_http_status_mapping () =
  check int "quota" 429 (K.http_code_of_glm_error_class K.Glm_quota_exceeded);
  check int "rate" 429 (K.http_code_of_glm_error_class K.Glm_rate_limited);
  check int "auth" 401 (K.http_code_of_glm_error_class K.Glm_auth_error);
  check int "server" 500 (K.http_code_of_glm_error_class K.Glm_server_error);
  check int "invalid" 400 (K.http_code_of_glm_error_class K.Glm_invalid_request)
;;

let test_build_request_thinking_modes_and_tool_stream () =
  let messages = [ T.user_msg "calculate" ] in
  let enabled =
    K.build_request
      ~stream:true
      ~config:
        (glm_config ~enable_thinking:true ~clear_thinking:false ~tool_stream:true ())
      ~messages
      ~tools:
        [ `Assoc
            [ "name", `String "calc"
            ; "description", `String "Calculate a value"
            ; "input_schema", `Assoc [ "type", `String "object" ]
            ]
        ]
      ()
    |> Yojson.Safe.from_string
  in
  check int "thinking enabled field count" 1 (field_count "thinking" enabled);
  check
    string
    "thinking enabled"
    "enabled"
    (enabled |> member "thinking" |> member "type" |> to_string);
  check
    bool
    "clear thinking false"
    false
    (enabled |> member "thinking" |> member "clear_thinking" |> to_bool);
  check bool "tool stream true" true (enabled |> member "tool_stream" |> to_bool);
  let disabled =
    K.build_request
      ~config:(glm_config ~enable_thinking:false ~tool_stream:true ())
      ~messages
      ()
    |> Yojson.Safe.from_string
  in
  check int "thinking disabled field count" 1 (field_count "thinking" disabled);
  check
    string
    "thinking disabled"
    "disabled"
    (disabled |> member "thinking" |> member "type" |> to_string);
  check
    bool
    "tool stream gated by stream flag"
    true
    (disabled |> member "tool_stream" = `Null);
  let passthrough =
    K.build_request ~config:(glm_config ()) ~messages () |> Yojson.Safe.from_string
  in
  check int "thinking omitted field count" 0 (field_count "thinking" passthrough);
  check bool "thinking omitted" true (passthrough |> member "thinking" = `Null)
;;

let test_parse_response_extracts_reasoning_and_usage () =
  let resp = K.parse_response (response_json ()) in
  check string "id" "chatcmpl-provider-k" resp.id;
  check string "model" "glm-5.1" resp.model;
  (match resp.content with
   | [ T.Thinking { content = "step by step"; _ }; T.Text "answer" ] -> ()
   | _ -> fail "expected reasoning block followed by answer text");
  match resp.usage with
  | Some usage ->
    check int "input tokens" 7 usage.input_tokens;
    check int "output tokens" 3 usage.output_tokens
  | None -> fail "expected usage"
;;

let test_parse_response_classifies_glm_errors () =
  let cases =
    [ ( {|{"error":{"code":"1305","message":"service overloaded"}}|}
      , Some "1305"
      , K.Glm_rate_limited
      , true )
    ; ( {|{"error":{"code":1234,"message":"server unavailable"}}|}
      , Some "1234"
      , K.Glm_server_error
      , true )
    ; ( {|{"error":{"code":{"nested":true},"message":"quota exceeded"}}|}
      , None
      , K.Glm_invalid_request
      , false )
    ; {|{"error":{"code":1200}}|}, Some "1200", K.Glm_invalid_request, false
    ]
  in
  List.iter
    (fun (body, code, expected_class, expected_retryable) ->
       match K.parse_response body with
       | exception K.Glm_api_error err ->
         check (option string) "error code" code err.code;
         check_class "error class" expected_class err.error_class;
         check bool "retryable" expected_retryable err.is_retryable
       | _ -> fail "expected Glm_api_error")
    cases
;;

let test_parse_response_wraps_openai_parse_errors () =
  match K.parse_response {|{"choices":"not-a-list"}|} with
  | exception K.Glm_api_error err ->
    check (option string) "parse code absent" None err.code;
    check bool "parse origin" true (err.origin = K.Response_parse);
    check_class "parse class" K.Glm_invalid_request err.error_class;
    check bool "parse is not retryable" false err.is_retryable;
    check bool "parse message surfaced" true (String.length err.message > 0)
  | _ -> fail "expected Glm_api_error"
;;

let test_extract_reasoning_handles_empty_and_malformed_bodies () =
  let resp =
    { T.id = "resp"
    ; model = "glm-5.1"
    ; stop_reason = T.EndTurn
    ; content = [ T.Text "answer" ]
    ; usage = None
    ; telemetry = None
    }
  in
  let unchanged label body =
    match (K.extract_reasoning_content resp body).content with
    | [ T.Text "answer" ] -> ()
    | _ -> fail (label ^ ": expected unchanged response")
  in
  unchanged "blank reasoning" (response_json ~reasoning:(Some "   ") ());
  unchanged "no choices" {|{"choices":[]}|};
  unchanged "malformed json" {|not json|}
;;

let test_parse_stream_chunk_uses_resolved_reasoning_dialect () =
  let data =
    {|{"id":"chunk-1","model":"glm-5.1","choices":[{"delta":{"reasoning_content":"thinking","content":"token"},"index":0}]}|}
  in
  match
    K.parse_stream_chunk ~streaming_reasoning:(RD.Delta_field "reasoning_content") data
  with
  | S.Openai_chunk chunk ->
    check (option string) "content" (Some "token") chunk.delta_content;
    check (option string) "reasoning" (Some "thinking") chunk.delta_reasoning
  | S.Openai_done | S.Openai_empty | S.Openai_provider_error _ | S.Openai_parse_failed _
    -> fail "expected stream chunk"
;;

let test_parse_stream_chunk_does_not_invent_missing_dialect () =
  let data =
    {|{"id":"chunk-1","model":"glm-5.1","choices":[{"delta":{"reasoning_content":"thinking","content":"token"},"index":0}]}|}
  in
  match K.parse_stream_chunk ~streaming_reasoning:RD.No_streaming_reasoning data with
  | S.Openai_chunk chunk ->
    check (option string) "content" (Some "token") chunk.delta_content;
    check (option string) "reasoning stays absent" None chunk.delta_reasoning
  | S.Openai_done | S.Openai_empty | S.Openai_provider_error _ | S.Openai_parse_failed _
    -> fail "expected stream chunk"
;;

let () =
  run
    "backend_glm_coverage"
    [ ( "classification"
      , [ test_case "error classification matrix" `Quick test_classification_matrix
        ; test_case
            "1261 envelope parses to context overflow (oas#2947)"
            `Quick
            test_check_glm_error_1261_envelope
        ; test_case "http status mapping" `Quick test_http_status_mapping
        ] )
    ; ( "request"
      , [ test_case
            "thinking modes and tool_stream"
            `Quick
            test_build_request_thinking_modes_and_tool_stream
        ] )
    ; ( "response"
      , [ test_case
            "reasoning content and usage"
            `Quick
            test_parse_response_extracts_reasoning_and_usage
        ; test_case "glm error classes" `Quick test_parse_response_classifies_glm_errors
        ; test_case
            "openai parse errors"
            `Quick
            test_parse_response_wraps_openai_parse_errors
        ; test_case
            "empty and malformed reasoning bodies"
            `Quick
            test_extract_reasoning_handles_empty_and_malformed_bodies
        ; test_case
            "stream uses resolved reasoning dialect"
            `Quick
            test_parse_stream_chunk_uses_resolved_reasoning_dialect
        ; test_case
            "stream does not invent a missing dialect"
            `Quick
            test_parse_stream_chunk_does_not_invent_missing_dialect
        ] )
    ]
;;
