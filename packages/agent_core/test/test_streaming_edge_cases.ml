open Alcotest
open Llm_provider.Types
module S = Llm_provider.Streaming

let usage ?(input_tokens = 1) ?(output_tokens = 2) () =
  { input_tokens
  ; output_tokens
  ; cache_creation_input_tokens = 0
  ; cache_read_input_tokens = 0
  ; cost_usd = None
  }
;;

let openai_chunk
      ?delta_content
      ?delta_reasoning
      ?delta_reasoning_details
      ?(delta_tool_calls = [])
      ?finish_reason
      ?chunk_usage
      ()
  : S.openai_chunk
  =
  { chunk_id = "chunk-1"
  ; chunk_model = "model-1"
  ; delta_content
  ; delta_reasoning
  ; delta_reasoning_details
  ; delta_tool_calls
  ; finish_reason
  ; chunk_usage
  }
;;

let ollama_chunk
      ?delta_content
      ?delta_thinking
      ?(tool_calls = [])
      ?done_reason
      ?usage
      ?timings
      ?(is_done = false)
      ()
  : S.ollama_chunk
  =
  { oll_model = "dashscope-3:8b"
  ; oll_delta_content = delta_content
  ; oll_delta_thinking = delta_thinking
  ; oll_tool_calls = tool_calls
  ; oll_done_reason = done_reason
  ; oll_is_done = is_done
  ; oll_usage = usage
  ; oll_timings = timings
  }
;;

let check_event_count label expected events =
  check int label expected (List.length events)
;;

let require_some label = function
  | Some x -> x
  | None -> fail (label ^ ": expected Some")
;;

let require_openai_chunk label = function
  | S.Openai_chunk chunk -> chunk
  | S.Openai_done -> fail (label ^ ": unexpected terminal sentinel")
  | S.Openai_empty -> fail (label ^ ": unexpected empty chunk")
  | S.Openai_provider_error _ -> fail (label ^ ": unexpected provider error")
  | S.Openai_parse_failed { reason; _ } ->
    fail (Printf.sprintf "%s: unexpected parse failure: %s" label reason)
;;

let require_ollama_chunk label = function
  | S.Ollama_chunk chunk -> chunk
  | S.Ollama_provider_error _ -> fail (label ^ ": unexpected provider error")
  | S.Ollama_parse_failed { reason; _ } ->
    fail (Printf.sprintf "%s: unexpected parse failure: %s" label reason)
;;

let parse_gemini_chunk data =
  match S.parse_gemini_sse_chunk data with
  | S.Gemini_chunk chunk -> Some chunk
  | S.Gemini_unsupported_part _ -> None
  | S.Gemini_unsupported_response _ -> None
  | S.Gemini_parse_failed _ -> None
;;

let require_gemini_events label state chunk =
  match S.gemini_chunk_to_events state chunk with
  | Ok events -> events
  | Error { reason } -> fail (Printf.sprintf "%s: %s" label reason)
;;

let test_anthropic_sse_parser_edges () =
  (match
     S.parse_sse_event
       (Some "message_start")
       {|{"message":{"id":"msg-1","model":"m","usage":null}}|}
   with
   | Some (MessageStart { usage = None; _ }) -> ()
   | _ -> fail "message_start without usage should parse");
  (match
     S.parse_sse_event
       (Some "content_block_delta")
       {|{"index":0,"delta":{"type":"future_delta","value":"ignored"}}|}
   with
   | Some (SSEParseFailed { reason; raw }) ->
     check
       string
       "unknown delta raw"
       {|{"index":0,"delta":{"type":"future_delta","value":"ignored"}}|}
       raw;
     check
       bool
       "unknown delta reason"
       true
       (String.starts_with
          ~prefix:"type_error: unsupported content_block_delta type: future_delta"
          reason)
   | _ -> fail "unknown delta type should fail closed");
  (match
     S.parse_sse_event
       (Some "message_delta")
       {|{"delta":{"stop_reason":null},"usage":null}|}
   with
   | Some (MessageDelta { stop_reason = None; usage = None }) -> ()
   | _ -> fail "message_delta without usage should parse");
  match S.parse_sse_event (Some "message_start") {|{"message":{"id":1}}|} with
  | Some (SSEParseFailed { reason; _ }) ->
    check bool "type error reason" true (String.starts_with ~prefix:"type_error:" reason)
  | _ -> fail "bad message_start shape should become SSEParseFailed"
;;

let test_first_token_classifier_edges () =
  check
    bool
    "thinking token"
    true
    (S.sse_event_is_first_token_signal
       (ContentBlockDelta { index = 0; delta = ThinkingDelta "plan" }));
  check
    bool
    "json token"
    true
    (S.sse_event_is_first_token_signal
       (ContentBlockDelta { index = 0; delta = InputJsonDelta "{}" }));
  check
    bool
    "empty thinking"
    false
    (S.sse_event_is_first_token_signal
       (ContentBlockDelta { index = 0; delta = ThinkingDelta "" }));
  List.iter
    (fun event ->
       check bool "non-token event" false (S.sse_event_is_first_token_signal event))
    [ ContentBlockStop { index = 0 }
    ; MessageDelta { stop_reason = None; usage = None }
    ; MessageStop
    ; SSEError { message = "boom"; error_type = None; raw = "boom" }
    ; NDJSONError { message = "boom"; error_type = None; raw = "boom" }
    ; SSEParseFailed { raw = "x"; reason = "bad" }
    ; SSEUnknownEventType { event_type = "future"; raw = "{}" }
    ]
;;

let test_deliverable_progress_classifier_edges () =
  check
    bool
    "text is deliverable"
    true
    (S.sse_event_is_deliverable_progress_signal
       (ContentBlockDelta { index = 0; delta = TextDelta "answer" }));
  check
    bool
    "tool args are deliverable"
    true
    (S.sse_event_is_deliverable_progress_signal
       (ContentBlockDelta { index = 0; delta = InputJsonDelta {|{"x":1}|} }));
  check
    bool
    "tool start is deliverable"
    true
    (S.sse_event_is_deliverable_progress_signal
       (ContentBlockStart
          { index = 0
          ; content_type = "tool_use"
          ; tool_id = Some "call_1"
          ; tool_name = Some "lookup"
          }));
  check
    bool
    "thinking is not deliverable"
    false
    (S.sse_event_is_deliverable_progress_signal
       (ContentBlockDelta { index = 0; delta = ThinkingDelta "private reasoning" }));
  check
    bool
    "empty text is not deliverable"
    false
    (S.sse_event_is_deliverable_progress_signal
       (ContentBlockDelta { index = 0; delta = TextDelta "" }))
;;

