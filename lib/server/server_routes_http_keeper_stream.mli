(** The route's answer once an answer is recorded: [delivered] false means
    the Keeper could not be told, which is not a success. *)
val ask_answer_response :
  ask_id:string ->
  answer_count:int ->
  open_remaining:int ->
  delivered:bool ->
  Http.Status.t * Yojson.Safe.t

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
    (~10 internal lets — [contains_casefold],
    [get_origin] / [cors_headers] adapter helpers,
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

type user_input_block = Keeper_multimodal_input.user_input_block =
  | User_text of string
  | User_image of user_media_block
  | User_document of user_media_block
  | User_audio of user_media_block
(** Semantic user-input blocks accepted from the dashboard.  This is a
    MASC request-boundary type, intentionally distinct from dashboard
    rich-render [ChatBlock] values and from AGENT_CORE provider blocks. *)

type keeper_chat_stream_request = {
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
  attachments : Keeper_chat_store.attachment list;
  direct_message : Keeper_invocation_contract.direct_message;
}
(** Parsed payload of a keeper chat-stream HTTP request.
    [message] is the text fallback used by the existing direct keeper
    path; [user_blocks] preserves semantic text/media input for the
    block-aware runtime path. [turn_instructions] and [surface_context]
    are optional copilot context fields; when
    [turn_instructions] is absent but [surface_context]
    is present, the surface context is formatted and
    injected as turn instructions. [direct_message] is the validated,
    turn-owned projection carried after this boundary. [channel] and
    [channel_workspace_id] are required together when any
    connector context is supplied; [channel_user_id] and
    [channel_user_name] are optional. *)

(** {1 Parsing} *)

val parse_keeper_chat_stream_request :
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

val handle_keeper_tool_approval :
  Mcp_server.server_state -> Httpun.Request.t -> Httpun.Reqd.t -> unit
(** Drives [POST /api/v1/keepers/tool-approval].

    Reads [{"name", "tool_call_id", "decision"}] where decision is
    ["approve"] or ["deny"], and releases the matching held tool call.

    Returns [{settled: true}] when a wait was actually released, and
    [{settled: false}] when none was: the call had already timed out, was
    answered, or was never held. That is reported rather than treated as
    success, so an operator is not told a call was approved when nothing was
    listening for it. *)

val handle_keeper_turns_list :
  Mcp_server.server_state -> Httpun.Request.t -> Httpun.Reqd.t -> unit
(** Drives [GET /api/v1/keepers/turns].

    One row per registered keeper naming whether a turn is running right now
    ([turn] is [null] or [{lane; started_at_unix}]). Live Owner projection,
    not a store read: the durable keeper meta cannot answer this, which is
    why the TUI keeper list polls this route for its "answering now" badge.
    A failed keeper-name census is a 500, never an empty fleet. *)

val handle_keeper_tool_approvals_list :
  Mcp_server.server_state -> Httpun.Request.t -> Httpun.Reqd.t -> unit
(** Drives [GET /api/v1/keepers/tool-approvals].

    Projects every held tool call from the shared approval registry:
    [{pending: [{keeper, tool_call_id, tool, args, question, because,
    asked_at, timeout_sec}]}], oldest first. Live registry state only — a wait
    exists exactly while its turn is parked on it. This is what lets an
    operator answer a call whose owning stream watcher is gone; without it
    such a call can only time out (masc#30034). [because] is the policy's
    one-line reason for asking — the listing is the only place an operator
    sees it, so it rides with the question. *)

val handle_keeper_tool_approval_mode_get :
  Mcp_server.server_state -> Httpun.Request.t -> Httpun.Reqd.t -> unit
(** Drives [GET /api/v1/keepers/tool-approval-mode]: the keepers moved off
    the default stance, as [{overrides: [{keeper, mode}], default:"auto"}].
    A keeper absent from the list is [auto]. *)

val handle_keeper_tool_approval_mode_set :
  actor:string ->
  Mcp_server.server_state -> Httpun.Request.t -> Httpun.Reqd.t -> unit
(** Drives [POST /api/v1/keepers/tool-approval-mode]. Reads
    [{"name", "mode"}] where mode is ["auto"] or ["yolo"], validates the
    keeper is registered, and sets the in-memory stance the approval gate
    consults per call. The stance does not survive a restart — deliberately:
    [yolo] runs every tool call unasked. [actor] is the authenticated
    operator who changed the stance and is recorded in the change log. *)

val handle_keeper_turn_interrupt :
  Mcp_server.server_state -> Httpun.Request.t -> Httpun.Reqd.t -> unit
(** Drives [POST /api/v1/keepers/turn/interrupt].
    Reads [{"name": "<keeper>", "request_id": "<operation>"}]. With a
    request id it asks {!Keeper_owner.interrupt_running_operation} for a
    mailbox-linearized compare-and-interrupt and echoes that id; a stale
    request can never cancel its replacement. The name-only form remains for
    operator surfaces that do not own a chat operation and uses
    {!Keeper_registry.interrupt_current_turn}.

    [signalled] is not a completed cancellation: the signal still has to
    reach the running fiber, and a fiber parked in an uncancellable section
    keeps running. The turn state, not this response, says whether the turn
    ended. *)

(** {1 SSE handler} *)

val handle_keeper_chat_stream :
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  submitted_by:string ->
  Mcp_server.server_state ->
  Httpun.Request.t ->
  Httpun.Reqd.t ->
  keeper_chat_stream_request ->
  unit
(** Drives the [POST /api/keeper/chat-stream] SSE
    response.  Streams keeper turn events back to the
    client over [text/event-stream] with CORS + cache
    suppression headers, gated by the per-request switch
    [sw] and the wall clock [clock].  Closes the writer
    on switch release; surfaces handler exceptions
    through the SSE stream rather than the HTTP envelope
    once the headers have flushed. *)

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
  events:Keeper_chat_events.keeper_chat_event Eio.Stream.t ->
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
    claims exactly once, streams events by operation id, and joins terminal
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
      (** [Some] only on [External_effect_completed], and only when the
          completed effect was a surface post. A memory-write completion
          carries {!Keeper_tool_execution.memory_revision_wire_key} instead
          and decodes to [None]. The decoder rejects the outcome with
          neither proof, with both, and either proof on any other
          outcome. *)
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
(** Wire-terminal accounting for one keeper chat operation: whether a live
    AG-UI audience exists and whether a terminal event (RUN_FINISHED/
    RUN_ERROR) made it out. The stream counts as open from sink registration
    — not from the first projected event — so a turn that fails after claim
    but before the projection runs still gets its synthesized terminal; the
    record is dropped when the last sink unregisters. Consumed by the Owner
    settle hook after the child switch unwinds (#28811). *)

module For_testing : sig
  val parse_request : string -> (keeper_chat_stream_request, string) result
  val has_connector_context : keeper_chat_stream_request -> bool
  val has_external_speaker : keeper_chat_stream_request -> bool
  val message_for_request : keeper_chat_stream_request -> string
  val chat_surface_of_request : keeper_chat_stream_request -> Surface_ref.t
  val chat_speaker_of_request : keeper_chat_stream_request -> Keeper_chat_store.speaker
  val turn_instructions_for_request : keeper_chat_stream_request -> string option
  val direct_message_of_request :
    keeper_chat_stream_request -> Keeper_invocation_contract.direct_message
  val keeper_chat_stream_headers : string -> Httpun.Headers.t
  val canonical_reply_payload_of_body :
    redact_text:(string -> string) ->
    string ->
    (canonical_reply_payload, canonical_reply_payload_error) result
  val direct_reply_terminal_error :
    ?has_visible_blocks:bool -> Yojson.Safe.t option -> string -> string option
  val persisted_reply_blocks :
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

  val note_operation_wire_event : operation_id:string -> Ag_ui.event -> unit
  val take_operation_wire_stream :
    operation_id:string -> operation_wire_stream option
  val synthesize_wire_terminal_on_settle :
    keeper_name:string ->
    operation_id:string ->
    execution:Keeper_owner.operation_execution ->
    unit
  val on_operation_execution_settled :
    keeper_name:string ->
    claimed_operation_id:Keeper_owner.Chat_operation.Operation_id.t option ->
    execution:Keeper_owner.operation_execution ->
    unit
  val register_operation_live_sink :
    operation_id:string -> (Ag_ui.event -> unit) -> unit -> unit
end

val handle_keeper_ask_answer :
  Mcp_server.server_state -> Httpun.Request.t -> Httpun.Reqd.t -> unit
(** Drives [POST /api/v1/keepers/ask-answer].

    Reads [{"name", "ask_id", "answers": [{"question_id", "response"}], ...}]
    where a response is [{"kind": "chose", "choice_ids": [...]}],
    [{"kind": "wrote", "text": ...}], or [{"kind": "skipped"}]. Optional
    ["actor_id"] and ["session_id"] record who answered and from which
    dashboard session.

    Two surfaces can submit for one ask at once and nothing locks the log. The
    fold settles on first write, so a submission that lost returns [`Conflict]
    carrying the answer that landed rather than a bare rejection: the surface
    showing it has to be able to say what was chosen instead.

    [`Not_found] means the ask or the keeper is unknown, [`Bad_request] that
    the submissions do not satisfy the recorded question, and [`Conflict] that
    the ask was already answered or withdrawn. *)

val handle_keeper_asks_list :
  Mcp_server.server_state -> Httpun.Request.t -> Httpun.Reqd.t -> unit
(** Drives [GET /api/v1/keepers/asks?name=<keeper>&include_resolved=<bool>].

    Without [name] this covers the whole fleet and every row names the Keeper
    it belongs to; with [name] it narrows to one and returns [`Not_found] when
    that Keeper is not registered. Defaults to open questions only.

    A surface renders these rows and answers through
    {!handle_keeper_ask_answer}, sending back choice ids taken from the rows it
    was given. No surface matches on label text, so rewording a choice cannot
    orphan an answer already recorded. *)
