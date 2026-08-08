(** Unit tests for SSE streaming types and usage tracking. *)

open Agent_sdk.Types

(* Helper: create api_usage from input/output token counts *)
let make_usage inp out =
  { input_tokens = inp
  ; output_tokens = out
  ; cache_creation_input_tokens = 0
  ; cache_read_input_tokens = 0
  ; cost_usd = None
  }
;;

(* ------------------------------------------------------------------ *)
(* Usage tracking                                                       *)
(* ------------------------------------------------------------------ *)

let test_empty_usage () =
  Alcotest.(check int) "total_input_tokens is 0" 0 empty_usage.total_input_tokens;
  Alcotest.(check int) "total_output_tokens is 0" 0 empty_usage.total_output_tokens;
  Alcotest.(check int) "api_calls is 0" 0 empty_usage.api_calls
;;

let test_add_usage_basic () =
  let s = add_usage empty_usage (make_usage 100 50) in
  Alcotest.(check int) "input_tokens accumulated" 100 s.total_input_tokens;
  Alcotest.(check int) "output_tokens accumulated" 50 s.total_output_tokens;
  Alcotest.(check int) "api_calls incremented" 1 s.api_calls
;;

let test_add_usage_multiple () =
  let s0 = add_usage empty_usage (make_usage 100 50) in
  let s1 = add_usage s0 (make_usage 200 80) in
  Alcotest.(check int) "input_tokens summed" 300 s1.total_input_tokens;
  Alcotest.(check int) "output_tokens summed" 130 s1.total_output_tokens;
  Alcotest.(check int) "api_calls counted" 2 s1.api_calls
;;

let test_add_usage_zero_tokens () =
  let s = add_usage empty_usage (make_usage 0 0) in
  Alcotest.(check int) "zero input accepted" 0 s.total_input_tokens;
  Alcotest.(check int) "zero output accepted" 0 s.total_output_tokens;
  Alcotest.(check int) "api_calls still incremented" 1 s.api_calls
;;

let test_add_usage_immutable () =
  let s0 = add_usage empty_usage (make_usage 100 50) in
  let _s1 = add_usage s0 (make_usage 10 5) in
  (* s0 must not be mutated *)
  Alcotest.(check int) "original input_tokens unchanged" 100 s0.total_input_tokens;
  Alcotest.(check int) "original api_calls unchanged" 1 s0.api_calls
;;

(* ------------------------------------------------------------------ *)
(* SSE event type construction                                          *)
(* ------------------------------------------------------------------ *)

let test_sse_message_start () =
  let evt =
    MessageStart
      { id = "msg_abc"
      ; model = "claude-sonnet-4"
      ; usage =
          Some
            { input_tokens = 100
            ; output_tokens = 0
            ; cache_creation_input_tokens = 0
            ; cache_read_input_tokens = 0
            ; cost_usd = None
            }
      }
  in
  match evt with
  | MessageStart { id; model; usage = Some u } ->
    Alcotest.(check string) "id" "msg_abc" id;
    Alcotest.(check string) "model" "claude-sonnet-4" model;
    Alcotest.(check int) "input_tokens" 100 u.input_tokens
  | _ -> Alcotest.fail "expected MessageStart"
;;

let test_sse_content_block_delta_text () =
  let delta = TextDelta "hello" in
  let evt = ContentBlockDelta { index = 0; delta } in
  match evt with
  | ContentBlockDelta { index; delta = TextDelta s } ->
    Alcotest.(check int) "index" 0 index;
    Alcotest.(check string) "text" "hello" s
  | _ -> Alcotest.fail "expected ContentBlockDelta with TextDelta"
;;

let test_sse_message_stop () =
  match MessageStop with
  | MessageStop -> ()
  | _ -> Alcotest.fail "expected MessageStop"
;;

let test_sse_ping () =
  match Ping with
  | Ping -> ()
  | _ -> Alcotest.fail "expected Ping"
;;

