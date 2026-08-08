(** SSE event parsing and synthetic event emission.

    Pure functions operating on {!Llm_provider.Types}. No agent_sdk coupling.
    The streaming HTTP client (create_message_stream) remains in agent_sdk. *)

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
             Some
               { input_tokens
               ; output_tokens = 0
               ; cache_creation_input_tokens
               ; cache_read_input_tokens
               ; cost_usd = None
               })
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
         let usage =
           let u = json |> member "usage" in
           if u = `Null
           then None
           else (
             let output_tokens = u |> member "output_tokens" |> to_int in
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
             Some
               { input_tokens = 0
               ; output_tokens
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
           | None -> data_str
         in
         let error_type = err |> member "type" |> to_string_option in
         Some (SSEError { message; error_type; raw = data_str })
       | other -> Some (SSEUnknownEventType { event_type = other; raw = data_str }))
  with
  | Yojson.Safe.Util.Type_error (msg, _) ->
    Some (SSEParseFailed { raw = data_str; reason = "type_error: " ^ msg })
  | Yojson.Json_error msg ->
    Some (SSEParseFailed { raw = data_str; reason = "json_error: " ^ msg })
;;

(* RFC-OAS-020: TTFT classification — distinguishes Anthropic prelude
   events ([MessageStart], [ContentBlockStart], [Ping]) from the
   first generated token. Capture point in [Complete] uses this
   to fill [Streaming_summary.ttft_ms]. *)
let sse_event_is_first_token_signal (e : sse_event) : bool =
  let non_empty s = String.length s > 0 in
  match e with
  | ContentBlockDelta { delta = TextDelta s; _ } -> non_empty s
  | ContentBlockDelta { delta = ThinkingDelta s; _ } -> non_empty s
  | ContentBlockDelta { delta = ReasoningDetailsDelta { reasoning_content; details }; _ }
    ->
    (match reasoning_content with
     | Some s when non_empty s -> true
     | Some _ | None -> details <> [])
  | ContentBlockDelta { delta = InputJsonDelta s | InputJsonSnapshot s; _ } -> non_empty s
  | ContentBlockDelta { delta = MediaDelta { data; _ }; _ } -> non_empty data
  | ContentBlockDelta { delta = ThinkingSignatureDelta _; _ } -> false
  | MessageStart _
  | ContentBlockStart _
  | ContentBlockStop _
  | MessageDelta _
  | MessageStop
  | Ping
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
  | ContentBlockDelta { delta = TextDelta s; _ } -> non_empty s
  | ContentBlockDelta { delta = InputJsonDelta s | InputJsonSnapshot s; _ } -> non_empty s
  | ContentBlockDelta { delta = MediaDelta { data; _ }; _ } -> non_empty data
  | ContentBlockStart { content_type = "tool_use"; _ } -> true
  | ContentBlockDelta { delta = ThinkingSignatureDelta _; _ }
  | ContentBlockDelta { delta = ThinkingDelta _; _ }
  | ContentBlockDelta { delta = ReasoningDetailsDelta _; _ }
  | MessageStart _
  | ContentBlockStart _
  | ContentBlockStop _
  | MessageDelta _
  | MessageStop
  | Ping
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
    Used as fallback for non-Anthropic providers that don't support SSE. *)
let emit_synthetic_events (response : api_response) on_event =
  on_event
    (MessageStart { id = response.id; model = response.model; usage = response.usage });
  List.iteri
    (fun index block ->
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
          on_event
            (ContentBlockDelta
               { index; delta = InputJsonSnapshot (Yojson.Safe.to_string input) })
        | Image { media_type; data; source_type }
        | Document { media_type; data; source_type }
        | Audio { media_type; data; source_type } ->
          (* Re-emit media payload through the typed media channel so a
             non-streamed media block survives an api_response -> synthetic SSE
             -> accumulator round-trip instead of collapsing to empty text. *)
          on_event
            (ContentBlockDelta
               { index; delta = MediaDelta { media_type; source_type; data } })
        | RedactedThinking _ | ToolResult _ -> ());
       on_event (ContentBlockStop { index }))
    response.content;
  on_event
    (MessageDelta { stop_reason = Some response.stop_reason; usage = response.usage });
  on_event MessageStop
;;

let%test "emit_synthetic_events round-trips a media block through the accumulator" =
  (* A non-streamed api_response carrying an Image survives the synthetic-SSE
     fallback: emit_synthetic_events -> Complete_stream_acc -> finalize yields the
     same Image. Revert the media delta/content_type arms here (or the accumulator
     media arms) and the image collapses to empty text, so this goes red. This is
     the real producer that keeps the new MediaDelta path from being dead code. *)
  let image =
    Image { media_type = "image/png"; data = "iVBORw0KGgo="; source_type = Types.Base64 }
  in
  let response : api_response =
    { id = "msg_rt"
    ; model = "test-model"
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

    Openai Chat Completions streaming uses SSE with flat deltas:
    - Text content arrives as [delta.content] strings
    - Tool calls arrive as [delta.tool_calls] with incremental arguments
    - [finish_reason] signals end of a choice
    - No explicit content_block_start/stop events (unlike Anthropic)

    We parse each SSE chunk into {!openai_chunk}, then convert to
    {!sse_event} list using a stateful adapter ({!openai_stream_state}). *)

(* Wire shape of streamed tool-call arguments. [Args_fragment] is an incremental
   string chunk that the accumulator appends; [Args_complete] is a whole
   JSON-value snapshot serialized in a single delta, which replaces the block
   buffer so a provider that re-emits the same snapshot does not concatenate it
   into invalid JSON. Each codec and the completed ToolUse boundary validate
   the value shape they allow. *)
type tool_call_arguments =
  | Args_fragment of string
  | Args_complete of string

type openai_tool_call_delta =
  { tc_index : int
  ; tc_id : string option
  ; tc_name : string option
  ; tc_arguments : tool_call_arguments option
  }

type openai_reasoning_details_delta =
  { delta_reasoning_content : string option
  ; delta_details : reasoning_detail list
  }

type openai_chunk_parse_error =
  { reason : string
  ; raw : string
  }

type openai_chunk =
  { chunk_id : string
  ; chunk_model : string
  ; delta_content : string option
  ; delta_reasoning : string option
  ; delta_reasoning_details : openai_reasoning_details_delta option
  ; delta_tool_calls : openai_tool_call_delta list
  ; finish_reason : string option
  ; chunk_usage : api_usage option
  }

type openai_sse_parse_result =
  | Openai_chunk of openai_chunk
  | Openai_done
  | Openai_empty
  | Openai_provider_error of
      { message : string
      ; error_type : string option
      ; raw : string
      }
  | Openai_parse_failed of openai_chunk_parse_error

(* RFC-OAS-020: TTFT classification for OpenAI-compat / Gemini /
   Ollama chunk streams. [true] when this chunk would surface a
   visible token (or tool-call argument) to the application;
   [false] for role-prelude chunks, [DONE]-only finalisers, and
   empty deltas. *)
let chunk_has_non_empty_delta (c : openai_chunk) : bool =
  let non_empty_opt = function
    | Some s -> String.length s > 0
    | None -> false
  in
  let non_empty_reasoning_details = function
    | Some { delta_reasoning_content; delta_details } ->
      non_empty_opt delta_reasoning_content || delta_details <> []
    | None -> false
  in
  non_empty_opt c.delta_content
  || non_empty_opt c.delta_reasoning
  || non_empty_reasoning_details c.delta_reasoning_details
  || c.delta_tool_calls <> []
;;

(* OpenAI-compatible / GLM / DashScope / Kimi streams terminate with this
   literal SSE payload (the bare token after [data: ]), not a JSON object. SSOT
   for the sentinel shared by the chunk parser, the terminal-event helper, and
   the Responses-API trailer. *)
let openai_done_sentinel = "[DONE]"

let assoc_field_opt name = function
  | `Assoc fields -> List.assoc_opt name fields
  | `List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null -> None
;;

let non_blank_json_string = function
  | `String s when String.trim s <> "" -> Ok (Some s)
  | `String _ -> Ok None
  | `Null -> Ok None
  | `Assoc _ | `List _ | `Int _ | `Intlit _ | `Float _ | `Bool _ -> Error "not_string"
;;

let parse_stream_reasoning_detail ~index = function
  | `Assoc fields as raw ->
    let text =
      match List.assoc_opt "text" fields with
      | Some (`String s) when String.trim s <> "" -> Some s
      | Some (`String _)
      | Some (`Assoc _ | `List _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null)
      | None -> None
    in
    Ok { raw; text }
  | `List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null ->
    Error (Printf.sprintf "malformed_delta_reasoning_details:index:%d:not_object" index)
;;

let parse_stream_reasoning_details = function
  | None -> Ok None
  | Some `Null -> Ok None
  | Some (`List []) -> Ok None
  | Some (`List details) ->
    let rec loop index acc = function
      | [] -> Ok (Some (List.rev acc))
      | detail :: rest ->
        (match parse_stream_reasoning_detail ~index detail with
         | Ok parsed -> loop (index + 1) (parsed :: acc) rest
         | Error _ as error -> error)
    in
    loop 0 [] details
  | Some (`Assoc _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _) ->
    Error "malformed_delta_reasoning_details:not_list"
;;

