(* See ollama_stream.mli for module rationale. *)

open Types
open Openai_wire
open Openai_stream_state
open Ollama_wire

(** Convert a parsed {!Ollama_wire.ollama_chunk} into {!sse_event} list.
    Reuses {!openai_stream_state} for block index tracking. *)
let ollama_chunk_to_events (state : openai_stream_state) (chunk : ollama_chunk)
  : sse_event list * Telemetry_event.t option
  =
  let events = ref [] in
  let emit evt = events := evt :: !events in
  let telemetry_event = ref None in
  let emit_thinking_delta text =
    (match state.thinking_state with
     | Not_thinking -> state.thinking_state <- Thinking_started (Unix.gettimeofday ())
     | Thinking_started _ | Thinking_done -> ());
    if not state.thinking_block_started
    then (
      state.thinking_block_index <- state.next_block_index;
      emit
        (ContentBlockStart
           { index = state.next_block_index
           ; content_type = "thinking"
           ; tool_id = None
           ; tool_name = None
           });
      state.thinking_block_started <- true;
      state.next_block_index <- state.next_block_index + 1);
    emit
      (ContentBlockDelta
         { index = state.thinking_block_index; delta = ThinkingDelta text })
  in
  let emit_text_delta text =
    if not state.text_block_started
    then (
      state.text_block_index <- state.next_block_index;
      emit
        (ContentBlockStart
           { index = state.next_block_index
           ; content_type = "text"
           ; tool_id = None
           ; tool_name = None
           });
      state.text_block_started <- true;
      state.next_block_index <- state.next_block_index + 1);
    emit (ContentBlockDelta { index = state.text_block_index; delta = TextDelta text })
  in
  (* Thinking content delta *)
  (match chunk.oll_delta_thinking with
   | Some text when text <> "" -> emit_thinking_delta text
   | Some empty_thinking ->
     let (_ : string) = empty_thinking in
     (match state.thinking_state with
      | Thinking_started t0 ->
        let thinking_duration_ms = (Unix.gettimeofday () -. t0) *. 1000.0 in
        state.thinking_state <- Thinking_done;
        telemetry_event
        := Some
             (Telemetry_event.Thinking_complete
                { provider = state.provider; model = state.model; thinking_duration_ms })
      | Not_thinking | Thinking_done -> ())
   | None ->
     (match state.thinking_state with
      | Thinking_started t0 ->
        let thinking_duration_ms = (Unix.gettimeofday () -. t0) *. 1000.0 in
        state.thinking_state <- Thinking_done;
        telemetry_event
        := Some
             (Telemetry_event.Thinking_complete
                { provider = state.provider; model = state.model; thinking_duration_ms })
      | Not_thinking | Thinking_done -> ()));
  (* Text content delta. A template-parser model puts reasoning in this
     channel wrapped in tags; split it the way the OpenAI-compatible
     projection does so the reply block carries the reply and nothing else. *)
  (match chunk.oll_delta_content with
   | Some text when text <> "" ->
     (match state.inline_reasoning with
      | None -> emit_text_delta text
      | Some split ->
        emit_inline_segments state emit (Inline_reasoning_split.feed_segments split text))
   | Some empty_text ->
     let (_ : string) = empty_text in
     ()
   | None -> ());
  (* Tool calls. Ollama native streams can emit complete calls in separate
     chunks; each chunk's JSON array restarts its positional index. Therefore
     an id-less [Args_complete] item is a new occurrence even when a prior
     chunk used the same array index. String argument fragments remain routed
     by wire index until their call completes. *)
  List.iter
    (fun (tc : ollama_tool_call_delta) ->
       let idless_semantics =
         match non_blank_provider_tool_id tc.oll_tc_id, tc.oll_tc_arguments with
         | Some _, (Some (Args_fragment _ | Args_complete _) | None) ->
           Continue_by_wire_index
         | None, Some (Args_complete _) -> Complete_occurrence
         | None, (Some (Args_fragment _) | None) -> Continue_by_wire_index
       in
       let block_idx =
         resolve_tool_block
           state
           ~protocol:"ollama"
           ~wire_index:tc.oll_tc_index
           ~provider_tool_id:tc.oll_tc_id
           ~tool_name:tc.oll_tc_name
           ~index_policy:Next_available
           ~idless_semantics
       in
       let resolution, start = block_idx in
       Option.iter emit start;
       match resolution, tc.oll_tc_arguments with
       | Tool_block_resolved { block_index; _ }, Some (Args_fragment args) when args <> ""
         -> emit (ContentBlockDelta { index = block_index; delta = InputJsonDelta args })
       | Tool_block_resolved { block_index; _ }, Some (Args_complete args) when args <> ""
         ->
         emit (ContentBlockDelta { index = block_index; delta = InputJsonSnapshot args })
       | Tool_block_resolved _, Some (Args_fragment _ | Args_complete _)
       | Tool_block_resolved _, None -> ()
       | Tool_block_rejected error, _ -> emit error)
    chunk.oll_tool_calls;
  (* Terminal chunk: emit MessageDelta with stop_reason + usage. *)
  if chunk.oll_is_done
  then (
    (* Bytes the inline-reasoning splitter was holding back belong to this
       message; an unterminated tag means the stream was cut mid-thought.
       Paths that never see a done chunk (provider error, truncated stream)
       retain an incomplete outcome. Previously emitted deltas are already
       observable; terminal validation cannot retract them. *)
    (match state.inline_reasoning with
     | None -> ()
     | Some split ->
       emit_inline_segments state emit (Inline_reasoning_split.flush_segments split));
    let stop_reason =
      match chunk.oll_done_reason with
      (* Non-streaming parsing can reject before returning content. Streaming
         may already have delivered deltas, so absence stays [None] and the
         accumulator returns typed [Stream_incomplete] at finalization. *)
      | None -> None
      | Some reason ->
        Some
          (Stop_reason_wire.of_finish
             (Stop_reason_wire.wire_finish_of_string reason)
             ~has_tool_blocks:(chunk.oll_tool_calls <> []))
    in
    List.iter emit (openai_open_block_stops state);
    emit
      (MessageDelta
         { stop_reason
         ; usage =
             Option.map
               (fun (u : Types.api_usage) : Types.delta_usage ->
                  { input_tokens = Some u.input_tokens
                  ; output_tokens = Some u.output_tokens
                  ; cache_creation_input_tokens = None
                  ; cache_read_input_tokens = None
                  ; cost_usd = u.cost_usd
                  })
               chunk.oll_usage
         });
    emit MessageStop);
  List.rev !events, !telemetry_event