let test_sse_error () =
  let evt = SSEError { message = "overloaded"; error_type = None; raw = "overloaded" } in
  match evt with
  | SSEError { message; _ } ->
    Alcotest.(check string) "error message" "overloaded" message
  | _ -> Alcotest.fail "expected SSEError"
;;

(* ------------------------------------------------------------------ *)
(* parse_sse_event                                                      *)
(* ------------------------------------------------------------------ *)

let test_parse_message_start () =
  let data =
    {|{"type":"message_start","message":{"id":"msg_01","model":"claude-3-7-sonnet-20250219","usage":{"input_tokens":42}}}|}
  in
  match Agent_sdk.Llm_provider.Streaming.parse_sse_event None data with
  | Some (MessageStart { id; model; usage }) ->
    Alcotest.(check string) "id" "msg_01" id;
    Alcotest.(check string) "model" "claude-3-7-sonnet-20250219" model;
    (match usage with
     | Some u -> Alcotest.(check int) "input_tokens" 42 u.input_tokens
     | None -> Alcotest.fail "expected Some usage")
  | Some _ -> Alcotest.fail "unexpected event type"
  | None -> Alcotest.fail "parse returned None"
;;

let test_parse_content_block_start () =
  let data =
    {|{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}|}
  in
  match Agent_sdk.Llm_provider.Streaming.parse_sse_event None data with
  | Some (ContentBlockStart { index; content_type; _ }) ->
    Alcotest.(check int) "index" 0 index;
    Alcotest.(check string) "content_type" "text" content_type
  | Some _ -> Alcotest.fail "unexpected event type"
  | None -> Alcotest.fail "parse returned None"
;;

