(** Unit tests for OpenAI-compatible SSE streaming parser. *)

open Llm_provider.Types
module S = Llm_provider.Streaming
module RD = Llm_provider.Reasoning_dialect
module Acc = Llm_provider.Complete_stream_acc

(* ── parse_openai_sse_chunk ─────────────────────────────── *)

let test_parse_text_chunk () =
  let data =
    {|{"id":"chatcmpl-abc","object":"chat.completion.chunk","model":"gpt-4","choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}|}
  in
  match S.parse_openai_sse_chunk data with
  | S.Openai_chunk chunk ->
    Alcotest.(check string) "id" "chatcmpl-abc" chunk.chunk_id;
    Alcotest.(check string) "model" "gpt-4" chunk.chunk_model;
    Alcotest.(check (option string)) "content" (Some "Hello") chunk.delta_content;
    Alcotest.(check (option string)) "finish" None chunk.finish_reason;
    Alcotest.(check int) "no tool_calls" 0 (List.length chunk.delta_tool_calls)
  | S.Openai_done | S.Openai_empty | S.Openai_provider_error _ | S.Openai_parse_failed _
    -> Alcotest.fail "expected OpenAI chunk"
;;

let test_parse_done_sentinel () =
  match S.parse_openai_sse_chunk "[DONE]" with
  | S.Openai_done -> ()
  | S.Openai_chunk _
  | S.Openai_empty
  | S.Openai_provider_error _
  | S.Openai_parse_failed _ -> Alcotest.fail "expected Openai_done"
;;

let test_parse_finish_reason () =
  let data =
    {|{"id":"c-1","model":"m","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}|}
  in
  match S.parse_openai_sse_chunk data with
  | S.Openai_chunk chunk ->
    Alcotest.(check (option string)) "finish" (Some "stop") chunk.finish_reason;
    Alcotest.(check (option string)) "no content" None chunk.delta_content
  | S.Openai_done | S.Openai_empty | S.Openai_provider_error _ | S.Openai_parse_failed _
    -> Alcotest.fail "expected OpenAI chunk"
;;

let test_parse_tool_call_start () =
  let data =
    {|{"id":"c-2","model":"m","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_abc","type":"function","function":{"name":"get_weather","arguments":""}}]},"finish_reason":null}]}|}
  in
  match S.parse_openai_sse_chunk data with
  | S.Openai_chunk chunk ->
    Alcotest.(check int) "1 tool_call" 1 (List.length chunk.delta_tool_calls);
    let tc = List.hd chunk.delta_tool_calls in
    Alcotest.(check int) "tc_index" 0 tc.tc_index;
    Alcotest.(check (option string)) "tc_id" (Some "call_abc") tc.tc_id;
    Alcotest.(check (option string)) "tc_name" (Some "get_weather") tc.tc_name;
    (match tc.tc_arguments with
     | Some (S.Args_fragment s) -> Alcotest.(check string) "tc_args" "" s
     | _ -> Alcotest.fail "expected Args_fragment for empty string arguments")
  | S.Openai_done | S.Openai_empty | S.Openai_provider_error _ | S.Openai_parse_failed _
    -> Alcotest.fail "expected OpenAI chunk"
;;