let parse_optional_delta_string ~position ~field json =
  match assoc_field_opt field json with
  | None | Some `Null -> Ok None
  | Some (`String value) when not (Api_common.string_is_blank value) -> Ok (Some value)
  | Some (`String _) -> Ok None
  | Some (`Assoc _ | `List _ | `Int _ | `Intlit _ | `Float _ | `Bool _) ->
    Error
      (Printf.sprintf
         "malformed_delta_tool_call:position:%d:%s_not_string"
         position
         field)
;;

let parse_delta_tool_call_type ~position json =
  match assoc_field_opt "type" json with
  | None | Some `Null | Some (`String "function") -> Ok ()
  | Some (`String _) ->
    Error
      (Printf.sprintf "malformed_delta_tool_call:position:%d:unsupported_type" position)
  | Some (`Assoc _ | `List _ | `Int _ | `Intlit _ | `Float _ | `Bool _) ->
    Error
      (Printf.sprintf "malformed_delta_tool_call:position:%d:type_not_string" position)
;;

let parse_delta_tool_call_index ~position json =
  match assoc_field_opt "index" json with
  | Some (`Int index) when index >= 0 -> Ok index
  | Some (`Intlit raw) ->
    (match int_of_string_opt raw with
     | Some index when index >= 0 -> Ok index
     | Some _ | None ->
       Error
         (Printf.sprintf
            "malformed_delta_tool_call:position:%d:index_not_nonnegative_integer"
            position))
  | None | Some `Null ->
    Error (Printf.sprintf "malformed_delta_tool_call:position:%d:missing_index" position)
  | Some (`Assoc _ | `List _ | `String _ | `Float _ | `Bool _ | `Int _) ->
    Error
      (Printf.sprintf
         "malformed_delta_tool_call:position:%d:index_not_nonnegative_integer"
         position)
;;

let parse_delta_tool_call_arguments ~position function_json =
  match assoc_field_opt "arguments" function_json with
  | None | Some `Null -> Ok None
  | Some (`String arguments) -> Ok (Some (Args_fragment arguments))
  | Some arguments ->
    (match Tool_call_input.validate_object arguments with
     | Ok arguments ->
       (* Some explicitly OpenAI-compatible servers send a complete JSON object
          rather than the wire string fragment. This is a structural wire
          variant, not a provider/model-name inference: the complete value
          replaces the accumulator buffer instead of being concatenated. *)
       Ok (Some (Args_complete (Yojson.Safe.to_string arguments)))
     | Error (Tool_call_input.Invalid_json _ | Tool_call_input.Not_object) ->
       Error
         (Printf.sprintf
            "malformed_delta_tool_call:position:%d:arguments_invalid_type"
            position))
;;

let parse_openai_delta_tool_call ~position = function
  | `Assoc _ as tool_call ->
    let ( let* ) = Result.bind in
    let* tc_index = parse_delta_tool_call_index ~position tool_call in
    let* () = parse_delta_tool_call_type ~position tool_call in
    let* tc_id = parse_optional_delta_string ~position ~field:"id" tool_call in
    let* tc_name, tc_arguments =
      match assoc_field_opt "function" tool_call with
      | None | Some `Null -> Ok (None, None)
      | Some (`Assoc _ as function_json) ->
        let* tc_name =
          parse_optional_delta_string ~position ~field:"name" function_json
        in
        let* tc_arguments = parse_delta_tool_call_arguments ~position function_json in
        Ok (tc_name, tc_arguments)
      | Some (`List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _) ->
        Error
          (Printf.sprintf
             "malformed_delta_tool_call:position:%d:function_not_object"
             position)
    in
    Ok { tc_index; tc_id; tc_name; tc_arguments }
  | `List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null ->
    Error (Printf.sprintf "malformed_delta_tool_call:position:%d:not_object" position)
;;

let parse_openai_delta_tool_calls delta =
  match assoc_field_opt "tool_calls" delta with
  | None | Some `Null -> Ok []
  | Some (`List calls) ->
    let rec loop position acc = function
      | [] -> Ok (List.rev acc)
      | call :: rest ->
        (match parse_openai_delta_tool_call ~position call with
         | Ok parsed -> loop (position + 1) (parsed :: acc) rest
         | Error _ as error -> error)
    in
    loop 0 [] calls
  | Some (`Assoc _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _) ->
    Error "malformed_delta_tool_calls:not_list"
;;

let openai_provider_error_of_json ~raw json =
  match assoc_field_opt "error" json with
  | Some (`Assoc _ as error) ->
    let message =
      match assoc_field_opt "message" error with
      | Some (`String message) -> message
      | None | Some (`Assoc _ | `List _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null)
        -> raw
    in
    let error_type =
      match assoc_field_opt "type" error with
      | Some (`String error_type) -> Some error_type
      | None | Some (`Assoc _ | `List _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null)
        -> None
    in
    Some (Openai_provider_error { message; error_type; raw })
  | Some (`String message) ->
    Some (Openai_provider_error { message; error_type = None; raw })
  | None | Some (`List _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null) -> None
;;

let openai_parse_failed ~raw reason = Openai_parse_failed { reason; raw }

(** Parse one OpenAI-compatible SSE data payload into a closed result. In
    particular, [delta.tool_calls] is one atomic protocol batch: one malformed
    member rejects the whole chunk, so no valid sibling can be executed after a
    malformed sibling was silently discarded. *)
let parse_openai_sse_chunk ?streaming_reasoning data_str : openai_sse_parse_result =
  if String.equal data_str openai_done_sentinel
  then Openai_done
  else (
    match Yojson.Safe.from_string data_str with
    | exception Yojson.Json_error message ->
      openai_parse_failed ~raw:data_str ("json_error: " ^ message)
    | json ->
      (match json with
       | `List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null ->
         openai_parse_failed ~raw:data_str "malformed_openai_sse_payload:not_object"
       | `Assoc _ ->
         (match openai_provider_error_of_json ~raw:data_str json with
          | Some provider_error -> provider_error
          | None ->
            let open Yojson.Safe.Util in
            (try
               let chunk_id = Cli_common_json.member_str "id" json in
               let chunk_model = Cli_common_json.member_str "model" json in
               (* [usage] is top-level, not under a choice, so it is read even
                  for the final [choices=[]] usage chunk. *)
               let chunk_usage =
                 let usage = json |> member "usage" in
                 if usage = `Null
                 then None
                 else (
                   let cached =
                     let details = usage |> member "prompt_tokens_details" in
                     if details = `Null
                     then 0
                     else Cli_common_json.member_int "cached_tokens" details
                   in
                   Some
                     { input_tokens = Cli_common_json.member_int "prompt_tokens" usage
                     ; output_tokens =
                         Cli_common_json.member_int "completion_tokens" usage
                     ; cache_creation_input_tokens = 0
                     ; cache_read_input_tokens = cached
                     ; cost_usd = None
                     })
               in
               match assoc_field_opt "choices" json with
               | Some (`List []) ->
                 (match chunk_usage with
                  | None -> Openai_empty
                  | Some _ ->
                    Openai_chunk
                      { chunk_id
                      ; chunk_model
                      ; delta_content = None
                      ; delta_reasoning = None
                      ; delta_reasoning_details = None
                      ; delta_tool_calls = []
                      ; finish_reason = None
                      ; chunk_usage
                      })
               | Some (`List (choice :: _)) ->
                 let delta = choice |> member "delta" in
                 let delta_content = delta |> member "content" |> to_string_option in
                 let non_blank_delta_field field =
                   match delta |> member field |> to_string_option with
                   | Some value when String.trim value <> "" -> Some value
                   | Some _ | None -> None
                 in
                 let reasoning_result =
                   match streaming_reasoning with
                   | Some Reasoning_dialect.Delta_reasoning_details ->
                     let reasoning_content_result =
                       match assoc_field_opt "reasoning_content" delta with
                       | None -> Ok None
                       | Some value ->
                         (match non_blank_json_string value with
                          | Ok _ as ok -> ok
                          | Error _ ->
                            Error "malformed_delta_reasoning_content:not_string")
                     in
                     let details_result =
                       parse_stream_reasoning_details
                         (assoc_field_opt "reasoning_details" delta)
                     in
                     (match reasoning_content_result, details_result with
                      | Ok reasoning_content, Ok details ->
                        (match reasoning_content, details with
                         | None, None -> Ok (None, None)
                         | Some _, None | _, Some _ ->
                           Ok
                             ( None
                             , Some
                                 { delta_reasoning_content = reasoning_content
                                 ; delta_details = Option.value details ~default:[]
                                 } ))
                      | Error reason, Ok _ | Ok _, Error reason | Error reason, Error _ ->
                        Error reason)
                   | Some (Reasoning_dialect.Delta_field field) ->
                     Ok (non_blank_delta_field field, None)
                   | Some
                       ( Reasoning_dialect.No_streaming_reasoning
                       | Reasoning_dialect.Template_parser ) -> Ok (None, None)
                   | None ->
                     let reasoning =
                       match non_blank_delta_field "reasoning_content" with
                       | Some _ as reasoning -> reasoning
                       | None -> delta |> member "reasoning" |> to_string_option
                     in
                     Ok (reasoning, None)
                 in
                 (match reasoning_result with
                  | Error reason -> openai_parse_failed ~raw:data_str reason
                  | Ok (delta_reasoning, delta_reasoning_details) ->
                    (match parse_openai_delta_tool_calls delta with
                     | Error reason -> openai_parse_failed ~raw:data_str reason
                     | Ok delta_tool_calls ->
                       let finish_reason =
                         choice |> member "finish_reason" |> to_string_option
                       in
                       Openai_chunk
                         { chunk_id
                         ; chunk_model
                         ; delta_content
                         ; delta_reasoning
                         ; delta_reasoning_details
                         ; delta_tool_calls
                         ; finish_reason
                         ; chunk_usage
                         }))
               | None | Some `Null ->
                 openai_parse_failed
                   ~raw:data_str
                   "malformed_openai_sse_payload:missing_choices"
               | Some (`Assoc _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _) ->
                 openai_parse_failed
                   ~raw:data_str
                   "malformed_openai_sse_payload:choices_not_list"
             with
             | Yojson.Safe.Util.Type_error (message, _) ->
               openai_parse_failed ~raw:data_str ("type_error: " ^ message)
             | Yojson.Safe.Util.Undefined (message, _) ->
               openai_parse_failed ~raw:data_str ("undefined: " ^ message)
             | Invalid_argument message ->
               openai_parse_failed ~raw:data_str ("invalid_argument: " ^ message)))))
;;

(** Request-local mutable state for converting OpenAI flat deltas to block-based
    events. One sequential stream decoder owns each value; it is never shared
    across fibers or domains. *)
type thinking_state =
  | Not_thinking
  | Thinking_started of float
  | Thinking_done

type tool_index_route =
  | Tool_index_single of int
  | Tool_index_ambiguous of int list

type tool_identity_origin =
  | Provider_supplied
  | Oas_allocated

type tool_block_identity =
  { id : string
  ; origin : tool_identity_origin
  }

type openai_stream_state =
  { mutable thinking_block_started : bool
  ; mutable thinking_block_index : int
  ; mutable text_block_started : bool
  ; mutable text_block_index : int
  ; tool_blocks_by_id : (string, int) Hashtbl.t
    (** Secondary lookup index from tool identity to normalized block index.
        [tool_block_identities] remains the identity authority. *)
  ; tool_block_indices : (int, tool_index_route) Hashtbl.t
    (** tool_call wire index -> routing state. Id-less continuation fragments
        can route only while the wire index maps to one known block. Once more
        than one id has used the same wire index, id-less fragments are
        ambiguous and must fail loud rather than silently picking the last
        writer. *)
  ; tool_block_identities : (int, tool_block_identity) Hashtbl.t
    (** Normalized block index -> the identity emitted at block start.  This is
        the sole identity authority for an open tool block. *)
  ; mutable next_block_index : int
  ; mutable thinking_state : thinking_state
  ; mutable gemini_message_model : Model_id.t option
  ; provider : string
  ; model : string
  }

let create_openai_stream_state ?(provider = "") ?(model = "") () =
  { thinking_block_started = false
  ; thinking_block_index = -1
  ; text_block_started = false
  ; text_block_index = -1
  ; tool_blocks_by_id = Hashtbl.create 4
  ; tool_block_indices = Hashtbl.create 4
  ; tool_block_identities = Hashtbl.create 4
  ; next_block_index = 0
  ; thinking_state = Not_thinking
  ; gemini_message_model = None
  ; provider
  ; model
  }
;;

type openai_projection_scalar_snapshot =
  { snapshot_thinking_block_started : bool
  ; snapshot_thinking_block_index : int
  ; snapshot_text_block_started : bool
  ; snapshot_text_block_index : int
  ; snapshot_next_block_index : int
  ; snapshot_thinking_state : thinking_state
  }

type openai_projection_undo =
  | Undo_tool_block_by_id of string * int option
  | Undo_tool_index_route of int * tool_index_route option
  | Undo_tool_block_identity of int * tool_block_identity option

type openai_projection_tx =
  { state : openai_stream_state
  ; scalar_snapshot : openai_projection_scalar_snapshot
  ; mutable undo : openai_projection_undo list
  }

let begin_openai_projection state =
  { state
  ; scalar_snapshot =
      { snapshot_thinking_block_started = state.thinking_block_started
      ; snapshot_thinking_block_index = state.thinking_block_index
      ; snapshot_text_block_started = state.text_block_started
      ; snapshot_text_block_index = state.text_block_index
      ; snapshot_next_block_index = state.next_block_index
      ; snapshot_thinking_state = state.thinking_state
      }
  ; undo = []
  }
;;

let restore_table_entry table key = function
  | Some value -> Hashtbl.replace table key value
  | None -> Hashtbl.remove table key
;;

let rollback_openai_projection tx =
  let state = tx.state in
  let snapshot = tx.scalar_snapshot in
  state.thinking_block_started <- snapshot.snapshot_thinking_block_started;
  state.thinking_block_index <- snapshot.snapshot_thinking_block_index;
  state.text_block_started <- snapshot.snapshot_text_block_started;
  state.text_block_index <- snapshot.snapshot_text_block_index;
  state.next_block_index <- snapshot.snapshot_next_block_index;
  state.thinking_state <- snapshot.snapshot_thinking_state;
  List.iter
    (function
      | Undo_tool_block_by_id (id, previous) ->
        restore_table_entry state.tool_blocks_by_id id previous
      | Undo_tool_index_route (index, previous) ->
        restore_table_entry state.tool_block_indices index previous
      | Undo_tool_block_identity (index, previous) ->
        restore_table_entry state.tool_block_identities index previous)
    tx.undo
;;

let tx_replace_tool_block_by_id tx id block_index =
  tx.undo
  <- Undo_tool_block_by_id (id, Hashtbl.find_opt tx.state.tool_blocks_by_id id) :: tx.undo;
  Hashtbl.replace tx.state.tool_blocks_by_id id block_index
;;

let tx_replace_tool_index_route tx index route =
  tx.undo
  <- Undo_tool_index_route (index, Hashtbl.find_opt tx.state.tool_block_indices index)
     :: tx.undo;
  Hashtbl.replace tx.state.tool_block_indices index route
;;

let tx_replace_tool_block_identity tx index identity =
  tx.undo
  <- Undo_tool_block_identity
       (index, Hashtbl.find_opt tx.state.tool_block_identities index)
     :: tx.undo;
  Hashtbl.replace tx.state.tool_block_identities index identity
;;

let tool_index_route_add_block route block_index =
  match route with
  | Tool_index_single existing when existing = block_index -> Tool_index_single existing
  | Tool_index_single existing ->
    Tool_index_ambiguous (List.sort_uniq compare [ existing; block_index ])
  | Tool_index_ambiguous indices ->
    Tool_index_ambiguous (List.sort_uniq compare (block_index :: indices))
;;