;;

[@@@coverage off]
(* ── ollama_chunk_to_events tests ─────────────────────────── *)

(* Inline-test-only helpers. [Streaming] has the same two for its OpenAI tests. *)
let[@warning "-32"] test_thinking_text = function
  | ContentBlockDelta { delta = ThinkingDelta s | ThinkingSnapshot s; _ } -> Some s
  | ContentBlockDelta { delta = (TextDelta _ | (TextSnapshot _ | (ThinkingSignatureDelta _ | (RedactedThinkingSnapshot _ | (ReasoningDetailsDelta _ | (InputJsonDelta _ | (InputJsonSnapshot _ | MediaDelta _)))))));_}
  | MessageStop | InlineContentReplay _ | ResponsesOutputItems _ | Ping | Connected | MessageStart _ | ContentBlockStart _ | ContentBlockStop _
  | MessageDelta _ | SSEError _ | NDJSONError _ | SSEParseFailed _ | NDJSONParseFailed _
  | SSEUnknownEventType _ | SSEUnsupportedPart _ | SSEUnsupportedResponse _ | Timeout _
  | StreamIncomplete _ -> None
;;

let[@warning "-32"] test_reply_text = function
  | ContentBlockDelta { delta = TextDelta s; _ } -> Some s
  | ContentBlockDelta { delta = (TextSnapshot _ | ((ThinkingDelta _ | ThinkingSnapshot _) | (ThinkingSignatureDelta _ | (RedactedThinkingSnapshot _ | (ReasoningDetailsDelta _ | (InputJsonDelta _ | (InputJsonSnapshot _ | MediaDelta _)))))));_}
  | MessageStop | InlineContentReplay _ | ResponsesOutputItems _ | Ping | Connected | MessageStart _ | ContentBlockStart _ | ContentBlockStop _
  | MessageDelta _ | SSEError _ | NDJSONError _ | SSEParseFailed _ | NDJSONParseFailed _
  | SSEUnknownEventType _ | SSEUnsupportedPart _ | SSEUnsupportedResponse _ | Timeout _
  | StreamIncomplete _ -> None