let test_parse_tool_call_args () =
  let data =
    {|{"id":"c-3","model":"m","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"loc"}}]},"finish_reason":null}]}|}
  in
  match S.parse_openai_sse_chunk data with
  | S.Openai_chunk chunk ->
    let tc = List.hd chunk.delta_tool_calls in
    (match tc.tc_arguments with
     | Some (S.Args_fragment s) -> Alcotest.(check string) "args" {|{"loc|} s
     | _ -> Alcotest.fail "expected Args_fragment for string arguments");
    Alcotest.(check (option string)) "no id" None tc.tc_id;
    Alcotest.(check (option string)) "no name" None tc.tc_name
  | S.Openai_done | S.Openai_empty | S.Openai_provider_error _ | S.Openai_parse_failed _
    -> Alcotest.fail "expected OpenAI chunk"
;;

let test_parse_usage () =
  let data =
    {|{"id":"c-4","model":"m","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}|}
  in
  match S.parse_openai_sse_chunk data with
  | S.Openai_chunk chunk ->
    (match chunk.chunk_usage with
     | Some u ->
       Alcotest.(check int) "input" 10 u.input_tokens;
       Alcotest.(check int) "output" 5 u.output_tokens
     | None -> Alcotest.fail "expected usage")
  | S.Openai_done | S.Openai_empty | S.Openai_provider_error _ | S.Openai_parse_failed _
    -> Alcotest.fail "expected OpenAI chunk"
;;

let test_parse_invalid_json () =
  match S.parse_openai_sse_chunk "not json" with
  | S.Openai_parse_failed { raw; reason } ->
    Alcotest.(check string) "raw invalid JSON" "not json" raw;
    Alcotest.(check bool) "typed JSON failure reason" true (String.length reason > 0)
  | S.Openai_chunk _ | S.Openai_done | S.Openai_empty | S.Openai_provider_error _ ->
    Alcotest.fail "expected Openai_parse_failed"
;;

let test_parse_empty_choices () =
  let data = {|{"id":"c-5","model":"m","choices":[]}|} in
  match S.parse_openai_sse_chunk data with
  | S.Openai_empty -> ()
  | S.Openai_chunk _ | S.Openai_done | S.Openai_provider_error _ | S.Openai_parse_failed _
    -> Alcotest.fail "expected Openai_empty"
;;

(* ── openai_chunk_to_events ─────────────────────────────── *)

let test_events_text_first_chunk () =
  let state = S.create_openai_stream_state () in
  let chunk : S.openai_chunk =
    { chunk_id = "c"
    ; chunk_model = "m"
    ; delta_content = Some "Hi"
    ; delta_reasoning = None
    ; delta_reasoning_details = None
    ; delta_tool_calls = []
    ; finish_reason = None
    ; chunk_usage = None
    }
  in
  let events, _tel = S.openai_chunk_to_events state chunk in
  Alcotest.(check int) "2 events" 2 (List.length events);
  (match List.nth events 0 with
   | ContentBlockStart { index = 0; content_type; _ } ->
     Alcotest.(check string) "text type" "text" content_type
   | _ -> Alcotest.fail "expected ContentBlockStart");
  match List.nth events 1 with
  | ContentBlockDelta { index = 0; delta = TextDelta s } ->
    Alcotest.(check string) "text" "Hi" s
  | _ -> Alcotest.fail "expected TextDelta"
;;

let test_events_text_subsequent () =
  let state = S.create_openai_stream_state () in
  (* First chunk starts the block *)
  let _ =
    S.openai_chunk_to_events
      state
      { chunk_id = "c"
      ; chunk_model = "m"
      ; delta_content = Some "A"
      ; delta_reasoning = None
      ; delta_reasoning_details = None
      ; delta_tool_calls = []
      ; finish_reason = None
      ; chunk_usage = None
      }
  in
  (* Second chunk: no ContentBlockStart *)
  let events, _tel =
    S.openai_chunk_to_events
      state
      { chunk_id = "c"
      ; chunk_model = "m"
      ; delta_content = Some "B"
      ; delta_reasoning = None
      ; delta_reasoning_details = None
      ; delta_tool_calls = []
      ; finish_reason = None
      ; chunk_usage = None
      }
  in
  Alcotest.(check int) "1 event" 1 (List.length events);
  match List.hd events with
  | ContentBlockDelta { delta = TextDelta s; _ } -> Alcotest.(check string) "text" "B" s
  | _ -> Alcotest.fail "expected TextDelta only"
;;

let test_events_tool_call () =
  let state = S.create_openai_stream_state () in
  let tc : S.openai_tool_call_delta =
    { tc_index = 0
    ; tc_id = Some "call_1"
    ; tc_name = Some "calc"
    ; tc_arguments = Some (S.Args_fragment "{\"x\":1}")
    }
  in
  let events, _tel =
    S.openai_chunk_to_events
      state
      { chunk_id = "c"
      ; chunk_model = "m"
      ; delta_content = None
      ; delta_reasoning = None
      ; delta_reasoning_details = None
      ; delta_tool_calls = [ tc ]
      ; finish_reason = None
      ; chunk_usage = None
      }
  in
  Alcotest.(check int) "2 events" 2 (List.length events);
  (match List.nth events 0 with
   | ContentBlockStart { content_type; tool_id; tool_name; _ } ->
     Alcotest.(check string) "type" "tool_use" content_type;
     Alcotest.(check (option string)) "tool_id" (Some "call_1") tool_id;
     Alcotest.(check (option string)) "tool_name" (Some "calc") tool_name
   | _ -> Alcotest.fail "expected ContentBlockStart tool_use");
  match List.nth events 1 with
  | ContentBlockDelta { delta = InputJsonDelta s; _ } ->
    Alcotest.(check string) "args" {|{"x":1}|} s
  | _ -> Alcotest.fail "expected InputJsonDelta"
;;

let idless_openai_tool_start () =
  let state = S.create_openai_stream_state () in
  let events, _ =
    S.openai_chunk_to_events
      state
      { chunk_id = "same-provider-chunk"
      ; chunk_model = "model"
      ; delta_content = None
      ; delta_reasoning = None
      ; delta_reasoning_details = None
      ; delta_tool_calls =
          [ { S.tc_index = 0
            ; tc_id = None
            ; tc_name = Some "lookup"
            ; tc_arguments = Some (S.Args_fragment {|{"q":"same"}|})
            }
          ]
      ; finish_reason = None
      ; chunk_usage = None
      }
  in
  match events with
  | [ ContentBlockStart { index = 0; content_type = "tool_use"; tool_id = Some id; _ }
    ; ContentBlockDelta { index = 0; delta = InputJsonDelta _ }
    ] -> id, state, events
  | _ -> Alcotest.fail "expected id-less call to receive one identity at block start"
;;

let test_events_idless_tool_identity_matches_final_response () =
  let start_id, state, events = idless_openai_tool_start () in
  let acc = Acc.create_stream_acc () in
  Acc.accumulate_event
    acc
    (MessageStart { id = "response"; model = "model"; usage = None });
  List.iter (Acc.accumulate_event acc) events;
  let terminal, _ =
    S.openai_chunk_to_events
      state
      { chunk_id = "same-provider-chunk"
      ; chunk_model = "model"
      ; delta_content = None
      ; delta_reasoning = None
      ; delta_reasoning_details = None
      ; delta_tool_calls = []
      ; finish_reason = Some "tool_calls"
      ; chunk_usage = None
      }
  in
  List.iter (Acc.accumulate_event acc) terminal;
  match Acc.finalize_stream_acc acc with
  | Ok { content = [ ToolUse { id; name = "lookup"; _ } ]; _ } ->
    Alcotest.(check string) "start and final identity" start_id id
  | Ok _ -> Alcotest.fail "expected one finalized ToolUse"
  | Error _ -> Alcotest.fail "expected id-less normalized stream to finalize"
;;

let test_events_idless_tool_ids_are_unique_across_streams () =
  let first, _, _ = idless_openai_tool_start () in
  let second, _, _ = idless_openai_tool_start () in
  Alcotest.(check bool) "separate streams allocate distinct ids" true (first <> second)
;;

let test_events_parallel_idless_tool_ids_are_distinct () =
  let state = S.create_openai_stream_state () in
  let call tc_index =
    { S.tc_index
    ; tc_id = None
    ; tc_name = Some "lookup"
    ; tc_arguments = Some (S.Args_fragment {|{"q":"same"}|})
    }
  in
  let events, _ =
    S.openai_chunk_to_events
      state
      { chunk_id = "chunk"
      ; chunk_model = "model"
      ; delta_content = None
      ; delta_reasoning = None
      ; delta_reasoning_details = None
      ; delta_tool_calls = [ call 0; call 1 ]
      ; finish_reason = None
      ; chunk_usage = None
      }
  in
  let ids =
    List.filter_map
      (function
        | ContentBlockStart { content_type = "tool_use"; tool_id = Some id; _ } -> Some id
        | _ -> None)
      events
  in
  match ids with
  | [ first; second ] ->
    Alcotest.(check bool) "parallel identical calls stay distinct" true (first <> second)
  | _ -> Alcotest.fail "expected two identified tool starts"
;;

let test_events_late_provider_tool_id_fails_closed () =
  let _, state, _ = idless_openai_tool_start () in
  let events, _ =
    S.openai_chunk_to_events
      state
      { chunk_id = "same-provider-chunk"
      ; chunk_model = "model"
      ; delta_content = None
      ; delta_reasoning = None
      ; delta_reasoning_details = None
      ; delta_tool_calls =
          [ { S.tc_index = 0
            ; tc_id = Some "provider-late-id"
            ; tc_name = None
            ; tc_arguments = Some (S.Args_fragment "}")
            }
          ]
      ; finish_reason = None
      ; chunk_usage = None
      }
  in
  match events with
  | [ SSEParseFailed { reason; _ } ] ->
    Alcotest.(check string)
      "late provider identity is explicit"
      "late_provider_tool_call_id: provider identity arrived after an OAS identity was \
       emitted"
      reason
  | _ -> Alcotest.fail "expected a typed late-provider-identity failure"
;;

let test_events_finish_reason () =
  let state = S.create_openai_stream_state () in
  let events, _tel =
    S.openai_chunk_to_events
      state
      { chunk_id = "c"
      ; chunk_model = "m"
      ; delta_content = None
      ; delta_tool_calls = []
      ; delta_reasoning = None
      ; delta_reasoning_details = None
      ; finish_reason = Some "stop"
      ; chunk_usage = None
      }
  in
  Alcotest.(check int) "1 event" 1 (List.length events);
  match List.hd events with
  | MessageDelta { stop_reason = Some EndTurn; _ } -> ()
  | _ -> Alcotest.fail "expected MessageDelta EndTurn"
;;

let test_events_tool_calls_finish () =
  let state = S.create_openai_stream_state () in
  let events, _tel =
    S.openai_chunk_to_events
      state
      { chunk_id = "c"
      ; chunk_model = "m"
      ; delta_content = None
      ; delta_tool_calls = []
      ; delta_reasoning = None
      ; delta_reasoning_details = None
      ; finish_reason = Some "tool_calls"
      ; chunk_usage = None
      }
  in
  match List.hd events with
  | MessageDelta { stop_reason = Some StopToolUse; _ } -> ()
  | _ -> Alcotest.fail "expected StopToolUse"
;;

let test_events_finish_closes_open_tool_block () =
  (* A tool block opened in an earlier chunk must receive a matching
     ContentBlockStop on the terminal finish chunk, so a per-message
     block-index consumer closes it before the next provider message reuses the
     same index. OpenAI-compat analogue of Anthropic's wire content_block_stop.
     Regression guard for the keeper-stream [tool_args_without_start]
     cross-message collision (deepseek-v4-flash via ollama_cloud). *)
  let state = S.create_openai_stream_state () in
  let tc : S.openai_tool_call_delta =
    { tc_index = 0
    ; tc_id = Some "call_xq02glug"
    ; tc_name = Some "get_weather"
    ; tc_arguments = Some (S.Args_fragment {|{"city":"Seoul"}|})
    }
  in
  let _open, _ =
    S.openai_chunk_to_events
      state
      { chunk_id = "c"
      ; chunk_model = "m"
      ; delta_content = None
      ; delta_reasoning = None
      ; delta_reasoning_details = None
      ; delta_tool_calls = [ tc ]
      ; finish_reason = None
      ; chunk_usage = None
      }
  in
  let events, _tel =
    S.openai_chunk_to_events
      state
      { chunk_id = "c"
      ; chunk_model = "m"
      ; delta_content = None
      ; delta_reasoning = None
      ; delta_reasoning_details = None
      ; delta_tool_calls = []
      ; finish_reason = Some "tool_calls"
      ; chunk_usage = None
      }
  in
  Alcotest.(check int) "stop + message_delta" 2 (List.length events);
  let stop_indices =
    List.filter_map
      (function
        | ContentBlockStop { index } -> Some index
        | _ -> None)
      events
  in
  Alcotest.(check (list int)) "open tool block 0 closed on finish" [ 0 ] stop_indices;
  match List.rev events with
  | MessageDelta { stop_reason = Some StopToolUse; _ } :: _ -> ()
  | _ -> Alcotest.fail "finish chunk must end with MessageDelta after closing blocks"
;;

let test_events_length_finish () =
  let state = S.create_openai_stream_state () in
  let events, _tel =
    S.openai_chunk_to_events
      state
      { chunk_id = "c"
      ; chunk_model = "m"
      ; delta_content = None
      ; delta_tool_calls = []
      ; delta_reasoning = None
      ; delta_reasoning_details = None
      ; finish_reason = Some "length"
      ; chunk_usage = None
      }
  in
  match List.hd events with
  | MessageDelta { stop_reason = Some MaxTokens; _ } -> ()
  | _ -> Alcotest.fail "expected MaxTokens"
;;

let test_events_empty_content_ignored () =
  let state = S.create_openai_stream_state () in
  let events, _tel =
    S.openai_chunk_to_events
      state
      { chunk_id = "c"
      ; chunk_model = "m"
      ; delta_content = Some ""
      ; delta_reasoning = None
      ; delta_reasoning_details = None
      ; delta_tool_calls = []
      ; finish_reason = None
      ; chunk_usage = None
      }
  in
  Alcotest.(check int) "0 events" 0 (List.length events)
;;

let test_parse_reasoning_chunk () =
  let data =
    {|{"id":"c-r","model":"dashscope","choices":[{"index":0,"delta":{"reasoning_content":"Let me think"},"finish_reason":null}]}|}
  in
  match S.parse_openai_sse_chunk data with
  | S.Openai_chunk chunk ->
    Alcotest.(check (option string))
      "reasoning"
      (Some "Let me think")
      chunk.delta_reasoning;
    Alcotest.(check (option string)) "no content" None chunk.delta_content
  | S.Openai_done | S.Openai_empty | S.Openai_provider_error _ | S.Openai_parse_failed _
    -> Alcotest.fail "expected OpenAI chunk"
;;

let test_parse_ollama_reasoning_fallback () =
  (* Ollama returns "reasoning" instead of "reasoning_content" *)
  let data =
    {|{"id":"c-ollama","model":"dashscope-3.5:35b","choices":[{"index":0,"delta":{"reasoning":"Ollama thinking"},"finish_reason":null}]}|}
  in
  match S.parse_openai_sse_chunk data with
  | S.Openai_chunk chunk ->
    Alcotest.(check (option string))
      "reasoning fallback"
      (Some "Ollama thinking")
      chunk.delta_reasoning;
    Alcotest.(check (option string)) "no content" None chunk.delta_content
  | S.Openai_done | S.Openai_empty | S.Openai_provider_error _ | S.Openai_parse_failed _
    -> Alcotest.fail "expected OpenAI chunk"
;;

let test_parse_reasoning_content_preferred () =
  (* reasoning_content wins over reasoning when both present and non-blank *)
  let data =
    {|{"id":"c-both","model":"dashscope","choices":[{"index":0,"delta":{"reasoning_content":"preferred","reasoning":"fallback"},"finish_reason":null}]}|}
  in
  match S.parse_openai_sse_chunk data with
  | S.Openai_chunk chunk ->
    Alcotest.(check (option string))
      "reasoning_content wins"
      (Some "preferred")
      chunk.delta_reasoning
  | S.Openai_done | S.Openai_empty | S.Openai_provider_error _ | S.Openai_parse_failed _
    -> Alcotest.fail "expected OpenAI chunk"
;;

let test_parse_blank_reasoning_content_falls_back () =
  (* blank reasoning_content should fall back to reasoning *)
  let data =
    {|{"id":"c-blank","model":"dashscope","choices":[{"index":0,"delta":{"reasoning_content":"  ","reasoning":"actual thinking"},"finish_reason":null}]}|}
  in
  match S.parse_openai_sse_chunk data with
  | S.Openai_chunk chunk ->
    Alcotest.(check (option string))
      "blank falls back"
      (Some "actual thinking")
      chunk.delta_reasoning
  | S.Openai_done | S.Openai_empty | S.Openai_provider_error _ | S.Openai_parse_failed _
    -> Alcotest.fail "expected OpenAI chunk"
;;

let test_parse_reasoning_uses_dialect_delta_field () =
  let data =
    {|{"id":"c-dialect","model":"dialect","choices":[{"index":0,"delta":{"reasoning_content":"wrong","reasoning":"selected"},"finish_reason":null}]}|}
  in
  match
    S.parse_openai_sse_chunk ~streaming_reasoning:(RD.Delta_field "reasoning") data
  with
  | S.Openai_chunk chunk ->
    Alcotest.(check (option string))
      "dialect-selected reasoning"
      (Some "selected")
      chunk.delta_reasoning
  | S.Openai_done | S.Openai_empty | S.Openai_provider_error _ | S.Openai_parse_failed _
    -> Alcotest.fail "expected OpenAI chunk"
;;

let test_parse_reasoning_respects_no_streaming_dialect () =
  let data =
    {|{"id":"c-none","model":"dialect","choices":[{"index":0,"delta":{"reasoning_content":"hidden"},"finish_reason":null}]}|}
  in
  match S.parse_openai_sse_chunk ~streaming_reasoning:RD.No_streaming_reasoning data with
  | S.Openai_chunk chunk ->
    Alcotest.(check (option string)) "no reasoning" None chunk.delta_reasoning
  | S.Openai_done | S.Openai_empty | S.Openai_provider_error _ | S.Openai_parse_failed _
    -> Alcotest.fail "expected OpenAI chunk"
;;

let test_parse_minimax_split_reasoning_details () =
  let data =
    {|{"id":"c-minimax","model":"minimax-m3","choices":[{"index":0,"delta":{"reasoning_content":"inspect schema","reasoning_details":[{"type":"text","text":"inspect schema"}]},"finish_reason":null}]}|}
  in
  match S.parse_openai_sse_chunk ~streaming_reasoning:RD.Delta_reasoning_details data with
  | S.Openai_chunk chunk ->
    Alcotest.(check (option string)) "no visible content" None chunk.delta_content;
    Alcotest.(check (option string)) "legacy reasoning unused" None chunk.delta_reasoning;
    (match chunk.delta_reasoning_details with
     | Some { delta_reasoning_content; delta_details } ->
       Alcotest.(check (option string))
         "reasoning content"
         (Some "inspect schema")
         delta_reasoning_content;
       (match delta_details with
        | [ detail ] ->
          Alcotest.(check (option string))
            "detail text"
            (Some "inspect schema")
            detail.text
        | _ -> Alcotest.fail "expected one reasoning detail")
     | None -> Alcotest.fail "expected typed reasoning_details delta")
  | S.Openai_done | S.Openai_empty | S.Openai_provider_error _ | S.Openai_parse_failed _
    -> Alcotest.fail "expected OpenAI chunk"
;;

let expect_split_parse_failed label expected_reason data =
  let parsed =
    S.parse_openai_sse_chunk ~streaming_reasoning:RD.Delta_reasoning_details data
  in
  match parsed with
  | S.Openai_parse_failed { reason; raw } ->
    Alcotest.(check string) (label ^ " reason") expected_reason reason;
    Alcotest.(check string) (label ^ " raw") data raw;
    let events, _tel =
      S.openai_sse_parse_result_to_events (S.create_openai_stream_state ()) parsed
    in
    (match events with
     | [ SSEParseFailed { reason; raw } ] ->
       Alcotest.(check string) (label ^ " event reason") expected_reason reason;
       Alcotest.(check string) (label ^ " event raw") data raw
     | _ -> Alcotest.fail (label ^ ": expected only SSEParseFailed"))
  | S.Openai_chunk _ | S.Openai_done | S.Openai_empty | S.Openai_provider_error _ ->
    Alcotest.fail (label ^ ": expected parse failure")
;;

let test_parse_minimax_split_malformed_details_fails_closed () =
  expect_split_parse_failed
    "non-list details"
    "malformed_delta_reasoning_details:not_list"
    {|{"id":"c-minimax","model":"minimax-m3","choices":[{"index":0,"delta":{"reasoning_details":{"text":"bad"}},"finish_reason":null}]}|}
;;

let test_parse_minimax_split_malformed_detail_item_fails_closed () =
  expect_split_parse_failed
    "non-object detail"
    "malformed_delta_reasoning_details:index:0:not_object"
    {|{"id":"c-minimax","model":"minimax-m3","choices":[{"index":0,"delta":{"reasoning_details":["bad"]},"finish_reason":null}]}|}
;;

let test_events_reasoning_then_text () =
  let state = S.create_openai_stream_state () in
  let r_events, _tel =
    S.openai_chunk_to_events
      state
      { chunk_id = "c"
      ; chunk_model = "m"
      ; delta_content = None
      ; delta_reasoning = Some "thinking..."
      ; delta_reasoning_details = None
      ; delta_tool_calls = []
      ; finish_reason = None
      ; chunk_usage = None
      }
  in
  Alcotest.(check int) "2 events (start+delta)" 2 (List.length r_events);
  (match List.nth r_events 0 with
   | ContentBlockStart { index = 0; content_type; _ } ->
     Alcotest.(check string) "thinking type" "thinking" content_type
   | _ -> Alcotest.fail "expected ContentBlockStart thinking at index 0");
  (match List.nth r_events 1 with
   | ContentBlockDelta { index = 0; delta = ThinkingDelta s } ->
     Alcotest.(check string) "thinking text" "thinking..." s
   | _ -> Alcotest.fail "expected ThinkingDelta at index 0");
  let t_events, _tel =
    S.openai_chunk_to_events
      state
      { chunk_id = "c"
      ; chunk_model = "m"
      ; delta_content = Some "answer"
      ; delta_reasoning = None
      ; delta_reasoning_details = None
      ; delta_tool_calls = []
      ; finish_reason = None
      ; chunk_usage = None
      }
  in
  Alcotest.(check int) "2 events (start+delta)" 2 (List.length t_events);
  (match List.nth t_events 0 with
   | ContentBlockStart { index = 1; content_type; _ } ->
     Alcotest.(check string) "text type" "text" content_type
   | _ -> Alcotest.fail "expected ContentBlockStart text at index 1");
  match List.nth t_events 1 with
  | ContentBlockDelta { index = 1; delta = TextDelta s } ->
    Alcotest.(check string) "text" "answer" s
  | _ -> Alcotest.fail "expected TextDelta at index 1"
;;

(** Regression test for issue #332: thinking delta index must match
    the assigned block index across multiple streaming chunks. *)
let test_events_reasoning_delta_index_multi_chunk () =
  let state = S.create_openai_stream_state () in
  (* First reasoning chunk: starts block at index 0 *)
  let r1, _tel =
    S.openai_chunk_to_events
      state
      { chunk_id = "c"
      ; chunk_model = "m"
      ; delta_content = None
      ; delta_reasoning = Some "step 1"
      ; delta_reasoning_details = None
      ; delta_tool_calls = []
      ; finish_reason = None
      ; chunk_usage = None
      }
  in
  Alcotest.(check int) "2 events (start+delta)" 2 (List.length r1);
  (match List.nth r1 0 with
   | ContentBlockStart { index; content_type; _ } ->
     Alcotest.(check int) "thinking start index" 0 index;
     Alcotest.(check string) "thinking type" "thinking" content_type
   | _ -> Alcotest.fail "expected ContentBlockStart thinking");
  (match List.nth r1 1 with
   | ContentBlockDelta { index; delta = ThinkingDelta _ } ->
     Alcotest.(check int) "thinking delta index matches start" 0 index
   | _ -> Alcotest.fail "expected ThinkingDelta");
  (* Second reasoning chunk: must still use the same block index *)
  let r2, _tel =
    S.openai_chunk_to_events
      state
      { chunk_id = "c"
      ; chunk_model = "m"
      ; delta_content = None
      ; delta_reasoning = Some "step 2"
      ; delta_reasoning_details = None
      ; delta_tool_calls = []
      ; finish_reason = None
      ; chunk_usage = None
      }
  in
  Alcotest.(check int) "1 event (delta only)" 1 (List.length r2);
  (match List.hd r2 with
   | ContentBlockDelta { index; delta = ThinkingDelta s } ->
     Alcotest.(check int) "subsequent thinking delta index" 0 index;
     Alcotest.(check string) "text" "step 2" s
   | _ -> Alcotest.fail "expected ThinkingDelta at index 0");
  (* Text after thinking: must get index 1, not 0 *)
  let t_events, _tel =
    S.openai_chunk_to_events
      state
      { chunk_id = "c"
      ; chunk_model = "m"
      ; delta_content = Some "answer"
      ; delta_reasoning = None
      ; delta_reasoning_details = None
      ; delta_tool_calls = []
      ; finish_reason = None
      ; chunk_usage = None
      }
  in
  match List.nth t_events 1 with
  | ContentBlockDelta { index; delta = TextDelta _ } ->
    Alcotest.(check int) "text delta index" 1 index
  | _ -> Alcotest.fail "expected TextDelta at index 1"
;;

(** Regression test for issue #333: tool-first stream must assign correct
    text block index when text arrives after tool calls. *)
let test_events_tool_first_then_text () =
  let state = S.create_openai_stream_state () in
  (* Step 1: tool call arrives first, gets block index 0 *)
  let tc : S.openai_tool_call_delta =
    { tc_index = 0
    ; tc_id = Some "call_1"
    ; tc_name = Some "get_weather"
    ; tc_arguments = Some (S.Args_fragment {|{"city":"Seoul"}|})
    }
  in
  let tool_events, _tel =
    S.openai_chunk_to_events
      state
      { chunk_id = "c"
      ; chunk_model = "m"
      ; delta_content = None
      ; delta_reasoning = None
      ; delta_reasoning_details = None
      ; delta_tool_calls = [ tc ]
      ; finish_reason = None
      ; chunk_usage = None
      }
  in
  Alcotest.(check int) "2 tool events" 2 (List.length tool_events);
  (match List.nth tool_events 0 with
   | ContentBlockStart { index; content_type; _ } ->
     Alcotest.(check int) "tool start index" 0 index;
     Alcotest.(check string) "tool_use type" "tool_use" content_type
   | _ -> Alcotest.fail "expected ContentBlockStart tool_use");
  (match List.nth tool_events 1 with
   | ContentBlockDelta { index; delta = InputJsonDelta _; _ } ->
     Alcotest.(check int) "tool delta index" 0 index
   | _ -> Alcotest.fail "expected InputJsonDelta at index 0");
  (* Step 2: text arrives — must get index 1, not 0 *)
  let text_events, _tel =
    S.openai_chunk_to_events
      state
      { chunk_id = "c"
      ; chunk_model = "m"
      ; delta_content = Some "sunny"
      ; delta_reasoning = None
      ; delta_reasoning_details = None
      ; delta_tool_calls = []
      ; finish_reason = None
      ; chunk_usage = None
      }
  in
  Alcotest.(check int) "2 text events" 2 (List.length text_events);
  (match List.nth text_events 0 with
   | ContentBlockStart { index; content_type; _ } ->
     Alcotest.(check int) "text start index" 1 index;
     Alcotest.(check string) "text type" "text" content_type
   | _ -> Alcotest.fail "expected ContentBlockStart text at index 1");
  (match List.nth text_events 1 with
   | ContentBlockDelta { index; delta = TextDelta s } ->
     Alcotest.(check int) "text delta index" 1 index;
     Alcotest.(check string) "text content" "sunny" s
   | _ -> Alcotest.fail "expected TextDelta at index 1");
  (* Step 3: subsequent text must reuse the same block index *)
  let text2_events, _tel =
    S.openai_chunk_to_events
      state
      { chunk_id = "c"
      ; chunk_model = "m"
      ; delta_content = Some " today"
      ; delta_reasoning = None
      ; delta_reasoning_details = None
      ; delta_tool_calls = []
      ; finish_reason = None
      ; chunk_usage = None
      }
  in
  Alcotest.(check int) "1 event (delta only)" 1 (List.length text2_events);
  match List.hd text2_events with
  | ContentBlockDelta { index; delta = TextDelta s } ->
    Alcotest.(check int) "subsequent text index" 1 index;
    Alcotest.(check string) "subsequent text" " today" s
  | _ -> Alcotest.fail "expected TextDelta at index 1"
;;

(** Regression test for issue #333: multiple tool calls then text. *)
let test_events_multi_tool_then_text () =
  let state = S.create_openai_stream_state () in
  (* Two tool calls: indices 0 and 1 *)
  let tc0 : S.openai_tool_call_delta =
    { tc_index = 0
    ; tc_id = Some "call_a"
    ; tc_name = Some "fn_a"
    ; tc_arguments = Some (S.Args_fragment "{}")
    }
  in
  let tc1 : S.openai_tool_call_delta =
    { tc_index = 1
    ; tc_id = Some "call_b"
    ; tc_name = Some "fn_b"
    ; tc_arguments = Some (S.Args_fragment "{}")
    }
  in
  let _ =
    S.openai_chunk_to_events
      state
      { chunk_id = "c"
      ; chunk_model = "m"
      ; delta_content = None
      ; delta_reasoning = None
      ; delta_reasoning_details = None
      ; delta_tool_calls = [ tc0; tc1 ]
      ; finish_reason = None
      ; chunk_usage = None
      }
  in
  (* Text must get index 2 *)
  let text_events, _tel =
    S.openai_chunk_to_events
      state
      { chunk_id = "c"
      ; chunk_model = "m"
      ; delta_content = Some "result"
      ; delta_reasoning = None
      ; delta_reasoning_details = None
      ; delta_tool_calls = []
      ; finish_reason = None
      ; chunk_usage = None
      }
  in
  (match List.nth text_events 0 with
   | ContentBlockStart { index; _ } ->
     Alcotest.(check int) "text after 2 tools index" 2 index
   | _ -> Alcotest.fail "expected ContentBlockStart at index 2");
  match List.nth text_events 1 with
  | ContentBlockDelta { index; _ } ->
    Alcotest.(check int) "text delta after 2 tools index" 2 index
  | _ -> Alcotest.fail "expected ContentBlockDelta at index 2"
;;

(** Regression test for issue #333: tool between thinking and text. *)
let test_events_thinking_tool_text () =
  let state = S.create_openai_stream_state () in
  (* Thinking: gets index 0 *)
  let _ =
    S.openai_chunk_to_events
      state
      { chunk_id = "c"
      ; chunk_model = "m"
      ; delta_content = None
      ; delta_reasoning = Some "planning"
      ; delta_reasoning_details = None
      ; delta_tool_calls = []
      ; finish_reason = None
      ; chunk_usage = None
      }
  in
  (* Tool call: gets index 1 *)
  let tc : S.openai_tool_call_delta =
    { tc_index = 0
    ; tc_id = Some "call_x"
    ; tc_name = Some "search"
    ; tc_arguments = Some (S.Args_fragment "{}")
    }
  in
  let _ =
    S.openai_chunk_to_events
      state
      { chunk_id = "c"
      ; chunk_model = "m"
      ; delta_content = None
      ; delta_reasoning = None
      ; delta_reasoning_details = None
      ; delta_tool_calls = [ tc ]
      ; finish_reason = None
      ; chunk_usage = None
      }
  in
  (* Text: must get index 2 *)
  let text_events, _tel =
    S.openai_chunk_to_events
      state
      { chunk_id = "c"
      ; chunk_model = "m"
      ; delta_content = Some "found it"
      ; delta_reasoning = None
      ; delta_reasoning_details = None
      ; delta_tool_calls = []
      ; finish_reason = None
      ; chunk_usage = None
      }
  in
  (match List.nth text_events 0 with
   | ContentBlockStart { index; _ } ->
     Alcotest.(check int) "text after thinking+tool" 2 index
   | _ -> Alcotest.fail "expected ContentBlockStart at index 2");
  match List.nth text_events 1 with
  | ContentBlockDelta { index; delta = TextDelta s } ->
    Alcotest.(check int) "text delta index" 2 index;
    Alcotest.(check string) "text" "found it" s
  | _ -> Alcotest.fail "expected TextDelta at index 2"
;;

let test_events_reasoning_details_accumulates_typed () =
  let data =
    {|{"id":"c-minimax","model":"minimax-m3","choices":[{"index":0,"delta":{"reasoning_content":"inspect schema","reasoning_details":[{"type":"text","text":"inspect schema"}]},"finish_reason":null}]}|}
  in
  let chunk =
    match
      S.parse_openai_sse_chunk ~streaming_reasoning:RD.Delta_reasoning_details data
    with
    | S.Openai_chunk chunk -> chunk
    | S.Openai_done | S.Openai_empty | S.Openai_provider_error _ | S.Openai_parse_failed _
      -> Alcotest.fail "expected OpenAI chunk"
  in
  let events, _tel = S.openai_chunk_to_events (S.create_openai_stream_state ()) chunk in
  (match events with
   | [ ContentBlockStart { index = 0; content_type = "reasoning_details"; _ }
     ; ContentBlockDelta
         { index = 0
         ; delta =
             ReasoningDetailsDelta
               { reasoning_content = Some "inspect schema"; details = [ detail ] }
         }
     ] ->
     Alcotest.(check (option string))
       "streamed detail text"
       (Some "inspect schema")
       detail.text
   | _ -> Alcotest.fail "expected reasoning_details start+delta");
  let acc = Acc.create_stream_acc () in
  Acc.accumulate_event
    acc
    (MessageStart { id = "msg"; model = "minimax-m3"; usage = None });
  List.iter (Acc.accumulate_event acc) events;
  Acc.accumulate_event acc (MessageDelta { stop_reason = Some EndTurn; usage = None });
  match Acc.finalize_stream_acc acc with
  | Ok { content = [ ReasoningDetails { reasoning_content; details } ]; _ } ->
    Alcotest.(check (option string))
      "final reasoning content"
      (Some "inspect schema")
      reasoning_content;
    (match details with
     | [ detail ] ->
       Alcotest.(check (option string))
         "final detail text"
         (Some "inspect schema")
         detail.text
     | _ -> Alcotest.fail "expected one final reasoning detail")
  | Ok _ -> Alcotest.fail "expected final ReasoningDetails block"
  | Error _ -> Alcotest.fail "expected successful accumulator finalization"
;;

let test_responses_non_object_frame_is_parse_failure () =
  let state =
    S.create_openai_stream_state ~provider:"openai_compat" ~model:"gpt-5.5" ()
  in
  (* Valid JSON that is not an object: Util.member raises Type_error, which
     must surface as SSEParseFailed instead of escaping the parser (#2632). *)
  List.iter
    (fun frame ->
       match S.responses_sse_to_events state (Some "response.created") frame with
       | [ SSEParseFailed { raw; reason } ], None ->
         Alcotest.(check string) "raw preserved" frame raw;
         Alcotest.(check bool) "reason non-empty" true (String.length reason > 0)
       | _ -> Alcotest.fail ("non-object frame must fail closed: " ^ frame))
    [ "null"; "[]"; "42" ]
;;

let test_responses_stream_reasoning_tool_and_terminal () =
  let state =
    S.create_openai_stream_state ~provider:"openai_compat" ~model:"gpt-5.5" ()
  in
  let events1, _ =
    S.responses_sse_to_events
      state
      (Some "response.created")
      {|{"type":"response.created","response":{"id":"resp_1","model":"gpt-5.5","status":"in_progress","usage":null}}|}
  in
  (match events1 with
   | [ MessageStart { id; model; usage } ] ->
     Alcotest.(check string) "id" "resp_1" id;
     Alcotest.(check string) "model" "gpt-5.5" model;
     Alcotest.(check bool) "usage absent" true (Option.is_none usage)
   | _ -> Alcotest.fail "expected MessageStart");
  let events2, _ =
    S.responses_sse_to_events
      state
      (Some "response.reasoning_summary_text.delta")
      {|{"type":"response.reasoning_summary_text.delta","item_id":"rs_1","output_index":0,"summary_index":0,"delta":"Need a lookup."}|}
  in
  (match events2 with
   | [ ContentBlockStart { index = 0; content_type = "thinking"; _ }
     ; ContentBlockDelta { index = 0; delta = ThinkingDelta "Need a lookup." }
     ] -> ()
   | _ -> Alcotest.fail "expected reasoning start+delta");
  let events3, _ =
    S.responses_sse_to_events
      state
      (Some "response.output_item.added")
      {|{"type":"response.output_item.added","output_index":1,"item":{"id":"fc_1","type":"function_call","call_id":"call_lookup","name":"lookup","arguments":""}}|}
  in
  (match events3 with
   | [ ContentBlockStart
         { index = 1
         ; content_type = "tool_use"
         ; tool_id = Some "call_lookup"
         ; tool_name = Some "lookup"
         }
     ] -> ()
   | _ -> Alcotest.fail "expected tool start");
  let events4, _ =
    S.responses_sse_to_events
      state
      (Some "response.function_call_arguments.delta")
      {|{"type":"response.function_call_arguments.delta","output_index":1,"item_id":"fc_1","delta":"{\"q\":\"weather\"}"}|}
  in
  (match events4 with
   | [ ContentBlockDelta { index = 1; delta = InputJsonDelta "{\"q\":\"weather\"}" } ] ->
     ()
   | _ -> Alcotest.fail "expected function arguments delta");
  let events5, _ =
    S.responses_sse_to_events
      state
      (Some "response.completed")
      {|{"type":"response.completed","response":{"id":"resp_1","model":"gpt-5.5","status":"completed","output":[{"id":"rs_1","type":"reasoning","summary":[{"type":"summary_text","text":"Need a lookup."}],"encrypted_content":"enc_reasoning_1"},{"id":"fc_1","type":"function_call","call_id":"call_lookup","name":"lookup","arguments":"{\"q\":\"weather\"}"}],"usage":{"input_tokens":12,"output_tokens":8,"input_tokens_details":{"cached_tokens":2}}}}|}
  in
  match events5 with
  | [ ContentBlockStart
        { index = 0
        ; content_type = "redacted_thinking"
        ; tool_id = Some raw_reasoning
        ; tool_name = None
        }
    ; MessageDelta { stop_reason = Some StopToolUse; usage = Some usage }
    ; MessageStop
    ] ->
    let reasoning = Yojson.Safe.from_string raw_reasoning in
    Alcotest.(check string)
      "reasoning type"
      "reasoning"
      (Yojson.Safe.Util.member "type" reasoning |> Yojson.Safe.Util.to_string);
    Alcotest.(check string)
      "encrypted reasoning"
      "enc_reasoning_1"
      (Yojson.Safe.Util.member "encrypted_content" reasoning |> Yojson.Safe.Util.to_string);
    Alcotest.(check int) "input tokens" 12 usage.input_tokens;
    Alcotest.(check int) "output tokens" 8 usage.output_tokens;
    Alcotest.(check int) "cache read" 2 usage.cache_read_input_tokens
  | _ -> Alcotest.fail "expected redacted reasoning carrier and terminal StopToolUse"
;;

let test_responses_stream_idless_tool_identity_matches_final_response () =
  let state =
    S.create_openai_stream_state ~provider:"openai_compat" ~model:"responses-model" ()
  in
  let acc = Acc.create_stream_acc () in
  let feed event_type data =
    let events, _ = S.responses_sse_to_events state (Some event_type) data in
    List.iter (Acc.accumulate_event acc) events;
    events
  in
  let _ =
    feed
      "response.created"
      {|{"type":"response.created","response":{"id":"resp","model":"responses-model","status":"in_progress","usage":null}}|}
  in
  let added =
    feed
      "response.output_item.added"
      {|{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","name":"lookup","arguments":""}}|}
  in
  let start_id =
    match added with
    | [ ContentBlockStart { index = 0; content_type = "tool_use"; tool_id = Some id; _ } ]
      -> id
    | _ -> Alcotest.fail "expected an OAS identity on the Responses tool start"
  in
  let _ =
    feed
      "response.function_call_arguments.delta"
      {|{"type":"response.function_call_arguments.delta","output_index":0,"delta":"{\"q\":\"weather\"}"}|}
  in
  let _ =
    feed
      "response.completed"
      {|{"type":"response.completed","response":{"id":"resp","model":"responses-model","status":"completed","output":[{"type":"function_call","name":"lookup","arguments":"{\"q\":\"weather\"}"}],"usage":{"input_tokens":1,"output_tokens":1}}}|}
  in
  match Acc.finalize_stream_acc acc with
  | Ok { content = [ ToolUse { id; name = "lookup"; _ } ]; _ } ->
    Alcotest.(check string) "Responses start and final identity" start_id id
  | Ok _ -> Alcotest.fail "expected one Responses ToolUse"
  | Error _ -> Alcotest.fail "expected id-less Responses tool stream to finalize"
;;

let test_responses_stream_item_id_is_not_tool_identity () =
  let state = S.create_openai_stream_state () in
  let events, _ =
    S.responses_sse_to_events
      state
      (Some "response.output_item.added")
      {|{"type":"response.output_item.added","output_index":0,"item":{"id":"fc_item_only","type":"function_call","name":"lookup","arguments":""}}|}
  in
  match events with
  | [ ContentBlockStart
        { index = 0; content_type = "tool_use"; tool_id = Some tool_id; _ }
    ] ->
    Alcotest.(check bool)
      "output item id is not reused as call identity"
      true
      (not (String.equal tool_id "fc_item_only"));
    Alcotest.(check bool)
      "id-less call receives OAS identity"
      true
      (String.starts_with ~prefix:"call_oas_" tool_id)
  | _ -> Alcotest.fail "expected one identified Responses tool start"
;;

let test_responses_stream_arguments_delta_preserves_call_id () =
  let state = S.create_openai_stream_state () in
  let events, _ =
    S.responses_sse_to_events
      state
      (Some "response.function_call_arguments.delta")
      {|{"type":"response.function_call_arguments.delta","output_index":0,"item_id":"fc_item","call_id":"call_native","delta":"{}"}|}
  in
  match events with
  | [ ContentBlockStart
        { index = 0
        ; content_type = "tool_use"
        ; tool_id = Some "call_native"
        ; tool_name = None
        }
    ; ContentBlockDelta { index = 0; delta = InputJsonDelta "{}" }
    ] -> ()
  | _ -> Alcotest.fail "expected delta call_id to identify its tool block"
;;

let test_responses_stream_hidden_reasoning_before_tool () =
  let state =
    S.create_openai_stream_state ~provider:"openai_compat" ~model:"gpt-5.5" ()
  in
  let events1, _ =
    S.responses_sse_to_events
      state
      (Some "response.output_item.added")
      {|{"type":"response.output_item.added","output_index":1,"item":{"id":"fc_1","type":"function_call","call_id":"call_lookup","name":"lookup","arguments":""}}|}
  in
  (match events1 with
   | [ ContentBlockStart { index = 1; content_type = "tool_use"; _ } ] -> ()
   | _ -> Alcotest.fail "expected tool block to keep Responses output_index");
  let events2, _ =
    S.responses_sse_to_events
      state
      (Some "response.function_call_arguments.delta")
      {|{"type":"response.function_call_arguments.delta","output_index":1,"item_id":"fc_1","delta":"{\"q\":\"weather\"}"}|}
  in
  (match events2 with
   | [ ContentBlockDelta { index = 1; delta = InputJsonDelta "{\"q\":\"weather\"}" } ] ->
     ()
   | _ -> Alcotest.fail "expected function arguments delta at output index 1");
  let events3, _ =
    S.responses_sse_to_events
      state
      (Some "response.completed")
      {|{"type":"response.completed","response":{"id":"resp_1","model":"gpt-5.5","status":"completed","output":[{"id":"rs_1","type":"reasoning","encrypted_content":"enc_hidden_1"},{"id":"fc_1","type":"function_call","call_id":"call_lookup","name":"lookup","arguments":"{\"q\":\"weather\"}"}],"usage":{"input_tokens":12,"output_tokens":8}}}|}
  in
  match events3 with
  | [ ContentBlockStart
        { index = 0
        ; content_type = "redacted_thinking"
        ; tool_id = Some raw_reasoning
        ; tool_name = None
        }
    ; MessageDelta { stop_reason = Some StopToolUse; usage = Some usage }
    ; MessageStop
    ] ->
    let reasoning = Yojson.Safe.from_string raw_reasoning in
    Alcotest.(check string)
      "encrypted reasoning"
      "enc_hidden_1"
      (Yojson.Safe.Util.member "encrypted_content" reasoning |> Yojson.Safe.Util.to_string);
    Alcotest.(check int) "input tokens" 12 usage.input_tokens;
    Alcotest.(check int) "output tokens" 8 usage.output_tokens
  | _ -> Alcotest.fail "expected hidden reasoning carrier before terminal"
;;

let test_responses_stream_interleaved_reasoning_tool_text_finalizes () =
  let module Acc = Llm_provider.Complete_stream_acc in
  let state =
    S.create_openai_stream_state ~provider:"openai_compat" ~model:"gpt-5.5" ()
  in
  let acc = Acc.create_stream_acc () in
  let feed evt_type data =
    let events, _ = S.responses_sse_to_events state (Some evt_type) data in
    List.iter (Acc.accumulate_event acc) events
  in
  feed
    "response.created"
    {|{"type":"response.created","response":{"id":"resp_1","model":"gpt-5.5","status":"in_progress","usage":null}}|};
  feed
    "response.reasoning_summary_text.delta"
    {|{"type":"response.reasoning_summary_text.delta","item_id":"rs_1","output_index":0,"summary_index":0,"delta":"Need "}|};
  feed
    "response.output_item.added"
    {|{"type":"response.output_item.added","output_index":1,"item":{"id":"fc_1","type":"function_call","call_id":"call_lookup","name":"lookup","arguments":""}}|};
  feed
    "response.function_call_arguments.delta"
    {|{"type":"response.function_call_arguments.delta","output_index":1,"item_id":"fc_1","delta":"{\"q\":"}|};
  feed
    "response.output_text.delta"
    {|{"type":"response.output_text.delta","output_index":2,"delta":"visible"}|};
  feed
    "response.reasoning_summary_text.delta"
    {|{"type":"response.reasoning_summary_text.delta","item_id":"rs_1","output_index":0,"summary_index":0,"delta":"lookup."}|};
  feed
    "response.function_call_arguments.delta"
    {|{"type":"response.function_call_arguments.delta","output_index":1,"item_id":"fc_1","delta":"\"weather\"}"}|};
  feed
    "response.completed"
    {|{"type":"response.completed","response":{"id":"resp_1","model":"gpt-5.5","status":"completed","output":[{"id":"rs_1","type":"reasoning","summary":[{"type":"summary_text","text":"Need lookup."}],"encrypted_content":"enc_reasoning_1"},{"id":"fc_1","type":"function_call","call_id":"call_lookup","name":"lookup","arguments":"{\"q\":\"weather\"}"},{"id":"msg_1","type":"message","content":[{"type":"output_text","text":"visible"}]}],"usage":{"input_tokens":12,"output_tokens":8,"input_tokens_details":{"cached_tokens":2}}}}|};
  match Acc.finalize_stream_acc acc with
  | Error _ -> Alcotest.fail "expected finalized Responses interleaved stream"
  | Ok response ->
    Alcotest.(check string) "id" "resp_1" response.id;
    Alcotest.(check string) "model" "gpt-5.5" response.model;
    Alcotest.(check bool) "stop reason" true (response.stop_reason = StopToolUse);
    (match response.content with
     | [ RedactedThinking raw_reasoning
       ; ToolUse { id = "call_lookup"; name = "lookup"; input }
       ; Text "visible"
       ] ->
       let reasoning = Yojson.Safe.from_string raw_reasoning in
       Alcotest.(check string)
         "reasoning type"
         "reasoning"
         (Yojson.Safe.Util.member "type" reasoning |> Yojson.Safe.Util.to_string);
       Alcotest.(check string)
         "encrypted reasoning"
         "enc_reasoning_1"
         (Yojson.Safe.Util.member "encrypted_content" reasoning
          |> Yojson.Safe.Util.to_string);
       Alcotest.(check bool) "tool args" true (input = `Assoc [ "q", `String "weather" ])
     | _ ->
       Alcotest.fail "expected reasoning carrier, tool use, and visible text separated");
    (match response.usage with
     | Some usage ->
       Alcotest.(check int) "input tokens" 12 usage.input_tokens;
       Alcotest.(check int) "output tokens" 8 usage.output_tokens;
       Alcotest.(check int) "cache read" 2 usage.cache_read_input_tokens
     | None -> Alcotest.fail "expected terminal usage")
;;

(* Regression for the Codex P2 streaming follow-up (#2073): a Responses stream
   that emits a [function_call] whose arguments even parse as JSON, then
   terminates with [response.incomplete] (max_output_tokens), must finalize as
   [MaxTokens] with NO ToolUse. The drop is status-aware (keyed on the truncated
   stop reason), not JSON-parse-based — proving the streaming path
   (responses_sse_to_events -> accumulator -> finalize) matches the non-streaming
   parser. *)
let test_responses_stream_incomplete_drops_partial_tool () =
  let module Acc = Llm_provider.Complete_stream_acc in
  let state =
    S.create_openai_stream_state ~provider:"openai_compat" ~model:"gpt-5.5" ()
  in
  let acc = Acc.create_stream_acc () in
  let feed evt_type data =
    let events, _ = S.responses_sse_to_events state (Some evt_type) data in
    List.iter (Acc.accumulate_event acc) events
  in
  feed
    "response.created"
    {|{"type":"response.created","response":{"id":"resp_1","model":"gpt-5.5","status":"in_progress"}}|};
  feed
    "response.output_item.added"
    {|{"type":"response.output_item.added","output_index":0,"item":{"id":"fc_1","type":"function_call","call_id":"call_1","name":"get_weather","arguments":""}}|};
  feed
    "response.function_call_arguments.delta"
    {|{"type":"response.function_call_arguments.delta","output_index":0,"item_id":"fc_1","delta":"{\"city\":\"Paris\"}"}|};
  feed
    "response.incomplete"
    {|{"type":"response.incomplete","response":{"id":"resp_1","model":"gpt-5.5","status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[{"id":"fc_1","type":"function_call","call_id":"call_1","name":"get_weather","arguments":"{\"city\":\"Paris\"}"}],"usage":{"input_tokens":12,"output_tokens":256}}}|};
  match Acc.finalize_stream_acc acc with
  | Error _ -> Alcotest.fail "expected Ok response for incomplete terminal"
  | Ok response ->
    Alcotest.(check bool)
      "incomplete max_output_tokens -> MaxTokens, not StopToolUse"
      true
      (response.stop_reason = MaxTokens);
    Alcotest.(check bool)
      "partial function_call dropped from streamed content"
      false
      (List.exists
         (function
           | ToolUse _ -> true
           | _ -> false)
         response.content)
;;

(* Companion to the max_output_tokens case: a [response.incomplete] for a
   non-token reason (content_filter) maps to [Unknown _], not [MaxTokens], yet the
   partial tool call must still be dropped. This proves the StreamIncomplete
   carry covers ALL incomplete reasons, not just MaxTokens. (#2073 follow-up.) *)
let test_responses_stream_incomplete_content_filter_drops_tool () =
  let module Acc = Llm_provider.Complete_stream_acc in
  let state =
    S.create_openai_stream_state ~provider:"openai_compat" ~model:"gpt-5.5" ()
  in
  let acc = Acc.create_stream_acc () in
  let feed evt_type data =
    let events, _ = S.responses_sse_to_events state (Some evt_type) data in
    List.iter (Acc.accumulate_event acc) events
  in
  feed
    "response.output_item.added"
    {|{"type":"response.output_item.added","output_index":0,"item":{"id":"fc_1","type":"function_call","call_id":"call_1","name":"get_weather","arguments":""}}|};
  feed
    "response.function_call_arguments.delta"
    {|{"type":"response.function_call_arguments.delta","output_index":0,"item_id":"fc_1","delta":"{\"city\":\"Paris\"}"}|};
  feed
    "response.incomplete"
    {|{"type":"response.incomplete","response":{"id":"resp_1","model":"gpt-5.5","status":"incomplete","incomplete_details":{"reason":"content_filter"},"output":[{"id":"fc_1","type":"function_call","call_id":"call_1","name":"get_weather","arguments":"{\"city\":\"Paris\"}"}],"usage":{"input_tokens":12,"output_tokens":8}}}|};
  match Acc.finalize_stream_acc acc with
  | Error _ -> Alcotest.fail "expected Ok response for incomplete terminal"
  | Ok response ->
    Alcotest.(check bool)
      "content_filter incomplete -> ContentFilter, not MaxTokens"
      true
      (response.stop_reason = ContentFilter);
    Alcotest.(check bool)
      "partial function_call dropped for non-token incomplete reason"
      false
      (List.exists
         (function
           | ToolUse _ -> true
           | _ -> false)
         response.content)
;;

(* ── tool-argument fail-closed (canonical accumulator) ───────────────────────
   The canonical [Complete_stream_acc] finalize path must not silently coerce a
   malformed tool-argument buffer to empty arguments. A non-empty buffer that
   fails to parse is a malformed tool call and surfaces a typed
   [Stream_parse_failed]; an empty buffer is the legitimate no-arguments case
   and yields [`Assoc []]. (RFC-OAS-029 S8: no silent permissive default.) *)
let malformed_tool_args_tag = "malformed_tool_use_arguments"

let test_stream_tool_args_malformed_fails_closed () =
  let module Acc = Llm_provider.Complete_stream_acc in
  let acc = Acc.create_stream_acc () in
  List.iter
    (Acc.accumulate_event acc)
    [ MessageStart { id = "m"; model = "m"; usage = None }
    ; ContentBlockStart
        { index = 0
        ; content_type = "tool_use"
        ; tool_id = Some "tu_bad"
        ; tool_name = Some "get_weather"
        }
    ; ContentBlockDelta { index = 0; delta = InputJsonDelta "not json{" }
    ; MessageDelta { stop_reason = Some StopToolUse; usage = None }
    ];
  match Acc.finalize_stream_acc acc with
  | Ok _ -> Alcotest.fail "expected Error: malformed tool arguments must fail closed"
  | Error (Stream_parse_failed { reason; _ }) ->
    Alcotest.(check bool)
      "reason identifies malformed tool arguments"
      true
      (String.starts_with ~prefix:malformed_tool_args_tag reason)
  | Error _ -> Alcotest.fail "expected Stream_parse_failed, got a different stream_error"
;;

let test_stream_tool_args_empty_is_no_args () =
  let module Acc = Llm_provider.Complete_stream_acc in
  let acc = Acc.create_stream_acc () in
  List.iter
    (Acc.accumulate_event acc)
    [ MessageStart { id = "m"; model = "m"; usage = None }
    ; ContentBlockStart
        { index = 0
        ; content_type = "tool_use"
        ; tool_id = Some "tu_empty"
        ; tool_name = Some "now"
        }
      (* no InputJsonDelta: the argument buffer stays empty *)
    ; MessageDelta { stop_reason = Some StopToolUse; usage = None }
    ];
  match Acc.finalize_stream_acc acc with
  | Error _ ->
    Alcotest.fail "expected Ok: empty arguments are the legitimate no-args case"
  | Ok response ->
    (match response.content with
     | [ ToolUse { id; name; input } ] ->
       Alcotest.(check string) "tool id preserved" "tu_empty" id;
       Alcotest.(check string) "tool name preserved" "now" name;
       Alcotest.(check string)
         "empty args -> empty object"
         "{}"
         (Yojson.Safe.to_string input)
     | _ -> Alcotest.fail "expected a single ToolUse block")
;;

let test_stream_tool_args_valid_parsed () =
  let module Acc = Llm_provider.Complete_stream_acc in
  let acc = Acc.create_stream_acc () in
  List.iter
    (Acc.accumulate_event acc)
    [ MessageStart { id = "m"; model = "m"; usage = None }
    ; ContentBlockStart
        { index = 0
        ; content_type = "tool_use"
        ; tool_id = Some "tu_ok"
        ; tool_name = Some "get_weather"
        }
    ; ContentBlockDelta { index = 0; delta = InputJsonDelta "{\"city\":" }
    ; ContentBlockDelta { index = 0; delta = InputJsonDelta "\"Paris\"}" }
    ; MessageDelta { stop_reason = Some StopToolUse; usage = None }
    ];
  match Acc.finalize_stream_acc acc with
  | Error _ -> Alcotest.fail "expected Ok for valid tool arguments"
  | Ok response ->
    (match response.content with
     | [ ToolUse { input; _ } ] ->
       Alcotest.(check string)
         "parsed args preserved verbatim"
         {|{"city":"Paris"}|}
         (Yojson.Safe.to_string input)
     | _ -> Alcotest.fail "expected a single ToolUse block")
;;

let parse_ollama_line_exn data =
  match S.parse_ollama_ndjson_chunk data with
  | S.Ollama_chunk chunk -> chunk
  | S.Ollama_provider_error { message; error_type; _ } ->
    Alcotest.failf
      "expected Ollama NDJSON stream chunk, got provider error message=%S type=%s"
      message
      (Option.value ~default:"<none>" error_type)
  | S.Ollama_parse_failed { reason; _ } ->
    Alcotest.failf
      "expected Ollama NDJSON stream chunk, got parse failure reason=%S"
      reason
;;

let test_ollama_native_interleaved_thinking_tool_text_finalizes () =
  let module Acc = Llm_provider.Complete_stream_acc in
  let state = S.create_openai_stream_state ~provider:"ollama" ~model:"qwen3.5:397b" () in
  let acc = Acc.create_stream_acc () in
  let feed line =
    let chunk = parse_ollama_line_exn line in
    let events, _ = S.ollama_chunk_to_events state chunk in
    List.iter (Acc.accumulate_event acc) events
  in
  feed
    {|{"model":"qwen3.5:397b","message":{"role":"assistant","thinking":"plan-"},"done":false}|};
  feed
    {|{"model":"qwen3.5:397b","message":{"role":"assistant","content":"visible"},"done":false}|};
  feed
    {|{"model":"qwen3.5:397b","message":{"role":"assistant","thinking":"done","tool_calls":[{"id":"call_1","function":{"name":"lookup","arguments":{"city":"Seoul"}}}]},"done":true,"done_reason":"tool_calls","prompt_eval_count":13,"eval_count":8}|};
  match Acc.finalize_stream_acc acc with
  | Error _ -> Alcotest.fail "expected finalized Ollama native stream"
  | Ok result ->
    Alcotest.(check bool) "stop reason" true (result.stop_reason = StopToolUse);
    (match result.usage with
     | Some usage ->
       Alcotest.(check int) "input tokens" 13 usage.input_tokens;
       Alcotest.(check int) "output tokens" 8 usage.output_tokens
     | None -> Alcotest.fail "expected done-line usage");
    (match result.content with
     | [ Thinking { content = "plan-done"; _ }
       ; Text "visible"
       ; ToolUse { id = "call_1"; name = "lookup"; input }
       ] ->
       Alcotest.(check bool) "tool args" true (input = `Assoc [ "city", `String "Seoul" ])
     | _ ->
       Alcotest.fail "expected thinking, visible text, and tool use to stay separated")
;;

let test_ollama_idless_tool_identity_matches_final_response () =
  let state = S.create_openai_stream_state ~provider:"ollama" ~model:"qwen" () in
  let chunk =
    parse_ollama_line_exn
      {|{"model":"qwen","message":{"role":"assistant","tool_calls":[{"function":{"name":"lookup","arguments":{"city":"Seoul"}}}]},"done":true,"done_reason":"tool_calls"}|}
  in
  let events, _ = S.ollama_chunk_to_events state chunk in
  let start_id =
    match events with
    | ContentBlockStart { content_type = "tool_use"; tool_id = Some id; _ } :: _ -> id
    | _ -> Alcotest.fail "expected Ollama id-less tool start to receive an identity"
  in
  let acc = Acc.create_stream_acc () in
  Acc.accumulate_event acc (MessageStart { id = "ollama"; model = "qwen"; usage = None });
  List.iter (Acc.accumulate_event acc) events;
  match Acc.finalize_stream_acc acc with
  | Ok { content = [ ToolUse { id; name = "lookup"; _ } ]; _ } ->
    Alcotest.(check string) "Ollama start and final identity" start_id id
  | Ok _ -> Alcotest.fail "expected one Ollama ToolUse"
  | Error _ -> Alcotest.fail "expected Ollama id-less tool stream to finalize"
;;

let test_ollama_idless_complete_calls_are_distinct_across_chunks () =
  let state = S.create_openai_stream_state ~provider:"ollama" ~model:"qwen" () in
  let acc = Acc.create_stream_acc () in
  Acc.accumulate_event acc (MessageStart { id = "ollama"; model = "qwen"; usage = None });
  let feed line =
    let chunk = parse_ollama_line_exn line in
    let events, _ = S.ollama_chunk_to_events state chunk in
    List.iter (Acc.accumulate_event acc) events
  in
  (* Both complete provider items occupy array index 0 in their own chunk.
     They are two call occurrences, not fragments of one call. *)
  feed
    {|{"model":"qwen","message":{"role":"assistant","tool_calls":[{"function":{"name":"lookup","arguments":{"city":"Seoul"}}}]},"done":false}|};
  feed
    {|{"model":"qwen","message":{"role":"assistant","tool_calls":[{"function":{"name":"lookup","arguments":{"city":"Seoul"}}}]},"done":true,"done_reason":"tool_calls"}|};
  match Acc.finalize_stream_acc acc with
  | Ok
      { content =
          [ ToolUse { id = first_id; name = "lookup"; input = first_input }
          ; ToolUse { id = second_id; name = "lookup"; input = second_input }
          ]
      ; _
      } ->
    Alcotest.(check bool) "occurrence ids differ" true (first_id <> second_id);
    Alcotest.(check bool)
      "first input"
      true
      (first_input = `Assoc [ "city", `String "Seoul" ]);
    Alcotest.(check bool)
      "second input"
      true
      (second_input = `Assoc [ "city", `String "Seoul" ])
  | Ok _ -> Alcotest.fail "expected two distinct id-less Ollama ToolUse occurrences"
  | Error _ -> Alcotest.fail "expected complete id-less occurrences to finalize"
;;

let () =
  let open Alcotest in
  run
    "streaming_openai"
    [ ( "parse_openai_sse_chunk"
      , [ test_case "text chunk" `Quick test_parse_text_chunk
        ; test_case "[DONE] sentinel" `Quick test_parse_done_sentinel
        ; test_case "finish_reason" `Quick test_parse_finish_reason
        ; test_case "tool_call start" `Quick test_parse_tool_call_start
        ; test_case "tool_call args" `Quick test_parse_tool_call_args
        ; test_case "usage" `Quick test_parse_usage
        ; test_case "invalid JSON" `Quick test_parse_invalid_json
        ; test_case "empty choices" `Quick test_parse_empty_choices
        ; test_case "reasoning_content" `Quick test_parse_reasoning_chunk
        ; test_case
            "ollama reasoning fallback"
            `Quick
            test_parse_ollama_reasoning_fallback
        ; test_case
            "reasoning_content preferred"
            `Quick
            test_parse_reasoning_content_preferred
        ; test_case
            "blank reasoning_content falls back"
            `Quick
            test_parse_blank_reasoning_content_falls_back
        ; test_case
            "reasoning dialect field"
            `Quick
            test_parse_reasoning_uses_dialect_delta_field
        ; test_case
            "no streaming reasoning dialect"
            `Quick
            test_parse_reasoning_respects_no_streaming_dialect
        ; test_case
            "minimax split reasoning details"
            `Quick
            test_parse_minimax_split_reasoning_details
        ; test_case
            "minimax split malformed details"
            `Quick
            test_parse_minimax_split_malformed_details_fails_closed
        ; test_case
            "minimax split malformed detail item"
            `Quick
            test_parse_minimax_split_malformed_detail_item_fails_closed
        ] )
    ; ( "openai_chunk_to_events"
      , [ test_case "text first chunk" `Quick test_events_text_first_chunk
        ; test_case "text subsequent" `Quick test_events_text_subsequent
        ; test_case "tool_call" `Quick test_events_tool_call
        ; test_case
            "id-less start identity equals finalized ToolUse"
            `Quick
            test_events_idless_tool_identity_matches_final_response
        ; test_case
            "id-less identities differ across streams"
            `Quick
            test_events_idless_tool_ids_are_unique_across_streams
        ; test_case
            "parallel id-less identities stay distinct"
            `Quick
            test_events_parallel_idless_tool_ids_are_distinct
        ; test_case
            "late provider identity fails closed"
            `Quick
            test_events_late_provider_tool_id_fails_closed
        ; test_case "finish stop" `Quick test_events_finish_reason
        ; test_case "finish tool_calls" `Quick test_events_tool_calls_finish
        ; test_case
            "finish closes open tool block"
            `Quick
            test_events_finish_closes_open_tool_block
        ; test_case "finish length" `Quick test_events_length_finish
        ; test_case "empty content ignored" `Quick test_events_empty_content_ignored
        ; test_case "reasoning then text" `Quick test_events_reasoning_then_text
        ; test_case
            "reasoning delta index multi-chunk (#332)"
            `Quick
            test_events_reasoning_delta_index_multi_chunk
        ; test_case "tool-first then text (#333)" `Quick test_events_tool_first_then_text
        ; test_case "multi-tool then text (#333)" `Quick test_events_multi_tool_then_text
        ; test_case "thinking + tool + text (#333)" `Quick test_events_thinking_tool_text
        ; test_case
            "reasoning details accumulates typed"
            `Quick
            test_events_reasoning_details_accumulates_typed
        ] )
    ; ( "responses_sse_to_events"
      , [ test_case
            "non-object frame is a typed parse failure"
            `Quick
            test_responses_non_object_frame_is_parse_failure
        ; test_case
            "reasoning tool and terminal"
            `Quick
            test_responses_stream_reasoning_tool_and_terminal
        ; test_case
            "hidden reasoning before tool"
            `Quick
            test_responses_stream_hidden_reasoning_before_tool
        ; test_case
            "id-less start identity equals finalized ToolUse"
            `Quick
            test_responses_stream_idless_tool_identity_matches_final_response
        ; test_case
            "item id is not tool identity"
            `Quick
            test_responses_stream_item_id_is_not_tool_identity
        ; test_case
            "arguments delta preserves call id"
            `Quick
            test_responses_stream_arguments_delta_preserves_call_id
        ; test_case
            "interleaved reasoning/tool/text finalizes"
            `Quick
            test_responses_stream_interleaved_reasoning_tool_text_finalizes
        ; test_case
            "incomplete drops partial tool (#2073)"
            `Quick
            test_responses_stream_incomplete_drops_partial_tool
        ; test_case
            "incomplete content_filter drops tool (#2073)"
            `Quick
            test_responses_stream_incomplete_content_filter_drops_tool
        ] )
    ; ( "tool_args_failclosed"
      , [ test_case
            "malformed args -> typed Stream_parse_failed"
            `Quick
            test_stream_tool_args_malformed_fails_closed
        ; test_case
            "empty args -> empty object (no-args)"
            `Quick
            test_stream_tool_args_empty_is_no_args
        ; test_case
            "valid args -> parsed verbatim"
            `Quick
            test_stream_tool_args_valid_parsed
        ] )
    ; ( "ollama_ndjson_to_events"
      , [ test_case
            "native interleaved thinking/tool/text finalizes"
            `Quick
            test_ollama_native_interleaved_thinking_tool_text_finalizes
        ; test_case
            "id-less start identity equals finalized ToolUse"
            `Quick
            test_ollama_idless_tool_identity_matches_final_response
        ; test_case
            "id-less complete calls stay distinct across chunks"
            `Quick
            test_ollama_idless_complete_calls_are_distinct_across_chunks
        ] )
    ]
;;