let test_parse_content_block_delta_text () =
  let data =
    {|{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hello"}}|}
  in
  match Agent_sdk.Llm_provider.Streaming.parse_sse_event None data with
  | Some (ContentBlockDelta { index; delta = TextDelta s }) ->
    Alcotest.(check int) "index" 0 index;
    Alcotest.(check string) "text" "hello" s
  | Some _ -> Alcotest.fail "unexpected event type"
  | None -> Alcotest.fail "parse returned None"
;;

let test_parse_content_block_delta_thinking () =
  let data =
    {|{"type":"content_block_delta","index":1,"delta":{"type":"thinking_delta","thinking":"I think..."}}|}
  in
  match Agent_sdk.Llm_provider.Streaming.parse_sse_event None data with
  | Some (ContentBlockDelta { index = 1; delta = ThinkingDelta s }) ->
    Alcotest.(check string) "thinking" "I think..." s
  | Some _ -> Alcotest.fail "unexpected event type"
  | None -> Alcotest.fail "parse returned None"
;;

let test_parse_content_block_delta_signature () =
  let data =
    {|{"type":"content_block_delta","index":1,"delta":{"type":"signature_delta","signature":"sig_opaque"}}|}
  in
  match Agent_sdk.Llm_provider.Streaming.parse_sse_event None data with
  | Some (ContentBlockDelta { index = 1; delta = ThinkingSignatureDelta s }) ->
    Alcotest.(check string) "signature" "sig_opaque" s
  | Some _ -> Alcotest.fail "unexpected event type"
  | None -> Alcotest.fail "parse returned None"
;;

let test_parse_redacted_thinking_block_start () =
  let data =
    {|{"type":"content_block_start","index":0,"content_block":{"type":"redacted_thinking","data":"opaque_data"}}|}
  in
  match Agent_sdk.Llm_provider.Streaming.parse_sse_event None data with
  | Some (ContentBlockStart { index = 0; content_type; tool_id = Some data; _ }) ->
    Alcotest.(check string) "content_type" "redacted_thinking" content_type;
    Alcotest.(check string) "data carrier" "opaque_data" data
  | Some _ -> Alcotest.fail "unexpected event type"
  | None -> Alcotest.fail "parse returned None"
;;

let test_parse_content_block_delta_input_json () =
  let data =
    {|{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"k\":"}}|}
  in
  match Agent_sdk.Llm_provider.Streaming.parse_sse_event None data with
  | Some (ContentBlockDelta { index = 2; delta = InputJsonDelta s }) ->
    Alcotest.(check string) "partial_json" {|{"k":|} s
  | Some _ -> Alcotest.fail "unexpected event type"
  | None -> Alcotest.fail "parse returned None"
;;

let test_parse_content_block_delta_unknown_fails_closed () =
  let data =
    {|{"type":"content_block_delta","index":2,"delta":{"type":"future_delta","value":"do not drop"}}|}
  in
  match Agent_sdk.Llm_provider.Streaming.parse_sse_event None data with
  | Some (SSEParseFailed { raw; reason }) ->
    Alcotest.(check string) "raw preserved" data raw;
    Alcotest.(check bool)
      "reason names unsupported delta"
      true
      (String.starts_with
         ~prefix:"type_error: unsupported content_block_delta type: future_delta"
         reason)
  | Some _ -> Alcotest.fail "expected SSEParseFailed for unknown delta subtype"
  | None -> Alcotest.fail "parse returned None"
;;

let test_parse_content_block_stop () =
  let data = {|{"type":"content_block_stop","index":0}|} in
  match Agent_sdk.Llm_provider.Streaming.parse_sse_event None data with
  | Some (ContentBlockStop { index }) -> Alcotest.(check int) "index" 0 index
  | Some _ -> Alcotest.fail "unexpected event type"
  | None -> Alcotest.fail "parse returned None"
;;

let test_parse_message_delta_end_turn () =
  let data =
    {|{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":57}}|}
  in
  match Agent_sdk.Llm_provider.Streaming.parse_sse_event None data with
  | Some (MessageDelta { stop_reason; usage }) ->
    (match stop_reason with
     | Some EndTurn -> ()
     | _ -> Alcotest.fail "expected EndTurn stop_reason");
    (match usage with
     | Some u -> Alcotest.(check int) "output_tokens" 57 u.output_tokens
     | None -> Alcotest.fail "expected Some usage")
  | Some _ -> Alcotest.fail "unexpected event type"
  | None -> Alcotest.fail "parse returned None"
;;

let test_parse_message_stop () =
  let data = {|{"type":"message_stop"}|} in
  match Agent_sdk.Llm_provider.Streaming.parse_sse_event None data with
  | Some MessageStop -> ()
  | Some _ -> Alcotest.fail "unexpected event type"
  | None -> Alcotest.fail "parse returned None"
;;

let test_parse_ping () =
  let data = {|{"type":"ping"}|} in
  match Agent_sdk.Llm_provider.Streaming.parse_sse_event None data with
  | Some Ping -> ()
  | Some _ -> Alcotest.fail "unexpected event type"
  | None -> Alcotest.fail "parse returned None"
;;

let test_parse_error_event () =
  let data =
    {|{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}|}
  in
  match Agent_sdk.Llm_provider.Streaming.parse_sse_event None data with
  | Some (SSEError { message; error_type; _ }) ->
    Alcotest.(check string) "error message" "Overloaded" message;
    Alcotest.(check (option string)) "error type" (Some "overloaded_error") error_type
  | Some _ -> Alcotest.fail "unexpected event type"
  | None -> Alcotest.fail "parse returned None"
;;

let test_parse_invalid_json () =
  match Agent_sdk.Llm_provider.Streaming.parse_sse_event None "not json at all" with
  | Some (SSEParseFailed { raw; reason }) ->
    Alcotest.(check string) "raw" "not json at all" raw;
    Alcotest.(check bool) "reason is present" true (String.length reason > 0)
  | Some _ -> Alcotest.fail "expected SSEParseFailed for invalid JSON"
  | None -> Alcotest.fail "parse returned None"
;;

let test_parse_unknown_event_type () =
  let data = {|{"type":"unknown_future_event","data":"x"}|} in
  match Agent_sdk.Llm_provider.Streaming.parse_sse_event None data with
  | Some (SSEUnknownEventType { event_type; raw }) ->
    Alcotest.(check string) "event_type" "unknown_future_event" event_type;
    Alcotest.(check string) "raw" data raw
  | Some _ -> Alcotest.fail "expected SSEUnknownEventType"
  | None -> Alcotest.fail "parse returned None"
;;

let test_parse_message_start_with_cache () =
  let data =
    {|{"type":"message_start","message":{"id":"msg_cache","model":"claude-sonnet-4","usage":{"input_tokens":100,"cache_creation_input_tokens":50,"cache_read_input_tokens":30}}}|}
  in
  match Agent_sdk.Llm_provider.Streaming.parse_sse_event None data with
  | Some (MessageStart { id; usage; _ }) ->
    Alcotest.(check string) "id" "msg_cache" id;
    (match usage with
     | Some u ->
       Alcotest.(check int) "input_tokens" 100 u.input_tokens;
       Alcotest.(check int) "cache_creation" 50 u.cache_creation_input_tokens;
       Alcotest.(check int) "cache_read" 30 u.cache_read_input_tokens
     | None -> Alcotest.fail "expected Some usage")
  | Some _ -> Alcotest.fail "unexpected event type"
  | None -> Alcotest.fail "parse returned None"
;;

let test_message_delta_with_cache_usage () =
  (* message_delta may carry usage with cache metrics *)
  let data =
    {|{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"input_tokens":0,"output_tokens":150,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}|}
  in
  match Agent_sdk.Llm_provider.Streaming.parse_sse_event None data with
  | Some (MessageDelta { stop_reason; usage }) ->
    (match stop_reason with
     | Some EndTurn -> ()
     | _ -> Alcotest.fail "expected end_turn");
    (match usage with
     | Some u ->
       Alcotest.(check int) "output" 150 u.output_tokens;
       Alcotest.(check int) "cache_write zero" 0 u.cache_creation_input_tokens
     | None -> Alcotest.fail "expected usage in delta")
  | Some _ -> Alcotest.fail "unexpected event type"
  | None -> Alcotest.fail "parse returned None"
;;

let test_message_start_missing_output_tokens () =
  (* Some API responses may omit output_tokens in message_start usage *)
  let data =
    {|{"type":"message_start","message":{"id":"msg_partial","model":"claude-sonnet-4-6","usage":{"input_tokens":500}}}|}
  in
  match Agent_sdk.Llm_provider.Streaming.parse_sse_event None data with
  | Some (MessageStart { id; usage; _ }) ->
    Alcotest.(check string) "id" "msg_partial" id;
    (match usage with
     | Some u -> Alcotest.(check int) "input" 500 u.input_tokens
     | None -> Alcotest.fail "expected usage")
  | Some _ -> Alcotest.fail "unexpected event type"
  | None -> Alcotest.fail "parse returned None"
;;

let test_parse_with_explicit_event_type () =
  (* event_type parameter overrides the 'type' field in JSON *)
  let data =
    {|{"message":{"id":"msg_02","model":"claude-haiku-4-5-20251001","usage":{"input_tokens":10}}}|}
  in
  match Agent_sdk.Llm_provider.Streaming.parse_sse_event (Some "message_start") data with
  | Some (MessageStart { id; _ }) ->
    Alcotest.(check string) "id via explicit event type" "msg_02" id
  | Some _ -> Alcotest.fail "unexpected event type"
  | None -> Alcotest.fail "parse returned None"
;;

let parse_openai_chunk_exn data =
  match Agent_sdk.Llm_provider.Streaming.parse_openai_sse_chunk data with
  | Agent_sdk.Llm_provider.Streaming.Openai_chunk chunk -> chunk
  | Agent_sdk.Llm_provider.Streaming.Openai_done
  | Agent_sdk.Llm_provider.Streaming.Openai_empty
  | Agent_sdk.Llm_provider.Streaming.Openai_provider_error _
  | Agent_sdk.Llm_provider.Streaming.Openai_parse_failed _ ->
    Alcotest.fail "expected OpenAI-compatible stream chunk"
;;

let test_openai_compat_interleaved_reasoning_and_tool_deltas () =
  (* Qwen/DeepSeek/Kimi/MiniMax/Nemotron-style OpenAI-compatible streams can
     interleave reasoning side-channel deltas with incremental tool-call
     argument JSON. They must become separate content blocks, not one visible
     assistant text buffer and not one shared argument buffer. *)
  let state =
    Agent_sdk.Llm_provider.Streaming.create_openai_stream_state
      ~provider:"ollama_cloud"
      ~model:"qwen3.5:397b"
      ()
  in
  let first =
    parse_openai_chunk_exn
      {|{"id":"chatcmpl-1","model":"qwen3.5:397b","choices":[{"delta":{"reasoning_content":"plan-","tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"lookup","arguments":"{\"city\":"}}]},"finish_reason":null}]}|}
  in
  let first_events, first_telemetry =
    Agent_sdk.Llm_provider.Streaming.openai_chunk_to_events state first
  in
  Alcotest.(check bool) "no first telemetry" true (Option.is_none first_telemetry);
  (match first_events with
   | [ ContentBlockStart { index = 0; content_type = "thinking"; _ }
     ; ContentBlockDelta { index = 0; delta = ThinkingDelta "plan-" }
     ; ContentBlockStart
         { index = 1
         ; content_type = "tool_use"
         ; tool_id = Some "call_1"
         ; tool_name = Some "lookup"
         }
     ; ContentBlockDelta { index = 1; delta = InputJsonDelta {|{"city":|} }
     ] -> ()
   | _ -> Alcotest.fail "expected separate thinking and tool argument events");
  let second =
    parse_openai_chunk_exn
      {|{"id":"chatcmpl-1","model":"qwen3.5:397b","choices":[{"delta":{"reasoning_content":"done","content":"visible","tool_calls":[{"index":0,"function":{"arguments":"\"Seoul\"}"}}]},"finish_reason":null}]}|}
  in
  let second_events, _ =
    Agent_sdk.Llm_provider.Streaming.openai_chunk_to_events state second
  in
  let finish =
    parse_openai_chunk_exn
      {|{"id":"chatcmpl-1","model":"qwen3.5:397b","choices":[{"delta":{},"finish_reason":"tool_calls"}]}|}
  in
  let finish_events, _ =
    Agent_sdk.Llm_provider.Streaming.openai_chunk_to_events state finish
  in
  let acc = Agent_sdk.Llm_provider.Complete_stream_acc.create_stream_acc () in
  List.iter
    (Agent_sdk.Llm_provider.Complete_stream_acc.accumulate_event acc)
    (first_events @ second_events @ finish_events);
  match Agent_sdk.Llm_provider.Complete_stream_acc.finalize_stream_acc acc with
  | Error _ -> Alcotest.fail "expected finalized interleaved stream"
  | Ok result ->
    Alcotest.(check bool) "stop reason" true (result.stop_reason = StopToolUse);
    (match result.content with
     | [ Thinking { content = "plan-done"; _ }
       ; ToolUse { id = "call_1"; name = "lookup"; input }
       ; Text "visible"
       ] ->
       Alcotest.(check bool) "tool args" true (input = `Assoc [ "city", `String "Seoul" ])
     | _ ->
       Alcotest.fail "expected thinking, tool use, and visible text to stay separated")
;;

let parse_anthropic_event_exn ?event_type data =
  match Agent_sdk.Llm_provider.Streaming.parse_sse_event event_type data with
  | Some event -> event
  | None -> Alcotest.fail "expected Anthropic SSE event"
;;

let test_anthropic_interleaved_thinking_tool_text_finalizes () =
  let module Acc = Agent_sdk.Llm_provider.Complete_stream_acc in
  let raw_events =
    [ parse_anthropic_event_exn
        {|{"type":"message_start","message":{"id":"msg_anth","model":"claude-sonnet-4-6","usage":{"input_tokens":11}}}|}
    ; parse_anthropic_event_exn
        {|{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}|}
    ; parse_anthropic_event_exn
        {|{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"plan-"}}|}
    ; parse_anthropic_event_exn
        {|{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"lookup","input":{}}}|}
    ; parse_anthropic_event_exn
        {|{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"city\":"}}|}
    ; parse_anthropic_event_exn
        {|{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"done"}}|}
    ; parse_anthropic_event_exn
        {|{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\"Seoul\"}"}}|}
    ; parse_anthropic_event_exn
        {|{"type":"content_block_start","index":2,"content_block":{"type":"text","text":""}}|}
    ; parse_anthropic_event_exn
        {|{"type":"content_block_delta","index":2,"delta":{"type":"text_delta","text":"visible"}}|}
    ; parse_anthropic_event_exn
        {|{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":7}}|}
    ; parse_anthropic_event_exn {|{"type":"message_stop"}|}
    ]
  in
  let acc = Acc.create_stream_acc () in
  List.iter (Acc.accumulate_event acc) raw_events;
  match Acc.finalize_stream_acc acc with
  | Error _ -> Alcotest.fail "expected finalized Anthropic interleaved stream"
  | Ok result ->
    Alcotest.(check bool) "stop reason" true (result.stop_reason = StopToolUse);
    (match result.content with
     | [ Thinking { content = "plan-done"; _ }
       ; ToolUse { id = "toolu_1"; name = "lookup"; input }
       ; Text "visible"
       ] ->
       Alcotest.(check bool) "tool args" true (input = `Assoc [ "city", `String "Seoul" ])
     | _ ->
       Alcotest.fail "expected thinking, tool use, and visible text to stay separated")