;;

let%test "ollama_chunk_to_events: content delta emits Start+Delta" =
  let state = create_openai_stream_state () in
  let chunk =
    { oll_model = "qwen3:8b"
    ; oll_delta_content = Some "hello"
    ; oll_delta_thinking = None
    ; oll_tool_calls = []
    ; oll_done_reason = None
    ; oll_is_done = false
    ; oll_usage = None
    ; oll_timings = None
    }
  in
  let events, _tel = ollama_chunk_to_events state chunk in
  match events with
  | [ ContentBlockStart { index = 0; content_type = "text"; _ }
    ; ContentBlockDelta { index = 0; delta = TextDelta "hello" }
    ] -> true
  | []
  | [ ( MessageStart _
      | ContentBlockStart _
      | ContentBlockDelta
          { delta =
              ( TextDelta _
              | TextSnapshot _
              | (ThinkingDelta _ | ThinkingSnapshot _)
              | ThinkingSignatureDelta _
              | RedactedThinkingSnapshot _
              | ReasoningDetailsDelta _
              | InputJsonDelta _
              | InputJsonSnapshot _
              | MediaDelta _ )
          ; _
          }
      | ContentBlockStop _
      | MessageDelta
          { stop_reason =
              ( None
              | Some
                  ( EndTurn
                  | StopToolUse
                  | MaxTokens
                  | StopSequence
                  | Refusal
                  | ContentFilter
                  | RepetitionTruncation
                  | PauseTurn
                  | Compaction
                  | ContextWindowExceeded
                  | UnmatchedToolCalls
                  | Unknown _ ) )
          ; _
          }
      | MessageStop
      | InlineContentReplay _ | ResponsesOutputItems _ | Ping
      | SSEError _
      | NDJSONError _
      | SSEParseFailed _
      | NDJSONParseFailed _
      | SSEUnknownEventType _
      | SSEUnsupportedPart _
      | SSEUnsupportedResponse _
      | Connected
      | Timeout _
      | StreamIncomplete _
       )
    ]
  | _ :: _ :: _ -> false
;;

let%test "ollama_chunk_to_events: subsequent content delta reuses block" =
  let state = create_openai_stream_state () in
  let mk text =
    { oll_model = "qwen3:8b"
    ; oll_delta_content = Some text
    ; oll_delta_thinking = None
    ; oll_tool_calls = []
    ; oll_done_reason = None
    ; oll_is_done = false
    ; oll_usage = None
    ; oll_timings = None
    }
  in
  let _ = ollama_chunk_to_events state (mk "he") in
  let events, _tel = ollama_chunk_to_events state (mk "llo") in
  (* Second chunk: only Delta, no new Start *)
  match events with
  | [ ContentBlockDelta { index = 0; delta = TextDelta "llo" } ] -> true
  | []
  | [ ( MessageStart _
      | ContentBlockStart _
      | ContentBlockDelta
          { delta =
              ( TextDelta _
              | TextSnapshot _
              | (ThinkingDelta _ | ThinkingSnapshot _)
              | ThinkingSignatureDelta _
              | RedactedThinkingSnapshot _
              | ReasoningDetailsDelta _
              | InputJsonDelta _
              | InputJsonSnapshot _
              | MediaDelta _ )
          ; _
          }
      | ContentBlockStop _
      | MessageDelta
          { stop_reason =
              ( None
              | Some
                  ( EndTurn
                  | StopToolUse
                  | MaxTokens
                  | StopSequence
                  | Refusal
                  | ContentFilter
                  | RepetitionTruncation
                  | PauseTurn
                  | Compaction
                  | ContextWindowExceeded
                  | UnmatchedToolCalls
                  | Unknown _ ) )
          ; _
          }
      | MessageStop
      | InlineContentReplay _ | ResponsesOutputItems _ | Ping
      | SSEError _
      | NDJSONError _
      | SSEParseFailed _
      | NDJSONParseFailed _
      | SSEUnknownEventType _
      | SSEUnsupportedPart _
      | SSEUnsupportedResponse _
      | Connected
      | Timeout _
      | StreamIncomplete _
       )
    ]
  | _ :: _ :: _ -> false
