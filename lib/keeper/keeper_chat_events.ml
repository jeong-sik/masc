type role = User | Assistant

type stream_protocol_error_kind =
  | Tool_start_duplicate_index
  | Tool_start_missing_identity
  | Tool_args_without_start
  | Tool_stop_without_start
  | Media_delta_invalid_block
  | Media_source_unsupported
  | Media_decode_failed
  | Media_persist_failed
  | Sse_error
  | Sse_parse_failed
  | Sse_unknown_event_type
  | Sse_stream_incomplete

type stream_protocol_error = {
  kind : stream_protocol_error_kind;
  index : int option;
  tool_call_id : string option;
  event_type : string option;
  reason : string option;
  raw_bytes : int option;
}

type keeper_chat_event =
  | Run_started of { run_id : string; thread_id : string }
  | Text_message_start of { message_id : string; role : role }
  | Text_delta of string
  | Text_message_end
  | Run_finished of { run_id : string }
  | Event_error of { message : string }
  | Custom of { name : string; value : Yojson.Safe.t }
  | Oas_stream_connected
  | Oas_stream_message_start of
      { provider_message_id : string
      ; model : string
      ; usage : Agent_sdk.Types.api_usage option
      }
  | Oas_stream_message_delta of
      { stop_reason : Agent_sdk.Types.stop_reason option
      ; usage : Agent_sdk.Types.api_usage option
      }
  | Oas_stream_message_stop
  | Oas_stream_ping
  | Oas_content_block_start of
      { index : int
      ; content_type : string
      ; tool_call_id : string option
      ; tool_call_name : string option
      }
  | Oas_content_block_stop of { index : int }
  | Oas_thinking_delta of { index : int; delta : string }
  | Oas_thinking_signature_delta of { index : int; signature_bytes : int }
  | Oas_media_delta of
      { index : int
      ; media_type : string
      ; source_type : Agent_sdk.Types.media_source_kind
      ; media_ref : string
          (* RFC-0301: reader-facing URL of the persisted media
             ([/api/v1/media/<token>], via Keeper_chat_media_store), replacing the
             pre-RFC byte count. The data channel carries the reference to the
             actual payload, not a telemetry count. *)
      }
  | Oas_stream_protocol_error of stream_protocol_error
  | Tool_call_start of { tool_call_id : string; tool_call_name : string }
  | Tool_call_args of { tool_call_id : string; delta : string }
  | Tool_call_args_snapshot of { tool_call_id : string; snapshot : string }
  | Tool_call_end of { tool_call_id : string }
  | Link_block of
      { url : string
      ; title : string
      ; description : string option
      ; image : string option
      }
  | Image_block of { url : string; caption : string option }
  | Audio_block of
      { token : string
      ; mime : string
      ; message_text : string
      ; duration_sec : float option
      }
  | Tool_context_block of
      { tool_call_id : string
      ; name : string
      ; args_summary : string
      ; result_summary : string option
      }

let create () = Eio.Stream.create 512

let publish stream event = Eio.Stream.add stream event

let subscribe stream = Eio.Stream.take stream

let json_opt key value =
  match value with
  | None -> []
  | Some value -> [ (key, value) ]

let api_usage_to_json (usage : Agent_sdk.Types.api_usage) =
  `Assoc
    ([
       ("input_tokens", `Int usage.input_tokens);
       ("output_tokens", `Int usage.output_tokens);
       ("total_tokens", `Int (Agent_sdk.Types.total_tokens usage));
       ("cache_creation_input_tokens", `Int usage.cache_creation_input_tokens);
       ("cache_read_input_tokens", `Int usage.cache_read_input_tokens);
     ]
     @ json_opt "cost_usd"
         (Option.map (fun value -> `Float value) usage.cost_usd))

let stream_protocol_error_kind_to_string = function
  | Tool_start_duplicate_index -> "tool_start_duplicate_index"
  | Tool_start_missing_identity -> "tool_start_missing_identity"
  | Tool_args_without_start -> "tool_args_without_start"
  | Tool_stop_without_start -> "tool_stop_without_start"
  | Media_delta_invalid_block -> "media_delta_invalid_block"
  | Media_source_unsupported -> "media_source_unsupported"
  | Media_decode_failed -> "media_decode_failed"
  | Media_persist_failed -> "media_persist_failed"
  | Sse_error -> "sse_error"
  | Sse_parse_failed -> "sse_parse_failed"
  | Sse_unknown_event_type -> "sse_unknown_event_type"
  | Sse_stream_incomplete -> "sse_stream_incomplete"

let stream_protocol_error_summary error =
  let parts =
    [
      Some (stream_protocol_error_kind_to_string error.kind);
      Option.map (Printf.sprintf "index=%d") error.index;
      Option.map (Printf.sprintf "tool_call_id=%s") error.tool_call_id;
      Option.map (Printf.sprintf "event_type=%s") error.event_type;
      error.reason;
      Option.map (Printf.sprintf "raw_bytes=%d") error.raw_bytes;
    ]
    |> List.filter_map Fun.id
  in
  String.concat " | " parts

let stream_protocol_error_to_json error =
  let fields =
    [
      ( "kind",
        `String (stream_protocol_error_kind_to_string error.kind) );
    ]
    @ json_opt "index" (Option.map (fun value -> `Int value) error.index)
    @ json_opt "tool_call_id"
        (Option.map (fun value -> `String value) error.tool_call_id)
    @ json_opt "event_type"
        (Option.map (fun value -> `String value) error.event_type)
    @ json_opt "reason" (Option.map (fun value -> `String value) error.reason)
    @ json_opt "raw_bytes" (Option.map (fun value -> `Int value) error.raw_bytes)
  in
  `Assoc fields