let record_tool_index_route ?tx state tool_index block_index =
  let route =
    match Hashtbl.find_opt state.tool_block_indices tool_index with
    | Some route -> tool_index_route_add_block route block_index
    | None -> Tool_index_single block_index
  in
  match tx with
  | Some tx -> tx_replace_tool_index_route tx tool_index route
  | None -> Hashtbl.replace state.tool_block_indices tool_index route
;;

type tool_block_index_policy =
  | Next_available
  | Next_after_carrier
  | Wire_index

type idless_tool_semantics =
  (* Argument fragments continue the one call selected by the wire index. *)
  | Continue_by_wire_index
  (* Each complete provider item is a new call occurrence.  Identical
      name/arguments must not collapse into one identity. *)
  | Complete_occurrence

type tool_route_failure =
  | Ambiguous_idless_continuation
  | Late_provider_identity
  | Provider_identity_route_conflict
  | Identity_index_conflict
  | Block_index_collision
  | Missing_block_identity

type tool_block_resolution =
  | Tool_block_resolved of
      { block_index : int
      ; identity : tool_block_identity
      }
  | Tool_block_rejected of sse_event

let non_blank_provider_tool_id = function
  | Some id when not (Api_common.string_is_blank id) -> Some id
  | Some _ | None -> None
;;

let tool_route_failure_reason = function
  | Ambiguous_idless_continuation ->
    "ambiguous_tool_call_index: id-less continuation follows multiple tool identities"
  | Late_provider_identity ->
    "late_provider_tool_call_id: provider identity arrived after an OAS identity was \
     emitted"
  | Provider_identity_route_conflict ->
    "provider_tool_call_id_route_conflict: one provider identity used multiple wire \
     routes"
  | Identity_index_conflict ->
    "tool_identity_index_conflict: identity lookup and block authority disagree"
  | Block_index_collision ->
    "tool_block_index_collision: distinct tool identities require the same normalized \
     block"
  | Missing_block_identity ->
    "missing_tool_block_identity: tool route references a block without identity state"
;;

let reject_tool_block ~protocol ~wire_index failure =
  Tool_block_rejected
    (SSEParseFailed
       { raw = Printf.sprintf "%s tool_call index %d" protocol wire_index
       ; reason = tool_route_failure_reason failure
       })
;;

let register_tool_block_identity ?tx state ~block_index identity =
  match tx with
  | Some tx ->
    tx_replace_tool_block_by_id tx identity.id block_index;
    tx_replace_tool_block_identity tx block_index identity
  | None ->
    Hashtbl.replace state.tool_blocks_by_id identity.id block_index;
    Hashtbl.replace state.tool_block_identities block_index identity
;;

let open_tool_block
      ?tx
      state
      ~protocol
      ~wire_index
      ~provider_tool_id
      ~tool_name
      ~index_policy
  =
  let block_index =
    match index_policy with
    | Next_available -> state.next_block_index
    | Next_after_carrier -> state.next_block_index + 1
    | Wire_index -> wire_index
  in
  if Hashtbl.mem state.tool_block_identities block_index
  then reject_tool_block ~protocol ~wire_index Block_index_collision, None
  else (
    let identity =
      match non_blank_provider_tool_id provider_tool_id with
      | Some id -> { id; origin = Provider_supplied }
      | None -> { id = Api_common.fresh_tool_use_id (); origin = Oas_allocated }
    in
    register_tool_block_identity ?tx state ~block_index identity;
    state.next_block_index <- max state.next_block_index (block_index + 1);
    ( Tool_block_resolved { block_index; identity }
    , Some
        (ContentBlockStart
           { index = block_index
           ; content_type = "tool_use"
           ; tool_id = Some identity.id
           ; tool_name
           }) ))
;;

let resolve_tool_block
      ?tx
      state
      ~protocol
      ~wire_index
      ~provider_tool_id
      ~tool_name
      ~index_policy
      ~idless_semantics
  =
  let reject failure = reject_tool_block ~protocol ~wire_index failure, None in
  let open_and_record () =
    let resolution, start =
      open_tool_block
        ?tx
        state
        ~protocol
        ~wire_index
        ~provider_tool_id
        ~tool_name
        ~index_policy
    in
    (match resolution with
     | Tool_block_resolved { block_index; _ } ->
       record_tool_index_route ?tx state wire_index block_index
     | Tool_block_rejected _ -> ());
    resolution, start
  in
  let route_contains_block route block_index =
    match route with
    | Tool_index_single routed -> routed = block_index
    | Tool_index_ambiguous routed -> List.mem block_index routed
  in
  match non_blank_provider_tool_id provider_tool_id with
  | Some id ->
    (match Hashtbl.find_opt state.tool_blocks_by_id id with
     | Some block_index ->
       (match Hashtbl.find_opt state.tool_block_indices wire_index with
        | Some route when route_contains_block route block_index ->
          (match Hashtbl.find_opt state.tool_block_identities block_index with
           | Some identity when String.equal identity.id id ->
             Tool_block_resolved { block_index; identity }, None
           | Some _ -> reject Identity_index_conflict
           | None -> reject Missing_block_identity)
        | Some _ | None -> reject Provider_identity_route_conflict)
     | None ->
       (match Hashtbl.find_opt state.tool_block_indices wire_index with
        | Some (Tool_index_single block_index) ->
          (match Hashtbl.find_opt state.tool_block_identities block_index with
           | Some { origin = Oas_allocated; _ } -> reject Late_provider_identity
           | Some { origin = Provider_supplied; _ } ->
             (match index_policy with
              | Next_available | Next_after_carrier -> open_and_record ()
              | Wire_index -> reject Block_index_collision)
           | None -> reject Missing_block_identity)
        | Some (Tool_index_ambiguous _) ->
          (match index_policy with
           | Next_available | Next_after_carrier -> open_and_record ()
           | Wire_index -> reject Block_index_collision)
        | None -> open_and_record ()))
  | None ->
    (match idless_semantics with
     | Complete_occurrence -> open_and_record ()
     | Continue_by_wire_index ->
       (match Hashtbl.find_opt state.tool_block_indices wire_index with
        | Some (Tool_index_single block_index) ->
          (match Hashtbl.find_opt state.tool_block_identities block_index with
           | Some identity -> Tool_block_resolved { block_index; identity }, None
           | None -> reject Missing_block_identity)
        | Some (Tool_index_ambiguous _) -> reject Ambiguous_idless_continuation
        | None -> open_and_record ()))
;;

(* OpenAI-compatible streams carry no wire [content_block_stop] event (unlike
   Anthropic, whose stops are parsed straight off the wire). Synthesize one
   [ContentBlockStop] per block this state opened so the emitted OAS event
   sequence stays symmetric: every [ContentBlockStart] gets a matching
   [ContentBlockStop]. The stream accumulator ignores stops, but block-lifecycle
   consumers depend on them — a stop closes a tool block so the NEXT provider
   message (a separate stream whose block indices restart at 0) reuses the same
   index without colliding with a still-open block, and so a tool-call-end is
   surfaced for that block. Called once on the terminal [finish_reason] chunk;
   blank/missing-finish chunks never close blocks. *)
let openai_open_block_stops (state : openai_stream_state) : sse_event list =
  let indices =
    (if state.thinking_block_started then [ state.thinking_block_index ] else [])
    @ (if state.text_block_started then [ state.text_block_index ] else [])
    @ Hashtbl.fold
        (fun block_index _identity acc -> block_index :: acc)
        state.tool_block_identities
        []
  in
  indices |> List.sort_uniq compare |> List.map (fun index -> ContentBlockStop { index })
;;

(** Project one parsed chunk into locally buffered events. Tool route failures
    remain typed so the caller can roll back tool-bearing chunks before any
    event escapes. *)
let project_openai_chunk ?tx (state : openai_stream_state) (chunk : openai_chunk)
  : (sse_event list * Telemetry_event.t option, sse_event) result
  =
  let events = ref [] in
  let emit evt = events := evt :: !events in
  let telemetry_event = ref None in
  (* Reasoning content delta — emitted before text *)
  (match chunk.delta_reasoning with
   | Some text when text <> "" ->
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
     if not state.thinking_block_started
     then (
       state.thinking_block_index <- state.next_block_index;
       emit
         (ContentBlockStart
            { index = state.next_block_index
            ; content_type = "reasoning_details"
            ; tool_id = None
            ; tool_name = None
            });
       state.thinking_block_started <- true;
       state.next_block_index <- state.next_block_index + 1);
     emit
       (ContentBlockDelta
          { index = state.thinking_block_index
          ; delta =
              ReasoningDetailsDelta
                { reasoning_content = delta_reasoning_content; details = delta_details }
          })
   | None -> ());
  (* Text content delta *)
  (match chunk.delta_content with
   | Some text when text <> "" ->
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
   | Some empty_text ->
     let (_ : string) = empty_text in
     ()
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
       in
       (* Close every block this message opened before the terminal MessageDelta,
          mirroring Anthropic's content_block_stop-then-message_delta ordering.
          Without this the OpenAI-compat stream leaves tool blocks open and a
          downstream per-message block-index consumer collides on the next
          message's reused index. *)
       List.iter emit (openai_open_block_stops state);
       emit (MessageDelta { stop_reason = Some stop_reason; usage = chunk.chunk_usage })
     | None ->
       (* With stream_options.include_usage the provider sends token totals in a
          separate final chunk that has no finish_reason and an empty choices
          array (hence no content/tool deltas). Emit a MessageDelta carrying only
          the usage so the accumulator records it. The finish_reason branch above
          already forwards usage when a stop arrives in the same chunk, so the two
          paths are mutually exclusive and usage is never emitted twice. *)
       (match chunk.chunk_usage with
        | Some _ -> emit (MessageDelta { stop_reason = None; usage = chunk.chunk_usage })
        | None -> ()));
    Ok (List.rev !events, !telemetry_event)
;;

(** Convert a parsed {!openai_chunk} into {!sse_event} list.
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
  | Openai_done -> [ MessageStop ], None
  | Openai_empty -> [], None
  | Openai_provider_error { message; error_type; raw } ->
    [ SSEError { message; error_type; raw } ], None
  | Openai_parse_failed { reason; raw } -> [ SSEParseFailed { reason; raw } ], None
;;

let test_tool_use_start_with_name = function
  | ContentBlockStart { index; content_type = "tool_use"; tool_name; _ } ->
    Some (index, tool_name)
  | MessageStart _
  | ContentBlockStart _
  | ContentBlockDelta _
  | ContentBlockStop _
  | MessageDelta _
  | MessageStop
  | Ping
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

let test_tool_use_start = function
  | ContentBlockStart { content_type = "tool_use"; _ } -> Some ()
  | MessageStart _
  | ContentBlockStart _
  | ContentBlockDelta _
  | ContentBlockStop _
  | MessageDelta _
  | MessageStop
  | Ping
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

let test_input_json_delta = function
  | ContentBlockDelta { index; delta = InputJsonDelta s } -> Some (index, s)
  | MessageStart _
  | ContentBlockStart _
  | ContentBlockDelta _
  | ContentBlockStop _
  | MessageDelta _
  | MessageStop
  | Ping
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
     into one buffer, which previously concatenated their arguments into invalid
     JSON and failed the turn with malformed_tool_use_arguments. *)
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
    ; delta_reasoning = None
    ; delta_reasoning_details = None
    ; delta_tool_calls =
        [ mk "a" "list_tasks" {|{"limit":5}|}
        ; mk "b" "run_shell" {|{"argv":["git"]}|}
        ; mk "c" "read_file" {|{"file_path":"x"}|}
        ]
    ; finish_reason = None
    ; chunk_usage = None
    }
  in
  let events, _ = openai_chunk_to_events state chunk in
  let starts = List.filter_map test_tool_use_start_with_name events in
  let deltas = List.filter_map test_input_json_delta events in
  starts = [ 0, Some "list_tasks"; 1, Some "run_shell"; 2, Some "read_file" ]
  && deltas = [ 0, {|{"limit":5}|}; 1, {|{"argv":["git"]}|}; 2, {|{"file_path":"x"}|} ]
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
    ; delta_reasoning = None
    ; delta_reasoning_details = None
    ; delta_tool_calls = []
    ; finish_reason = None
    ; chunk_usage = None
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
    ; delta_reasoning = None
    ; delta_reasoning_details = None
    ; delta_tool_calls = []
    ; finish_reason = None
    ; chunk_usage = None
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
        | _ -> None)
      events
  in
  let deltas =
    List.filter_map
      (function
        | ContentBlockDelta { index; delta = InputJsonDelta s } -> Some (index, s)
        | _ -> None)
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
    ; delta_reasoning = None
    ; delta_reasoning_details = None
    ; delta_tool_calls = []
    ; finish_reason = None
    ; chunk_usage = None
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
  | unexpected_events ->
    let (_ : sse_event list) = unexpected_events in
    false