;;

let%test "ollama_chunk_to_events: done with stop_reason emits MessageDelta" =
  let state = create_openai_stream_state () in
  let chunk =
    { oll_model = "qwen3:8b"
    ; oll_delta_content = None
    ; oll_delta_thinking = None
    ; oll_tool_calls = []
    ; oll_done_reason = Some "stop"
    ; oll_is_done = true
    ; oll_usage =
        Some
          { input_tokens = 10
          ; output_tokens = 20
          ; cache_creation_input_tokens = 0
          ; cache_read_input_tokens = 0
          ; cost_usd = None
          }
    ; oll_timings = None
    }
  in
  let events, _tel = ollama_chunk_to_events state chunk in
  match events with
  | [ MessageDelta { stop_reason = Some EndTurn; usage = Some u }; MessageStop ] ->
    u.input_tokens = Some 10 && u.output_tokens = Some 20
  | []
  | [ ( MessageStart _
      | ContentBlockStart _
      | ContentBlockDelta
          { delta =
              ( TextDelta _
              | TextSnapshot _
              | (ThinkingDelta _ | ThinkingSnapshot _)
              | ThinkingSignatureDelta _
              | RedactedThinkingSnapshot _
              | ReasoningDetailsDelta _
              | InputJsonDelta _
              | InputJsonSnapshot _
              | MediaDelta _ )
          ; _
          }
      | ContentBlockStop _
      | MessageDelta
          { stop_reason =
              ( None
              | Some
                  ( EndTurn
                  | StopToolUse
                  | MaxTokens
                  | StopSequence
                  | Refusal
                  | ContentFilter
                  | RepetitionTruncation
                  | PauseTurn
                  | Compaction
                  | ContextWindowExceeded
                  | UnmatchedToolCalls
                  | Unknown _ ) )
          ; _
          }
      | MessageStop
      | InlineContentReplay _ | ResponsesOutputItems _ | Ping
      | SSEError _
      | NDJSONError _
      | SSEParseFailed _
      | NDJSONParseFailed _
      | SSEUnknownEventType _
      | SSEUnsupportedPart _
      | SSEUnsupportedResponse _
      | Connected
      | Timeout _
      | StreamIncomplete _
       )
    ]
  | _ :: _ :: _ -> false
;;

