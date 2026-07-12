(** Gate_keeper_backend -- adapter between the Channel Gate and the keeper subsystem.

    This module owns the coupling to [Keeper_tool_surface], [Client_identity],
    and [Workspace].  The gate orchestrator ([Channel_gate]) calls
    {!dispatch} without knowing how keeper dispatch works internally.

    The return type {!Gate_protocol.dispatch_result} lives in
    [Gate_protocol] so that [Channel_gate] does not need to depend
    on this module for type definitions.

    @since 2.222.0 *)

(** {1 Connector deferred-reply routing (RFC-connector-deferred-reply-via-chat-queue)} *)

type connector_kind =
  | Discord
  | Slack
  | Generic
(** The typed identity of the connector a {!dispatch} serves, injected at
    dispatch-construction time. [Discord] and [Slack] each have an in-process
    inbound gateway and an outbound adapter, so a busy message projects onto the
    chat queue; [Generic] (the HTTP gate-route lane: imessage-bot, cli-connector)
    keeps the async [masc_keeper_msg] poll path. See
    RFC-connector-deferred-reply-via-chat-queue §3.2–3.3 and RFC-0317. *)

type submission_owner =
  | Authenticated_caller of string
  | Channel_actor
(** Owner of an async request produced by this dispatch. [Channel_actor] uses
    the external actor's deterministic gate identity. [Authenticated_caller]
    keeps poll/cancel authority with the already-authenticated HTTP principal. *)

val route_busy_connector :
  connector_kind ->
  channel_id:string ->
  user_id:string ->
  user_name:string ->
  team_id:string option ->
  thread_ts:string option ->
  [ `Enqueue_chat_queue of Keeper_chat_queue.message_source | `Async_poll ]
(** Pure routing decision for a connector message that arrives while the keeper
    has an in-flight turn. Exhaustive over {!connector_kind}: [Discord] and
    [Slack] return [`Enqueue_chat_queue] with the typed source so the serial
    {!Keeper_chat_consumer} drains and delivers it after the slot frees;
    [Generic] returns [`Async_poll]. Exposed for unit testing the decision in
    isolation. *)

val dispatch :
  connector_kind:connector_kind ->
  submission_owner:submission_owner ->
  sw:Eio.Switch.t ->
  clock:_ Eio.Time.clock ->
  proc_mgr:Eio_unix.Process.mgr_ty Eio.Resource.t option ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t option ->
  config:Workspace.config ->
  channel:string ->
  channel_user_id:string ->
  channel_user_name:string ->
  channel_workspace_id:string ->
  keeper_name:string ->
  idempotency_key:string ->
  metadata:(string * string) list ->
  content:string ->
  Gate_protocol.dispatch_result
(** Build a keeper context, call the keeper surface, and parse the response.
    When the target keeper already has an admitted turn in flight, the busy
    message is routed per {!route_busy_connector}: a [Discord]/[Slack]
    [connector_kind] enqueues onto [Keeper_chat_queue] for deferred delivery via
    the serial consumer's outbound adapter
    (RFC-connector-deferred-reply-via-chat-queue). The enqueue is acknowledged
    only after its durable snapshot commits; the reply's [message_request]
    carries the queue receipt id and revision. When admission is fenced by a
    typed Keeper shutdown operation, the same envelope carries
    [shutdown_operation_id] and the ACK says the receipt waits for the next
    active lane rather than promising completion of a current turn.
    Persistence failure returns an explicit [Keeper_error_result], never a
    queued ACK. [Generic]
    returns an accepted async request envelope ([Keeper_msg_async]) instead of
    blocking the connector request behind that turn. The [channel] and
    [channel_user_id] are used to construct the agent name
    ([gate:<channel>:<workspace_id>:<user_id>]) for conversation identity;
    [submission_owner] independently binds poll/cancel authority. The other connector fields are
    injected into the keeper-visible message body so external user identity
    survives memory and handoff boundaries. *)

