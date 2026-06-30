(** Keeper_chat_events — channel-agnostic event bus for keeper chat turns.

    Decouples turn processing from delivery. Each turn gets its own
    event stream instance; adapters consume events and translate to
    channel-specific protocols (SSE, Discord REST, Slack REST).

    @since 2.145.0 *)

(** {1 Types} *)

type role = User | Assistant

type stream_protocol_error_kind =
  | Tool_start_duplicate_index
  | Tool_start_missing_identity
  | Tool_args_without_start
  | Tool_stop_without_start
  | Sse_error
  | Sse_parse_failed
  | Sse_unknown_event_type
  | Sse_stream_incomplete

type stream_protocol_error = {
  kind : stream_protocol_error_kind;
  index : int option;
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
      ; bytes : int
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

(** {1 Stream operations} *)

(** [create ()] returns a new bounded event stream.
    Each turn should create its own stream instance. *)
val create : unit -> keeper_chat_event Eio.Stream.t

(** [publish stream event] adds [event] to the stream.
    Non-blocking; raises if the stream is full (backpressure). *)
val publish : keeper_chat_event Eio.Stream.t -> keeper_chat_event -> unit

(** [subscribe stream] blocks until an event is available, then returns it. *)
val subscribe : keeper_chat_event Eio.Stream.t -> keeper_chat_event

val api_usage_to_json : Agent_sdk.Types.api_usage -> Yojson.Safe.t
val stream_protocol_error_kind_to_string : stream_protocol_error_kind -> string
val stream_protocol_error_summary : stream_protocol_error -> string
val stream_protocol_error_to_json : stream_protocol_error -> Yojson.Safe.t