;;

(** {1 OpenAI Responses API SSE Streaming}

    Responses streaming uses item-level event names:
    - [response.output_text.delta] for assistant text
    - [response.reasoning_summary_text.delta] / [response.reasoning_text.delta]
      for reasoning summaries/text
    - [response.output_item.added] + [response.function_call_arguments.delta]
      for function calls
    - [response.completed] / [response.incomplete] / [response.failed] for
      terminal status and usage.

    Keep this separate from {!parse_openai_sse_chunk}: Responses has no
    [choices[].delta] envelope. *)

let responses_member_string_opt key json =
  let open Yojson.Safe.Util in
  json |> member key |> to_string_option
;;

let responses_member_int_default key json =
  let open Yojson.Safe.Util in
  json |> member key |> to_int_option |> Option.value ~default:0
;;

let responses_advance_next_block_index state index =
  if index >= state.next_block_index then state.next_block_index <- index + 1
;;

let responses_usage_of_response response =
  let open Yojson.Safe.Util in
  match response |> member "usage" with
  | `Assoc _ as usage ->
    let input_tokens = responses_member_int_default "input_tokens" usage in
    let output_tokens = responses_member_int_default "output_tokens" usage in
    let cache_read_input_tokens =
      match usage |> member "input_tokens_details" with
      | `Assoc _ as details -> responses_member_int_default "cached_tokens" details
      | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> 0
    in
    Some
      { input_tokens
      ; output_tokens
      ; cache_creation_input_tokens = 0
      ; cache_read_input_tokens
      ; cost_usd = None
      }
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> None
;;

let responses_output_has_function_call response =
  let open Yojson.Safe.Util in
  match response |> member "output" with
  | `List items ->
    List.exists
      (fun item ->
         match responses_member_string_opt "type" item with
         | Some ("function_call" | "custom_tool_call") -> true
         | Some _ | None -> false)
      items
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ -> false
;;

let responses_incomplete_reason_opt response =
  let open Yojson.Safe.Util in
  match response |> member "incomplete_details" with
  | `Assoc _ as details -> responses_member_string_opt "reason" details
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> None
;;

let responses_incomplete_reason response =
  responses_incomplete_reason_opt response |> Option.value ~default:"incomplete"
;;

let responses_failed_message response =
  let open Yojson.Safe.Util in
  match response |> member "error" with
  | `Assoc _ as err -> responses_member_string_opt "message" err
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> None
;;

let responses_stop_reason_of_response response =
  Responses_stop_reason.of_status
    ~status:(responses_member_string_opt "status" response)
    ~incomplete_reason:(responses_incomplete_reason_opt response)
    ~failed_message:(responses_failed_message response)
    ~has_tool_calls:(responses_output_has_function_call response)
;;

let responses_error_message json =
  let open Yojson.Safe.Util in
  match json |> member "error" with
  | `Assoc _ as err ->
    responses_member_string_opt "message" err |> Option.value ~default:"Responses error"
  | `String message -> message
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `List _ ->
    responses_member_string_opt "message" json |> Option.value ~default:"Responses error"
;;

let responses_error_type json =
  let open Yojson.Safe.Util in
  match json |> member "error" with
  | `Assoc _ as err ->
    (match responses_member_string_opt "type" err with
     | Some _ as t -> t
     | None -> responses_member_string_opt "code" err)
  | `String _ | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `List _ ->
    responses_member_string_opt "code" json
;;

let responses_ensure_thinking_block state emit ~output_index =
  (match state.thinking_state with
   | Not_thinking -> state.thinking_state <- Thinking_started (Unix.gettimeofday ())
   | Thinking_started _ | Thinking_done -> ());
  if not state.thinking_block_started
  then (
    state.thinking_block_index <- output_index;
    emit
      (ContentBlockStart
         { index = output_index
         ; content_type = "thinking"
         ; tool_id = None
         ; tool_name = None
         });
    state.thinking_block_started <- true;
    responses_advance_next_block_index state output_index);
  state.thinking_block_index
;;

let responses_ensure_text_block state emit ~output_index =
  if not state.text_block_started
  then (
    state.text_block_index <- output_index;
    emit
      (ContentBlockStart
         { index = output_index; content_type = "text"; tool_id = None; tool_name = None });
    state.text_block_started <- true;
    responses_advance_next_block_index state output_index);
  state.text_block_index
;;

let responses_tool_id_of_item item = responses_member_string_opt "call_id" item

let responses_ensure_tool_block state emit ~output_index ~tool_id ~tool_name =
  let resolution, start =
    resolve_tool_block
      state
      ~protocol:"openai_responses"
      ~wire_index:output_index
      ~provider_tool_id:tool_id
      ~tool_name
      ~index_policy:Wire_index
      ~idless_semantics:Continue_by_wire_index
  in
  Option.iter emit start;
  match resolution with
  | Tool_block_resolved { block_index; _ } -> Some block_index
  | Tool_block_rejected error ->
    emit error;
    None
;;

let responses_emit_redacted_reasoning_outputs state emit response =
  let open Yojson.Safe.Util in
  match response |> member "output" with
  | `List items ->
    List.iteri
      (fun output_index item ->
         match responses_member_string_opt "type" item with
         | Some "reasoning" ->
           (match item |> member "encrypted_content" |> to_string_option with
            | Some encrypted_content when String.trim encrypted_content <> "" ->
              emit
                (ContentBlockStart
                   { index = output_index
                   ; content_type = "redacted_thinking"
                   ; tool_id = Some (Yojson.Safe.to_string item)
                   ; tool_name = None
                   });
              responses_advance_next_block_index state output_index
            | Some _ | None -> ())
         | Some _ | None -> ())
      items
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ -> ()
;;