val dispatch_with_text_snapshot :
  connector_kind:connector_kind ->
  submission_owner:submission_owner ->
  on_text_snapshot:(string -> unit) ->
  sw:Eio.Switch.t ->
  clock:_ Eio.Time.clock ->
  proc_mgr:Eio_unix.Process.mgr_ty Eio.Resource.t option ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t option ->
  config:Workspace.config ->
  channel:string ->
  channel_user_id:string ->
  channel_user_name:string ->
  channel_workspace_id:string ->
  keeper_name:string ->
  idempotency_key:string ->
  metadata:(string * string) list ->
  content:string ->
  Gate_protocol.dispatch_result
(** Streaming-capable variant of {!dispatch}. The callback receives the
    accumulated assistant text after keeper-scoped secret redaction, so
    connector transports can update one visible message without leaking raw
    provider deltas. The final {!Gate_protocol.dispatch_result} remains the
    authoritative turn result. *)

val agent_name_for_channel_actor :
  channel:string ->
  channel_workspace_id:string ->
  channel_user_id:string ->
  string
(** Deterministic keeper session key for one external actor inside one
    external workspace/thread. *)

val contextualize_message :
  channel:string ->
  channel_user_id:string ->
  channel_user_name:string ->
  channel_workspace_id:string ->
  metadata:(string * string) list ->
  content:string ->
  string
(** Render a stable external-channel context envelope ahead of the raw
    user message so keeper memory can retain actor/channel metadata. *)

val persist_connector_assistant_reply :
  base_dir:string ->
  keeper_name:string ->
  source:string ->
  ?surface:Surface_ref.t ->
  ?conversation_id:string ->
  ?turn_ref:Ids.Turn_ref.t ->
  reply:string ->
  unit ->
  unit
(** Persist a completed connector direct reply on the same chat lane that
    received the inbound user line. Empty replies are ignored.
    [turn_ref] (RFC-0233 §7) is the join key the keeper minted into the
    reply payload, stamped on the assistant row. *)

val filesystem_safe_or_unknown : string -> string
(** Sanitize a value for use as a filesystem path component.
    Replaces everything outside [A-Za-z0-9_-] with '_'.
    Empty or fully-stripped values collapse to "unknown". *)

val extract_reply_text : string -> string
(** Parse the reply text from a keeper response JSON body.
    Reads the ["reply"] field for JSON responses; non-JSON or missing-reply
    bodies are returned verbatim. *)

val extract_turn_stats : string -> Gate_protocol.turn_stats option
(** Extract model usage statistics from a keeper response JSON body.
    Returns [None] when all fields are absent or zero. *)

(** {1 Async ACK Envelope Parsing}

    The Channel Gate's async dispatch path returns a JSON envelope that the
    downstream connector uses to track the keeper-side request lifecycle
    (request_id, status, destination). Parsing this envelope is a wire
    boundary: malformed input must surface as a typed failure so the
    dispatch site can emit a deliberate degraded ACK rather than silently
    substitute the keeper's reply body. *)

type ack_parse_failure =
  | Invalid_json of string
  | Missing_request_id
  | Empty_request_id
  | Missing_status
  | Invalid_status of string
(** Closed-sum typed parse failure for {!extract_message_request_ack}. Each
    variant names a distinct cause so the dispatch site can log structured
    backend drift and emit a degraded ACK that names the parse failure
    explicitly. *)

val ack_parse_failure_to_string : ack_parse_failure -> string
(** Render an {!ack_parse_failure} as a stable human-readable label. Used
    by the degraded ACK path so the connector sees a precise cause rather
    than the raw keeper reply body. *)

val extract_message_request_ack :
  channel:string ->
  channel_user_id:string ->
  keeper_name:string ->
  metadata:(string * string) list ->
  string ->
  (Gate_protocol.message_request, ack_parse_failure) result
(** Parse the async ACK envelope from a keeper tool response body.
    Returns [Ok request] when the body is a valid JSON object with both
    a non-empty [request_id] and a [status] that maps to one of the closed
    [Gate_protocol.message_request_status] variants.
    Returns [Error reason] otherwise. JSON parse failures are isolated
    from the closed-sum status check so that a malformed envelope is
    surfaced as a backend-degraded path, distinct from a legitimately
    absent ACK field. *)
