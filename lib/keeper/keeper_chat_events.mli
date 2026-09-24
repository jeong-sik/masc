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
  | Tool_replay_mismatch
  | Tool_delta_invalid_kind
  | Tool_attempt_superseded
  | Tool_message_start_conflict
  | Stream_event_after_terminal
  | Tool_occurrence_mapping_invalid
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
  | Sse_stream_repeating
  | Sse_timeout
      (** The transport's stream liveness bound expired (first event or idle
          gap) before the provider finished. Ends the attempt, not the turn. *)

type runtime_attempt_scope_disposition =
  | Preserve_previous_scope
  | Abandon_previous_scope
(** Pre-advance authority for a runtime fallback boundary. The durable stream
    accumulator decides whether the prior scope was sealed; worker transport
    and live projection carry this closed value without recomputing it. *)

type tool_stream_occurrence =
  { stream_scope : int
  ; provider_message_id : string option
  ; block_index : int
  }
(** Server-owned streamed tool occurrence. [stream_scope]/[block_index] is the
    live row authority. Provider message/call ids are optional correlation
    data and may be blank or reused. *)

type stream_protocol_error = {
  kind : stream_protocol_error_kind;
  quarantined_occurrence : tool_stream_occurrence option;
  (** Exact live row this error invalidated, when one was actually quarantined.
      Diagnostics that did not invalidate a tool row keep [None]. Consumers
      must not select a row from [tool_call_id] or [index]. *)
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
  | Batch_bound of { operation_id : Keeper_chat_operation.Operation_id.t; execution_id : Keeper_chat_operation.Operation_id.t }
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
  | Agent_core_runtime_attempt_started of
      { runtime_id : string option
      ; attempt_index : int option
      }
      (** Exact resolved-runtime attempt boundary. Readers discard unfinished
          text/thinking from the prior attempt while retaining finalized and
          quarantined tool evidence. *)
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
  | Tool_call_start of
      { occurrence : tool_stream_occurrence
      ; tool_call_id : string option
      ; tool_call_name : string
      }
  | Tool_call_args of
      { occurrence : tool_stream_occurrence
      ; tool_call_id : string option
      ; delta : string
      }
  | Tool_call_args_snapshot of
      { occurrence : tool_stream_occurrence
      ; tool_call_id : string option
      ; snapshot : string
      }
  | Tool_call_end of
      { occurrence : tool_stream_occurrence
      ; tool_call_id : string option
      }
      (** Provider argument streaming ended. This is not execution completion. *)
  | Tool_approval_requested of
      { tool_call_id : string
      ; tool_call_name : string
      ; args : string
      ; question : string
      ; because : string
      }
      (** The turn is held at this call until an operator answers or the wait
          runs out. Carries the call's arguments as sent, because a reader
          deciding whether to allow it needs to see what it would do -- the
          name alone does not distinguish reading a file from rewriting it.
          [because] is the policy's one-line reason for asking rather than
          running: the operator cannot see the policy table, only this. *)
  | Tool_approval_settled of
      { tool_call_id : string
      ; outcome : string
      }
      (** How the wait ended: the operator's answer, or that nobody gave one.
          Sent so a pane showing the prompt stops showing it, including on the
          paths where no answer arrived. *)
  | Tool_result_ready of
      { occurrence : tool_stream_occurrence
      ; tool_call_id : string option
      ; execution_id : Ids.Execution_id.t
      }
      (** The exact tool result is durably readable from the tool-call store.
          [occurrence] is the streamed row authority, [tool_call_id] remains
          optional provider correlation data, and
          [execution_id] is the canonical cross-store join key. *)
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

val bus_capacity : int
(** Events the bus buffers before [publish] suspends the publisher. *)

type t
(** Bounded per-turn event stream plus its optional journal hook (RFC-0412
    stage 1). One publisher fiber writes it; one adapter fiber reads it.

    The publisher ends the turn with {!close}. The reader keeps reading until
    it takes {!Closed}; terminal events ([Run_finished], [Event_error]) tell
    the reader what to deliver but do not end its reading. A reader that
    stopped early would leave the publisher suspended in [Eio.Stream.add] once
    {!bus_capacity} events waited, and the turn would never settle. *)

(** What a read returns: the next value, or the publisher's declaration that
    no event follows. Once a reader has taken [Closed], every later read
    returns [Closed] without blocking. *)
type 'a next =
  | Next of 'a
  | Closed

(** One event as the bus stamped it: the 0-based publish-order sequence number
    and the publish-time clock reading. The journal line for this event (via
    [on_publish]) and every live projection of it carry the same [seq] and
    [ts], so a journal replay reproduces the live wire bytes. *)
type published =
  { seq : int
  ; ts : float
  ; event : keeper_chat_event
  }

(** [create ?first_seq ?now ?on_publish ()] returns a new bounded event stream. Each turn
    should create its own stream instance. [first_seq] defaults to zero for a
    fresh operation; a continuation supplies the next durable journal sequence.
    [now] is the clock read once per
    [publish] (default [Time_compat.now]; injectable for deterministic tests).
    [on_publish], when given, is invoked synchronously with that seq and ts
    BEFORE the event enters the bus; hook exceptions are logged and swallowed
    (except cancellation, which is re-raised) so a journal failure can never
    break the live turn. *)
val create :
  ?first_seq:int ->
  ?now:(unit -> float) ->
  ?on_publish:(seq:int -> ts:float -> keeper_chat_event -> unit) ->
  unit ->
  t

(** [publish t event] runs the journal hook (if any) and adds [event] to the
    stream. With a journal hook installed, the hook performs brief blocking
    Unix I/O (fsync + rollback per line); hook-free buses are non-blocking
    until full. A full stream suspends the writer fiber until a reader frees
    a slot (Eio backpressure) — the hook has already run by then, so the
    journal still holds the event. After {!reader_gone} the bus is skipped
    altogether, so this call cannot suspend.

    @raise Invalid_argument after {!close}: a publish after the end of the
    turn is a publisher defect, never a delivery. *)
val publish : t -> keeper_chat_event -> unit

(** [close t] declares that no event follows. Idempotent. The reader takes it
    after every event published before it; a full stream suspends this call
    exactly as it suspends [publish]. A close cancelled while suspended has
    added nothing and leaves the bus open, so a later close still ends the
    turn. The closed flag is set when this call returns, which can be after
    the reader has taken the sentinel; the one publisher fiber is inside this
    call for that window, so no [publish] can land in it. After
    {!reader_gone} there is nobody to hand the sentinel to and this call adds
    nothing. *)
val close : t -> unit

(** [reader_gone t] declares that the bus's consumer has stopped reading and
    will not read again. Idempotent, suspends nowhere, and releases every
    publisher already waiting for room.

    The bus holds one turn's events for one consumer, and its bounded window
    is backpressure on a consumer that is slower than the turn. A consumer
    that leaves instead — a failed adapter, an unconfigured connector, an
    operator interrupt — turns that window into a wedge: the turn fills it,
    suspends in [publish], never returns, and never releases the Owner's turn
    slot. Calling this on the way out replaces that with a drop: {!publish}
    keeps feeding the journal hook, which is the durable record, and stops
    feeding the bus, which nobody is reading.

    Every consumer reaches this whatever ends it, so no consumer has to read
    events it does not want in order to keep the turn alive. *)
val reader_gone : t -> unit

(** [subscribe t] blocks until an event is available and returns it, or
    returns [Closed] once the publisher has closed the bus and every earlier
    event has been read. *)
val subscribe : t -> keeper_chat_event next

(** [subscribe_published t] is {!subscribe} with the seq and ts the bus
    stamped at publish time. The wire adapter reads through this so the frame
    id is the journal seq and the projected timestamp is the journaled ts. *)
val subscribe_published : t -> published next

(** [take_nonblocking t] returns the next queued event, or [None] when the
    bus is empty or closed. Test support: it bypasses the blocking
    [subscribe] contract and must not sit on a live read path. *)
val take_nonblocking : t -> keeper_chat_event option

val api_usage_to_json : Agent_core.Types.api_usage -> Yojson.Safe.t

(** JSON for cumulative mid-stream counters: only reported fields appear,
    so "not reported" stays distinguishable from 0. *)
val delta_usage_to_json : Agent_core.Types.delta_usage -> Yojson.Safe.t

(** The wire spelling of why the provider stopped writing, as
    [Keeper_chat_event_log] writes it into the journal and the AGUI projection
    sends it to a client. Re-exported here so a reader whose dune unit does not
    link agent_core still spells the word the producer wrote. *)
val stop_reason_to_string : Agent_core.Types.stop_reason -> string

val stream_protocol_error_kind_to_string : stream_protocol_error_kind -> string
val stream_protocol_error_kind_of_string :
  string -> stream_protocol_error_kind option
val stream_protocol_error_summary : stream_protocol_error -> string
val stream_protocol_error_to_json : stream_protocol_error -> Yojson.Safe.t