let responses_sse_to_events (state : openai_stream_state) event_type data_str
  : sse_event list * Telemetry_event.t option
  =
  (* The Responses API delivers its terminal status via a [response.completed]
     event before this trailing sentinel, so [DONE] needs no synthesized
     terminal here -- the accumulator already has a stop_reason. *)
  if String.equal data_str openai_done_sentinel
  then [], None
  else (
    (* Decode through the shared total boundary (#2620): a valid-JSON
       non-object frame raises Util.Type_error out of [member], which a
       Json_error-only guard would let escape the parser (oas#2632). *)
    let decode json =
      let open Yojson.Safe.Util in
      let evt_type =
        match event_type with
        | Some t when String.trim t <> "" -> t
        | Some _ | None -> Cli_common_json.member_str "type" json
      in
      let events = ref [] in
      let emit evt = events := evt :: !events in
      let emit_terminal response =
        emit
          (MessageDelta
             { stop_reason = responses_stop_reason_of_response response
             ; usage = responses_usage_of_response response
             });
        emit MessageStop
      in
      (match evt_type with
       | "response.created" ->
         let response = json |> member "response" in
         emit
           (MessageStart
              { id = Cli_common_json.member_str "id" response
              ; model = Cli_common_json.member_str "model" response
              ; usage = responses_usage_of_response response
              })
       | "response.output_text.delta" ->
         (match responses_member_string_opt "delta" json with
          | Some delta when delta <> "" ->
            let output_index = responses_member_int_default "output_index" json in
            let index = responses_ensure_text_block state emit ~output_index in
            emit (ContentBlockDelta { index; delta = TextDelta delta })
          | Some _ | None -> ())
       | "response.output_text.done" ->
         if not state.text_block_started
         then (
           match responses_member_string_opt "text" json with
           | Some text when text <> "" ->
             let output_index = responses_member_int_default "output_index" json in
             let index = responses_ensure_text_block state emit ~output_index in
             emit (ContentBlockDelta { index; delta = TextDelta text })
           | Some _ | None -> ())
       | "response.reasoning_summary_text.delta" | "response.reasoning_text.delta" ->
         (match responses_member_string_opt "delta" json with
          | Some delta when delta <> "" ->
            let output_index = responses_member_int_default "output_index" json in
            let index = responses_ensure_thinking_block state emit ~output_index in
            emit (ContentBlockDelta { index; delta = ThinkingDelta delta })
          | Some _ | None -> ())
       | "response.reasoning_summary_text.done" | "response.reasoning_text.done" ->
         if not state.thinking_block_started
         then (
           match responses_member_string_opt "text" json with
           | Some text when text <> "" ->
             let output_index = responses_member_int_default "output_index" json in
             let index = responses_ensure_thinking_block state emit ~output_index in
             emit (ContentBlockDelta { index; delta = ThinkingDelta text })
           | Some _ | None -> ())
       | "response.output_item.added" ->
         let output_index = responses_member_int_default "output_index" json in
         let item = json |> member "item" in
         (match responses_member_string_opt "type" item with
          | Some ("function_call" | "custom_tool_call") ->
            let (_ : int option) =
              responses_ensure_tool_block
                state
                emit
                ~output_index
                ~tool_id:(responses_tool_id_of_item item)
                ~tool_name:(responses_member_string_opt "name" item)
            in
            ()
          | Some _ | None -> ())
       | "response.function_call_arguments.delta" ->
         (match responses_member_string_opt "delta" json with
          | Some delta when delta <> "" ->
            let output_index = responses_member_int_default "output_index" json in
            let index =
              responses_ensure_tool_block
                state
                emit
                ~output_index
                  (* [call_id] is the function-call identity on every official
                   arguments event. [item_id] identifies only the output item
                   and is never substituted for it. *)
                ~tool_id:(responses_member_string_opt "call_id" json)
                ~tool_name:None
            in
            (match index with
             | Some index ->
               emit (ContentBlockDelta { index; delta = InputJsonDelta delta })
             | None -> ())
          | Some _ | None -> ())
       | "response.completed" | "response.incomplete" ->
         let response = json |> member "response" in
         responses_emit_redacted_reasoning_outputs state emit response;
         (* A [response.incomplete] terminal means the turn was cut off, so any
            in-progress tool call is partial. Carry that to the accumulator
            (which drops partial tool blocks at finalize) for ANY incomplete
            reason — [stop_reason = MaxTokens] alone only covers
            max_output_tokens, not e.g. content_filter. (#2073 follow-up.) *)
         (match responses_member_string_opt "status" response with
          | Some "incomplete" ->
            emit (StreamIncomplete { reason = responses_incomplete_reason response })
          | Some _ | None -> ());
         emit_terminal response
       | "response.failed" | "error" ->
         emit
           (SSEError
              { message = responses_error_message json
              ; error_type = responses_error_type json
              ; raw = data_str
              })
       | "response.in_progress"
       | "response.output_item.done"
       | "response.content_part.added"
       | "response.content_part.done"
       | "response.function_call_arguments.done"
       | "response.reasoning_summary_part.added"
       | "response.reasoning_summary_part.done"
       | "response.refusal.delta"
       | "response.refusal.done"
       | "response.queued" -> ()
       | other -> emit (SSEUnknownEventType { event_type = other; raw = data_str }));
      List.rev !events, None
    in
    match Json_util.decode_json_with decode data_str with
    | Ok result -> result
    | Error reason -> [ SSEParseFailed { raw = data_str; reason } ], None)
;;

(** {1 Gemini SSE Streaming}

    Gemini [streamGenerateContent?alt=sse] emits SSE data lines with
    JSON payloads: [{candidates: [{content: {parts: [...]}}]}].
    Each chunk may contain text, thought, or functionCall parts. *)

type gemini_terminal_reason =
  | Gemini_candidate_finish_reason of string
  | Gemini_prompt_block_reason of string

type gemini_chunk =
  { gem_model : string option
  ; gem_parts : Yojson.Safe.t list
  ; gem_finish_reason : gemini_terminal_reason option
  ; gem_usage : api_usage option
  }

type gemini_unsupported_part =
  | Gemini_executable_code
  | Gemini_code_execution_result
  | Gemini_tool_call
  | Gemini_tool_response
  | Gemini_function_response
  | Gemini_file_data
  | Gemini_audio_transcription
  | Gemini_streaming_function_call_arguments
  | Gemini_streaming_function_call_continuation

type gemini_unsupported_response = Gemini_multiple_candidates of { count : int }

type gemini_sse_parse_result =
  | Gemini_chunk of gemini_chunk
  | Gemini_unsupported_part of
      { part : gemini_unsupported_part
      ; raw : string
      }
  | Gemini_unsupported_response of
      { response : gemini_unsupported_response
      ; raw : string
      }
  | Gemini_parse_failed of
      { reason : string
      ; raw : string
      }

type gemini_chunk_to_events_error = { reason : string }

let gemini_assoc_field key = function
  | `Assoc fields -> List.assoc_opt key fields
  | `List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null -> None
;;

let gemini_field ~path key json =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some value -> Ok value
     | None -> Error (Printf.sprintf "%s.%s:missing" path key))
  | value ->
    Error (Printf.sprintf "%s:not_object(got %s)" path (Json_util.json_type_name value))
;;

let gemini_object ~path = function
  | `Assoc _ as value -> Ok value
  | value ->
    Error (Printf.sprintf "%s:not_object(got %s)" path (Json_util.json_type_name value))
;;

let gemini_list ~path = function
  | `List values -> Ok values
  | value ->
    Error (Printf.sprintf "%s:not_array(got %s)" path (Json_util.json_type_name value))
;;

let gemini_optional_string ~path key json =
  match gemini_assoc_field key json with
  | None | Some `Null -> Ok None
  | Some (`String value) -> Ok (Some value)
  | Some value ->
    Error
      (Printf.sprintf
         "%s.%s:not_string(got %s)"
         path
         key
         (Json_util.json_type_name value))
;;

let gemini_required_string ~path key json =
  match gemini_field ~path key json with
  | Ok (`String value) when not (Api_common.string_is_blank value) -> Ok value
  | Ok (`String _) -> Error (Printf.sprintf "%s.%s:blank" path key)
  | Ok value ->
    Error
      (Printf.sprintf
         "%s.%s:not_string(got %s)"
         path
         key
         (Json_util.json_type_name value))
  | Error _ as error -> error
;;

let gemini_optional_int_default_zero ~path key json =
  match gemini_assoc_field key json with
  | None | Some `Null -> Ok 0
  | Some (`Int value) -> Ok value
  | Some (`Intlit raw) ->
    (match int_of_string_opt raw with
     | Some value -> Ok value
     | None -> Error (Printf.sprintf "%s.%s:not_integer" path key))
  | Some value ->
    Error
      (Printf.sprintf
         "%s.%s:not_integer(got %s)"
         path
         key
         (Json_util.json_type_name value))
;;

let gemini_part_metadata_object_fields =
  [ "partMetadata"; "mediaResolution"; "videoMetadata" ]
;;

let gemini_part_metadata_fields =
  [ "thought"; "thoughtSignature" ] @ gemini_part_metadata_object_fields
;;

let validate_gemini_part_metadata ~path part =
  let ( let* ) = Result.bind in
  let* () =
    match gemini_assoc_field "thought" part with
    | None | Some `Null | Some (`Bool _) -> Ok ()
    | Some value ->
      Error
        (Printf.sprintf
           "%s.thought:not_boolean(got %s)"
           path
           (Json_util.json_type_name value))
  in
  let* () =
    match gemini_assoc_field "thoughtSignature" part with
    | None | Some `Null -> Ok ()
    | Some (`String value) when not (Api_common.string_is_blank value) -> Ok ()
    | Some (`String _) -> Error (Printf.sprintf "%s.thoughtSignature:blank" path)
    | Some value ->
      Error
        (Printf.sprintf
           "%s.thoughtSignature:not_string(got %s)"
           path
           (Json_util.json_type_name value))
  in
  let rec validate_objects = function
    | [] -> Ok ()
    | key :: rest ->
      (match gemini_assoc_field key part with
       | None | Some `Null | Some (`Assoc _) -> validate_objects rest
       | Some value ->
         Error
           (Printf.sprintf
              "%s.%s:not_object(got %s)"
              path
              key
              (Json_util.json_type_name value)))
  in
  validate_objects gemini_part_metadata_object_fields
;;

let gemini_supported_part_payloads = [ "text"; "functionCall"; "inlineData" ]

let validate_gemini_part ~position part =
  let ( let* ) = Result.bind in
  let path = Printf.sprintf "gemini.candidates[0].content.parts[%d]" position in
  let* fields =
    match part with
    | `Assoc fields -> Ok fields
    | value ->
      Error (Printf.sprintf "%s:not_object(got %s)" path (Json_util.json_type_name value))
  in
  let part = `Assoc fields in
  let* () =
    let unsupported_field =
      List.find_opt
        (fun (key, _) ->
           not
             (List.mem key (gemini_supported_part_payloads @ gemini_part_metadata_fields)))
        fields
    in
    match unsupported_field with
    | Some (key, _) -> Error (Printf.sprintf "%s.%s:unsupported_field" path key)
    | None -> Ok ()
  in
  let* () = validate_gemini_part_metadata ~path part in
  let payloads =
    List.filter_map
      (fun key ->
         match gemini_assoc_field key part with
         | None -> None
         | Some value -> Some (key, value))
      gemini_supported_part_payloads
  in
  match payloads with
  | [] -> Error (path ^ ":missing_supported_payload")
  | [ ("text", `String _) ] -> Ok ()
  | [ ("text", value) ] ->
    Error
      (Printf.sprintf "%s.text:not_string(got %s)" path (Json_util.json_type_name value))
  | [ ("functionCall", (`Assoc function_call_fields as function_call)) ] ->
    let unsupported_field =
      List.find_opt
        (fun (key, _) -> not (List.mem key [ "id"; "name"; "args"; "willContinue" ]))
        function_call_fields
    in
    let* () =
      match unsupported_field with
      | Some (key, _) ->
        Error (Printf.sprintf "%s.functionCall.%s:unsupported_field" path key)
      | None -> Ok ()
    in
    let* _id = gemini_optional_string ~path:(path ^ ".functionCall") "id" function_call in
    let* _ = gemini_required_string ~path:(path ^ ".functionCall") "name" function_call in
    let* () =
      match gemini_assoc_field "args" function_call with
      | None | Some `Null | Some (`Assoc _) -> Ok ()
      | Some value ->
        Error
          (Printf.sprintf
             "%s.functionCall.args:not_object(got %s)"
             path
             (Json_util.json_type_name value))
    in
    let* () =
      match gemini_assoc_field "willContinue" function_call with
      | None | Some `Null | Some (`Bool _) -> Ok ()
      | Some value ->
        Error
          (Printf.sprintf
             "%s.functionCall.willContinue:not_boolean(got %s)"
             path
             (Json_util.json_type_name value))
    in
    Ok ()
  | [ ("functionCall", value) ] ->
    Error
      (Printf.sprintf
         "%s.functionCall:not_object(got %s)"
         path
         (Json_util.json_type_name value))
  | [ ("inlineData", `Assoc _) ] -> Ok ()
  | [ ("inlineData", value) ] ->
    Error
      (Printf.sprintf
         "%s.inlineData:not_object(got %s)"
         path
         (Json_util.json_type_name value))
  | [ (key, _) ] -> Error (Printf.sprintf "%s.%s:unsupported_payload" path key)
  | _ :: _ :: _ -> Error (path ^ ":multiple_payloads")
;;

type gemini_payload_failure =
  | Gemini_payload_malformed of string
  | Gemini_payload_unsupported_part of gemini_unsupported_part
  | Gemini_payload_unsupported_response of gemini_unsupported_response

type gemini_unsupported_payload_kind =
  | Gemini_executable_code_payload
  | Gemini_code_execution_result_payload
  | Gemini_tool_call_payload
  | Gemini_tool_response_payload
  | Gemini_function_response_payload
  | Gemini_file_data_payload
  | Gemini_audio_transcription_payload

let gemini_unsupported_payload_kind_wire_name = function
  | Gemini_executable_code_payload -> "executableCode"
  | Gemini_code_execution_result_payload -> "codeExecutionResult"
  | Gemini_tool_call_payload -> "toolCall"
  | Gemini_tool_response_payload -> "toolResponse"
  | Gemini_function_response_payload -> "functionResponse"
  | Gemini_file_data_payload -> "fileData"
  | Gemini_audio_transcription_payload -> "audioTranscription"
;;

let gemini_unsupported_part_of_payload_kind = function
  | Gemini_executable_code_payload -> Gemini_executable_code
  | Gemini_code_execution_result_payload -> Gemini_code_execution_result
  | Gemini_tool_call_payload -> Gemini_tool_call
  | Gemini_tool_response_payload -> Gemini_tool_response
  | Gemini_function_response_payload -> Gemini_function_response
  | Gemini_file_data_payload -> Gemini_file_data
  | Gemini_audio_transcription_payload -> Gemini_audio_transcription
;;

let gemini_unsupported_part_wire_name = function
  | Gemini_executable_code ->
    gemini_unsupported_payload_kind_wire_name Gemini_executable_code_payload
  | Gemini_code_execution_result ->
    gemini_unsupported_payload_kind_wire_name Gemini_code_execution_result_payload
  | Gemini_tool_call -> gemini_unsupported_payload_kind_wire_name Gemini_tool_call_payload
  | Gemini_tool_response ->
    gemini_unsupported_payload_kind_wire_name Gemini_tool_response_payload
  | Gemini_function_response ->
    gemini_unsupported_payload_kind_wire_name Gemini_function_response_payload
  | Gemini_file_data -> gemini_unsupported_payload_kind_wire_name Gemini_file_data_payload
  | Gemini_audio_transcription ->
    gemini_unsupported_payload_kind_wire_name Gemini_audio_transcription_payload
  | Gemini_streaming_function_call_arguments -> "functionCall.partialArgs"
  | Gemini_streaming_function_call_continuation -> "functionCall.willContinue"
;;

let gemini_unsupported_response_wire_name = function
  | Gemini_multiple_candidates _ -> "candidates"
;;

let gemini_unsupported_payload_kinds =
  [ Gemini_executable_code_payload
  ; Gemini_code_execution_result_payload
  ; Gemini_tool_call_payload
  ; Gemini_tool_response_payload
  ; Gemini_function_response_payload
  ; Gemini_file_data_payload
  ; Gemini_audio_transcription_payload
  ]
;;

let gemini_unsupported_part_fields =
  List.map gemini_unsupported_payload_kind_wire_name gemini_unsupported_payload_kinds
  @ gemini_part_metadata_fields
;;

let gemini_validate_allowed_fields ~path ~allowed fields =
  match List.find_opt (fun (key, _) -> not (List.mem key allowed)) fields with
  | Some (key, _) -> Error (Printf.sprintf "%s.%s:unsupported_field" path key)
  | None -> Ok ()
;;

let gemini_object_fields ~path = function
  | `Assoc fields -> Ok fields
  | value ->
    Error (Printf.sprintf "%s:not_object(got %s)" path (Json_util.json_type_name value))
;;

let gemini_optional_object ~path key json =
  match gemini_assoc_field key json with
  | None | Some `Null | Some (`Assoc _) -> Ok ()
  | Some value ->
    Error
      (Printf.sprintf
         "%s.%s:not_object(got %s)"
         path
         key
         (Json_util.json_type_name value))
;;

let validate_gemini_unsupported_part_envelope ~path fields =
  let ( let* ) = Result.bind in
  let* () =
    gemini_validate_allowed_fields ~path ~allowed:gemini_unsupported_part_fields fields
  in
  validate_gemini_part_metadata ~path (`Assoc fields)
;;

let gemini_unsupported_part_of_json ~position part =
  let path = Printf.sprintf "gemini.candidates[0].content.parts[%d]" position in
  match part with
  | `Assoc fields ->
    let streaming_function_call =
      match List.assoc_opt "functionCall" fields with
      | Some (`Assoc function_call_fields) ->
        if List.mem_assoc "partialArgs" function_call_fields
        then Some Gemini_streaming_function_call_arguments
        else if List.assoc_opt "willContinue" function_call_fields = Some (`Bool true)
        then Some Gemini_streaming_function_call_continuation
        else None
      | Some _ | None -> None
    in
    (match streaming_function_call with
     | Some unsupported_part ->
       Some
         (let ( let* ) = Result.bind in
          let* () =
            gemini_validate_allowed_fields
              ~path
              ~allowed:(gemini_supported_part_payloads @ gemini_part_metadata_fields)
              fields
          in
          let* () = validate_gemini_part_metadata ~path (`Assoc fields) in
          let function_call_path = path ^ ".functionCall" in
          let* function_call_fields =
            match List.assoc_opt "functionCall" fields with
            | Some value -> gemini_object_fields ~path:function_call_path value
            | None -> Error (function_call_path ^ ":missing")
          in
          let* () =
            gemini_validate_allowed_fields
              ~path:function_call_path
              ~allowed:[ "id"; "name"; "args"; "partialArgs"; "willContinue" ]
              function_call_fields
          in
          let function_call = `Assoc function_call_fields in
          let* _id = gemini_optional_string ~path:function_call_path "id" function_call in
          let* _name =
            gemini_optional_string ~path:function_call_path "name" function_call
          in
          let* () =
            gemini_optional_object ~path:function_call_path "args" function_call
          in
          let* () =
            match gemini_assoc_field "partialArgs" function_call with
            | None | Some `Null | Some (`List _) -> Ok ()
            | Some value ->
              Error
                (Printf.sprintf
                   "%s.partialArgs:not_array(got %s)"
                   function_call_path
                   (Json_util.json_type_name value))
          in
          let* () =
            match gemini_assoc_field "willContinue" function_call with
            | None | Some `Null | Some (`Bool _) -> Ok ()
            | Some value ->
              Error
                (Printf.sprintf
                   "%s.willContinue:not_boolean(got %s)"
                   function_call_path
                   (Json_util.json_type_name value))
          in
          Ok unsupported_part)
     | None ->
       let payloads =
         List.filter_map
           (fun kind ->
              let key = gemini_unsupported_payload_kind_wire_name kind in
              match List.assoc_opt key fields with
              | Some value -> Some (kind, value)
              | None -> None)
           gemini_unsupported_payload_kinds
       in
       (match payloads with
        | [] -> None
        | _ :: _ :: _ -> Some (Error (path ^ ":multiple_payloads"))
        | [ (Gemini_executable_code_payload, value) ] ->
          let ( let* ) = Result.bind in
          Some
            (let* () = validate_gemini_unsupported_part_envelope ~path fields in
             let* code_fields =
               gemini_object_fields ~path:(path ^ ".executableCode") value
             in
             let* () =
               gemini_validate_allowed_fields
                 ~path:(path ^ ".executableCode")
                 ~allowed:[ "id"; "language"; "code" ]
                 code_fields
             in
             let code = `Assoc code_fields in
             let* _id =
               gemini_optional_string ~path:(path ^ ".executableCode") "id" code
             in
             let* _language =
               gemini_required_string ~path:(path ^ ".executableCode") "language" code
             in
             let* _code =
               gemini_required_string ~path:(path ^ ".executableCode") "code" code
             in
             Ok Gemini_executable_code)
        | [ (Gemini_code_execution_result_payload, value) ] ->
          let ( let* ) = Result.bind in
          Some
            (let* () = validate_gemini_unsupported_part_envelope ~path fields in
             let* result_fields =
               gemini_object_fields ~path:(path ^ ".codeExecutionResult") value
             in
             let* () =
               gemini_validate_allowed_fields
                 ~path:(path ^ ".codeExecutionResult")
                 ~allowed:[ "id"; "outcome"; "output" ]
                 result_fields
             in
             let result = `Assoc result_fields in
             let* _id =
               gemini_optional_string ~path:(path ^ ".codeExecutionResult") "id" result
             in
             let* _outcome =
               gemini_required_string
                 ~path:(path ^ ".codeExecutionResult")
                 "outcome"
                 result
             in
             let* _output =
               gemini_optional_string
                 ~path:(path ^ ".codeExecutionResult")
                 "output"
                 result
             in
             Ok Gemini_code_execution_result)
        | [ (Gemini_tool_call_payload, value) ] ->
          let ( let* ) = Result.bind in
          Some
            (let* () = validate_gemini_unsupported_part_envelope ~path fields in
             let tool_call_path = path ^ ".toolCall" in
             let* tool_call_fields = gemini_object_fields ~path:tool_call_path value in
             let* () =
               gemini_validate_allowed_fields
                 ~path:tool_call_path
                 ~allowed:[ "id"; "toolType"; "args" ]
                 tool_call_fields
             in
             let tool_call = `Assoc tool_call_fields in
             let* _id = gemini_required_string ~path:tool_call_path "id" tool_call in
             let* _tool_type =
               gemini_required_string ~path:tool_call_path "toolType" tool_call
             in
             let* () = gemini_optional_object ~path:tool_call_path "args" tool_call in
             Ok Gemini_tool_call)
        | [ (Gemini_tool_response_payload, value) ] ->
          let ( let* ) = Result.bind in
          Some
            (let* () = validate_gemini_unsupported_part_envelope ~path fields in
             let tool_response_path = path ^ ".toolResponse" in
             let* tool_response_fields =
               gemini_object_fields ~path:tool_response_path value
             in
             let* () =
               gemini_validate_allowed_fields
                 ~path:tool_response_path
                 ~allowed:[ "id"; "toolType"; "response" ]
                 tool_response_fields
             in
             let tool_response = `Assoc tool_response_fields in
             let* _id =
               gemini_required_string ~path:tool_response_path "id" tool_response
             in
             let* _tool_type =
               gemini_required_string ~path:tool_response_path "toolType" tool_response
             in
             let* () =
               gemini_optional_object ~path:tool_response_path "response" tool_response
             in
             Ok Gemini_tool_response)
        | [ ( (( Gemini_function_response_payload
               | Gemini_file_data_payload
               | Gemini_audio_transcription_payload ) as kind)
            , value )
          ] ->
          let ( let* ) = Result.bind in
          Some
            (let* () = validate_gemini_unsupported_part_envelope ~path fields in
             let* _ =
               gemini_object_fields
                 ~path:(path ^ "." ^ gemini_unsupported_payload_kind_wire_name kind)
                 value
             in
             Ok (gemini_unsupported_part_of_payload_kind kind))))
  | `List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null -> None
;;

let parse_gemini_json json : (gemini_chunk, gemini_payload_failure) result =
  let malformed result =
    Result.map_error (fun reason -> Gemini_payload_malformed reason) result
  in
  let gemini_optional_string ~path key json =
    malformed (gemini_optional_string ~path key json)
  in
  let gemini_optional_finish_reason ~path json =
    match gemini_optional_string ~path "finishReason" json with
    | Ok (Some "") -> Ok None
    | result -> result
  in
  let gemini_required_string ~path key json =
    malformed (gemini_required_string ~path key json)
  in
  let gemini_field ~path key json = malformed (gemini_field ~path key json) in
  let gemini_list ~path json = malformed (gemini_list ~path json) in
  let gemini_object ~path json = malformed (gemini_object ~path json) in
  let gemini_optional_int_default_zero ~path key json =
    malformed (gemini_optional_int_default_zero ~path key json)
  in
  let ( let* ) = Result.bind in
  let* () =
    match json with
    | `Assoc _ -> Ok ()
    | value ->
      Error
        (Gemini_payload_malformed
           (Printf.sprintf
              "gemini_sse_payload:not_object(got %s)"
              (Json_util.json_type_name value)))
  in
  let* model_version = gemini_optional_string ~path:"gemini" "modelVersion" json in
  let* candidates =
    match gemini_assoc_field "candidates" json with
    | None | Some `Null -> Ok []
    | Some candidates -> gemini_list ~path:"gemini.candidates" candidates
  in
  let* candidate, gem_finish_reason =
    match candidates with
    | [ candidate ] ->
      let* candidate = gemini_object ~path:"gemini.candidates[0]" candidate in
      let* finish_reason =
        gemini_optional_finish_reason ~path:"gemini.candidates[0]" candidate
      in
      Ok
        ( candidate
        , Option.map (fun reason -> Gemini_candidate_finish_reason reason) finish_reason
        )
    | _ :: _ ->
      Error
        (Gemini_payload_unsupported_response
           (Gemini_multiple_candidates { count = List.length candidates }))
    | [] ->
      let* prompt_feedback = gemini_field ~path:"gemini" "promptFeedback" json in
      let* prompt_feedback =
        gemini_object ~path:"gemini.promptFeedback" prompt_feedback
      in
      let* block_reason =
        gemini_required_string ~path:"gemini.promptFeedback" "blockReason" prompt_feedback
      in
      Ok (`Assoc [], Some (Gemini_prompt_block_reason block_reason))
  in
  let terminal_without_content = Option.is_some gem_finish_reason in
  let* parts =
    match gemini_assoc_field "content" candidate with
    | (None | Some `Null) when terminal_without_content -> Ok []
    | None -> Error (Gemini_payload_malformed "gemini.candidates[0].content:missing")
    | Some content ->
      let* content = gemini_object ~path:"gemini.candidates[0].content" content in
      (match gemini_assoc_field "parts" content with
       | (None | Some `Null) when terminal_without_content -> Ok []
       | None ->
         Error (Gemini_payload_malformed "gemini.candidates[0].content.parts:missing")
       | Some parts_value ->
         gemini_list ~path:"gemini.candidates[0].content.parts" parts_value)
  in
  let rec validate_parts position unsupported_part = function
    | [] -> Ok unsupported_part
    | part :: rest ->
      (match gemini_unsupported_part_of_json ~position part with
       | Some (Ok part) ->
         let unsupported_part =
           match unsupported_part with
           | Some _ -> unsupported_part
           | None -> Some part
         in
         validate_parts (position + 1) unsupported_part rest
       | Some (Error reason) -> Error (Gemini_payload_malformed reason)
       | None ->
         (match validate_gemini_part ~position part with
          | Error reason -> Error (Gemini_payload_malformed reason)
          | Ok () -> validate_parts (position + 1) unsupported_part rest))
  in
  let* unsupported_part = validate_parts 0 None parts in
  let* () =
    match unsupported_part with
    | None -> Ok ()
    | Some part -> Error (Gemini_payload_unsupported_part part)
  in
  let* gem_usage =
    match gemini_assoc_field "usageMetadata" json with
    | None | Some `Null -> Ok None
    | Some (`Assoc _ as usage) ->
      let* input_tokens =
        gemini_optional_int_default_zero
          ~path:"gemini.usageMetadata"
          "promptTokenCount"
          usage
      in
      let* output_tokens =
        gemini_optional_int_default_zero
          ~path:"gemini.usageMetadata"
          "candidatesTokenCount"
          usage
      in
      let* cache_read_input_tokens =
        gemini_optional_int_default_zero
          ~path:"gemini.usageMetadata"
          "cachedContentTokenCount"
          usage
      in
      Ok
        (Some
           { input_tokens
           ; output_tokens
           ; cache_creation_input_tokens = 0
           ; cache_read_input_tokens
           ; cost_usd = None
           })
    | Some value ->
      Error
        (Gemini_payload_malformed
           (Printf.sprintf
              "gemini.usageMetadata:not_object(got %s)"
              (Json_util.json_type_name value)))
  in
  Ok { gem_model = model_version; gem_parts = parts; gem_finish_reason; gem_usage }