;;

(* ------------------------------------------------------------------ *)
(* emit_synthetic_events                                                *)
(* ------------------------------------------------------------------ *)

let collect_events response =
  let events = ref [] in
  Agent_sdk.Llm_provider.Streaming.emit_synthetic_events response (fun evt ->
    events := evt :: !events);
  List.rev !events
;;

let test_synthetic_text_only () =
  let response : api_response =
    { id = "msg-s1"
    ; model = "test"
    ; stop_reason = EndTurn
    ; content = [ Text "hello" ]
    ; usage =
        Some
          { input_tokens = 10
          ; output_tokens = 5
          ; cache_creation_input_tokens = 0
          ; cache_read_input_tokens = 0
          ; cost_usd = None
          }
    ; telemetry = None
    }
  in
  let events = collect_events response in
  (* MessageStart, ContentBlockStart, TextDelta, ContentBlockStop, MessageDelta, MessageStop *)
  Alcotest.(check int) "6 events" 6 (List.length events);
  (match List.nth events 0 with
   | MessageStart { id; _ } -> Alcotest.(check string) "id" "msg-s1" id
   | _ -> Alcotest.fail "expected MessageStart");
  (match List.nth events 1 with
   | ContentBlockStart { index; content_type; _ } ->
     Alcotest.(check int) "idx" 0 index;
     Alcotest.(check string) "type" "text" content_type
   | _ -> Alcotest.fail "expected ContentBlockStart");
  (match List.nth events 2 with
   | ContentBlockDelta { delta = TextDelta s; _ } ->
     Alcotest.(check string) "text" "hello" s
   | _ -> Alcotest.fail "expected TextDelta");
  match List.nth events 4 with
  | MessageDelta { stop_reason = Some EndTurn; _ } -> ()
  | _ -> Alcotest.fail "expected MessageDelta EndTurn"
