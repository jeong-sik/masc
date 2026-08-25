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
  { continuation_channel : Keeper_continuation_channel.t
  ; surface : Surface_ref.t
  ; conversation_id : string option
  ; external_message_id : string option
  ; workspace_id : string option
  }
(** Immutable projection of the connector-owned delivery coordinates. The leaf
    parses its own protocol and supplies this value; the Keeper adapter treats
    every field as typed opaque input and does not inspect product metadata.
    [workspace_id] is the connector workspace identity (Discord guild / Slack
    team); [None] is the explicit typed absence (e.g. a Discord DM), never an
    empty string. *)

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
(** Commit one in-process connector event as a per-Keeper durable operation
    before returning. The connector leaf owns {!connector_delivery};
    this adapter neither identifies products nor derives routes from
    product-specific metadata. The producer's typed request identity is the
    operation id and transcript delivery key; retries converge without a
    derived hash namespace. The typed [delivery.workspace_id] is persisted on
    the durable user row like the speaker identity; any disagreement between
    the typed delivery, the gate [channel_workspace_id], or the connector
    metadata fails closed instead of guessing a workspace. *)

val dispatch :
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
(** Commit a generic HTTP Gate message as one durable Keeper operation and
    return its operation-backed [message_request] immediately. *)

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

val filesystem_safe_or_unknown : string -> string
(** Sanitize a value for use as a filesystem path component.
    Replaces everything outside [A-Za-z0-9_-] with '_'.
    Empty or fully-stripped values collapse to "unknown". *)
