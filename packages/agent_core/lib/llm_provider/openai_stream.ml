(* See openai_stream.mli for module rationale. *)

open Types
open Openai_wire
open Openai_stream_state

(** Project one parsed chunk into locally buffered events. Tool route failures
    remain typed so the caller can roll back tool-bearing chunks before any
    event escapes. *)
let project_openai_chunk ?tx (state : openai_stream_state) (chunk : openai_chunk)
  : (sse_event list * Telemetry_event.t option, sse_event) result
  =
  let events = ref [] in
  let emit evt = events := evt :: !events in
  let telemetry_event = ref None in
  state.refusal_seen <- state.refusal_seen || chunk.delta_refusal;
  (* Reasoning content delta — emitted before text *)
  let emit_thinking_delta text =
    (match state.thinking_state with
     | Not_thinking -> state.thinking_state <- Thinking_started (Unix.gettimeofday ())
     | Thinking_started _ | Thinking_done ->
       (* Already started, or model is re-emitting reasoning after a
          closure — keep current state. Enumerated explicitly so adding
          a new [thinking_state] variant forces review of how it should
          react to a fresh reasoning chunk. *)
       ());
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
  (match chunk.delta_reasoning with
   | Some text when text <> "" -> emit_thinking_delta text
   | Some "" ->
     (match state.thinking_state with
      | Thinking_started t0 ->
        let thinking_duration_ms = (Unix.gettimeofday () -. t0) *. 1000.0 in
        state.thinking_state <- Thinking_done;
        telemetry_event
        := Some
             (Telemetry_event.Thinking_complete
                { provider = state.provider; model = state.model; thinking_duration_ms })
      | Not_thinking | Thinking_done ->
        (* Empty reasoning chunk while never started, or after a prior
           close — no telemetry to emit. Enumerated explicitly so a new
           [thinking_state] variant cannot silently inherit the no-op. *)
        ())
   | Some empty_reasoning ->
     let (_ : string) = empty_reasoning in
     ()
   | None -> ());
  (match chunk.delta_reasoning_details with
   | Some { delta_reasoning_content; delta_details } ->
     (match state.thinking_state with
      | Not_thinking -> state.thinking_state <- Thinking_started (Unix.gettimeofday ())
      | Thinking_started _ | Thinking_done -> ());
     let index = match state.reasoning_details_index with
       | Some index -> index
       | None ->
           let index = state.next_block_index in
           state.reasoning_details_index <- Some index;
           state.next_block_index <- index + 1;
           emit (ContentBlockStart {index; content_type = "reasoning_details";
                                    tool_id = None; tool_name = None});
           index
     in
     emit (ContentBlockDelta {index; delta = ReasoningDetailsDelta
       {reasoning_content=delta_reasoning_content;details=delta_details}})
   | None -> ());
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
  (* Explicit content framing is independent of the native reasoning dialect.
     Preserve inline segment order and distinct native/inline block identities. *)
  (match chunk.delta_content with
   | Some text when text <> "" ->
     (match state.inline_reasoning with
      | None -> emit_text_delta text
      | Some split ->
        if state.preserve_inline_content then state.inline_raw_rev <- text :: state.inline_raw_rev;
        emit_inline_segments state emit (Inline_reasoning_split.feed_segments split text))
   | Some empty_text ->
     if state.preserve_inline_content then state.inline_raw_rev <- empty_text :: state.inline_raw_rev
   | None -> ());
  (* Tool call deltas are one state transaction with the rest of this chunk.
     A late identity/index conflict rolls back every earlier sibling and
     discards locally buffered events before the caller can observe them. *)
  let rec emit_tool_calls = function
    | [] -> Ok ()
    | (tc : openai_tool_call_delta) :: rest ->
      let resolution, start =
        resolve_tool_block
          ?tx
          state
          ~protocol:"openai"
          ~wire_index:tc.tc_index
          ~provider_tool_id:tc.tc_id
          ~tool_name:tc.tc_name
          ~index_policy:Next_available
          ~idless_semantics:Continue_by_wire_index
      in
      (match resolution with
       | Tool_block_rejected error -> Error error
       | Tool_block_resolved { block_index; _ } ->
         Option.iter emit start;
         (match tc.tc_arguments with
          | Some (Args_fragment args) when args <> "" ->
            emit (ContentBlockDelta { index = block_index; delta = InputJsonDelta args })
          | Some (Args_complete args) when args <> "" ->
            emit
              (ContentBlockDelta { index = block_index; delta = InputJsonSnapshot args })
          | Some (Args_fragment _ | Args_complete _) | None -> ());
         emit_tool_calls rest)
  in
  match emit_tool_calls chunk.delta_tool_calls with
  | Error error -> Error error
  | Ok () ->
    (* Finish reason -> MessageDelta *)
    (match chunk.finish_reason with
     | Some reason ->
       let stop_reason =
         (* OpenAI wire vocabulary -> PROVISIONAL stop_reason. The accumulated
            tool-block set is unknown at the chunk boundary (tool arguments arrive
            as deltas before this terminal chunk), so a "tool_calls" finish is
            recorded as a provisional StopToolUse and reconciled against the
            assembled content in Complete_stream_acc.finalize_stream_acc
            (Stop_reason_wire.reconcile). SSOT: the wire vocabulary lives in
            Stop_reason_wire, not in an unguarded chunk-level match. *)
         Stop_reason_wire.provisional_of_string reason
         |> Stop_reason_wire.with_refusal ~has_refusal:state.refusal_seen
       in
       (* Close every block this message opened before the terminal MessageDelta,
          mirroring Anthropic's content_block_stop-then-message_delta ordering.
          Without this the OpenAI-compat stream leaves tool blocks open and a
          downstream per-message block-index consumer collides on the next
          message's reused index. *)
       (* Bytes the inline-reasoning splitter was holding back belong to this
          message. Release them before the blocks close: an unterminated tag
          means the stream was cut mid-thought, and dropping what it carried
          would lose the reasoning outright. *)
       (match state.inline_reasoning with
        | None -> ()
        | Some split ->
          emit_inline_segments state emit (Inline_reasoning_split.flush_segments split));
       List.iter emit (openai_open_block_stops state);
       (match state.inline_reasoning with
        | None -> ()
        | Some _ when state.preserve_inline_content && state.inline_raw_rev <> [] -> emit (InlineContentReplay
            {raw_content=String.concat "" (List.rev state.inline_raw_rev);
             block_indices=List.rev state.inline_indices_rev})
        | Some _ -> ());
       emit
         (MessageDelta
            { stop_reason = Some stop_reason
            ; usage = chunk.chunk_usage
            })
     | None ->
       (* With stream_options.include_usage the provider sends token totals in a
          separate final chunk that has no finish_reason and an empty choices
          array (hence no content/tool deltas). Emit a MessageDelta carrying only
          the usage so the accumulator records it. The finish_reason branch above
          already forwards usage when a stop arrives in the same chunk, so the two
          paths are mutually exclusive and usage is never emitted twice. *)
       (match chunk.chunk_usage with
        | Some usage ->
          emit
            (MessageDelta
               { stop_reason = None
               ; usage = Some usage
               })
        | None -> ()));
    let events = List.rev !events in
    let events =
      match state.openai_prelude with
      | Reported_prelude_published | Output_without_prelude -> events
      | Awaiting_reported_metadata ->
        if not (Api_common.string_is_blank chunk.chunk_id)
           && not (Api_common.string_is_blank chunk.chunk_model)
        then (
          state.openai_prelude <- Reported_prelude_published;
          (* The pair belongs to this wire chunk. Never assemble it from
             separate partial headers or substitute the requested model.
             Usage remains on its existing MessageDelta, exactly once. *)
          MessageStart {id=chunk.chunk_id; model=chunk.chunk_model; usage=None} :: events)
        else (
          (* A late prelude is not a metadata update: accumulators and chat
             consumers treat it as a response boundary. Preserve the existing
             metadata-poor output rather than reopening it later. *)
          if events <> [] then state.openai_prelude <- Output_without_prelude;
          events)
    in
    Ok (events, !telemetry_event)
;;

(** Convert a parsed {!Openai_wire.openai_chunk} into {!sse_event} list.
    Synthesizes [ContentBlockStart] events on first occurrence of text content
    or each new tool-call identity, and matching stops on terminal chunks.

    Tool-bearing chunks are transactional: a sibling route conflict returns
    exactly one parse failure and rolls back every scalar/table mutation. The
    structurally exact no-tool fast path avoids transaction allocation for the
    common text/reasoning token stream. *)
let openai_chunk_to_events (state : openai_stream_state) (chunk : openai_chunk)
  : sse_event list * Telemetry_event.t option
  =
  match chunk.delta_tool_calls with
  | [] ->
    (match project_openai_chunk state chunk with
     | Ok result -> result
     | Error error -> [ error ], None)
  | _ :: _ ->
    let tx = begin_openai_projection state in
    (match project_openai_chunk ~tx state chunk with
     | Ok result -> result
     | Error error ->
       rollback_openai_projection tx;
       [ error ], None
     | exception exn ->
       rollback_openai_projection tx;
       raise exn)
;;

let openai_sse_parse_result_to_events state = function
  | Openai_chunk chunk -> openai_chunk_to_events state chunk
  | Openai_done ->
    (* The terminal sentinel is observable even without a preceding chunk.
       It closes the prelude window; later data must not invent a new start. *)
    (match state.openai_prelude with
     | Awaiting_reported_metadata -> state.openai_prelude <- Output_without_prelude
     | Reported_prelude_published | Output_without_prelude -> ());
    [ MessageStop ], None
  | Openai_empty -> [], None
  | Openai_provider_error { message; error_type; provider_status; report; raw } ->
    [ SSEError { message; error_type; provider_status; report; raw } ], None
  | Openai_parse_failed { reason; raw } -> [ SSEParseFailed { reason; raw } ], None
  | Openai_undeclared_reasoning_member { declared; member; raw } ->
    (* The stream fails on the chunk that exposed the row: the raw payload is
       the evidence and the reason names both members so the catalog can be
       corrected. *)
    ( [ SSEParseFailed
          { reason =
              Printf.sprintf
                "undeclared_reasoning_member:%s:declared:%s"
                member
                declared
          ; raw
          }
      ]
    , None )
;;

(* Inline-test-only; the release profile strips the tests that call it. *)
let[@warning "-32"] test_tool_use_start_with_name = function
  | ContentBlockStart { index; content_type = "tool_use"; tool_name; _ } ->
    Some (index, tool_name)
  | MessageStart _
  | ContentBlockStart _
  | ContentBlockDelta _
  | ContentBlockStop _
  | MessageDelta _
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
  | StreamIncomplete _ -> None
;;

(* Inline-test-only; the release profile strips the tests that call it. *)
let[@warning "-32"] test_tool_use_start = function
  | ContentBlockStart { content_type = "tool_use"; _ } -> Some ()
  | MessageStart _
  | ContentBlockStart _
  | ContentBlockDelta _
  | ContentBlockStop _
  | MessageDelta _
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
  | StreamIncomplete _ -> None
;;

(* Inline-test-only; the release profile strips the tests that call it. *)
let[@warning "-32"] test_input_json_delta = function
  | ContentBlockDelta { index; delta = InputJsonDelta s } -> Some (index, s)
  | MessageStart _
  | ContentBlockStart _
  | ContentBlockDelta
      { delta =
          ( TextDelta _
          | TextSnapshot _
          | (ThinkingDelta _ | ThinkingSnapshot _)
          | ThinkingSignatureDelta _
          | RedactedThinkingSnapshot _
          | ReasoningDetailsDelta _
          | InputJsonSnapshot _
          | MediaDelta _ )
      ; _
      }
  | ContentBlockStop _
  | MessageDelta _
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
  | StreamIncomplete _ -> None
;;

let%test
    "openai_chunk_to_events: parallel tool calls sharing wire index:0 get distinct blocks"
  =
  (* minimax-m3 (Ollama Cloud) stamps every parallel tool call index:0 but gives
     each a distinct id. Blocks are keyed by id so the three calls do not collapse
     into one buffer whose concatenated arguments are not one JSON object. *)
  let mk id name args : openai_tool_call_delta =
    { tc_index = 0
    ; tc_id = Some id
    ; tc_name = Some name
    ; tc_arguments = Some (Args_fragment args)
    }
  in
  let state = create_openai_stream_state () in
  let chunk =
    { chunk_id = "c"
    ; chunk_model = "minimax-m3"
    ; delta_content = None
    ; delta_refusal = false
    ; delta_reasoning = None
    ; delta_reasoning_details = None
    ; delta_tool_calls =
        [ mk "a" "list_tasks" {|{"limit":5}|}
        ; mk "b" "run_shell" {|{"argv":["git"]}|}
        ; mk "c" "read_file" {|{"file_path":"x"}|}
        ]
    ; finish_reason = None
    ; chunk_usage = None
    ; chunk_timings = None
    }
  in
  let events, _ = openai_chunk_to_events state chunk in
  let starts = List.filter_map test_tool_use_start_with_name events in
  let deltas = List.filter_map test_input_json_delta events in
  starts = [ 0, Some "list_tasks"; 1, Some "run_shell"; 2, Some "read_file" ]
  && deltas = [ 0, {|{"limit":5}|}; 1, {|{"argv":["git"]}|}; 2, {|{"file_path":"x"}|} ]
;;

(* Inline-test-only helpers for the inline-reasoning split. *)
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

let[@warning "-32"] test_content_chunk ?(finish_reason = None) content =
  { chunk_id = "c"
  ; chunk_model = "minimax-m3"
  ; delta_content = Some content
  ; delta_refusal = false
  ; delta_reasoning = None
  ; delta_reasoning_details = None
  ; delta_tool_calls = []
  ; finish_reason
  ; chunk_usage = None
  ; chunk_timings = None
  }
;;

let%test "minimax-m3 declares inline reasoning without losing its reasoning stream" =
  (* Both halves matter. The declaration is worthless if it does not reach the
     capability record, and folding it into [reasoning_streaming_format] would
     displace [Delta_reasoning_details] and cost the model the reasoning it
     already streams correctly. *)
  match Capabilities.for_model_id "minimax-m3" with
  | None -> false
  | Some caps ->
    let inline =
      match caps.Capabilities.content_inline_reasoning with
      | Capabilities.Think_tags | Capabilities.Think_tags_with_chat_replay -> true
      | Capabilities.No_content_inline_reasoning | Capabilities.Content_chunks -> false
    in
    let stream_intact =
      match (Reasoning_dialect.of_capabilities caps).streaming with
      | Reasoning_dialect.Delta_field_and_details "reasoning_content" -> true
      | Reasoning_dialect.Delta_field_and_details _
      | Reasoning_dialect.No_streaming_reasoning
      | Reasoning_dialect.Delta_field _
      | Reasoning_dialect.Template_parser -> false
    in
    inline && stream_intact
;;

let%test "openai_chunk_to_events: a declared template model keeps reasoning out of the reply"
  =
  let state = create_openai_stream_state ~inline_reasoning:true () in
  let events, _ =
    openai_chunk_to_events state (test_content_chunk "<think>weighing</think>the answer")
  in
  List.filter_map test_thinking_text events = [ "weighing" ]
  && List.filter_map test_reply_text events = [ "the answer" ]
;;

let%test "openai_chunk_to_events: an undeclared model keeps every byte of its content" =
  (* The split is a declaration, not a guess about text that looks like a tag. *)
  let state = create_openai_stream_state () in
  let events, _ =
    openai_chunk_to_events state (test_content_chunk "<think>weighing</think>the answer")
  in
  List.filter_map test_thinking_text events = []
  && List.filter_map test_reply_text events = [ "<think>weighing</think>the answer" ]
;;

let%test "openai_chunk_to_events: a tag split across chunks leaks no fragment" =
  let state = create_openai_stream_state ~inline_reasoning:true () in
  let feed content =
    fst (openai_chunk_to_events state (test_content_chunk content))
  in
  (* Bound in order: [@] does not fix the order its arguments are evaluated in,
     and a stream fed backwards proves nothing. *)
  let first = feed "<thi" in
  let second = feed "nk>mid</th" in
  let third = feed "ink>done" in
  let events = first @ second @ third in
  List.filter_map test_thinking_text events = [ "mid" ]
  && List.filter_map test_reply_text events = [ "done" ]
;;

let%test "openai_chunk_to_events: a cut thought is released as reasoning at stream end" =
  (* Every unbalanced block measured on the live fleet was short exactly one
     closing tag. The held bytes are reasoning, not reply, and not nothing. *)
  let state = create_openai_stream_state ~inline_reasoning:true () in
  let opened, _ = openai_chunk_to_events state (test_content_chunk "<think>cut off") in
  let terminal, _ =
    openai_chunk_to_events
      state
      { (test_content_chunk "") with finish_reason = Some "stop" }
  in
  let events = opened @ terminal in
  List.filter_map test_thinking_text events = [ "cut off" ]
  && List.filter_map test_reply_text events = []
;;

let%test "openai_chunk_to_events: id-less continuation fragment stays in its call's block"
  =
  (* OpenAI streams a tool call's id and name only on its first chunk, then sends
     argument fragments carrying just the index. An id-less continuation must
     route back to the block opened for that index, not open a new one. *)
  let base =
    { chunk_id = "c"
    ; chunk_model = "m"
    ; delta_content = None
    ; delta_refusal = false
    ; delta_reasoning = None
    ; delta_reasoning_details = None
    ; delta_tool_calls = []
    ; finish_reason = None
    ; chunk_usage = None
    ; chunk_timings = None
    }
  in
  let state = create_openai_stream_state () in
  let ev1, _ =
    openai_chunk_to_events
      state
      { base with
        delta_tool_calls =
          [ { tc_index = 0
            ; tc_id = Some "a"
            ; tc_name = Some "calc"
            ; tc_arguments = Some (Args_fragment {|{"x":|})
            }
          ]
      }
  in
  let ev2, _ =
    openai_chunk_to_events
      state
      { base with
        delta_tool_calls =
          [ { tc_index = 0
            ; tc_id = None
            ; tc_name = None
            ; tc_arguments = Some (Args_fragment {|1}|})
            }
          ]
      }
  in
  let starts = List.filter_map test_tool_use_start (ev1 @ ev2) in
  let deltas = List.filter_map test_input_json_delta (ev1 @ ev2) in
  List.length starts = 1 && deltas = [ 0, {|{"x":|}; 0, {|1}|} ]
;;

let%test
    "openai_chunk_to_events: gemma-style fragmented parallel calls keep distinct blocks"
  =
  (* gemma4-coder-fable5 (RunPod llama-server) emits parallel tool calls the
     spec-compliant way: distinct wire indices, id and name only on each call's
     first chunk, then argument fragments carrying just the index. Each call's
     fragments must accumulate into its own block (one Start per call, fragments
     routed back by index). Captured wire, 2026-06-30. *)
  let base =
    { chunk_id = "c"
    ; chunk_model = "gemma4-coder-fable5"
    ; delta_content = None
    ; delta_refusal = false
    ; delta_reasoning = None
    ; delta_reasoning_details = None
    ; delta_tool_calls = []
    ; finish_reason = None
    ; chunk_usage = None
    ; chunk_timings = None
    }
  in
  let tc tc_index tc_id tc_name args =
    { tc_index; tc_id; tc_name; tc_arguments = Some (Args_fragment args) }
  in
  let state = create_openai_stream_state () in
  let chunks =
    [ [ tc 0 (Some "a") (Some "list_tasks") {|{"li|} ]
    ; [ tc 0 None None {|mit":5}|} ]
    ; [ tc 1 (Some "b") (Some "run_shell") {|{"ar|} ]
    ; [ tc 1 None None {|gv":["git"]}|} ]
    ]
  in
  let events =
    List.concat_map
      (fun tcs -> fst (openai_chunk_to_events state { base with delta_tool_calls = tcs }))
      chunks
  in
  let starts =
    List.filter_map
      (function
        | ContentBlockStart { index; content_type = "tool_use"; tool_name; _ } ->
          Some (index, tool_name)
        | MessageStart _
        | ContentBlockStart _
        | ContentBlockDelta _
        | ContentBlockStop _
        | MessageDelta _
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
        | StreamIncomplete _ -> None)
      events
  in
  let deltas =
    List.filter_map
      (function
        | ContentBlockDelta { index; delta = InputJsonDelta s } -> Some (index, s)
        | MessageStart _
        | ContentBlockStart _
        | ContentBlockDelta
            { delta =
                ( TextDelta _
                | TextSnapshot _
                | (ThinkingDelta _ | ThinkingSnapshot _)
                | ThinkingSignatureDelta _
                | RedactedThinkingSnapshot _
                | ReasoningDetailsDelta _
                | InputJsonSnapshot _
                | MediaDelta _ )
            ; _
            }
        | ContentBlockStop _
        | MessageDelta _
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
        | StreamIncomplete _ -> None)
      events
  in
  starts = [ 0, Some "list_tasks"; 1, Some "run_shell" ]
  && deltas = [ 0, {|{"li|}; 0, {|mit":5}|}; 1, {|{"ar|}; 1, {|gv":["git"]}|} ]
;;

let%test "openai_chunk_to_events: id-less continuation on ambiguous index fails loud" =
  let base =
    { chunk_id = "c"
    ; chunk_model = "minimax-m3"
    ; delta_content = None
    ; delta_refusal = false
    ; delta_reasoning = None
    ; delta_reasoning_details = None
    ; delta_tool_calls = []
    ; finish_reason = None
    ; chunk_usage = None
    ; chunk_timings = None
    }
  in
  let tc tc_id args =
    { tc_index = 0; tc_id; tc_name = None; tc_arguments = Some (Args_fragment args) }
  in
  let state = create_openai_stream_state () in
  let _ =
    openai_chunk_to_events
      state
      { base with
        delta_tool_calls = [ tc (Some "a") {|{"a":|}; tc (Some "b") {|{"b":|} ]
      }
  in
  let events, _ =
    openai_chunk_to_events state { base with delta_tool_calls = [ tc None {|1}|} ] }
  in
  match events with
  | [ SSEParseFailed { raw; reason } ] ->
    raw = "openai tool_call index 0"
    && reason
       = "ambiguous_tool_call_index: id-less continuation follows multiple tool \
          identities"
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

[@@@coverage off]

let[@warning "-32"] test_block_starts (events : sse_event list) =
  List.filter_map (function
    | ContentBlockStart {index;content_type;_} -> Some (index,content_type)
    | MessageStart _ | ContentBlockDelta _ | ContentBlockStop _ | MessageDelta _
    | MessageStop | InlineContentReplay _ | ResponsesOutputItems _ | Ping | SSEError _ | NDJSONError _ | SSEParseFailed _
    | NDJSONParseFailed _ | SSEUnknownEventType _ | SSEUnsupportedPart _
    | SSEUnsupportedResponse _ | Connected | Timeout _ | StreamIncomplete _ -> None) events
;;

let[@warning "-32"] test_block_deltas (events : sse_event list) =
  List.filter_map (function
    | ContentBlockDelta {index;delta} -> Some (index,delta)
    | MessageStart _ | ContentBlockStart _ | ContentBlockStop _ | MessageDelta _
    | MessageStop | InlineContentReplay _ | ResponsesOutputItems _ | Ping | SSEError _ | NDJSONError _ | SSEParseFailed _
    | NDJSONParseFailed _ | SSEUnknownEventType _ | SSEUnsupportedPart _
    | SSEUnsupportedResponse _ | Connected | Timeout _ | StreamIncomplete _ -> None) events
;;

let[@warning "-32"] test_is_parse_failed : sse_event -> bool = function
  | SSEParseFailed _ -> true
  | MessageStart _ | ContentBlockStart _ | ContentBlockDelta _ | ContentBlockStop _
  | MessageDelta _ | MessageStop | InlineContentReplay _ | ResponsesOutputItems _ | Ping | SSEError _ | NDJSONError _
  | NDJSONParseFailed _ | SSEUnknownEventType _ | SSEUnsupportedPart _
  | SSEUnsupportedResponse _ | Connected | Timeout _ | StreamIncomplete _ -> false
;;

let[@warning "-32"] test_thinking_text : content_delta -> string option = function
  | ThinkingDelta text | ThinkingSnapshot text -> Some text
  | TextDelta _ | TextSnapshot _ | ThinkingSignatureDelta _ | RedactedThinkingSnapshot _
  | ReasoningDetailsDelta _ | InputJsonDelta _ | InputJsonSnapshot _ | MediaDelta _ -> None
;;

let[@warning "-32"] test_visible_text : content_delta -> string option = function
  | TextDelta text -> Some text
  | TextSnapshot _ | (ThinkingDelta _ | ThinkingSnapshot _) | ThinkingSignatureDelta _ | RedactedThinkingSnapshot _
  | ReasoningDetailsDelta _ | InputJsonDelta _ | InputJsonSnapshot _ | MediaDelta _ -> None
;;

let%test "native details and inline reasoning retain distinct block payloads" =
  let state = create_openai_stream_state ~inline_reasoning:true () in
  let chunk = { (test_content_chunk "A<think>B</think>C") with
    delta_reasoning_details = Some {delta_reasoning_content = Some "native"; delta_details = []} } in
  let events, _ = openai_chunk_to_events state chunk in
  let starts = test_block_starts events in
  let deltas = test_block_deltas events in
  starts = [0,"reasoning_details";1,"text";2,"thinking";3,"text"]
  && List.exists (fun (index, delta) -> index = 2 && test_thinking_text delta = Some "B") deltas
  && not (List.exists (fun (index, delta) -> index = 0 && Option.is_some (test_thinking_text delta)) deltas)
;;

let%test "inline answer emits incrementally after reasoning before terminal" =
  let state = create_openai_stream_state ~inline_reasoning:true () in
  let first, _ = openai_chunk_to_events state (test_content_chunk "<think>private</think>hel") in
  let second, _ = openai_chunk_to_events state (test_content_chunk "lo") in
  let visible events = List.filter_map (fun (_, delta) -> test_visible_text delta) (test_block_deltas events) in
  visible first = ["hel"] && visible second = ["lo"]
;;

let%test "rejected tool chunk restores inline mode and held tag bytes" =
  let check prefix rejected continuation expected =
    let state = create_openai_stream_state ~inline_reasoning:true () in
    let tool id =
      { tc_index = 0; tc_id = id; tc_name = Some "fixture";
        tc_arguments = Some (Args_fragment "") } in
    let initial = { (test_content_chunk prefix) with delta_tool_calls = [tool None] } in
    let before, _ = openai_chunk_to_events state initial in
    (* A provider identity cannot replace the synthesized identity of that
       existing call. The preceding content in this same chunk must roll back. *)
    let invalid = { (test_content_chunk rejected) with
      delta_tool_calls = [tool (Some "late-provider-id")] } in
    let rejected_events, _ = openai_chunk_to_events state invalid in
    let after, _ = openai_chunk_to_events state
      { (test_content_chunk continuation) with finish_reason = Some "stop" } in
    let payloads = List.filter_map (fun (_, delta) ->
      match test_visible_text delta with
      | Some text -> Some (`Text text)
      | None -> Option.map (fun text -> `Thinking text) (test_thinking_text delta))
      (test_block_deltas (before @ after)) in
    List.length rejected_events = 1 && List.for_all test_is_parse_failed rejected_events
    && payloads = expected
  in
  check "<thi" "nk>discarded</think>" "nk>private</think>reply"
    [`Thinking "private"; `Text "reply"]
  && check "<think>private</thi" "nk>discarded" "nk>reply"
    [`Thinking "private"; `Text "reply"]
;;