;;

let test_synthetic_thinking () =
  let response : api_response =
    { id = "msg-t"
    ; model = "test"
    ; stop_reason = EndTurn
    ; content = [ Thinking { signature = Some "sig"; content = "I think..." } ]
    ; usage = None
    ; telemetry = None
    }
  in
  let events = collect_events response in
  match List.nth events 2 with
  | ContentBlockDelta { delta = ThinkingDelta s; _ } ->
    Alcotest.(check string) "thinking" "I think..." s
  | _ -> Alcotest.fail "expected ThinkingDelta"
;;

let test_synthetic_tool_use () =
  let response : api_response =
    { id = "msg-tu"
    ; model = "test"
    ; stop_reason = StopToolUse
    ; content = [ ToolUse { id = "tu1"; name = "calc"; input = `Assoc [ "x", `Int 1 ] } ]
    ; usage = None
    ; telemetry = None
    }
  in
  let events = collect_events response in
  (match List.nth events 1 with
   | ContentBlockStart { content_type; tool_id; tool_name; _ } ->
     Alcotest.(check string) "type" "tool_use" content_type;
     Alcotest.(check (option string)) "tool_id" (Some "tu1") tool_id;
     Alcotest.(check (option string)) "tool_name" (Some "calc") tool_name
   | _ -> Alcotest.fail "expected tool_use ContentBlockStart");
  match List.nth events 2 with
  | ContentBlockDelta { delta = InputJsonSnapshot s; _ } ->
    Alcotest.(check bool) "has json" true (String.length s > 0)
  | _ -> Alcotest.fail "expected InputJsonSnapshot"
