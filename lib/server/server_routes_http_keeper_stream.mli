(** Server_routes_http_keeper_stream — keeper chat
    streaming HTTP route + payload parser.

    [Server_routes_http.ml] does
    [include Server_routes_http_keeper_stream] (as part
    of the route facade), and
    [server_routes_http_routes_dashboard] does
    [open Server_routes_http_keeper_stream] to reach
    {!parse_keeper_chat_stream_request} +
    {!handle_keeper_chat_stream} +
    {!keeper_chat_stream_error_json} unqualified.  The
    [module Keeper_stream = ...] aliases in 4 sister
    routing modules are leftover from an earlier
    refactor and currently have no call sites — they
    keep working through the type-passthrough but do not
    add to the surface here.

    External surface (4 entries + 1 record):
    - {b stream tunable} ({!sse_dashboard_retry_backoff_ms}) — SSE
      reconnect backoff shared with the dashboard route.
    - {b request record} ({!keeper_chat_stream_request})
      returned by the parser, consumed by the handler;
      the dashboard route reaches the [.name] field via
      record-pattern access.
    - {b parser} ({!parse_keeper_chat_stream_request})
      reached unqualified by the dashboard route + via
      dotted call from
      [test/test_gate_keeper_backend].
    - {b error envelope}
      ({!keeper_chat_stream_error_json}) reached
      unqualified by the dashboard route when surfacing
      parse / authorization failures.
    - {b SSE handler} ({!handle_keeper_chat_stream})
      drives the per-request SSE stream.

    Internal helpers stay private at this boundary
    (~10 internal lets — [get_origin] / [cors_headers] adapter helpers,
    [keeper_chat_stream_*] sub-renderers + per-event
    framing and connector-context helpers). *)

(** {1 Stream tunables} *)

(** SSE reconnect backoff (ms) primed on the dashboard keeper-chat streams.
    Shared with {!Server_routes_http_routes_dashboard} (reached via [open]) so the
    two dashboard priming sites cannot silently diverge; intentionally distinct
    from {!Server_mcp_transport_http_headers.sse_retry_ms} (the MCP transport). *)
val sse_dashboard_retry_backoff_ms : int

(** {1 Request record} *)

type user_media_block = Keeper_multimodal_input.user_media_block = {
  attachment_id : string;
  name : string;
  mime_type : string;
  size : int option;
}
(** Media user input block carried by the dashboard stream request.
    [attachment_id] points at an entry in [attachments]; raw media stays
    in the attachment payload for the current dashboard contract and is
    not mixed into the text [message]. *)

type user_image_reference = Keeper_multimodal_input.user_image_reference = {
  value : string;
  mime_type : string option;
}

type user_image_source = Keeper_multimodal_input.user_image_source =
  | Attached of user_media_block
  | Url_ref of user_image_reference
  | File_id_ref of user_image_reference

type user_input_block = Keeper_multimodal_input.user_input_block =
  | User_text of string
  | User_image of user_image_source
  | User_document of user_media_block
  | User_audio of user_media_block
(** Semantic user-input blocks accepted from the dashboard.  This is a
    MASC request-boundary type, intentionally distinct from dashboard
    rich-render [ChatBlock] values and from AGENT_CORE provider blocks. *)

type admission_intent = Queue_only | Interactive of {
  control_token : string; target : Keeper_owner_registry.interactive_target option }

