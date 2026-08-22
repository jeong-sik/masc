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
  | Media_delta_invalid_block
  | Media_source_unsupported
  | Media_decode_failed
  | Media_payload_too_large
  | Media_persist_failed
  | Sse_error
  | Ndjson_error
  | Sse_parse_failed
  | Ndjson_parse_failed
  | Sse_unknown_event_type
  | Sse_unsupported_part
  | Sse_unsupported_response
  | Sse_stream_incomplete

type stream_protocol_error = {
  kind : stream_protocol_error_kind;
  index : int option;
  tool_call_id : string option;
  event_type : string option;
  reason : string option;
  raw_bytes : int option;
}

type reply_details =
  { reply : string
  ; turn_outcome : Keeper_turn_outcome.t
  ; turn_ref : Ids.Turn_ref.t
  }

type continuation_checkpoint =
  { message : string
  ; request_id : string option
  }

type keeper_chat_event =
  | Run_started of { run_id : string; thread_id : string }
  | Text_message_start of { message_id : string; role : role }
  | Text_delta of string
  | Text_message_end
  | External_effect_completed of
      { target : Keeper_surface_post.delivery_target }
      (** A terminal tool already delivered the reply outside this adapter.
          Connector adapters settle the receipt without emitting another
          text message. [target] names where the post actually landed. *)
  | Run_finished of { run_id : string }
  | Event_error of { message : string }
  | Reply_details of reply_details
  | Continuation_checkpoint of continuation_checkpoint
  | Agent_core_stream_connected
  | Agent_core_stream_message_start of
      { provider_message_id : string
      ; model : string
      ; usage : Agent_core.Types.api_usage option
      }
  | Agent_core_stream_message_delta of
      { stop_reason : Agent_core.Types.stop_reason option
      ; usage : Agent_core.Types.delta_usage option
      }
  | Agent_core_stream_message_stop
  | Agent_core_stream_ping
  | Agent_core_content_block_start of
      { index : int
      ; content_type : string
      ; tool_call_id : string option
      ; tool_call_name : string option
      }
  | Agent_core_content_block_stop of { index : int }
  | Agent_core_thinking_delta of { index : int; delta : string }
  | Agent_core_thinking_signature_delta of { index : int; signature_bytes : int }
  | Agent_core_media_delta of
      { index : int
      ; media_type : string
      ; source_type : Agent_core.Types.media_source_kind
      ; media_ref : string
          (** RFC-0301: reader-facing URL of the persisted media
              ([/api/v1/media/<token>]), replacing the pre-RFC byte count. *)
      }
  | Agent_core_stream_protocol_error of stream_protocol_error
  | Tool_call_start of { tool_call_id : string; tool_call_name : string }
  | Tool_call_args of { tool_call_id : string; delta : string }
  | Tool_call_args_snapshot of { tool_call_id : string; snapshot : string }
  | Tool_call_end of { tool_call_id : string }
      (** Provider argument streaming ended. This is not execution completion. *)
  | Tool_result_ready of { tool_call_id : string }
      (** The exact tool result is durably readable from the tool-call store. *)
  | Link_block of
      { url : string
      ; title : string
      ; description : string option
      ; image : string option
      }
  | Image_block of { url : string; caption : string option }
  | Status_block of Keeper_chat_blocks.status_block
      (** Typed control status for channel adapters. It is rendered as channel
          UI and never reclassified as assistant speech. *)
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

val api_usage_to_json : Agent_core.Types.api_usage -> Yojson.Safe.t

(** JSON for cumulative mid-stream counters: only reported fields appear,
    so "not reported" stays distinguishable from 0. *)
val delta_usage_to_json : Agent_core.Types.delta_usage -> Yojson.Safe.t
val stream_protocol_error_kind_to_string : stream_protocol_error_kind -> string
val stream_protocol_error_summary : stream_protocol_error -> string
val stream_protocol_error_to_json : stream_protocol_error -> Yojson.Safe.t