let%test "ollama_chunk_to_events: overflow reason stays typed" =
  let state = create_openai_stream_state () in
  let chunk : ollama_chunk =
    { oll_model = "qwen3:8b"
    ; oll_delta_content = None
    ; oll_delta_thinking = None
    ; oll_tool_calls = []
    ; oll_done_reason = Some "model_context_window_exceeded"
    ; oll_is_done = true
    ; oll_usage = None
    ; oll_timings = None
    }
  in
  match fst (ollama_chunk_to_events state chunk) with
  | [ MessageDelta { stop_reason = Some ContextWindowExceeded; usage = None }
    ; MessageStop
    ] -> true
  | (MessageDelta { stop_reason = Some (ContextWindowExceeded); usage = None })::(MessageStop)::_::_
  | (MessageDelta { stop_reason = Some (ContextWindowExceeded); usage = None })::(InlineContentReplay _ | ResponsesOutputItems _ | Ping | ( Connected | ( MessageStart _ | ( ContentBlockStart _ | ( ContentBlockDelta _ | ( ContentBlockStop _ | ( MessageDelta _ | ( SSEError _ | ( NDJSONError _ | ( SSEParseFailed _ | ( NDJSONParseFailed _ | ( SSEUnknownEventType _ | ( SSEUnsupportedPart _ | ( SSEUnsupportedResponse _ | ( Timeout _ | ( StreamIncomplete _ ))))))))))))))))::_
  | (MessageDelta { stop_reason = Some (ContextWindowExceeded); usage = None })::[]
  | (MessageDelta { stop_reason = Some (ContextWindowExceeded); usage = Some _ })::_
  | (MessageDelta { stop_reason = Some (EndTurn | (StopToolUse | (MaxTokens | (StopSequence | (Refusal | (ContentFilter | (RepetitionTruncation | (PauseTurn | (Compaction | (UnmatchedToolCalls | Unknown _)))))))))); usage = _ })::_
  | (MessageDelta { stop_reason = None; usage = _ })::_
  | (MessageStop | (InlineContentReplay _ | ResponsesOutputItems _ | Ping | (Connected | (MessageStart _ | (ContentBlockStart _ | (ContentBlockDelta _ | (ContentBlockStop _ | (SSEError _ | (NDJSONError _ | (SSEParseFailed _ | (NDJSONParseFailed _ | (SSEUnknownEventType _ | (SSEUnsupportedPart _ | (SSEUnsupportedResponse _ | (Timeout _ | (StreamIncomplete _ ))))))))))))))))::_
  | [] -> false
;;

let%test "ollama_chunk_to_events: done with zero usage → usage=None" =
  let state = create_openai_stream_state () in
  let chunk =
    { oll_model = "qwen3:8b"
    ; oll_delta_content = None
    ; oll_delta_thinking = None
    ; oll_tool_calls = []
    ; oll_done_reason = Some "stop"
    ; oll_is_done = true
    ; oll_usage = None
    ; oll_timings = None
    }
  in
  let events, _tel = ollama_chunk_to_events state chunk in
  match events with
  | [ MessageDelta { stop_reason = Some EndTurn; usage = None }; MessageStop ] -> true
  | ((MessageDelta { stop_reason = Some (EndTurn); usage = None })::(MessageStop)::_::_ | (MessageDelta { stop_reason = Some (EndTurn); usage = None })::(InlineContentReplay _ | ResponsesOutputItems _ | Ping | (Connected | (MessageStart _ | (ContentBlockStart _ | (ContentBlockDelta _ | ( ContentBlockStop _ | ( MessageDelta _ | ( SSEError _ | ( NDJSONError _ | ( SSEParseFailed _ | ( NDJSONParseFailed _ | ( SSEUnknownEventType _ | ( SSEUnsupportedPart _ | ( SSEUnsupportedResponse _ | ( Timeout _ | ( StreamIncomplete _ ))))))))))))))))::_ | (MessageDelta { stop_reason = Some (EndTurn); usage = None })::[] | (MessageDelta { stop_reason = Some (EndTurn); usage = Some _ })::_ | (MessageDelta { stop_reason = Some (StopToolUse | (MaxTokens | (StopSequence | (Refusal | (ContentFilter | (RepetitionTruncation | (PauseTurn | (Compaction | (ContextWindowExceeded | (UnmatchedToolCalls | Unknown _)))))))))); usage = _ })::_ | (MessageDelta { stop_reason = None; usage = _ })::_ | (MessageStop | (InlineContentReplay _ | ResponsesOutputItems _ | Ping | (Connected | (MessageStart _ | (ContentBlockStart _ | (ContentBlockDelta _ | (ContentBlockStop _ | (SSEError _ | (NDJSONError _ | (SSEParseFailed _ | (NDJSONParseFailed _ | (SSEUnknownEventType _ | (SSEUnsupportedPart _ | (SSEUnsupportedResponse _ | (Timeout _ | (StreamIncomplete _ ))))))))))))))))::_ | []) as unexpected_events -> let (_ : sse_event list) = unexpected_events in
    false
;;