type keeper_chat_stream_request = {
  admission_intent : admission_intent;
  request_id : Keeper_owner.Chat_operation.Operation_id.t;
  name : string;
  message : string;
  user_blocks : user_input_block list;
  turn_instructions : string option;
  surface_context : Yojson.Safe.t option;
  channel : string;
  channel_user_id : string;
  channel_user_name : string;
  channel_workspace_id : string;
  sender_keeper : Keeper_identity.Keeper_id.t option;
      (** The registered Keeper that sent this request, carried from the
          durable operation source where the submitting tool matched the
          Keeper registry. The HTTP body cannot set it: the parser always
          yields [None]. *)
  attachments : Keeper_chat_store.attachment list;
  direct_message : Keeper_invocation_contract.direct_message;
  since_seq : Keeper_chat_event_log.replay_position;
      (** Where a re-POST of the same [request_id] asks the replay to start:
          after the last journal seq the client received, or the whole turn
          — which is also what an absent field, a first submit, says. When
          the owner already holds the operation the handler replays the
          journaled suffix before the live sink attaches (RFC-0412 §3.2).
          Decoded by {!Keeper_chat_event_log.replay_position_of_wire}: absent
          or an integer [>= 0]; anything else fails the parse. *)
}
(** Parsed payload of a keeper chat-stream HTTP request.
    [message] retains the nonblank request text verbatim, or uses a text fallback
    when it is blank; [user_blocks] preserves semantic text/media input for the
    block-aware runtime path. [turn_instructions] and [surface_context]
    are optional copilot context fields; when
    [turn_instructions] is absent but [surface_context]
    is present, the surface context is formatted and
    injected as turn instructions. [direct_message] is the validated,
    turn-owned projection carried after this boundary. [channel] and
    [channel_workspace_id] are required together when any
    connector context is supplied; [channel_user_id] and
    [channel_user_name] are optional. *)

(** {1 Reply chunks} *)

val split_keeper_reply_chunks : string -> string list
(** Splits a reply the provider did not stream into the text deltas published
    in its place: after a sentence end followed by whitespace, after the first
    newline of a blank line, and at a space once a chunk passes the hard-wrap
    width. [String.concat "" (split_keeper_reply_chunks text) = text] for every
    [text]; no chunk is empty. *)

(** {1 Parsing} *)

val parse_keeper_chat_stream_request :
  media_store:Agent_core.History.media_store ->
  string -> (keeper_chat_stream_request, string) result
(** Parses the HTTP body string into a
    {!keeper_chat_stream_request}.  Returns
    [Error reason] on JSON shape mismatches, missing
    [name] / content, unknown or duplicate fields, wrong field types,
    malformed [user_blocks] / [attachments], or partial connector context. *)

(** {1 Error envelope} *)

val keeper_chat_stream_error_json : string -> Yojson.Safe.t
(** [{ "error": { "message": "…" } }] envelope for
    parse / handler errors. *)

(** {1 SSE response headers} *)

val keeper_chat_stream_headers : string -> Httpun.Headers.t
(** Headers of a per-turn SSE response to a request from [origin]. The
    connection closes with the writer: Httpun adds no Content-Length to a
    streaming body, so the writer close is the only end of the response. *)

(** {1 SSE handler} *)

val handle_keeper_chat_stream :
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  submitted_by:string ->
  Mcp_server.server_state ->
  Httpun.Request.t ->
  Http_reqd.t ->
  keeper_chat_stream_request ->
  unit
(** Drives the [POST /api/keeper/chat-stream] SSE response
    (RFC-0493 §3.2). One fiber forked on [sw] submits the operation while
    the retry frame waits for the socket, then is the stream's only sender:
    it writes the acceptance and the reconnect replay, then serves the live
    events of the turn through
    {!Server_sse_pump}. The Keeper turn only puts its events in that
    stream's queue. The stream ends after the turn's terminal, when the
    operation settled without one, when the client is gone, when a frame
    has waited 90 seconds for the socket, or when 4,096 events wait in the
    queue. The client then reconnects with [since_seq] and gets the
    journaled events back; a queued event whose journal append failed is
    not in the journal and does not come back. A failure of the stream is
    logged and does not fail [sw]. *)

(** {1 Owner operation turn execution} *)

type queued_turn_failure_kind =
  | Turn_failed
  | Turn_cancelled
  | No_visible_reply
  | Missing_turn_ref
  | Transcript_persist_failed
  | Stream_projection_failed

