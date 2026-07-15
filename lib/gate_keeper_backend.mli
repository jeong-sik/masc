(** Gate_keeper_backend -- adapter between the Channel Gate and the keeper subsystem.

    This module owns the coupling to [Keeper_tool_surface], [Client_identity],
    and [Workspace].  The gate orchestrator ([Channel_gate]) calls
    {!dispatch} without knowing how keeper dispatch works internally.

    The return type {!Gate_protocol.dispatch_result} lives in
    [Gate_protocol] so that [Channel_gate] does not need to depend
    on this module for type definitions.

    @since 2.222.0 *)

(** {1 Connector delivery} *)

type connector_delivery =
  { source : Keeper_chat_queue.message_source
  ; surface : Surface_ref.t
  ; conversation_id : string option
  ; external_message_id : string option
  }
(** Immutable projection of the connector-owned delivery coordinates. The leaf
    parses its own protocol and supplies this value; the Keeper adapter treats
    every field as typed opaque input and does not inspect product metadata. *)

val accept_connector :
  delivery:connector_delivery ->
  clock:_ Eio.Time.clock ->
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
(** Commit one in-process connector event to the existing per-Keeper durable
    chat queue before returning. The connector leaf owns {!connector_delivery};
    this adapter neither identifies products nor derives routes from
    product-specific metadata. The producer's typed request identity is the
    queue receipt and transcript delivery key; retries converge without a
    derived hash namespace. *)

val dispatch :
  submitted_by:string ->
  sw:Eio.Switch.t ->
  clock:_ Eio.Time.clock ->
  proc_mgr:Eio_unix.Process.mgr_ty Eio.Resource.t option ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t option ->
  publication_recovery_provider:
    Keeper_publication_recovery_availability.provider ->
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
(** Build the generic HTTP Gate Keeper context. A busy Keeper returns an
    accepted async request envelope ([Keeper_msg_async]) instead of blocking the
    HTTP request. Durable connector leaves use {!accept_connector} and do not
    enter this path. The [channel] and [channel_user_id] construct the agent name
    ([gate:<channel>:<workspace_id>:<user_id>]) for conversation identity;
    [submitted_by] independently binds poll/cancel authority. The other
    generic Gate fields are injected into the keeper-visible message body so
    external user identity survives memory and handoff boundaries. *)

val dispatch_with_text_snapshot :
  submitted_by:string ->
  on_text_snapshot:(string -> unit) ->
  sw:Eio.Switch.t ->
  clock:_ Eio.Time.clock ->
  proc_mgr:Eio_unix.Process.mgr_ty Eio.Resource.t option ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t option ->
  publication_recovery_provider:
    Keeper_publication_recovery_availability.provider ->
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