let%test "ollama_chunk_to_events: tool_calls emit Start+InputJsonSnapshot" =
  let state = create_openai_stream_state () in
  let chunk =
    { oll_model = "qwen3:8b"
    ; oll_delta_content = None
    ; oll_delta_thinking = None
    ; oll_tool_calls =
        [ { oll_tc_index = 0
          ; oll_tc_id = None
          ; oll_tc_name = Some "search"
          ; oll_tc_arguments = Some (Args_complete {|{"q":"hello"}|})
          }
        ]
    ; oll_done_reason = Some "tool_calls"
    ; oll_is_done = true
    ; oll_usage = None
    ; oll_timings = None
    }
  in
  let events, _tel = ollama_chunk_to_events state chunk in
  match events with
  | [ ContentBlockStart
        { index = 0
        ; content_type = "tool_use"
        ; tool_id = Some tool_id
        ; tool_name = Some "search"
        }
    ; ContentBlockDelta { index = 0; delta = InputJsonSnapshot args }
      (* [openai_open_block_stops] closes every block this state opened once the
         terminal chunk arrives, so the tool block's stop belongs between the
         arguments and the message end. *)
    ; ContentBlockStop { index = 0 }
    ; MessageDelta { stop_reason = Some StopToolUse; _ }
    ; MessageStop
    ] -> String.starts_with ~prefix:"call_agent_core_" tool_id && args = {|{"q":"hello"}|}
  | []
  | [ ( MessageStart _
      | ContentBlockStart _
      | ContentBlockDelta
          { delta =
              ( TextDelta _
              | TextSnapshot _
              | (ThinkingDelta _ | ThinkingSnapshot _)
              | ThinkingSignatureDelta _
              | RedactedThinkingSnapshot _
              | ReasoningDetailsDelta _
              | InputJsonDelta _
              | InputJsonSnapshot _
              | MediaDelta _ )
          ; _
          }
      | ContentBlockStop _
      | MessageDelta
          { stop_reason =
              ( None
              | Some
                  ( EndTurn
                  | StopToolUse
                  | MaxTokens
                  | StopSequence
                  | Refusal
                  | ContentFilter
                  | RepetitionTruncation
                  | PauseTurn
                  | Compaction
                  | ContextWindowExceeded
                  | UnmatchedToolCalls
                  | Unknown _ ) )
          ; _
          }
      | MessageStop
      | InlineContentReplay _ | ResponsesOutputItems _ | Ping
      | SSEError _
      | NDJSONError _
      | SSEParseFailed _
      | NDJSONParseFailed _
      | SSEUnknownEventType _
      | SSEUnsupportedPart _
      | SSEUnsupportedResponse _
      | Connected
      | Timeout _
      | StreamIncomplete _
       )
    ]
  | _ :: _ :: _ -> false
;;

let%test "ollama_chunk_to_events: thinking delta emits thinking block first" =
  let state = create_openai_stream_state () in
  let chunk =
    { oll_model = "qwen3:8b"
    ; oll_delta_content = None
    ; oll_delta_thinking = Some "considering"
    ; oll_tool_calls = []
    ; oll_done_reason = None
    ; oll_is_done = false
    ; oll_usage = None
    ; oll_timings = None
    }
  in
  let events, _tel = ollama_chunk_to_events state chunk in
  match events with
  | [ ContentBlockStart { index = 0; content_type = "thinking"; _ }
    ; ContentBlockDelta { index = 0; delta = ThinkingDelta "considering" }
    ] -> true
  | []
  | [ ( MessageStart _
      | ContentBlockStart _
      | ContentBlockDelta
          { delta =
              ( TextDelta _
              | TextSnapshot _
              | (ThinkingDelta _ | ThinkingSnapshot _)
              | ThinkingSignatureDelta _
              | RedactedThinkingSnapshot _
              | ReasoningDetailsDelta _
              | InputJsonDelta _
              | InputJsonSnapshot _
              | MediaDelta _ )
          ; _
          }
      | ContentBlockStop _
      | MessageDelta
          { stop_reason =
              ( None
              | Some
                  ( EndTurn
                  | StopToolUse
                  | MaxTokens
                  | StopSequence
                  | Refusal
                  | ContentFilter
                  | RepetitionTruncation
                  | PauseTurn
                  | Compaction
                  | ContextWindowExceeded
                  | UnmatchedToolCalls
                  | Unknown _ ) )
          ; _
          }
      | MessageStop
      | InlineContentReplay _ | ResponsesOutputItems _ | Ping
      | SSEError _
      | NDJSONError _
      | SSEParseFailed _
      | NDJSONParseFailed _
      | SSEUnknownEventType _
      | SSEUnsupportedPart _
      | SSEUnsupportedResponse _
      | Connected
      | Timeout _
      | StreamIncomplete _
       )
    ]
  | _ :: _ :: _ -> false