;;

let parse_gemini_sse_chunk data_str : gemini_sse_parse_result =
  match Yojson.Safe.from_string data_str with
  | exception Yojson.Json_error message ->
    Gemini_parse_failed { raw = data_str; reason = "json_error: " ^ message }
  | exception Invalid_argument message ->
    Gemini_parse_failed { raw = data_str; reason = "json_invalid_argument: " ^ message }
  | json ->
    (match parse_gemini_json json with
     | Ok chunk -> Gemini_chunk chunk
     | Error (Gemini_payload_malformed reason) ->
       Gemini_parse_failed { raw = data_str; reason }
     | Error (Gemini_payload_unsupported_part part) ->
       Gemini_unsupported_part { raw = data_str; part }
     | Error (Gemini_payload_unsupported_response response) ->
       Gemini_unsupported_response { raw = data_str; response })
;;

let gemini_message_start_for_model (state : openai_stream_state) raw_model =
  match Model_id.of_string raw_model with
  | Error reason ->
    raise
      (Backend_gemini.Gemini_api_error
         (Printf.sprintf "gemini.modelVersion invalid: %s" reason))
  | Ok model_id ->
    (match state.gemini_message_model with
     | None ->
       state.gemini_message_model <- Some model_id;
       Some (MessageStart { id = ""; model = Model_id.to_string model_id; usage = None })
     | Some observed when Model_id.equal observed model_id -> None
     | Some _ ->
       raise
         (Backend_gemini.Gemini_api_error
            "gemini.modelVersion changed within one streamed response"))
;;