let test_synthetic_events_media_blocks () =
  let response : api_response =
    { id = "r1"
    ; model = "m1"
    ; stop_reason = EndTurn
    ; usage = Some (usage ())
    ; telemetry = None
    ; content =
        [ Image { media_type = "image/png"; data = "aW1n"; source_type = Base64 }
        ; Document { media_type = "application/pdf"; data = "ZG9j"; source_type = Base64 }
        ; Audio { media_type = "wav"; data = "YXVkaW8="; source_type = Base64 }
        ; RedactedThinking "hidden"
        ; ToolResult
            { tool_use_id = "call-1"
            ; content = "ok"
            ; outcome = Tool_succeeded
            ; json = None
            ; content_blocks = None
            }
        ]
    }
  in
  let events = ref [] in
  S.emit_synthetic_events response (fun event -> events := event :: !events);
  let events = List.rev !events in
  check_event_count "start + 5 block starts/stops + 3 media deltas + stop" 16 events;
  let starts =
    List.filter_map
      (function
        | ContentBlockStart { content_type; tool_id; _ } -> Some (content_type, tool_id)
        | _ -> None)
      events
  in
  (* Image/Document/Audio use typed media starts/deltas so synthetic streaming
     preserves non-text payloads; RedactedThinking keeps its opaque payload for
     tool-loop round-trips (#2061). *)
  check
    (list (pair string (option string)))
    "media-like synthetic starts"
    [ "image", None
    ; "document", None
    ; "audio", None
    ; "redacted_thinking", Some "hidden"
    ; "text", None
    ]
    starts
;;

let test_openai_parse_edge_shapes () =
  let mixed_tool_calls =
    {|{"id":"c","model":"m","choices":[{"delta":{"tool_calls":[{"index":"bad"},{"index":0,"function":{"arguments":"{}"}}]},"finish_reason":null}],"usage":{"prompt_tokens":4,"completion_tokens":5,"prompt_tokens_details":{"cached_tokens":3}}}|}
  in
  let mixed_result = S.parse_openai_sse_chunk mixed_tool_calls in
  (match mixed_result with
   | S.Openai_parse_failed { reason; raw } ->
     check
       string
       "mixed batch failure reason"
       "malformed_delta_tool_call:position:0:index_not_nonnegative_integer"
       reason;
     check string "mixed batch raw payload" mixed_tool_calls raw
   | S.Openai_chunk _ -> fail "malformed sibling must reject the complete batch"
   | S.Openai_done -> fail "mixed tool-call payload cannot be DONE"
   | S.Openai_empty -> fail "mixed tool-call payload cannot be empty"
   | S.Openai_provider_error _ -> fail "mixed tool-call payload is not a provider error");
  let state = S.create_openai_stream_state ~provider:"p" ~model:"m" () in
  let events, telemetry = S.openai_sse_parse_result_to_events state mixed_result in
  check bool "parse failure has no telemetry" true (Option.is_none telemetry);
  (match events with
   | [ SSEParseFailed { reason; raw } ] ->
     check
       string
       "projected batch failure reason"
       "malformed_delta_tool_call:position:0:index_not_nonnegative_integer"
       reason;
     check string "projected batch raw payload" mixed_tool_calls raw
   | _ -> fail "malformed batch must emit exactly one SSEParseFailed event");
  let valid_then_malformed =
    {|{"id":"c","model":"m","choices":[{"delta":{"tool_calls":[{"index":0,"id":"call-valid","type":"function","function":{"name":"lookup","arguments":"{}"}},{"index":"bad"}]},"finish_reason":null}]}|}
  in
  let valid_then_malformed_result = S.parse_openai_sse_chunk valid_then_malformed in
  (match valid_then_malformed_result with
   | S.Openai_parse_failed { reason; raw } ->
     check
       string
       "valid-first batch failure reason"
       "malformed_delta_tool_call:position:1:index_not_nonnegative_integer"
       reason;
     check string "valid-first batch raw payload" valid_then_malformed raw
   | S.Openai_chunk _ -> fail "valid prefix must not survive a malformed suffix"
   | S.Openai_done -> fail "valid-first mixed payload cannot be DONE"
   | S.Openai_empty -> fail "valid-first mixed payload cannot be empty"
   | S.Openai_provider_error _ -> fail "valid-first mixed payload is not a provider error");
  let valid_first_events, valid_first_telemetry =
    S.openai_sse_parse_result_to_events
      (S.create_openai_stream_state ~provider:"p" ~model:"m" ())
      valid_then_malformed_result
  in
  check
    bool
    "valid-first parse failure has no telemetry"
    true
    (Option.is_none valid_first_telemetry);
  (match valid_first_events with
   | [ SSEParseFailed { reason; raw } ] ->
     check
       string
       "valid-first projected failure reason"
       "malformed_delta_tool_call:position:1:index_not_nonnegative_integer"
       reason;
     check string "valid-first projected raw payload" valid_then_malformed raw
   | _ -> fail "valid prefix must not emit before a malformed suffix");
  let non_list_tool_calls =
    {|{"id":"c","model":"m","choices":[{"delta":{"tool_calls":{"unexpected":true}},"finish_reason":null}]}|}
  in
  match S.parse_openai_sse_chunk non_list_tool_calls with
  | S.Openai_parse_failed { reason; raw } ->
    check string "non-list batch failure" "malformed_delta_tool_calls:not_list" reason;
    check string "non-list batch raw payload" non_list_tool_calls raw
  | S.Openai_chunk _ -> fail "non-list tool_calls must not be ignored"
  | S.Openai_done -> fail "non-list tool_calls payload cannot be DONE"
  | S.Openai_empty -> fail "non-list tool_calls payload cannot be empty"
  | S.Openai_provider_error _ -> fail "non-list payload is not a provider error"
;;

let test_openai_object_arguments () =
  (* llama.cpp / llama-server (#20198) streams tool-call [arguments] as a
     JSON object rather than a serialized string. [to_string_option] returns
     None for an object, which silently dropped the args (ToolUse with empty
     input). The parser must serialize the object to a string instead. *)
  let object_args =
    {|{"id":"c","model":"m","choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"f","arguments":{"x":1}}}]},"finish_reason":null}]}|}
  in
  let chunk =
    require_openai_chunk "openai object args" (S.parse_openai_sse_chunk object_args)
  in
  match chunk.delta_tool_calls with
  | [ tc ] ->
    (match tc.tc_arguments with
     | Some (S.Args_complete s) ->
       check
         string
         "object arguments serialized as a complete value (not dropped to None)"
         {|{"x":1}|}
         s
     | Some (S.Args_fragment _) ->
       fail "object arguments must be tagged Args_complete, not a fragment"
     | None -> fail "object arguments dropped to None")
  | _ -> fail "expected exactly one tool call"
;;

let test_openai_malformed_tool_call_shapes_fail_closed () =
  let cases =
    [ ( "non-object member"
      , {|{"choices":[{"delta":{"tool_calls":[null]}}]}|}
      , "malformed_delta_tool_call:position:0:not_object" )
    ; ( "negative index"
      , {|{"choices":[{"delta":{"tool_calls":[{"index":-1}]}}]}|}
      , "malformed_delta_tool_call:position:0:index_not_nonnegative_integer" )
    ; ( "non-string id"
      , {|{"choices":[{"delta":{"tool_calls":[{"index":0,"id":42}]}}]}|}
      , "malformed_delta_tool_call:position:0:id_not_string" )
    ; ( "unsupported type"
      , {|{"choices":[{"delta":{"tool_calls":[{"index":0,"type":"custom"}]}}]}|}
      , "malformed_delta_tool_call:position:0:unsupported_type" )
    ; ( "non-string type"
      , {|{"choices":[{"delta":{"tool_calls":[{"index":0,"type":42}]}}]}|}
      , "malformed_delta_tool_call:position:0:type_not_string" )
    ; ( "non-object function"
      , {|{"choices":[{"delta":{"tool_calls":[{"index":0,"function":[]}]}}]}|}
      , "malformed_delta_tool_call:position:0:function_not_object" )
    ; ( "non-string name"
      , {|{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":42}}]}}]}|}
      , "malformed_delta_tool_call:position:0:name_not_string" )
    ; ( "scalar arguments"
      , {|{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":true}}]}}]}|}
      , "malformed_delta_tool_call:position:0:arguments_invalid_type" )
    ; ( "array arguments"
      , {|{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":[]}}]}}]}|}
      , "malformed_delta_tool_call:position:0:arguments_invalid_type" )
    ]
  in
  List.iter
    (fun (label, raw, expected_reason) ->
       let parsed = S.parse_openai_sse_chunk raw in
       (match parsed with
        | S.Openai_parse_failed { reason; raw = observed_raw } ->
          check string (label ^ " reason") expected_reason reason;
          check string (label ^ " raw") raw observed_raw
        | S.Openai_chunk _ -> fail (label ^ ": malformed call was accepted")
        | S.Openai_done -> fail (label ^ ": malformed call became DONE")
        | S.Openai_empty -> fail (label ^ ": malformed call became empty")
        | S.Openai_provider_error _ ->
          fail (label ^ ": malformed call became provider error"));
       let events, _telemetry =
         S.openai_sse_parse_result_to_events
           (S.create_openai_stream_state ~provider:"p" ~model:"m" ())
           parsed
       in
       match events with
       | [ SSEParseFailed { reason; raw = observed_raw } ] ->
         check string (label ^ " event reason") expected_reason reason;
         check string (label ^ " event raw") raw observed_raw
       | _ -> fail (label ^ ": expected exactly one SSEParseFailed event"))
    cases
;;

let test_openai_blank_id_and_name_accepted_as_none () =
  let raw =
    {|{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"","function":{"name":"","arguments":"\"argv\": "}}]}}]}|}
  in
  let parsed = S.parse_openai_sse_chunk raw in
  match parsed with
  | S.Openai_chunk { delta_tool_calls = [ call ]; _ } ->
    check int "index" 0 call.tc_index;
    (match call.tc_id with
     | None -> ()
     | Some _ -> fail "expected tc_id to be None for blank string");
    (match call.tc_name with
     | None -> ()
     | Some _ -> fail "expected tc_name to be None for blank string")
  | _ -> fail "expected valid Openai_chunk with tool call"
;;

let test_openai_tool_route_conflict_is_transactional () =
  let tc tc_index tc_id tc_name tc_arguments : S.openai_tool_call_delta =
    { tc_index; tc_id = Some tc_id; tc_name = Some tc_name; tc_arguments }
  in
  let state = S.create_openai_stream_state () in
  let conflicting_chunk =
    openai_chunk
      ~delta_reasoning:"plan"
      ~delta_content:"answer"
      ~delta_tool_calls:
        [ tc 0 "call-a" "first" (Some (S.Args_complete {|{"a":1}|}))
        ; tc 1 "call-b" "second" (Some (S.Args_complete {|{"b":2}|}))
        ; tc 1 "call-a" "first" None
        ]
      ()
  in
  let events, telemetry = S.openai_chunk_to_events state conflicting_chunk in
  check bool "route conflict has no telemetry" true (Option.is_none telemetry);
  (match events with
   | [ SSEParseFailed { raw; reason } ] ->
     check string "route conflict raw" "openai tool_call index 1" raw;
     check
       string
       "route conflict reason"
       "provider_tool_call_id_route_conflict: one provider identity used multiple wire \
        routes"
       reason
   | _ -> fail "valid siblings must not emit before a later route conflict");
  let retry_events, _ =
    S.openai_chunk_to_events
      state
      (openai_chunk
         ~delta_reasoning:"plan"
         ~delta_content:"answer"
         ~delta_tool_calls:[ tc 0 "call-a" "first" (Some (S.Args_complete {|{"a":1}|})) ]
         ())
  in
  (match retry_events with
   | [ ContentBlockStart { index = 0; content_type = "thinking"; _ }
     ; ContentBlockDelta { index = 0; delta = ThinkingDelta "plan" }
     ; ContentBlockStart { index = 1; content_type = "text"; _ }
     ; ContentBlockDelta { index = 1; delta = TextDelta "answer" }
     ; ContentBlockStart { index = 2; content_type = "tool_use"; _ }
     ; ContentBlockDelta { index = 2; delta = InputJsonSnapshot {|{"a":1}|} }
     ] -> ()
   | _ -> fail "route-conflict rollback must leave the stream state unchanged");
  let shared_index_state = S.create_openai_stream_state () in
  let shared_index_conflict, _ =
    S.openai_chunk_to_events
      shared_index_state
      (openai_chunk
         ~delta_tool_calls:
           [ tc 0 "call-a" "first" (Some (S.Args_complete {|{"a":1}|}))
           ; tc 0 "call-b" "second" (Some (S.Args_complete {|{"b":2}|}))
           ; { S.tc_index = 0; tc_id = None; tc_name = None; tc_arguments = None }
           ]
         ())
  in
  (match shared_index_conflict with
   | [ SSEParseFailed { reason; _ } ] ->
     check
       string
       "same-key route conflict reason"
       "ambiguous_tool_call_index: id-less continuation follows multiple tool identities"
       reason
   | _ -> fail "same-key route conflict must discard every earlier sibling");
  let shared_index_retry, _ =
    S.openai_chunk_to_events
      shared_index_state
      (openai_chunk
         ~delta_tool_calls:[ tc 0 "call-a" "first" (Some (S.Args_complete {|{"a":1}|})) ]
         ())
  in
  match shared_index_retry with
  | [ ContentBlockStart { index = 0; content_type = "tool_use"; _ }
    ; ContentBlockDelta { index = 0; delta = InputJsonSnapshot {|{"a":1}|} }
    ] -> ()
  | _ -> fail "same-key journal rollback must restore the missing route"
;;

let test_openai_event_edge_branches () =
  let state = S.create_openai_stream_state ~provider:"p" ~model:"m" () in
  ignore (S.openai_chunk_to_events state (openai_chunk ~delta_reasoning:"thinking" ()));
  let empty_reasoning_events, telemetry =
    S.openai_chunk_to_events state (openai_chunk ~delta_reasoning:"" ())
  in
  check_event_count "empty reasoning emits no content event" 0 empty_reasoning_events;
  (match telemetry with
   | Some (Llm_provider.Telemetry_event.Thinking_complete r) ->
     check string "provider" "p" r.provider;
     check string "model" "m" r.model
   | _ -> fail "expected thinking completion telemetry");
  let repeat_reasoning_events, _ =
    S.openai_chunk_to_events state (openai_chunk ~delta_reasoning:"again" ())
  in
  check_event_count
    "repeat reasoning after done emits delta only"
    1
    repeat_reasoning_events;
  let tool_state = S.create_openai_stream_state () in
  let tc_empty =
    { S.tc_index = 0
    ; tc_id = Some "call-1"
    ; tc_name = Some "search"
    ; tc_arguments = Some (S.Args_fragment "")
    }
  in
  let tc_none = { S.tc_index = 0; tc_id = None; tc_name = None; tc_arguments = None } in
  let first_tool_events, _ =
    S.openai_chunk_to_events tool_state (openai_chunk ~delta_tool_calls:[ tc_empty ] ())
  in
  check_event_count "empty-args tool starts block only" 1 first_tool_events;
  let reused_tool_events, _ =
    S.openai_chunk_to_events tool_state (openai_chunk ~delta_tool_calls:[ tc_none ] ())
  in
  check_event_count "same tool index without args emits nothing" 0 reused_tool_events;
  let finish_state = S.create_openai_stream_state () in
  let refusal_finish_events, _ =
    S.openai_chunk_to_events
      finish_state
      (openai_chunk ~finish_reason:"refusal" ~chunk_usage:(usage ()) ())
  in
  match refusal_finish_events with
  | [ MessageDelta { stop_reason = Some Refusal; usage = Some _ } ] -> ()
  | _ -> fail "expected refusal finish reason to map to Refusal"
;;

let test_gemini_parse_edge_shapes () =
  (match
     S.parse_gemini_sse_chunk
       {|{"candidates":[{"content":{"parts":[{"text":"no model"}]}}]}|}
   with
   | S.Gemini_chunk chunk ->
     check (option string) "absent modelVersion" None chunk.gem_model
   | S.Gemini_parse_failed { reason; _ } ->
     failf "absent optional modelVersion was rejected: %s" reason
   | S.Gemini_unsupported_part _ -> fail "absent modelVersion is not a Part kind"
   | S.Gemini_unsupported_response _ -> fail "absent modelVersion is not a response kind");
  (match
     S.parse_gemini_sse_chunk
       {|{"modelVersion":"","candidates":[{"content":{"parts":[{"text":"empty model"}]}}]}|}
   with
   | S.Gemini_chunk chunk ->
     check (option string) "empty modelVersion remains distinct" (Some "") chunk.gem_model
   | S.Gemini_parse_failed { reason; _ } ->
     failf "empty modelVersion was rejected instead of preserved: %s" reason
   | S.Gemini_unsupported_part _ -> fail "empty modelVersion is not a Part kind"
   | S.Gemini_unsupported_response _ -> fail "empty modelVersion is not a response kind");
  (match
     S.parse_gemini_sse_chunk
       {|{"modelVersion":"gemini-wire-model","candidates":[{"content":{"parts":[{"text":"done"}]},"finishReason":"STOP"}]}|}
   with
   | S.Gemini_chunk chunk ->
     let events, _ =
       require_gemini_events
         "response model propagation"
         (S.create_openai_stream_state ~model:"requested-model" ())
         chunk
     in
     let acc = Llm_provider.Complete_stream_acc.create_stream_acc () in
     List.iter (Llm_provider.Complete_stream_acc.accumulate_event acc) events;
     (match Llm_provider.Complete_stream_acc.finalize_stream_acc acc with
      | Ok response ->
        check
          string
          "wire model reaches final response"
          "gemini-wire-model"
          response.model
      | Error _ -> fail "terminal Gemini chunk did not finalize")
   | S.Gemini_parse_failed { reason; _ } ->
     failf "model propagation fixture was rejected: %s" reason
   | S.Gemini_unsupported_part _ -> fail "model propagation has no unsupported Part"
   | S.Gemini_unsupported_response _ ->
     fail "model propagation has no unsupported response");
  (match
     S.parse_gemini_sse_chunk
       {|{"candidates":[{"content":{"parts":[{"text":"partial"}]},"finishReason":""}]}|}
   with
   | S.Gemini_chunk chunk ->
     (match chunk.gem_finish_reason with
      | None -> ()
      | Some _ -> fail "empty finishReason became a terminal reason")
   | S.Gemini_parse_failed { reason; _ } ->
     failf "empty finishReason was rejected: %s" reason
   | S.Gemini_unsupported_part _ -> fail "empty finishReason is not a Part kind"
   | S.Gemini_unsupported_response _ -> fail "empty finishReason is not a response kind");
  (match
     parse_gemini_chunk {|{"modelVersion":"gem","candidates":[],"usageMetadata":null}|}
   with
   | None -> ()
   | Some _ -> fail "empty candidates should be rejected by missing content");
  (match
     parse_gemini_chunk
       {|{"modelVersion":"gem","candidates":{"unexpected":true},"usageMetadata":null}|}
   with
   | None -> ()
   | Some _ -> fail "non-list candidates should be rejected by missing content");
  (match
     S.parse_gemini_sse_chunk
       {|{"candidates":[{"content":{"parts":[{"text":"a"}]}},{"content":{"parts":[{"text":"b"}]}}]}|}
   with
   | S.Gemini_unsupported_response { response; raw } ->
     (match response with
      | S.Gemini_multiple_candidates { count } ->
        check int "multiple candidates count" 2 count;
        check
          string
          "multiple candidates wire field"
          "candidates"
          (S.gemini_unsupported_response_wire_name response);
        check bool "multiple candidates raw preserved" true (String.length raw > 0))
   | S.Gemini_chunk _ -> fail "multiple Gemini candidates must not be dropped"
   | S.Gemini_unsupported_part _ -> fail "multiple candidates are not a Part kind"
   | S.Gemini_parse_failed { reason; _ } ->
     failf "multiple candidates were collapsed into malformed: %s" reason);
  (match
     S.parse_gemini_sse_chunk
       {|{"modelVersion":"gem","candidates":[{"content":{"parts":{"bad":true}}}],"usageMetadata":null}|}
   with
   | S.Gemini_parse_failed { reason; _ } ->
     check
       string
       "non-list parts reason"
       "gemini.candidates[0].content.parts:not_array(got object)"
       reason
   | S.Gemini_chunk _ -> fail "non-list parts must be rejected"
   | S.Gemini_unsupported_part _ -> fail "non-list parts are not a Part kind"
   | S.Gemini_unsupported_response _ -> fail "non-list parts are not a response kind");
  match S.parse_gemini_sse_chunk "{not-json" with
  | S.Gemini_parse_failed { raw; reason } ->
    check string "invalid gemini raw" "{not-json" raw;
    check bool "invalid gemini reason" true (String.length reason > 0)
  | S.Gemini_chunk _ -> fail "invalid gemini json should be rejected"
  | S.Gemini_unsupported_part _ -> fail "invalid JSON is not a Part kind"
  | S.Gemini_unsupported_response _ -> fail "invalid JSON is not a response kind"
;;

let check_gemini_refusal label expected_reason payload =
  match S.parse_gemini_sse_chunk payload with
  | S.Gemini_chunk chunk ->
    check
      bool
      (label ^ ": terminal reason preserved")
      true
      (chunk.gem_finish_reason = expected_reason);
    let events, _ = require_gemini_events label (S.create_openai_stream_state ()) chunk in
    (match events with
     | [ MessageStart { model = "gem"; _ }
       ; MessageDelta { stop_reason = Some Refusal; _ }
       ] -> ()
     | _ -> failf "%s: expected a typed refusal" label)
  | S.Gemini_parse_failed { reason; _ } ->
    failf "%s: valid policy block was rejected: %s" label reason
  | S.Gemini_unsupported_part _ ->
    failf "%s: policy block is not an unsupported Part" label
  | S.Gemini_unsupported_response _ ->
    failf "%s: policy block is not an unsupported response" label
;;

let test_gemini_policy_blocks_are_not_wire_failures () =
  check_gemini_refusal
    "prompt policy block"
    (Some (S.Gemini_prompt_block_reason "OTHER"))
    {|{"modelVersion":"gem","promptFeedback":{"blockReason":"OTHER"},"candidates":[]}|};
  check_gemini_refusal
    "safety prompt policy block"
    (Some (S.Gemini_prompt_block_reason "SAFETY"))
    {|{"modelVersion":"gem","promptFeedback":{"blockReason":"SAFETY"},"candidates":[]}|};
  check_gemini_refusal
    "omitted empty candidates policy block"
    (Some (S.Gemini_prompt_block_reason "SAFETY"))
    {|{"modelVersion":"gem","promptFeedback":{"blockReason":"SAFETY"}}|};
  check_gemini_refusal
    "candidate policy block"
    (Some (S.Gemini_candidate_finish_reason "PROHIBITED_CONTENT"))
    {|{"modelVersion":"gem","candidates":[{"finishReason":"PROHIBITED_CONTENT"}]}|}
;;

let test_gemini_supported_metadata_and_function_call_shapes () =
  (match
     S.parse_gemini_sse_chunk
       {|{"candidates":[{"content":{"parts":[{"text":"ok","partMetadata":{},"mediaResolution":{},"videoMetadata":{}}]}}]}|}
   with
   | S.Gemini_chunk _ -> ()
   | S.Gemini_parse_failed { reason; _ } ->
     failf "official Part metadata was rejected: %s" reason
   | S.Gemini_unsupported_part _ -> fail "Part metadata is not a payload kind"
   | S.Gemini_unsupported_response _ -> fail "Part metadata is not a response kind");
  (match
     S.parse_gemini_sse_chunk
       {|{"candidates":[{"content":{"parts":[{"functionCall":{"name":"lookup"}}]}}]}|}
   with
   | S.Gemini_chunk chunk ->
     let events, _ =
       require_gemini_events
         "argument-free function call"
         (S.create_openai_stream_state ())
         chunk
     in
     check
       bool
       "missing args becomes the empty object"
       true
       (List.exists
          (function
            | ContentBlockDelta { delta = InputJsonSnapshot "{}"; _ } -> true
            | _ -> false)
          events)
   | S.Gemini_parse_failed { reason; _ } ->
     failf "optional functionCall.args was rejected: %s" reason
   | S.Gemini_unsupported_part _ -> fail "argument-free function call is supported"
   | S.Gemini_unsupported_response _ ->
     fail "argument-free function call is not a response");
  (match
     S.parse_gemini_sse_chunk
       {|{"candidates":[{"content":{"parts":[{"functionCall":{"name":"lookup","args":{},"willContinue":false}}]}}]}|}
   with
   | S.Gemini_chunk _ -> ()
   | S.Gemini_parse_failed { reason; _ } ->
     failf "terminal willContinue=false was rejected: %s" reason
   | S.Gemini_unsupported_part _ ->
     fail "terminal willContinue=false is not incremental arguments"
   | S.Gemini_unsupported_response _ ->
     fail "terminal willContinue=false is not a response kind");
  (match
     S.parse_gemini_sse_chunk
       {|{"candidates":[{"content":{"parts":[{"functionCall":{"name":"lookup","willContinue":true}}]}}]}|}
   with
   | S.Gemini_unsupported_part { part; _ } ->
     check
       string
       "streaming continuation remains explicit"
       "functionCall.willContinue"
       (S.gemini_unsupported_part_wire_name part)
   | S.Gemini_chunk _ -> fail "streaming continuation must not be dropped"
   | S.Gemini_parse_failed { reason; _ } ->
     failf "official streaming continuation was called malformed: %s" reason
   | S.Gemini_unsupported_response _ ->
     fail "streaming continuation is not a response kind");
  match
    S.parse_gemini_sse_chunk
      {|{"candidates":[{"content":{"parts":[{"functionCall":{"name":"lookup","partialArgs":[],"willContinue":true}}]}}]}|}
  with
  | S.Gemini_unsupported_part { part; _ } ->
    check
      string
      "streaming function args remain explicit"
      "functionCall.partialArgs"
      (S.gemini_unsupported_part_wire_name part)
  | S.Gemini_chunk _ -> fail "streaming function args must not be dropped"
  | S.Gemini_parse_failed { reason; _ } ->
    failf "official streaming function args were called malformed: %s" reason
  | S.Gemini_unsupported_response _ ->
    fail "streaming function args are not a response kind"
;;

let test_gemini_part_shape_failure_is_explicit () =
  match
    S.parse_gemini_sse_chunk
      {|{"candidates":[{"content":{"parts":[{"unknownPart":{}}]}}]}|}
  with
  | S.Gemini_parse_failed { raw; reason } ->
    check bool "unknown part raw preserved" true (String.length raw > 0);
    check
      string
      "unknown part reason"
      "gemini.candidates[0].content.parts[0].unknownPart:unsupported_field"
      reason
  | S.Gemini_chunk _ -> fail "unknown Gemini part must not be accepted"
  | S.Gemini_unsupported_part _ ->
    fail "unknown fields must remain malformed, not official unsupported Parts"
  | S.Gemini_unsupported_response _ -> fail "unknown fields are not a response kind"
;;

let test_gemini_official_unsupported_part_is_not_malformed () =
  let raw =
    {|{"candidates":[{"content":{"parts":[{"executableCode":{"language":"PYTHON","code":"print(1)"}}]}}]}|}
  in
  (match S.parse_gemini_sse_chunk raw with
   | S.Gemini_unsupported_part { part; raw = observed_raw } ->
     check
       string
       "typed unsupported Part"
       "executableCode"
       (S.gemini_unsupported_part_wire_name part);
     check string "unsupported Part raw preserved" raw observed_raw
   | S.Gemini_parse_failed _ -> fail "official unsupported Part must not be malformed"
   | S.Gemini_chunk _ -> fail "unsupported Part must not be silently accepted"
   | S.Gemini_unsupported_response _ -> fail "unsupported Part is not a response kind");
  match
    S.parse_gemini_sse_chunk
      {|{"candidates":[{"content":{"parts":[{"functionResponse":{"name":"lookup","response":{}}}]}}]}|}
  with
  | S.Gemini_unsupported_part { part; _ } ->
    check
      string
      "typed function response Part"
      "functionResponse"
      (S.gemini_unsupported_part_wire_name part)
  | S.Gemini_parse_failed _ -> fail "official functionResponse must not be malformed"
  | S.Gemini_chunk _ -> fail "unsupported functionResponse must not be dropped"
  | S.Gemini_unsupported_response _ -> fail "functionResponse is not a response kind"
;;

let test_gemini_unsupported_part_shape_is_explicit () =
  let result_raw =
    {|{"candidates":[{"content":{"parts":[{"codeExecutionResult":{"outcome":"OUTCOME_OK","output":"1"}}]}}]}|}
  in
  (match S.parse_gemini_sse_chunk result_raw with
   | S.Gemini_unsupported_part { part; raw } ->
     check
       string
       "typed code execution result Part"
       "codeExecutionResult"
       (S.gemini_unsupported_part_wire_name part);
     check string "code execution result raw preserved" result_raw raw
   | S.Gemini_parse_failed _ -> fail "official code execution result must be typed"
   | S.Gemini_chunk _ -> fail "unsupported Part must not be silently accepted"
   | S.Gemini_unsupported_response _ -> fail "unsupported Part is not a response kind");
  match
    S.parse_gemini_sse_chunk
      {|{"candidates":[{"content":{"parts":[{"executableCode":{"language":"PYTHON"}}]}}]}|}
  with
  | S.Gemini_parse_failed { reason; _ } ->
    check
      string
      "malformed executable code reason"
      "gemini.candidates[0].content.parts[0].executableCode.code:missing"
      reason
  | S.Gemini_unsupported_part _ -> fail "malformed executableCode must remain malformed"
  | S.Gemini_chunk _ -> fail "malformed executableCode must not be accepted"
  | S.Gemini_unsupported_response _ ->
    fail "malformed executableCode is not a response kind"
;;

let test_gemini_builtin_tool_parts_are_typed () =
  let tool_call_raw =
    {|{"candidates":[{"content":{"parts":[{"thoughtSignature":"sig","toolCall":{"toolType":"GOOGLE_SEARCH_WEB","args":{"queries":["seoul"]},"id":"call-1"}}]}}]}|}
  in
  (match S.parse_gemini_sse_chunk tool_call_raw with
   | S.Gemini_unsupported_part { part; raw } ->
     check string "typed toolCall" "toolCall" (S.gemini_unsupported_part_wire_name part);
     check string "toolCall raw preserved" tool_call_raw raw
   | S.Gemini_parse_failed _ -> fail "official toolCall must be typed"
   | S.Gemini_chunk _ -> fail "unsupported toolCall must not be silently accepted"
   | S.Gemini_unsupported_response _ -> fail "toolCall is not a response kind");
  let tool_response_raw =
    {|{"candidates":[{"content":{"parts":[{"thoughtSignature":"sig","toolResponse":{"toolType":"GOOGLE_SEARCH_WEB","response":{"search_suggestions":"x"},"id":"call-1"}}]}}]}|}
  in
  (match S.parse_gemini_sse_chunk tool_response_raw with
   | S.Gemini_unsupported_part { part; raw } ->
     check
       string
       "typed toolResponse"
       "toolResponse"
       (S.gemini_unsupported_part_wire_name part);
     check string "toolResponse raw preserved" tool_response_raw raw
   | S.Gemini_parse_failed _ -> fail "official toolResponse must be typed"
   | S.Gemini_chunk _ -> fail "unsupported toolResponse must not be silently accepted"
   | S.Gemini_unsupported_response _ -> fail "toolResponse is not a response kind");
  match
    S.parse_gemini_sse_chunk
      {|{"candidates":[{"content":{"parts":[{"toolCall":{"toolType":"GOOGLE_SEARCH_WEB"}}]}}]}|}
  with
  | S.Gemini_parse_failed { reason; _ } ->
    check
      string
      "malformed toolCall reason"
      "gemini.candidates[0].content.parts[0].toolCall.id:missing"
      reason
  | S.Gemini_unsupported_part _ -> fail "malformed toolCall must remain malformed"
  | S.Gemini_chunk _ -> fail "malformed toolCall must not be accepted"
  | S.Gemini_unsupported_response _ -> fail "malformed toolCall is not a response kind"
;;

let test_gemini_malformed_part_precedes_unsupported_part () =
  match
    S.parse_gemini_sse_chunk
      {|{"candidates":[{"content":{"parts":[{"executableCode":{"language":"PYTHON","code":"print(1)"}},{"unknownPart":{}}]}}]}|}
  with
  | S.Gemini_parse_failed { reason; _ } ->
    check
      string
      "malformed sibling reason"
      "gemini.candidates[0].content.parts[1].unknownPart:unsupported_field"
      reason
  | S.Gemini_unsupported_part _ ->
    fail "malformed sibling must not be hidden by unsupported Part"
  | S.Gemini_chunk _ -> fail "malformed sibling must not be accepted"
  | S.Gemini_unsupported_response _ -> fail "malformed sibling is not a response kind"
;;

let gemini_chunk ?(parts = []) ?finish_reason ?usage () : S.gemini_chunk =
  { gem_model = Some "gemini-test"
  ; gem_parts = parts
  ; gem_finish_reason =
      Option.map (fun reason -> S.Gemini_candidate_finish_reason reason) finish_reason
  ; gem_usage = usage
  }
;;

let test_gemini_model_identity_is_single_and_fail_closed () =
  let state = S.create_openai_stream_state ~provider:"gemini" ~model:"gem" () in
  let text_part text = `Assoc [ "text", `String text ] in
  let first_events, _ =
    require_gemini_events
      "first model observation"
      state
      (gemini_chunk ~parts:[ text_part "first" ] ())
  in
  check
    bool
    "first model observation emits MessageStart"
    true
    (List.exists
       (function
         | MessageStart _ -> true
         | _ -> false)
       first_events);
  let repeated_events, _ =
    require_gemini_events
      "repeated model observation"
      state
      (gemini_chunk ~parts:[ text_part "second" ] ())
  in
  check
    bool
    "repeated identical model does not emit MessageStart"
    false
    (List.exists
       (function
         | MessageStart _ -> true
         | _ -> false)
       repeated_events);
  let changed_chunk =
    { (gemini_chunk ~parts:[ text_part "changed" ] ()) with
      gem_model = Some "different-gemini-model"
    }
  in
  match S.gemini_chunk_to_events state changed_chunk with
  | Error { reason } ->
    check
      string
      "changed model is an explicit stream failure"
      "gemini_sse_chunk_decode_failure: gemini.modelVersion changed within one streamed \
       response"
      reason
  | Ok _ -> fail "changed modelVersion must not be silently accepted"
;;

let test_gemini_event_edge_branches () =
  let state = S.create_openai_stream_state ~provider:"gemini" ~model:"gem" () in
  let thought_part = `Assoc [ "thought", `Bool true; "text", `String "plan" ] in
  ignore
    (require_gemini_events
       "thought chunk"
       state
       (gemini_chunk ~parts:[ thought_part ] ()));
  let no_thought_events, telemetry =
    require_gemini_events
      "empty text chunk"
      state
      (gemini_chunk ~parts:[ `Assoc [ "text", `String "" ] ] ())
  in
  check_event_count "no-thought chunk emits no events" 0 no_thought_events;
  (match telemetry with
   | Some (Llm_provider.Telemetry_event.Thinking_complete r) ->
     check string "provider" "gemini" r.provider
   | _ -> fail "expected gemini thinking completion telemetry");
  let restarted_events, _ =
    require_gemini_events
      "restarted thought chunk"
      state
      (gemini_chunk ~parts:[ thought_part ] ())
  in
  check_event_count "thinking after done restarts and emits delta" 1 restarted_events;
  let function_call_part =
    `Assoc
      [ ( "functionCall"
        , `Assoc [ "name", `String "lookup"; "args", `Assoc [ "q", `String "seoul" ] ] )
      ]
  in
  let tool_events, _ =
    require_gemini_events
      "function call"
      (S.create_openai_stream_state ())
      (gemini_chunk ~parts:[ function_call_part ] ())
  in
  check_event_count "function call emits message, tool start, and arguments" 3 tool_events;
  let empty_text_without_call = `Assoc [ "functionCall", `String "not-an-object" ] in
  (match
     S.gemini_chunk_to_events
       (S.create_openai_stream_state ())
       (gemini_chunk ~parts:[ empty_text_without_call ] ())
   with
   | Error { reason } ->
     check bool "non-object functionCall rejected" true (String.length reason > 0)
   | Ok _ -> fail "non-object functionCall must not be ignored");
  let max_tokens_events, _ =
    require_gemini_events
      "max tokens chunk"
      (S.create_openai_stream_state ())
      (gemini_chunk ~finish_reason:"MAX_TOKENS" ~usage:(usage ()) ())
  in
  (match max_tokens_events with
   | [ MessageStart { model = "gemini-test"; _ }
     ; MessageDelta { stop_reason = Some MaxTokens; usage = Some _ }
     ] -> ()
   | _ -> fail "expected gemini max-tokens finish");
  let unknown_events, _ =
    require_gemini_events
      "safety finish chunk"
      (S.create_openai_stream_state ())
      (gemini_chunk ~finish_reason:"SAFETY" ())
  in
  match unknown_events with
  | [ MessageStart { model = "gemini-test"; _ }
    ; MessageDelta { stop_reason = Some Refusal; _ }
    ] -> ()
  | _ -> fail "expected gemini unknown finish"
;;

let test_ollama_parse_edge_shapes () =
  let non_object_message =
    require_ollama_chunk
      "non-object message"
      (S.parse_ollama_ndjson_chunk {|{"model":"m","message":"text","done":false}|})
  in
  check (option string) "no content" None non_object_message.oll_delta_content;
  check int "no tool calls" 0 (List.length non_object_message.oll_tool_calls);
  let args_variants =
    require_ollama_chunk
      "tool argument variants"
      (S.parse_ollama_ndjson_chunk
         {|{"model":"m","message":{"content":"","thinking":"","tool_calls":[{"id":"a","function":{"name":"null_args","arguments":null}},{"function":{"name":"string_args","arguments":"{\"x\":1}"}},{"function":{"name":"bool_args","arguments":true}}]},"done":true,"prompt_eval_duration":1000000,"eval_duration":0}|})
  in
  check (option string) "empty content becomes None" None args_variants.oll_delta_content;
  check
    (option string)
    "empty thinking becomes None"
    None
    args_variants.oll_delta_thinking;
  check int "three tool calls" 3 (List.length args_variants.oll_tool_calls);
  (match args_variants.oll_tool_calls with
   | [ first; second; third ] ->
     (match first.oll_tc_arguments with
      | None -> ()
      | Some _ -> fail "expected None for null args");
     (match second.oll_tc_arguments with
      | Some (S.Args_fragment s) -> check string "string args" {|{"x":1}|} s
      | _ -> fail "expected Args_fragment for string args");
     (match third.oll_tc_arguments with
      | Some (S.Args_complete s) -> check string "bool args" "true" s
      | _ -> fail "expected Args_complete for bool args")
   | _ -> fail "unexpected tool calls");
  (match args_variants.oll_timings with
   | Some t ->
     check (option (float 0.001)) "prompt ms" (Some 1.0) t.prompt_ms;
     check (option (float 0.001)) "zero eval rate" None t.predicted_per_second
   | None -> fail "expected timings");
  (match S.parse_ollama_ndjson_chunk {|{"done":false}|} with
   | S.Ollama_parse_failed _ -> ()
   | S.Ollama_chunk _ | S.Ollama_provider_error _ -> fail "missing model must fail");
  (match S.parse_ollama_ndjson_chunk {|{"model":"m"}|} with
   | S.Ollama_parse_failed _ -> ()
   | S.Ollama_chunk _ | S.Ollama_provider_error _ -> fail "missing done must fail");
  (match S.parse_ollama_ndjson_chunk {|{"model":"   ","done":false}|} with
   | S.Ollama_parse_failed _ -> ()
   | S.Ollama_chunk _ | S.Ollama_provider_error _ -> fail "blank model must fail");
  (match S.parse_ollama_ndjson_chunk {|{"error":42,"model":"m","done":false}|} with
   | S.Ollama_parse_failed _ -> ()
   | S.Ollama_chunk _ | S.Ollama_provider_error _ -> fail "invalid error field must fail");
  match S.parse_ollama_ndjson_chunk {|{"model":1,"done":false}|} with
  | S.Ollama_parse_failed _ -> ()
  | S.Ollama_chunk _ | S.Ollama_provider_error _ -> fail "type error should fail"
;;

let test_ollama_event_edge_branches () =
  let state = S.create_openai_stream_state ~provider:"ollama" ~model:"m" () in
  ignore (S.ollama_chunk_to_events state (ollama_chunk ~delta_thinking:"first" ()));
  let repeated_thinking_events, _ =
    S.ollama_chunk_to_events state (ollama_chunk ~delta_thinking:"second" ())
  in
  check_event_count "repeated thinking emits delta only" 1 repeated_thinking_events;
  let empty_thinking_events, empty_tel =
    S.ollama_chunk_to_events state (ollama_chunk ~delta_thinking:"" ())
  in
  check_event_count "empty thinking emits no event" 0 empty_thinking_events;
  (match empty_tel with
   | Some (Llm_provider.Telemetry_event.Thinking_complete r) ->
     check string "provider" "ollama" r.provider
   | _ -> fail "expected empty-thinking telemetry");
  let none_state = S.create_openai_stream_state ~provider:"ollama" ~model:"m" () in
  ignore (S.ollama_chunk_to_events none_state (ollama_chunk ~delta_thinking:"start" ()));
  let none_thinking_events, none_tel =
    S.ollama_chunk_to_events none_state (ollama_chunk ())
  in
  check_event_count "missing thinking closes telemetry only" 0 none_thinking_events;
  (match none_tel with
   | Some (Llm_provider.Telemetry_event.Thinking_complete _) -> ()
   | _ -> fail "expected none-thinking telemetry");
  let text_empty_events, _ =
    S.ollama_chunk_to_events
      (S.create_openai_stream_state ())
      (ollama_chunk ~delta_content:"" ())
  in
  check_event_count "empty text ignored" 0 text_empty_events;
  let tool_state = S.create_openai_stream_state () in
  let tc_empty =
    { S.oll_tc_index = 0
    ; oll_tc_id = Some "call"
    ; oll_tc_name = Some "lookup"
    ; oll_tc_arguments = Some (S.Args_fragment "")
    }
  in
  let tc_none =
    { S.oll_tc_index = 0; oll_tc_id = None; oll_tc_name = None; oll_tc_arguments = None }
  in
  let tool_start_events, _ =
    S.ollama_chunk_to_events tool_state (ollama_chunk ~tool_calls:[ tc_empty ] ())
  in
  check_event_count "empty-args ollama tool starts only" 1 tool_start_events;
  let tool_reuse_events, _ =
    S.ollama_chunk_to_events tool_state (ollama_chunk ~tool_calls:[ tc_none ] ())
  in
  check_event_count "reused ollama tool without args emits nothing" 0 tool_reuse_events;
  let done_none_events, _ =
    S.ollama_chunk_to_events
      (S.create_openai_stream_state ())
      (ollama_chunk ~is_done:true ())
  in
  (match done_none_events with
   | [ MessageDelta { stop_reason = None; _ } ] -> ()
   | _ -> fail "done without reason should remain absent");
  let done_length_events, _ =
    S.ollama_chunk_to_events
      (S.create_openai_stream_state ())
      (ollama_chunk ~is_done:true ~done_reason:"length" ())
  in
  (match done_length_events with
   | [ MessageDelta { stop_reason = Some MaxTokens; _ } ] -> ()
   | _ -> fail "done length should be MaxTokens");
  let done_unknown_tool_events, _ =
    S.ollama_chunk_to_events
      (S.create_openai_stream_state ())
      (ollama_chunk ~is_done:true ~done_reason:"future" ~tool_calls:[ tc_none ] ())
  in
  (match done_unknown_tool_events with
   | [ ContentBlockStart _; MessageDelta { stop_reason = Some (Unknown "future"); _ } ] ->
     ()
   | _ -> fail "unknown done reason with tools should remain non-executable");
  let done_unknown_events, _ =
    S.ollama_chunk_to_events
      (S.create_openai_stream_state ())
      (ollama_chunk ~is_done:true ~done_reason:"content_filter" ())
  in
  match done_unknown_events with
  | [ MessageDelta { stop_reason = Some ContentFilter; _ } ] -> ()
  | _ -> fail "canonical content_filter reason should stay typed"
;;

let () =
  run
    "streaming_edge_cases"
    [ ( "anthropic_sse"
      , [ test_case "parser edge cases" `Quick test_anthropic_sse_parser_edges
        ; test_case
            "first-token classifier edges"
            `Quick
            test_first_token_classifier_edges
        ; test_case
            "deliverable progress classifier edges"
            `Quick
            test_deliverable_progress_classifier_edges
        ; test_case "synthetic media events" `Quick test_synthetic_events_media_blocks
        ] )
    ; ( "openai_sse"
      , [ test_case "parse edge shapes" `Quick test_openai_parse_edge_shapes
        ; test_case "object-form tool arguments" `Quick test_openai_object_arguments
        ; test_case
            "blank id and name accepted as none"
            `Quick
            test_openai_blank_id_and_name_accepted_as_none
        ; test_case
            "malformed tool-call shapes fail closed"
            `Quick
            test_openai_malformed_tool_call_shapes_fail_closed
        ; test_case
            "tool route conflict is transactional"
            `Quick
            test_openai_tool_route_conflict_is_transactional
        ; test_case "event edge branches" `Quick test_openai_event_edge_branches
        ] )
    ; ( "gemini_sse"
      , [ test_case "parse edge shapes" `Quick test_gemini_parse_edge_shapes
        ; test_case
            "policy blocks are typed refusals"
            `Quick
            test_gemini_policy_blocks_are_not_wire_failures
        ; test_case
            "supported metadata and function calls"
            `Quick
            test_gemini_supported_metadata_and_function_call_shapes
        ; test_case "part shape failure" `Quick test_gemini_part_shape_failure_is_explicit
        ; test_case
            "official unsupported Part is typed"
            `Quick
            test_gemini_official_unsupported_part_is_not_malformed
        ; test_case
            "unsupported Part shape is explicit"
            `Quick
            test_gemini_unsupported_part_shape_is_explicit
        ; test_case
            "built-in tool Parts are typed"
            `Quick
            test_gemini_builtin_tool_parts_are_typed
        ; test_case
            "malformed sibling is not hidden"
            `Quick
            test_gemini_malformed_part_precedes_unsupported_part
        ; test_case
            "model identity is single and fail-closed"
            `Quick
            test_gemini_model_identity_is_single_and_fail_closed
        ; test_case "event edge branches" `Quick test_gemini_event_edge_branches
        ] )
    ; ( "ollama_ndjson"
      , [ test_case "parse edge shapes" `Quick test_ollama_parse_edge_shapes
        ; test_case "event edge branches" `Quick test_ollama_event_edge_branches
        ] )
    ]
;;