type queued_turn_outcome =
  | Delivered of { outcome_ref : string }
  | Failed of
      { kind : queued_turn_failure_kind
      ; detail : string
      }

type turn_submission =
  | Owner_operation of
      { operation_id : Keeper_owner.Chat_operation.Operation_id.t
      ; admission_token : Keeper_turn_dispatch_authority.token
      ; execution_sw : Eio.Switch.t
      ; surface : Surface_ref.t
      ; speaker : Keeper_chat_store.speaker
      ; conversation_id : string option
      ; external_message_id : string option
      ; workspace_id : string option
      ; extra_mentions : Keeper_identity.Keeper_id.t list
      }

val process_single_turn :
  batch_binding:(Keeper_chat_operation.Operation_id.t * Keeper_chat_operation.Operation_id.t) option ->
  user_row_origin:Keeper_chat_store.user_row_origin ->
  submission:turn_submission ->
  state:Mcp_server.server_state ->
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  auth_token:string option ->
  thread_id:string ->
  continuation_channel:Keeper_continuation_channel.t ->
  closed:bool ref ->
  client_disconnects:(Eio.Switch.t * unit Eio.Stream.t) option ->
  payload:keeper_chat_stream_request ->
  run_id:string ->
  message_id:string ->
  agent_name:string ->
  events:Keeper_chat_events.t ->
  queued_turn_outcome option
(** Execute one already-claimed Owner operation and publish its live turn
    events. The operation owns transcript provenance, admission, cancellation,
    and terminal settlement; this function never creates another durable
    request identity. [closed] and [client_disconnects] affect only a live SSE
    projection, never the accepted operation. [user_row_origin] decides whether
    the operation appends the user row or observes an upstream append.

    With no visible blocks, the operation records a typed terminal failure
    rather than inventing assistant prose. *)

val operation_runner :
  state:Mcp_server.server_state ->
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  Keeper_owner.operation_runner
(** Production runner installed into every Keeper Owner. It leaves the FIFO
    head Queued until the Keeper registry entry exists and is healthy, then
    claims exactly once, streams events by runtime base, Keeper and operation id,
    and joins terminal
    connector delivery before returning. *)

(** {1 Testing helpers} *)

type canonical_reply_payload_error =
  | Malformed_reply_json of { parser_detail : string }
  | Reply_payload_not_object
  | Missing_payload_field of string
  | Duplicate_payload_field of string
  | Invalid_payload_field_type of string
  | Unknown_turn_outcome
  | Invalid_turn_ref
  | Invalid_external_effect_target of string

type canonical_reply_payload =
  { payload_json : Yojson.Safe.t
  ; turn_outcome : Keeper_turn_outcome.t
  ; turn_ref : Ids.Turn_ref.t
  ; external_effect_target : Keeper_surface_post.delivery_target option
      (** Completed surface-post evidence. Required for [Terminal_effect_settled]
          and optional for [Continuation_checkpoint], where completed delivery
          does not settle the unfinished operation. Rejected on other outcomes. *)
  ; visible_reply : string
  ; poll_body : string
  }

val canonical_reply_payload_error_to_string :
  canonical_reply_payload_error -> string

type keeper_stream_bridge_state = Keeper_chat_agent_core_stream_bridge.state
(** Per-stream AGENT_CORE event bridge state. Abstract outside tests so callers cannot
    construct synthetic stream correlation state. *)

type translated_keeper_stream_event =
  Keeper_chat_agent_core_stream_bridge.translated_event = {
  bridge_state : keeper_stream_bridge_state;
  chat_events : Keeper_chat_events.keeper_chat_event list;
}
(** Result of translating one typed AGENT_CORE stream event into keeper chat events. *)