;;

let test_synthetic_image_media_delta () =
  let response : api_response =
    { id = "msg-img"
    ; model = "test"
    ; stop_reason = EndTurn
    ; content = [ Image { media_type = "image/png"; data = "abc"; source_type = Base64 } ]
    ; usage = None
    ; telemetry = None
    }
  in
  let events = collect_events response in
  Alcotest.(check int) "6 events" 6 (List.length events);
  (match List.nth events 1 with
   | ContentBlockStart { content_type; _ } ->
     Alcotest.(check string) "image block type" "image" content_type
   | _ -> Alcotest.fail "expected image ContentBlockStart");
  match List.nth events 2 with
  | ContentBlockDelta
      { delta =
          MediaDelta { media_type = "image/png"; source_type = Base64; data = "abc" }
      ; _
      } -> ()
  | _ -> Alcotest.fail "expected image MediaDelta"
;;

let test_synthetic_multi_block () =
  let response : api_response =
    { id = "msg-m"
    ; model = "test"
    ; stop_reason = EndTurn
    ; content =
        [ Thinking { signature = Some "s"; content = "hmm" }
        ; Text "answer"
        ; ToolUse { id = "tu2"; name = "read"; input = `Assoc [] }
        ]
    ; usage = None
    ; telemetry = None
    }
  in
  let events = collect_events response in
  (* Thinking emits content and signature deltas; other blocks emit one delta. *)
  Alcotest.(check int) "13 events" 13 (List.length events);
  (* Check index increases *)
  (match List.nth events 1 with
   | ContentBlockStart { index = 0; _ } -> ()
   | _ -> Alcotest.fail "expected index 0");
  (match List.nth events 3 with
   | ContentBlockDelta { index = 0; delta = ThinkingSignatureDelta "s" } -> ()
   | _ -> Alcotest.fail "expected thinking signature delta");
  (match List.nth events 5 with
   | ContentBlockStart { index = 1; _ } -> ()
   | _ -> Alcotest.fail "expected index 1");
  match List.nth events 8 with
  | ContentBlockStart { index = 2; _ } -> ()
  | _ -> Alcotest.fail "expected index 2"
;;

let test_synthetic_usage_propagation () =
  let usage : api_usage =
    { input_tokens = 100
    ; output_tokens = 50
    ; cache_creation_input_tokens = 10
    ; cache_read_input_tokens = 5
    ; cost_usd = None
    }
  in
  let response : api_response =
    { id = "msg-u"
    ; model = "test"
    ; stop_reason = EndTurn
    ; content = [ Text "x" ]
    ; usage = Some usage
    ; telemetry = None
    }
  in
  let events = collect_events response in
  (match List.hd events with
   | MessageStart { usage = Some u; _ } -> Alcotest.(check int) "input" 100 u.input_tokens
   | _ -> Alcotest.fail "expected MessageStart with usage");
  match List.nth events 4 with
  | MessageDelta { usage = Some u; _ } -> Alcotest.(check int) "output" 50 u.output_tokens
  | _ -> Alcotest.fail "expected MessageDelta with usage"
;;

(* ------------------------------------------------------------------ *)
(* Test runner                                                          *)
(* ------------------------------------------------------------------ *)

let () =
  let open Alcotest in
  run
    "streaming"
    [ ( "usage_tracking"
      , [ test_case "empty_usage" `Quick test_empty_usage
        ; test_case "add_usage_basic" `Quick test_add_usage_basic
        ; test_case "add_usage_multiple" `Quick test_add_usage_multiple
        ; test_case "add_usage_zero_tokens" `Quick test_add_usage_zero_tokens
        ; test_case "add_usage_immutable" `Quick test_add_usage_immutable
        ] )
    ; ( "sse_event_types"
      , [ test_case "message_start" `Quick test_sse_message_start
        ; test_case "content_block_delta_text" `Quick test_sse_content_block_delta_text
        ; test_case "message_stop" `Quick test_sse_message_stop
        ; test_case "ping" `Quick test_sse_ping
        ; test_case "sse_error" `Quick test_sse_error
        ] )
    ; ( "parse_sse_event"
      , [ test_case "message_start" `Quick test_parse_message_start
        ; test_case "content_block_start" `Quick test_parse_content_block_start
        ; test_case "content_block_delta_text" `Quick test_parse_content_block_delta_text
        ; test_case
            "content_block_delta_thinking"
            `Quick
            test_parse_content_block_delta_thinking
        ; test_case
            "content_block_delta_signature"
            `Quick
            test_parse_content_block_delta_signature
        ; test_case
            "redacted_thinking_block_start"
            `Quick
            test_parse_redacted_thinking_block_start
        ; test_case
            "content_block_delta_input_json"
            `Quick
            test_parse_content_block_delta_input_json
        ; test_case
            "content_block_delta_unknown_fails_closed"
            `Quick
            test_parse_content_block_delta_unknown_fails_closed
        ; test_case "content_block_stop" `Quick test_parse_content_block_stop
        ; test_case "message_delta_end_turn" `Quick test_parse_message_delta_end_turn
        ; test_case "message_stop" `Quick test_parse_message_stop
        ; test_case "ping" `Quick test_parse_ping
        ; test_case "error_event" `Quick test_parse_error_event
        ; test_case "invalid_json" `Quick test_parse_invalid_json
        ; test_case "unknown_event_type" `Quick test_parse_unknown_event_type
        ; test_case "message_start_with_cache" `Quick test_parse_message_start_with_cache
        ; test_case "explicit_event_type" `Quick test_parse_with_explicit_event_type
        ; test_case "message_delta_with_cache" `Quick test_message_delta_with_cache_usage
        ; test_case
            "message_start_missing_output"
            `Quick
            test_message_start_missing_output_tokens
        ; test_case
            "openai_compat interleaved reasoning/tool deltas"
            `Quick
            test_openai_compat_interleaved_reasoning_and_tool_deltas
        ; test_case
            "anthropic interleaved thinking/tool/text finalizes"
            `Quick
            test_anthropic_interleaved_thinking_tool_text_finalizes
        ] )
    ; ( "emit_synthetic_events"
      , [ test_case "text only" `Quick test_synthetic_text_only
        ; test_case "thinking block" `Quick test_synthetic_thinking
        ; test_case "tool use" `Quick test_synthetic_tool_use
        ; test_case "image media delta" `Quick test_synthetic_image_media_delta
        ; test_case "multi block indexes" `Quick test_synthetic_multi_block
        ; test_case "usage propagation" `Quick test_synthetic_usage_propagation
        ] )
    ]
;;