let gemini_chunk_to_events_impl (state : openai_stream_state) (chunk : gemini_chunk)
  : sse_event list * Telemetry_event.t option
  =
  let open Yojson.Safe.Util in
  let events = ref [] in
  let emit evt = events := evt :: !events in
  let telemetry_event = ref None in
  (match chunk.gem_model with
   | Some model -> Option.iter emit (gemini_message_start_for_model state model)
   | None -> ());
  let has_thought_part =
    List.exists
      (fun part ->
         Cli_common_json.member_bool "thought" part
         &&
         match part |> member "text" |> to_string_option with
         | Some text when text <> "" -> true
         | Some empty_text ->
           let (_ : string) = empty_text in
           false
         | None -> false)
      chunk.gem_parts
  in
  (match state.thinking_state, has_thought_part with
   | Not_thinking, true | Thinking_done, true ->
     state.thinking_state <- Thinking_started (Unix.gettimeofday ())
   | Thinking_started t0, false ->
     let thinking_duration_ms = (Unix.gettimeofday () -. t0) *. 1000.0 in
     state.thinking_state <- Thinking_done;
     telemetry_event
     := Some
          (Telemetry_event.Thinking_complete
             { provider = state.provider; model = state.model; thinking_duration_ms })
   | Not_thinking, false | Thinking_done, false | Thinking_started _, true -> ());
  List.iteri
    (fun part_index part ->
       let is_thought = Cli_common_json.member_bool "thought" part in
       let part_thought_signature = Backend_gemini.thought_signature_of_part part in
       let emit_signed_part ~target ~content_type ~delta thought_signature =
         (match target with
          | Backend_gemini.Gemini_text_part -> state.text_block_started <- false
          | Backend_gemini.Gemini_thought_part -> state.thinking_block_started <- false
          | Backend_gemini.Gemini_image_part
          | Backend_gemini.Gemini_audio_part
          | Backend_gemini.Gemini_document_part -> ());
         let carrier_index = state.next_block_index in
         let carrier_payload =
           Backend_gemini.gemini_part_thought_signature_payload ~target ~thought_signature
         in
         emit
           (ContentBlockStart
              { index = carrier_index
              ; content_type = "redacted_thinking"
              ; tool_id = Some carrier_payload
              ; tool_name = None
              });
         let content_index = carrier_index + 1 in
         emit
           (ContentBlockStart
              { index = content_index; content_type; tool_id = None; tool_name = None });
         emit (ContentBlockDelta { index = content_index; delta });
         state.next_block_index <- content_index + 1
       in
       let emit_function_call_delta () =
         match part |> member "functionCall" with
         | `Assoc _ as fc ->
           let name = Cli_common_json.member_str "name" fc in
           let args =
             match fc |> member "args" with
             | `Null -> `Assoc []
             | args -> args
           in
           let provider_tool_id = fc |> member "id" |> to_string_option in
           let thought_signature = part_thought_signature in
           let resolution, start =
             resolve_tool_block
               state
               ~protocol:"gemini"
               ~wire_index:part_index
               ~provider_tool_id
               ~tool_name:(Some name)
               ~index_policy:
                 (match thought_signature with
                  | Some _ -> Next_after_carrier
                  | None -> Next_available)
               ~idless_semantics:Complete_occurrence
           in
           (match resolution with
            | Tool_block_rejected error -> emit error
            | Tool_block_resolved { block_index = idx; identity } ->
              (match start with
               | Some start ->
                 (match thought_signature with
                  | Some thought_signature ->
                    let payload =
                      Backend_gemini.gemini_thought_signature_payload
                        ~tool_use_id:identity.id
                        ~thought_signature
                    in
                    let carrier_index = idx - 1 in
                    emit
                      (ContentBlockStart
                         { index = carrier_index
                         ; content_type = "redacted_thinking"
                         ; tool_id = Some payload
                         ; tool_name = None
                         })
                  | None -> ());
                 emit start
               | None -> ());
              emit
                (ContentBlockDelta
                   { index = idx; delta = InputJsonSnapshot (Yojson.Safe.to_string args) }))
         | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> ()
       in
       let emit_textual_part text =
         match part_thought_signature with
         | Some thought_signature ->
           if is_thought
           then
             emit_signed_part
               ~target:Backend_gemini.Gemini_thought_part
               ~content_type:"thinking"
               ~delta:(ThinkingDelta text)
               thought_signature
           else
             emit_signed_part
               ~target:Backend_gemini.Gemini_text_part
               ~content_type:"text"
               ~delta:(TextDelta text)
               thought_signature
         | None when String.equal text "" -> ()
         | None ->
           if is_thought
           then (
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
                  { index = state.thinking_block_index; delta = ThinkingDelta text }))
           else (
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
             emit
               (ContentBlockDelta
                  { index = state.text_block_index; delta = TextDelta text }))
       in
       let emit_media_part inline_data =
         let target, block =
           Backend_gemini.media_content_block_of_inline_data inline_data
         in
         let content_type, delta =
           match block with
           | Image { media_type; source_type; data } ->
             "image", MediaDelta { media_type; source_type; data }
           | Audio { media_type; source_type; data } ->
             "audio", MediaDelta { media_type; source_type; data }
           | Document { media_type; source_type; data } ->
             "document", MediaDelta { media_type; source_type; data }
           | Text _
           | Thinking _
           | ReasoningDetails _
           | RedactedThinking _
           | ToolUse _
           | ToolResult _ ->
             raise
               (Backend_gemini.Gemini_api_error
                  "Gemini inlineData decoder produced a non-media content block")
         in
         match part_thought_signature with
         | Some thought_signature ->
           emit_signed_part ~target ~content_type ~delta thought_signature
         | None ->
           let index = state.next_block_index in
           emit
             (ContentBlockStart { index; content_type; tool_id = None; tool_name = None });
           emit (ContentBlockDelta { index; delta });
           state.next_block_index <- index + 1
       in
       let emit_non_text_part () =
         match part |> member "functionCall" with
         | `Assoc _ -> emit_function_call_delta ()
         | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
           (match part |> member "inlineData" with
            | `Assoc _ as inline_data -> emit_media_part inline_data
            | `Null ->
              (match part_thought_signature with
               | Some _ ->
                 raise
                   (Backend_gemini.Gemini_api_error
                      "Gemini thoughtSignature is attached to an unsupported Part")
               | None -> ())
            | _ ->
              raise
                (Backend_gemini.Gemini_api_error "Gemini inlineData must be an object"))
       in
       match part |> member "text" |> to_string_option with
       | Some text when not (String.equal text "") -> emit_textual_part text
       | Some empty_text ->
         (match part |> member "functionCall" with
          | `Assoc _ -> emit_function_call_delta ()
          | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
            (match part |> member "inlineData" with
             | `Assoc _ as inline_data -> emit_media_part inline_data
             | `Null -> emit_textual_part empty_text
             | _ ->
               raise
                 (Backend_gemini.Gemini_api_error "Gemini inlineData must be an object")))
       | None -> emit_non_text_part ())
    chunk.gem_parts;
  (* Finish reason *)
  (match chunk.gem_finish_reason with
   | Some (Gemini_candidate_finish_reason reason) ->
     let stop_reason =
       Backend_gemini.stop_reason_of_finish_reason
         ~has_tool_use:(Hashtbl.length state.tool_block_indices > 0)
         reason
     in
     emit (MessageDelta { stop_reason = Some stop_reason; usage = chunk.gem_usage })
   | Some (Gemini_prompt_block_reason _) ->
     emit (MessageDelta { stop_reason = Some Refusal; usage = chunk.gem_usage })
   | None -> ());
  List.rev !events, !telemetry_event
;;

let rec validate_gemini_parts position = function
  | [] -> Ok ()
  | part :: rest ->
    (match validate_gemini_part ~position part with
     | Error _ as error -> error
     | Ok () -> validate_gemini_parts (position + 1) rest)
;;

let gemini_chunk_to_events state chunk =
  match validate_gemini_parts 0 chunk.gem_parts with
  | Error reason -> Error { reason = "gemini_sse_chunk_shape_failure: " ^ reason }
  | Ok () ->
    (try Ok (gemini_chunk_to_events_impl state chunk) with
     | Backend_gemini.Gemini_api_error reason ->
       Error { reason = "gemini_sse_chunk_decode_failure: " ^ reason }
     | Yojson.Safe.Util.Type_error (reason, _) ->
       Error { reason = "gemini_sse_chunk_decode_type_error: " ^ reason }
     | Yojson.Safe.Util.Undefined (reason, _) ->
       Error { reason = "gemini_sse_chunk_decode_undefined: " ^ reason }
     | Invalid_argument reason ->
       Error { reason = "gemini_sse_chunk_decode_invalid_argument: " ^ reason })
;;

(** {1 Ollama NDJSON Streaming}

    Ollama [/api/chat] with [stream:true] emits one JSON object per
    line. Non-final lines carry a [message.content] delta; the final
    line has [done:true] together with [done_reason] and the four
    timing fields ([prompt_eval_count] / [prompt_eval_duration] /
    [eval_count] / [eval_duration]) that the Openai compat path on
    [/v1/chat/completions] strips out. *)

type ollama_tool_call_delta =
  { oll_tc_index : int
  ; oll_tc_id : string option
  ; oll_tc_name : string option
  ; oll_tc_arguments : tool_call_arguments option
  }

type ollama_chunk =
  { oll_model : string
  ; oll_delta_content : string option
  ; oll_delta_thinking : string option
  ; oll_tool_calls : ollama_tool_call_delta list
  ; oll_done_reason : string option
  ; oll_is_done : bool
  ; oll_usage : api_usage option
  ; oll_timings : inference_timings option
  }

type ollama_ndjson_parse_result =
  | Ollama_chunk of ollama_chunk
  | Ollama_provider_error of
      { message : string
      ; error_type : string option
      ; raw : string
      }
  | Ollama_parse_failed of
      { reason : string
      ; raw : string
      }

let ollama_required_fields json =
  let open Yojson.Safe.Util in
  match
    json |> member "model" |> to_string_option, json |> member "done" |> to_bool_option
  with
  | Some model, Some is_done when not (Api_common.string_is_blank model) ->
    Some (model, is_done)
  | Some _, Some _ | None, _ | _, None -> None
;;

type ollama_line_shape =
  | Ollama_data_fields of string * bool
  | Ollama_provider_error_fields of
      { message : string
      ; error_type : string option
      }
  | Ollama_malformed_fields of string

let ollama_line_shape json =
  let open Yojson.Safe.Util in
  match json |> member "error" with
  | `String message -> Ollama_provider_error_fields { message; error_type = None }
  | `Assoc error_fields ->
    let error = `Assoc error_fields in
    let message =
      error |> member "message" |> to_string_option |> Option.value ~default:""
    in
    let error_type = error |> member "type" |> to_string_option in
    Ollama_provider_error_fields { message; error_type }
  | `Null ->
    (match ollama_required_fields json with
     | Some (model, is_done) -> Ollama_data_fields (model, is_done)
     | None -> Ollama_malformed_fields "ollama_ndjson_missing_required_field")
  | `Bool _ | `Int _ | `Intlit _ | `Float _ | `List _ ->
    Ollama_malformed_fields "ollama_ndjson_error_field_type"
;;

let parse_ollama_ndjson_chunk data_str : ollama_ndjson_parse_result =
  let open Yojson.Safe.Util in
  try
    let json = Yojson.Safe.from_string data_str in
    match ollama_line_shape json with
    | Ollama_provider_error_fields { message; error_type } ->
      Ollama_provider_error { message; error_type; raw = data_str }
    | Ollama_malformed_fields reason -> Ollama_parse_failed { reason; raw = data_str }
    | Ollama_data_fields (oll_model, oll_is_done) ->
      let oll_done_reason = json |> member "done_reason" |> to_string_option in
      let message = json |> member "message" in
      let oll_delta_content =
        match message with
        | `Assoc _ ->
          let s = message |> member "content" |> to_string_option in
          (match s with
           | Some "" -> None
           | other -> other)
        | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> None
      in
      let oll_delta_thinking =
        match message with
        | `Assoc _ ->
          let s = message |> member "thinking" |> to_string_option in
          (match s with
           | Some "" -> None
           | other -> other)
        | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> None
      in
      let oll_tool_calls =
        match message with
        | `Assoc _ ->
          (match message |> member "tool_calls" with
           | `List items ->
             List.mapi
               (fun idx tc ->
                  let func = tc |> member "function" in
                  let oll_tc_name = func |> member "name" |> to_string_option in
                  let oll_tc_id = tc |> member "id" |> to_string_option in
                  let oll_tc_arguments =
                    match func |> member "arguments" with
                    | `Null -> None
                    | (`Assoc _ | `List _) as v ->
                      Some (Args_complete (Yojson.Safe.to_string v))
                    | `String s -> Some (Args_fragment s)
                    | other -> Some (Args_complete (Yojson.Safe.to_string other))
                  in
                  { oll_tc_index = idx; oll_tc_id; oll_tc_name; oll_tc_arguments })
               items
           | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ -> [])
        | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> []
      in
      (* Token-count usage. Ollama only emits these on the done chunk.
         When both counts are zero we return None, matching the
         non-streaming path in [Backend_ollama.parse_ollama_response]
         so that a downstream consumer's usage-trust classification sees
         [Usage_missing] instead of [zero_token_usage_reported]. *)
      let oll_usage =
        let input = json |> member "prompt_eval_count" |> to_int_option in
        let output = json |> member "eval_count" |> to_int_option in
        match input, output with
        | None, None -> None
        | Some _, None | None, Some _ | Some _, Some _ ->
          let input_tokens = Option.value ~default:0 input in
          let output_tokens = Option.value ~default:0 output in
          if input_tokens = 0 && output_tokens = 0
          then None
          else
            Some
              { input_tokens
              ; output_tokens
              ; cache_creation_input_tokens = 0
              ; cache_read_input_tokens = 0
              ; cost_usd = None
              }
      in
      (* inference_timings: same wire-format the non-streaming
         Backend_ollama.parse_ollama_response builds, so downstream
         (record_llm_tok_s_metrics) is byte-identical between the two
         paths. Durations are nanoseconds on the wire; convert to ms
         and tok/s here. *)
      let oll_timings =
        let prompt_n = json |> member "prompt_eval_count" |> to_int_option in
        let prompt_ns = json |> member "prompt_eval_duration" |> to_int_option in
        let predicted_n = json |> member "eval_count" |> to_int_option in
        let predicted_ns = json |> member "eval_duration" |> to_int_option in
        let any_set =
          Option.is_some prompt_n
          || Option.is_some prompt_ns
          || Option.is_some predicted_n
          || Option.is_some predicted_ns
        in
        if not any_set
        then None
        else (
          let ms_of_ns ns_opt = Option.map (fun ns -> float_of_int ns /. 1e6) ns_opt in
          let per_second n_opt ns_opt =
            match n_opt, ns_opt with
            | Some n, Some ns when ns > 0 ->
              Some (float_of_int n /. (float_of_int ns /. 1e9))
            | Some _, Some _ | Some _, None | None, Some _ | None, None -> None
          in
          Some
            { prompt_n
            ; prompt_ms = ms_of_ns prompt_ns
            ; prompt_per_second = per_second prompt_n prompt_ns
            ; predicted_n
            ; predicted_ms = ms_of_ns predicted_ns
            ; predicted_per_second = per_second predicted_n predicted_ns
            ; cache_n = None
            })
      in
      Ollama_chunk
        { oll_model
        ; oll_delta_content
        ; oll_delta_thinking
        ; oll_tool_calls
        ; oll_done_reason
        ; oll_is_done
        ; oll_usage
        ; oll_timings
        }
  with
  | Yojson.Json_error message ->
    Ollama_parse_failed { reason = "json_error: " ^ message; raw = data_str }
  | Type_error (message, _) ->
    Ollama_parse_failed { reason = "type_error: " ^ message; raw = data_str }
;;

(** Convert a parsed {!ollama_chunk} into {!sse_event} list.
    Reuses {!openai_stream_state} for block index tracking. *)
let ollama_chunk_to_events (state : openai_stream_state) (chunk : ollama_chunk)
  : sse_event list * Telemetry_event.t option
  =
  let events = ref [] in
  let emit evt = events := evt :: !events in
  let telemetry_event = ref None in
  (* Thinking content delta *)
  (match chunk.oll_delta_thinking with
   | Some text when text <> "" ->
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
  (* Text content delta *)
  (match chunk.oll_delta_content with
   | Some text when text <> "" ->
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
    emit (MessageDelta { stop_reason; usage = chunk.oll_usage }));
  List.rev !events, !telemetry_event
;;

[@@@coverage off]
(* ── parse_ollama_ndjson_chunk tests ──────────────────────── *)

let%test "parse_ollama_ndjson_chunk: content delta line" =
  let line =
    {|{"model":"dashscope-3:8b","message":{"role":"assistant","content":"hi"},"done":false}|}
  in
  match parse_ollama_ndjson_chunk line with
  | Ollama_parse_failed _ | Ollama_provider_error _ -> false
  | Ollama_chunk c ->
    c.oll_model = "dashscope-3:8b"
    && c.oll_delta_content = Some "hi"
    && c.oll_delta_thinking = None
    && c.oll_tool_calls = []
    && (not c.oll_is_done)
    && c.oll_usage = None
    && c.oll_timings = None
;;

let%test "parse_ollama_ndjson_chunk: done line carries timings + usage" =
  let line =
    {|{"model":"dashscope-3:8b","message":{"role":"assistant","content":""},
       "done_reason":"stop","done":true,
       "prompt_eval_count":15,"prompt_eval_duration":300000000,
       "eval_count":50,"eval_duration":1000000000}|}
  in
  match parse_ollama_ndjson_chunk line with
  | Ollama_parse_failed _ | Ollama_provider_error _ -> false
  | Ollama_chunk c ->
    c.oll_is_done
    && c.oll_done_reason = Some "stop"
    && (match c.oll_usage with
        | Some u -> u.input_tokens = 15 && u.output_tokens = 50
        | None -> false)
    &&
      (match c.oll_timings with
      | Some t ->
        t.predicted_n = Some 50
        && t.prompt_n = Some 15
        && (match t.predicted_per_second with
            | Some v -> abs_float (v -. 50.0) < 0.001
            | None -> false)
        &&
          (match t.prompt_per_second with
          | Some v -> abs_float (v -. 50.0) < 0.001
          | None -> false)
      | None -> false)
;;

let%test "parse_ollama_ndjson_chunk: zero eval_duration → per_second None" =
  let line =
    {|{"model":"dashscope-3:8b","message":{"role":"assistant","content":""},
       "done":true,"eval_count":10,"eval_duration":0}|}
  in
  match parse_ollama_ndjson_chunk line with
  | Ollama_chunk c ->
    (match c.oll_timings with
     | Some t -> t.predicted_n = Some 10 && t.predicted_per_second = None
     | None -> false)
  | Ollama_parse_failed _ | Ollama_provider_error _ -> false
;;

let%test "parse_ollama_ndjson_chunk: tool_calls fully formed in done line" =
  let line =
    {|{"model":"dashscope-3:8b","message":{"role":"assistant","content":"",
       "tool_calls":[{"function":{"name":"foo","arguments":{"x":1}}}]},
       "done":true,"done_reason":"tool_calls"}|}
  in
  match parse_ollama_ndjson_chunk line with
  | Ollama_parse_failed _ | Ollama_provider_error _ -> false
  | Ollama_chunk c ->
    (match c.oll_tool_calls with
     | [ tc ] ->
       tc.oll_tc_name = Some "foo"
       &&
         (match tc.oll_tc_arguments with
         | Some (Args_fragment args | Args_complete args) ->
           let json = Yojson.Safe.from_string args in
           json |> Yojson.Safe.Util.member "x" |> Yojson.Safe.Util.to_int = 1
         | None -> false)
     | unexpected_tool_calls ->
       let (_ : ollama_tool_call_delta list) = unexpected_tool_calls in
       false)
;;

let%test "parse_ollama_ndjson_chunk: malformed json is explicit" =
  match parse_ollama_ndjson_chunk "{not valid" with
  | Ollama_parse_failed _ -> true
  | Ollama_chunk _ | Ollama_provider_error _ -> false
;;

let%test "parse_ollama_ndjson_chunk: provider error is explicit" =
  match parse_ollama_ndjson_chunk {|{"error":"model failed"}|} with
  | Ollama_provider_error { message; error_type = None; raw } ->
    message = "model failed" && raw = {|{"error":"model failed"}|}
  | Ollama_chunk _ | Ollama_parse_failed _ -> false
  | Ollama_provider_error { error_type = Some _; _ } -> false
;;

let%test "parse_ollama_ndjson_chunk: missing provider message does not copy raw" =
  let raw = {|{"error":{"type":"server_error","detail":"opaque"}}|} in
  match parse_ollama_ndjson_chunk raw with
  | Ollama_provider_error { message; error_type = Some "server_error"; raw = r } ->
    message = "" && r = raw
  | Ollama_chunk _ | Ollama_parse_failed _ -> false
  | Ollama_provider_error { error_type = None; _ } -> false
  | Ollama_provider_error { error_type = Some _; _ } -> false
;;

let%test "parse_ollama_ndjson_chunk: done with zero token counts keeps chunk" =
  let line =
    {|{"model":"dashscope-3:8b","message":{"role":"assistant","content":""},
       "done_reason":"stop","done":true,
       "prompt_eval_count":0,"eval_count":0}|}
  in
  match parse_ollama_ndjson_chunk line with
  | Ollama_chunk c -> c.oll_is_done && c.oll_usage = None
  | Ollama_parse_failed _ | Ollama_provider_error _ -> false
;;

(* ── ollama_chunk_to_events tests ─────────────────────────── *)

let%test "ollama_chunk_to_events: content delta emits Start+Delta" =
  let state = create_openai_stream_state () in
  let chunk =
    { oll_model = "dashscope-3:8b"
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
  | unexpected_events ->
    let (_ : sse_event list) = unexpected_events in
    false
;;

let%test "ollama_chunk_to_events: subsequent content delta reuses block" =
  let state = create_openai_stream_state () in
  let mk text =
    { oll_model = "dashscope-3:8b"
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
  | unexpected_events ->
    let (_ : sse_event list) = unexpected_events in
    false
;;

let%test "ollama_chunk_to_events: done with stop_reason emits MessageDelta" =
  let state = create_openai_stream_state () in
  let chunk =
    { oll_model = "dashscope-3:8b"
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
  | [ MessageDelta { stop_reason = Some EndTurn; usage = Some u } ] ->
    u.input_tokens = 10 && u.output_tokens = 20
  | unexpected_events ->
    let (_ : sse_event list) = unexpected_events in
    false
;;

let%test "ollama_chunk_to_events: overflow reason stays typed" =
  let state = create_openai_stream_state () in
  let chunk : ollama_chunk =
    { oll_model = "dashscope-3:8b"
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
  | [ MessageDelta { stop_reason = Some ContextWindowExceeded; usage = None } ] -> true
  | _ -> false
;;

let%test "ollama_chunk_to_events: done with zero usage → usage=None" =
  let state = create_openai_stream_state () in
  let chunk =
    { oll_model = "dashscope-3:8b"
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
  | [ MessageDelta { stop_reason = Some EndTurn; usage = None } ] -> true
  | unexpected_events ->
    let (_ : sse_event list) = unexpected_events in
    false
;;

let%test "ollama_chunk_to_events: tool_calls emit Start+InputJsonSnapshot" =
  let state = create_openai_stream_state () in
  let chunk =
    { oll_model = "dashscope-3:8b"
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
    ; MessageDelta { stop_reason = Some StopToolUse; _ }
    ] -> String.starts_with ~prefix:"call_oas_" tool_id && args = {|{"q":"hello"}|}
  | unexpected_events ->
    let (_ : sse_event list) = unexpected_events in
    false
;;

let%test "ollama_chunk_to_events: thinking delta emits thinking block first" =
  let state = create_openai_stream_state () in
  let chunk =
    { oll_model = "dashscope-3:8b"
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
  | unexpected_events ->
    let (_ : sse_event list) = unexpected_events in
    false
;;

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
  | unexpected_event ->
    let (_ : sse_event option) = unexpected_event in
    false
;;

let%test "parse_sse_event: malformed JSON yields SSEParseFailed" =
  let raw = "{not valid json" in
  match parse_sse_event None raw with
  | Some (SSEParseFailed { raw = r; reason }) -> r = raw && String.length reason > 0
  | unexpected_event ->
    let (_ : sse_event option) = unexpected_event in
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
  | unexpected_event ->
    let (_ : sse_event option) = unexpected_event in
    false
;;

let%test "parse_sse_event: blank explicit event type yields SSEParseFailed" =
  let raw = "{}" in
  match parse_sse_event (Some "  ") raw with
  | Some (SSEParseFailed { raw = observed_raw; reason }) ->
    observed_raw = raw && reason = "sse_event_type_blank"
  | unexpected_event ->
    let (_ : sse_event option) = unexpected_event in
    false
;;

let%test "parse_sse_event: non-string payload type yields SSEParseFailed" =
  let raw = "{\"type\":42}" in
  match parse_sse_event None raw with
  | Some (SSEParseFailed { raw = observed_raw; reason }) ->
    observed_raw = raw && reason = "sse_event_type_not_string"
  | unexpected_event ->
    let (_ : sse_event option) = unexpected_event in
    false
;;

let%test "parse_sse_event: non-object payload yields SSEParseFailed" =
  let raw = "[]" in
  match parse_sse_event (Some "ping") raw with
  | Some (SSEParseFailed { raw = observed_raw; reason }) ->
    observed_raw = raw && reason = "sse_payload_must_be_object"
  | unexpected_event ->
    let (_ : sse_event option) = unexpected_event in
    false
;;

let%test "parse_sse_event: known event still parses normally" =
  (* Sanity: refactor must not regress the happy path. *)
  let raw = "{\"type\":\"message_stop\"}" in
  match parse_sse_event None raw with
  | Some MessageStop -> true
  | unexpected_event ->
    let (_ : sse_event option) = unexpected_event in
    false
;;