type operation_wire_stream = Wire_started | Wire_terminal_sent
(** Wire-terminal accounting for one runtime base, Keeper and operation id: whether a live
    AG-UI audience exists and whether a terminal event (RUN_FINISHED/
    RUN_ERROR) made it out. The stream counts as open from sink registration
    — not from the first projected event — so a turn that fails after claim
    but before the projection runs still gets its synthesized terminal; the
    record is dropped when the last sink unregisters. Consumed by the Owner
    settle hook after the child switch unwinds (#28811). *)

module For_testing : sig
  val persist_batch_user_rows : base_dir:string -> keeper_name:string ->
    Keeper_chat_operation.t list -> (unit, string) result
  val operation_execution_of_outcome :
    operation_state:(unit -> (Keeper_chat_operation.state, string) result) ->
    pending_continuation:(unit -> (Keeper_direct_gate_continuation.pending option, string) result) ->
    outcome:queued_turn_outcome option -> delivery:(unit, string) result ->
    Keeper_owner.operation_execution
  val parse_request :
    media_store:Agent_core.History.media_store ->
    string -> (keeper_chat_stream_request, string) result

  (** Reconnect dedup: [false] only for a seq the replay already wrote. *)
  val live_event_is_new : replayed:(int, unit) Hashtbl.t -> int option -> bool

  (** The frames a reconnect replays for [since_seq], or [] when the journal
      is missing, unreadable, corrupt, or holds an event the projection
      refuses; never raises (except cancellation). *)
  val journal_replay_frames :
    base_path:string ->
    keeper_name:string ->
    operation_id:string ->
    since_seq:Keeper_chat_event_log.replay_position ->
    (int * Ag_ui.event) list
  val operation_terminal_after_replay :
    base_path:string -> keeper_name:string -> operation:Keeper_chat_operation.t ->
    replayed:(int, unit) Hashtbl.t -> Ag_ui.event option
  (** Cursor-independent accepted operation failure, absent when this replay already
      delivered the terminal for that exact durable settlement. *)

  (** What a Keeper chat stream's sending fiber takes from its queue. *)
  type chat_stream_item =
    | Live of int option * Ag_ui.event  (** From the live sink, with its seq. *)
    | Missed_terminal of Ag_ui.event
        (** The terminal the operation record holds and the wire never carried. *)
    | Settled
        (** The turn ended before the live part: the operation had settled, or
            the replay wrote its terminal. *)

  val keeper_chat_step :
    replayed:(int, unit) Hashtbl.t -> chat_stream_item -> Server_sse_pump.step
  (** The frame the stream writes for an item: nothing for a seq the replay
      already wrote, the last frame for a terminal, and the end for
      [Settled]. *)

  val keeper_chat_idle :
    client_gone:(unit -> bool) ->
    operation_state:(unit -> Keeper_owner.Chat_operation.state option) ->
    Server_sse_pump.idle
  (** What a quiet stream does: ends when the client is gone (without
      reading the operation), sends a keepalive while the operation is
      queued or running, ends when it settled, and waits when its record
      cannot be read ([None]). *)

  val serve_accepted_chat :
    send:(string -> Server_sse_response.outcome) ->
    closed:(unit -> unit) ->
    queue:chat_stream_item Server_sse_pump.Queue.t ->
    acceptance_frame:string ->
    replay:(unit -> (int * Ag_ui.event) list) ->
    missed_terminal:(replayed:(int, unit) Hashtbl.t -> Ag_ui.event option) ->
    settled:bool ->
    idle:(unit -> Server_sse_pump.idle) ->
    clock:_ Eio.Time.clock ->
    ping_interval_s:float ->
    Server_sse_pump.ending option
  (** The handler after an accepted submit: writes the acceptance and the
      replay, queues the missed terminal and [Settled] (when [settled] or the
      replay wrote a terminal) behind the live events that arrived meanwhile,
      then runs the pump. [None] when the client was gone before the live
      part. *)

  val send_retry_beside_submit :
    send:(string -> Server_sse_response.outcome) ->
    retry_frame:string ->
    (unit -> 'submitted) ->
    Server_sse_response.outcome * 'submitted
  (** The handler before the acceptance: hands [retry_frame] to [send] and
      runs the submit while that frame waits for the socket. Returns once
      both are done. *)
  val has_connector_context : keeper_chat_stream_request -> bool
  val has_external_speaker : keeper_chat_stream_request -> bool
  val message_for_request : keeper_chat_stream_request -> string
  val chat_surface_of_request : keeper_chat_stream_request -> Surface_ref.t
  val chat_speaker_of_request : keeper_chat_stream_request -> Keeper_chat_store.speaker
  val input_speaker_of_request : keeper_chat_stream_request -> Keeper_input_speaker.t
  val turn_instructions_for_request : keeper_chat_stream_request -> string option
  val direct_message_of_request :
    keeper_chat_stream_request -> Keeper_invocation_contract.direct_message
  val canonical_reply_payload_of_body :
    redact_text:(string -> string) ->
    string ->
    (canonical_reply_payload, canonical_reply_payload_error) result
  val direct_reply_terminal_error :
    ?has_visible_blocks:bool ->
    Yojson.Safe.t option ->
    string ->
    Keeper_request_failure.cause option
  val persisted_reply_blocks :
    reply:string ->
    turn_outcome:Keeper_turn_outcome.t ->
    Keeper_chat_blocks.chat_block list option ->
    Keeper_chat_blocks.chat_block list option
  val queued_delivery_outcome_of_turn_ref :
    Ids.Turn_ref.t option -> queued_turn_outcome
  val committed_delivery_outcome :
    turn_ref:Ids.Turn_ref.t option ->
    (unit, string) result ->
    (queued_turn_outcome, string) result
  val empty_reply_delivery_plan :
    has_visible_blocks:bool ->
    has_tool_calls:bool ->
    [ `Visible_blocks | `Tool_calls_only | `Failure ]

  val control_turn_delivery :
    turn_outcome:Keeper_turn_outcome.t ->
    spoken:string option ->
    [ `Assistant_row of string | `Tool_calls_only ]
  (** What a control-boundary or external-effect turn writes. [spoken] is the
      turn's trimmed words. Words are kept on every outcome; only a wordless
      [External_effect_completed] writes no assistant row. *)

  val surface_context_to_instructions : Yojson.Safe.t -> string option
  val keeper_tool_failure_log_details :
    tool_name:string ->
    agent_name:string ->
    duration_ms:int ->
    streaming:bool ->
    error_body:string ->
    failure_class:Tool_result.tool_failure_class ->
    Yojson.Safe.t

  val note_operation_wire_event :
    base_path:string -> keeper_name:string -> operation_id:string -> Ag_ui.event -> unit
  val take_operation_wire_stream :
    base_path:string -> keeper_name:string -> operation_id:string -> operation_wire_stream option
  val synthesize_wire_terminal_on_settle :
    base_path:string ->
    keeper_name:string ->
    operation_id:string ->
    execution:Keeper_owner.operation_execution ->
    unit
  val on_operation_execution_settled :
    base_path:string ->
    keeper_name:string ->
    claimed_operation_id:Keeper_owner.Chat_operation.Operation_id.t option ->
    operations:Keeper_chat_operation.t list ->
    execution:Keeper_owner.operation_execution ->
    unit
  val register_operation_live_sink :
    base_path:string ->
    keeper_name:string ->
    operation_id:string ->
    (seq:int option -> Ag_ui.event -> unit) ->
    unit ->
    unit

  val publish_stream_events :
    redact_text:(string -> string) ->
    base_dir:string ->
    publish:(Keeper_chat_events.keeper_chat_event -> unit) ->
    keeper_stream_bridge_state ->
    (int * Agent_core.Types.sse_event) list ->
    keeper_stream_bridge_state
  (** What a chat request does with the events its
      {!Keeper_stream_text_redaction.Scoped} redactor released: translate each
      under its stream scope and publish the chat events in order. *)
end