;;

let%test "ollama_chunk_to_events: inline think tags split across chunks stay out of the \
          reply"
  =
  (* An ollama-served template model that ignores think:false renders
     <think>...</think> inside [message.content]; a declared template model
     splits it here, tags fragmented across chunk boundaries included. *)
  let state = create_openai_stream_state ~inline_reasoning:true () in
  let feed content =
    let line =
      Printf.sprintf
        {|{"model":"qwen3:8b","message":{"role":"assistant","content":"%s"},"done":false}|}
        content
    in
    match parse_ollama_ndjson_chunk line with
    | Ollama_chunk chunk -> fst (ollama_chunk_to_events state chunk)
    | Ollama_provider_error _ | Ollama_parse_failed _ -> []
  in
  (* Bound in order: [@] does not fix the order its arguments are evaluated in,
     and a stream fed backwards proves nothing. *)
  let first = feed "<thi" in
  let second = feed "nk>mid</th" in
  let third = feed "ink>answer" in
  let events = first @ second @ third in
  List.filter_map test_thinking_text events = [ "mid" ]
  && List.filter_map test_reply_text events = [ "answer" ]
;;

let%test "ollama_chunk_to_events: a cut thought is released as reasoning at done" =
  let state = create_openai_stream_state ~inline_reasoning:true () in
  let feed line =
    match parse_ollama_ndjson_chunk line with
    | Ollama_chunk chunk -> fst (ollama_chunk_to_events state chunk)
    | Ollama_provider_error _ | Ollama_parse_failed _ -> []
  in
  let opened =
    feed
      {|{"model":"qwen3:8b","message":{"role":"assistant","content":"<think>cut off"},"done":false}|}
  in
  let terminal =
    feed
      {|{"model":"qwen3:8b","message":{"role":"assistant","content":""},"done":true,"done_reason":"stop"}|}
  in
  let events = opened @ terminal in
  List.filter_map test_thinking_text events = [ "cut off" ]
  && List.filter_map test_reply_text events = []
;;

let%test "ollama_chunk_to_events: text resuming after a think block stays well-formed"
  =
  (* Each channel transition opens a fresh index, preserving the original
     order in both the live deltas and the final indexed block sequence. *)
  let state = create_openai_stream_state ~inline_reasoning:true () in
  let feed content =
    let line =
      Printf.sprintf
        {|{"model":"qwen3:8b","message":{"role":"assistant","content":"%s"},"done":false}|}
        content
    in
    match parse_ollama_ndjson_chunk line with
    | Ollama_chunk chunk -> fst (ollama_chunk_to_events state chunk)
    | Ollama_provider_error _ | Ollama_parse_failed _ -> []
  in
  let first = feed "answer " in
  let second = feed "<think>more</think>" in
  let third = feed " tail" in
  let events = first @ second @ third in
  let starts =
    List.filter_map
      (function
        | ContentBlockStart { index; content_type; _ } -> Some (index, content_type)
        | MessageStop | InlineContentReplay _ | ResponsesOutputItems _ | Ping | Connected | MessageStart _ | ContentBlockDelta _ | ContentBlockStop _
        | MessageDelta _ | SSEError _ | NDJSONError _ | SSEParseFailed _ | NDJSONParseFailed _
        | SSEUnknownEventType _ | SSEUnsupportedPart _ | SSEUnsupportedResponse _ | Timeout _
        | StreamIncomplete _ -> None)
      events
  in
  List.filter_map test_thinking_text events = [ "more" ]
  && List.filter_map test_reply_text events = [ "answer "; " tail" ]
  && starts = [ 0, "text"; 1, "thinking"; 2, "text" ]
;;
