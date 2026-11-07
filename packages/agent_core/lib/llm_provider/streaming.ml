(** SSE event parsing and synthetic event emission.

    Pure functions operating on {!Llm_provider.Types}. No agent_core coupling.
    The streaming HTTP client (create_message_stream) remains in agent_core. *)

open Types

let event_type_of_payload event_type json : (string, string) result =
  match json with
  | `Assoc fields ->
    (match event_type with
     | Some value when not (Api_common.string_is_blank value) -> Ok value
     | Some _ -> Error "sse_event_type_blank"
     | None ->
       (match List.assoc_opt "type" fields with
        | Some (`String value) when not (Api_common.string_is_blank value) -> Ok value
        | Some (`String _) -> Error "sse_event_type_blank"
        | Some _ -> Error "sse_event_type_not_string"
        | None -> Error "sse_event_type_missing"))
  | _ -> Error "sse_payload_must_be_object"
;;

(** Parse a single SSE data JSON payload into an [sse_event]. *)
let parse_sse_event event_type data_str =
  let open Yojson.Safe.Util in
  try
    let json = Yojson.Safe.from_string data_str in
    match event_type_of_payload event_type json with
    | Error reason -> Some (SSEParseFailed { raw = data_str; reason })
    | Ok evt_type ->
      (match evt_type with
       | "message_start" ->
         let msg = json |> member "message" in
         let id = msg |> member "id" |> to_string in
         let model = msg |> member "model" |> to_string in
         let usage =
           let u = msg |> member "usage" in
           if u = `Null
           then None
           else (
             let input_tokens = u |> member "input_tokens" |> to_int in
             let cache_creation_input_tokens =
               u
               |> member "cache_creation_input_tokens"
               |> to_int_option
               |> Option.value ~default:0
             in
             let cache_read_input_tokens =
               u
               |> member "cache_read_input_tokens"
               |> to_int_option
               |> Option.value ~default:0
             in
             (* The start snapshot seeds every counter; a later cumulative
                message_delta replaces the ones it reports (#28903). *)
             Some
               (Backend_anthropic.usage_of_wire_counts
                  ~input_tokens
                  ~output_tokens:
                    (Cli_common_json.member_int "output_tokens" u)
                  ~cache_creation_input_tokens
                  ~cache_read_input_tokens))
         in
         Some (MessageStart { id; model; usage })
       | "content_block_start" ->
         let index = json |> member "index" |> to_int in
         let cb = json |> member "content_block" in
         let content_type = cb |> member "type" |> to_string in
         let tool_id =
           match content_type with
           | "redacted_thinking" -> cb |> member "data" |> to_string_option
           | _ -> cb |> member "id" |> to_string_option
         in
         let tool_name = cb |> member "name" |> to_string_option in
         let non_blank_tool_id =
           match tool_id with
           | Some id when not (Api_common.string_is_blank id) -> Some id
           | Some _ | None -> None
         in
         (match content_type, non_blank_tool_id with
          | "tool_use", None ->
            Some
              (SSEParseFailed
                 { raw = Printf.sprintf "anthropic tool_use index %d" index
                 ; reason =
                     Printf.sprintf
                       "malformed_tool_use:index:%d:missing_provider_id"
                       index
                 })
          | "tool_use", Some tool_id ->
            Some
              (ContentBlockStart
                 { index; content_type; tool_id = Some tool_id; tool_name })
          | _, _ -> Some (ContentBlockStart { index; content_type; tool_id; tool_name }))
       | "content_block_delta" ->
         let index = json |> member "index" |> to_int in
         let delta_json = json |> member "delta" in
         let delta_type = delta_json |> member "type" |> to_string in
         let delta =
           match delta_type with
           | "text_delta" -> TextDelta (delta_json |> member "text" |> to_string)
           | "thinking_delta" ->
             ThinkingDelta (delta_json |> member "thinking" |> to_string)
           | "signature_delta" ->
             ThinkingSignatureDelta (delta_json |> member "signature" |> to_string)
           | "input_json_delta" ->
             InputJsonDelta (delta_json |> member "partial_json" |> to_string)
           | unknown_delta_type ->
             raise
               (Yojson.Safe.Util.Type_error
                  ( "unsupported content_block_delta type: " ^ unknown_delta_type
                  , delta_json ))
         in
         Some (ContentBlockDelta { index; delta })
       | "content_block_stop" ->
         let index = json |> member "index" |> to_int in
         Some (ContentBlockStop { index })
       | "message_delta" ->
         let delta = json |> member "delta" in
         let stop_reason =
           delta
           |> member "stop_reason"
           |> to_string_option
           |> Option.map stop_reason_of_string
         in
         let usage : Types.delta_usage option =
           let u = json |> member "usage" in
           if u = `Null
           then None
           else (
             (* message_delta usage is wire-cumulative (official streaming
                contract): every reported field is the message's running
                total, so each is carried as present-or-absent for the
                accumulator to replace, never add (#28903). The wire's
                input_tokens is exclusive; when the delta reports it, the
                same report carries the cache components it accounts
                against, so the inclusive normalization uses those
                (an unreported cache field in that report reads as 0, the
                api_usage convention). *)
             let output_tokens = u |> member "output_tokens" |> to_int in
             let cache_creation_input_tokens =
               u |> member "cache_creation_input_tokens" |> to_int_option
             in
             let cache_read_input_tokens =
               u |> member "cache_read_input_tokens" |> to_int_option
             in
             let input_tokens =
               u
               |> member "input_tokens"
               |> to_int_option
               |> Option.map (fun exclusive_input ->
                 (* DET-OK: absent wire field is 0 by api_usage convention *)
                 exclusive_input
                 + Option.value cache_creation_input_tokens ~default:0
                 (* DET-OK: absent wire field is 0 by api_usage convention *)
                 + Option.value cache_read_input_tokens ~default:0)
             in
             Some
               { Types.input_tokens
               ; output_tokens = Some output_tokens
               ; cache_creation_input_tokens
               ; cache_read_input_tokens
               ; cost_usd = None
               })
         in
         Some (MessageDelta { stop_reason; usage })
       | "message_stop" -> Some MessageStop
       | "ping" -> Some Ping
       | "error" ->
         let err = json |> member "error" in
         let message =
           match err |> member "message" |> to_string_option with
           | Some m -> m
           | None -> Openai_error_envelope.missing_message
         in
         let error_type = err |> member "type" |> to_string_option in
         Some
           (SSEError
              { message
              ; error_type
              ; provider_status = None
              ; report = Types.Provider_stated
              ; raw = data_str
              })
       | other -> Some (SSEUnknownEventType { event_type = other; raw = data_str }))
  with
  | Yojson.Safe.Util.Type_error (msg, _) ->
    Some (SSEParseFailed { raw = data_str; reason = "type_error: " ^ msg })
  | Yojson.Json_error msg ->
    Some (SSEParseFailed { raw = data_str; reason = "json_error: " ^ msg })
;;

(* Agent Core contract: TTFT classification — distinguishes prelude events
   ([MessageStart], a [ContentBlockStart] that carries no content, [Ping])
   from the first generated content. Capture point in [Complete_stream] uses this
   to fill [Streaming_summary.ttft_ms] and to end the first-event budget. *)
let sse_event_is_first_token_signal (e : sse_event) : bool =
  let non_empty s = String.length s > 0 in
  match e with
  | ContentBlockDelta { delta = TextDelta s | TextSnapshot s; _ } -> non_empty s
  | ContentBlockDelta { delta = ThinkingDelta s | ThinkingSnapshot s; _ } -> non_empty s
  | ContentBlockDelta { delta = ReasoningDetailsDelta { reasoning_content; details }; _ }
    ->
    (match reasoning_content with
     | Some s when non_empty s -> true
     | Some _ | None -> details <> [])
  | ContentBlockDelta { delta = InputJsonDelta s | InputJsonSnapshot s; _ } -> non_empty s
  | ContentBlockDelta { delta = MediaDelta { source; _ }; _ } ->
    non_empty (Types.media_source_payload source)
  (* A redacted thinking block is generated content the caller receives
     ([Types.RedactedThinking]): the model has produced, so the first-event
     wait is over and TTFT is measured to it. Anthropic delivers the whole
     block in its [content_block_start], with the payload in [tool_id]. *)
  | ContentBlockStart { content_type = "redacted_thinking"; tool_id = Some data; _ } ->
    not (Api_common.string_is_blank data)
  | ContentBlockDelta { delta = RedactedThinkingSnapshot data; _ } -> non_empty data
  | ContentBlockDelta { delta = ThinkingSignatureDelta _; _ } -> false
  | MessageStart _
  | ContentBlockStart _
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
  | StreamIncomplete _ -> false
;;

let sse_event_is_deliverable_progress_signal (e : sse_event) : bool =
  let non_empty s = String.length s > 0 in
  match e with
  | ContentBlockDelta { delta = TextDelta s | TextSnapshot s; _ } -> non_empty s
  | ContentBlockDelta { delta = InputJsonDelta s | InputJsonSnapshot s; _ } -> non_empty s
  | ContentBlockDelta { delta = MediaDelta { source; _ }; _ } ->
    non_empty (Types.media_source_payload source)
  | ContentBlockStart { content_type = "tool_use"; _ } -> true
  | ContentBlockDelta { delta = ThinkingSignatureDelta _; _ }
  | ContentBlockDelta { delta = RedactedThinkingSnapshot _; _ }
  | ContentBlockDelta { delta = (ThinkingDelta _ | ThinkingSnapshot _); _ }
  | ContentBlockDelta { delta = ReasoningDetailsDelta _; _ }
  | MessageStart _
  | ContentBlockStart _
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
  | StreamIncomplete _ -> false
;;

(** Emit synthetic SSE events from a complete [api_response].
    Used as fallback for non-Anthropic providers that don't support SSE.

    An unreadable tool call is emitted as the tool block it was on the wire,
    at its [tool_use_ordinal] among the tool calls, with its argument text as a
    snapshot. A consumer that counts tool blocks then sees what a stream would
    have shown it, and the accumulator classifies the call again on its own. *)
let emit_synthetic_events (response : api_response) on_event =
  on_event
    (MessageStart { id = response.id; model = response.model; usage = response.usage });
  let next_index = ref 0 in
  let next_tool_ordinal = ref 0 in
  (* Emission walks the calls in ordinal order; the response does not promise
     its list is in that order. *)
  let pending_unreadable =
    ref
      (List.stable_sort
         (fun (a : unreadable_tool_use) (b : unreadable_tool_use) ->
            Int.compare a.tool_use_ordinal b.tool_use_ordinal)
         response.unreadable_tool_uses)
  in
  let take_index () =
    let index = !next_index in
    incr next_index;
    index
  in
  let emit_unreadable (call : unreadable_tool_use) =
    let index = take_index () in
    incr next_tool_ordinal;
    on_event
      (ContentBlockStart
         { index
         ; content_type = "tool_use"
         ; tool_id = Some call.tool_use_id
         ; tool_name = Some call.tool_name
         });
    on_event (ContentBlockDelta { index; delta = InputJsonSnapshot call.arguments });
    on_event (ContentBlockStop { index })
  in
  let rec emit_unreadable_due () =
    match !pending_unreadable with
    | call :: rest when call.tool_use_ordinal <= !next_tool_ordinal ->
      pending_unreadable := rest;
      emit_unreadable call;
      emit_unreadable_due ()
    | _ :: _ | [] -> ()
  in
  let stream_indices =
    List.map
      (fun block ->
         let content_type, tool_id, tool_name =
           match block with
           | Text _ -> "text", None, None
           | Thinking _ -> "thinking", None, None
           | ReasoningDetails _ -> "reasoning_details", None, None
           | ToolUse { id; name; _ } -> "tool_use", Some id, Some name
           | Image _ -> "image", None, None
           | Document _ -> "document", None, None
           | Audio _ -> "audio", None, None
           | RedactedThinking data -> "redacted_thinking", Some data, None
           | ToolResult _ -> "text", None, None
         in
         (match block with
          | ToolUse _ -> emit_unreadable_due ()
          | Text _ | Thinking _ | ReasoningDetails _ | RedactedThinking _ | ToolResult _
          | Image _ | Document _ | Audio _ -> ());
         let index = take_index () in
         on_event (ContentBlockStart { index; content_type; tool_id; tool_name });
         (match block with
          | Text s -> on_event (ContentBlockDelta { index; delta = TextDelta s })
          | Thinking { content; signature } ->
            on_event (ContentBlockDelta { index; delta = ThinkingDelta content });
            (match signature with
             | Some s ->
               on_event (ContentBlockDelta { index; delta = ThinkingSignatureDelta s })
             | None -> ())
          | ReasoningDetails { reasoning_content; details } ->
            on_event
              (ContentBlockDelta
                 { index; delta = ReasoningDetailsDelta { reasoning_content; details } })
          | ToolUse { input; _ } ->
            incr next_tool_ordinal;
            on_event
              (ContentBlockDelta
                 { index; delta = InputJsonSnapshot (Yojson.Safe.to_string input) })
          | Image { media_type; source }
          | Document { media_type; source }
          | Audio { media_type; source } ->
            (* Re-emit media payload through the typed media channel so a
               non-streamed media block survives an api_response -> synthetic SSE
               -> accumulator round-trip instead of collapsing to empty text. *)
            on_event
              (ContentBlockDelta
                 { index; delta = MediaDelta { media_type; source } })
          | RedactedThinking _ | ToolResult _ -> ());
         on_event (ContentBlockStop { index });
         index)
      response.content
  in
  List.iter emit_unreadable !pending_unreadable;
  (* The start event already carried the complete usage; repeating it here
     would make any replace-or-add accumulator double-count. The synthetic
     delta only settles the stop reason. Inline replay names content
     positions; an unreadable call emitted before a block moves that block's
     stream index, so the positions are carried over to stream indices. *)
  (match Option.bind response.telemetry (fun telemetry -> telemetry.inline_content_replay) with
   | None -> ()
   | Some {Inline_content_replay.raw_content;block_indices} ->
     let stream_indices = Array.of_list stream_indices in
     let block_indices =
       List.map
         (fun position ->
            if position >= 0 && position < Array.length stream_indices
            then stream_indices.(position)
            else position)
         block_indices
     in
     on_event (InlineContentReplay {raw_content;block_indices}));
  on_event (MessageDelta { stop_reason = Some response.stop_reason; usage = None });
  on_event MessageStop
;;

let%test "emit_synthetic_events round-trips a media block through the accumulator" =
  (* A non-streamed api_response carrying an Image survives the synthetic-SSE
     fallback: emit_synthetic_events -> Complete_stream_acc -> finalize yields the
     same Image. Revert the media delta/content_type arms here (or the accumulator
     media arms) and the image collapses to empty text, so this goes red. This is
     the real producer that keeps the new MediaDelta path from being dead code. *)
  let image =
    Image { media_type = "image/png"; source = Types.Base64 "iVBORw0KGgo=" }
  in
  let response : api_response =
    { id = "msg_rt"
    ; model = "test-model"
    ; unreadable_tool_uses = []
    ; stop_reason = EndTurn
    ; content = [ image ]
    ; usage = None
    ; telemetry = None
    }
  in
  let events = ref [] in
  emit_synthetic_events response (fun e -> events := e :: !events);
  let acc = Complete_stream_acc.create_stream_acc () in
  List.iter (Complete_stream_acc.accumulate_event acc) (List.rev !events);
  match Complete_stream_acc.finalize_stream_acc acc with
  | Error _ -> false
  | Ok result -> result.content = [ image ]
;;

(** {1 OpenAI-compatible SSE Streaming}

    {!Openai_stream} turns each {!Openai_wire.openai_chunk} into stream events
    with a request-local {!openai_stream_state}, defined in
    {!Openai_stream_state}. *)

(* [streaming.mli] exports the state as an abstract type. *)
type openai_stream_state = Openai_stream_state.openai_stream_state

let create_openai_stream_state = Openai_stream_state.create_openai_stream_state
let openai_chunk_to_events = Openai_stream.openai_chunk_to_events
let openai_sse_parse_result_to_events = Openai_stream.openai_sse_parse_result_to_events

(** {1 OpenAI Responses API SSE Streaming}

    {!Responses_stream} turns one Responses API payload into stream events and
    keeps the block state in {!openai_stream_state}. *)

let responses_sse_to_events = Responses_stream.responses_sse_to_events

(** {1 Error Bodies Without an SSE Payload} *)

(* A 200 response the transport accepted as SSE but whose body carries no
   [data:] payload at all: some providers and gateways answer with a bare
   JSON error object instead of an event stream. Read the envelope the same
   way an in-stream chunk would, so the declared status (429/5xx) reaches
   retry classification instead of surfacing as an incomplete stream. [None]
   keeps the caller's previous behaviour for anything that is not an error
   envelope. *)
let sse_error_event_of_bodiless_body ~raw body =
  match Yojson.Safe.from_string body with
  | exception (Yojson.Json_error _ | Invalid_argument _) -> None
  | (`Assoc _ as json) ->
    (match
       Option.bind
         (Json_util.assoc_member_opt "error" json)
         Openai_error_envelope.of_error_value
     with
     | None -> None
     | Some envelope ->
       Some
         (Types.SSEError
            { message = envelope.message
            ; error_type = envelope.error_type
            ; provider_status = envelope.provider_status
            ; report = envelope.report
            ; raw
            }))
  | (`List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null) -> None
;;

(** {1 Gemini SSE Streaming}

    {!Gemini_wire} reads one payload into a {!Gemini_wire.gemini_chunk}.
    {!Gemini_stream} turns that chunk into stream events and keeps the block
    state in {!openai_stream_state}. *)

type gemini_chunk_to_events_error = Gemini_stream.gemini_chunk_to_events_error =
  { reason : string }

let gemini_chunk_to_events = Gemini_stream.gemini_chunk_to_events

(** {1 Ollama NDJSON Streaming}

    {!Ollama_wire} reads each NDJSON line into an {!Ollama_wire.ollama_chunk}.
    {!Ollama_stream} converts it to {!sse_event} list. *)

let ollama_chunk_to_events = Ollama_stream.ollama_chunk_to_events

[@@@coverage off]

(* parse_sse_event regression: the previous implementation returned [None]
   for both unknown event types and JSON parse failures, silently dropping
   the chunk. Downstream consumers then proceeded as if the chunk were a
   harmless heartbeat (like Ping), eventually finalizing without seeing
   MessageStop and presenting a phantom completion. The accumulator could
   not distinguish "no event in this chunk" from "we lost data here".
   These regression tests pin the new contract: the parser surfaces a
   structured failure event so the accumulator can react. *)

let%test "parse_sse_event: unknown event type yields SSEUnknownEventType" =
  let raw = "{\"type\":\"future_event_v3\"}" in
  match parse_sse_event None raw with
  | Some (SSEUnknownEventType { event_type; raw = r }) ->
    event_type = "future_event_v3" && r = raw
  | (Some (MessageStop | (InlineContentReplay _ | ResponsesOutputItems _ | Ping | (Connected | (MessageStart _ | (ContentBlockStart _ | (ContentBlockDelta _ | (ContentBlockStop _ | (MessageDelta _ | (SSEError _ | (NDJSONError _ | (SSEParseFailed _ | (NDJSONParseFailed _ | (SSEUnsupportedPart _ | (SSEUnsupportedResponse _ | (Timeout _ | (StreamIncomplete _ )))))))))))))))) | None) as unexpected_event -> let (_ : sse_event option) = unexpected_event in
    false
;;

let%test "parse_sse_event: malformed JSON yields SSEParseFailed" =
  let raw = "{not valid json" in
  match parse_sse_event None raw with
  | Some (SSEParseFailed { raw = r; reason }) -> r = raw && String.length reason > 0
  | (Some (MessageStop | (InlineContentReplay _ | ResponsesOutputItems _ | Ping | (Connected | (MessageStart _ | (ContentBlockStart _ | (ContentBlockDelta _ | (ContentBlockStop _ | (MessageDelta _ | (SSEError _ | (NDJSONError _ | (NDJSONParseFailed _ | (SSEUnknownEventType _ | (SSEUnsupportedPart _ | (SSEUnsupportedResponse _ | (Timeout _ | (StreamIncomplete _ )))))))))))))))) | None) as unexpected_event -> let (_ : sse_event option) = unexpected_event in
    false
;;

let%test "parse_sse_event: type field missing yields SSEParseFailed" =
  (* A valid JSON object without its discriminator is malformed protocol data,
     not a future event type. Preserve that distinction for the stream error
     classifier; do not manufacture an empty event type. *)
  let raw = "{\"id\":\"foo\"}" in
  match parse_sse_event None raw with
  | Some (SSEParseFailed { raw = observed_raw; reason }) ->
    observed_raw = raw && reason = "sse_event_type_missing"
  | (Some (MessageStop | (InlineContentReplay _ | ResponsesOutputItems _ | Ping | (Connected | (MessageStart _ | (ContentBlockStart _ | (ContentBlockDelta _ | (ContentBlockStop _ | (MessageDelta _ | (SSEError _ | (NDJSONError _ | (NDJSONParseFailed _ | (SSEUnknownEventType _ | (SSEUnsupportedPart _ | (SSEUnsupportedResponse _ | (Timeout _ | (StreamIncomplete _ )))))))))))))))) | None) as unexpected_event -> let (_ : sse_event option) = unexpected_event in
    false
;;

let%test "parse_sse_event: blank explicit event type yields SSEParseFailed" =
  let raw = "{}" in
  match parse_sse_event (Some "  ") raw with
  | Some (SSEParseFailed { raw = observed_raw; reason }) ->
    observed_raw = raw && reason = "sse_event_type_blank"
  | (Some (MessageStop | (InlineContentReplay _ | ResponsesOutputItems _ | Ping | (Connected | (MessageStart _ | (ContentBlockStart _ | (ContentBlockDelta _ | (ContentBlockStop _ | (MessageDelta _ | (SSEError _ | (NDJSONError _ | (NDJSONParseFailed _ | (SSEUnknownEventType _ | (SSEUnsupportedPart _ | (SSEUnsupportedResponse _ | (Timeout _ | (StreamIncomplete _ )))))))))))))))) | None) as unexpected_event -> let (_ : sse_event option) = unexpected_event in
    false
;;

let%test "parse_sse_event: non-string payload type yields SSEParseFailed" =
  let raw = "{\"type\":42}" in
  match parse_sse_event None raw with
  | Some (SSEParseFailed { raw = observed_raw; reason }) ->
    observed_raw = raw && reason = "sse_event_type_not_string"
  | (Some (MessageStop | (InlineContentReplay _ | ResponsesOutputItems _ | Ping | (Connected | (MessageStart _ | (ContentBlockStart _ | (ContentBlockDelta _ | (ContentBlockStop _ | (MessageDelta _ | (SSEError _ | (NDJSONError _ | (NDJSONParseFailed _ | (SSEUnknownEventType _ | (SSEUnsupportedPart _ | (SSEUnsupportedResponse _ | (Timeout _ | (StreamIncomplete _ )))))))))))))))) | None) as unexpected_event -> let (_ : sse_event option) = unexpected_event in
    false
;;

let%test "parse_sse_event: non-object payload yields SSEParseFailed" =
  let raw = "[]" in
  match parse_sse_event (Some "ping") raw with
  | Some (SSEParseFailed { raw = observed_raw; reason }) ->
    observed_raw = raw && reason = "sse_payload_must_be_object"
  | (Some (MessageStop | (InlineContentReplay _ | ResponsesOutputItems _ | Ping | (Connected | (MessageStart _ | (ContentBlockStart _ | (ContentBlockDelta _ | (ContentBlockStop _ | (MessageDelta _ | (SSEError _ | (NDJSONError _ | (NDJSONParseFailed _ | (SSEUnknownEventType _ | (SSEUnsupportedPart _ | (SSEUnsupportedResponse _ | (Timeout _ | (StreamIncomplete _ )))))))))))))))) | None) as unexpected_event -> let (_ : sse_event option) = unexpected_event in
    false
;;

let%test "parse_sse_event: known event still parses normally" =
  (* Sanity: refactor must not regress the happy path. *)
  let raw = "{\"type\":\"message_stop\"}" in
  match parse_sse_event None raw with
  | Some MessageStop -> true
  | (Some (InlineContentReplay _ | ResponsesOutputItems _ | Ping | (Connected | (MessageStart _ | (ContentBlockStart _ | (ContentBlockDelta _ | (ContentBlockStop _ | (MessageDelta _ | (SSEError _ | (NDJSONError _ | (SSEParseFailed _ | (NDJSONParseFailed _ | (SSEUnknownEventType _ | (SSEUnsupportedPart _ | (SSEUnsupportedResponse _ | (Timeout _ | (StreamIncomplete _ )))))))))))))))) | None) as unexpected_event -> let (_ : sse_event option) = unexpected_event in
    false
;;
