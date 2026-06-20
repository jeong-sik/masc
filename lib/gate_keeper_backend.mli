(** Gate_keeper_backend -- adapter between the Channel Gate and the keeper subsystem.

    This module owns the coupling to [Keeper_tool_surface], [Client_identity],
    and [Workspace].  The gate orchestrator ([Channel_gate]) calls
    {!dispatch} without knowing how keeper dispatch works internally.

    The return type {!Gate_protocol.dispatch_result} lives in
    [Gate_protocol] so that [Channel_gate] does not need to depend
    on this module for type definitions.

    @since 2.222.0 *)

val dispatch :
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
  metadata:(string * string) list ->
  content:string ->
  Gate_protocol.dispatch_result
(** Build a keeper context, call [Keeper_tool_surface.dispatch], and parse
    the response.  The [channel] and [channel_user_id] are used to
    construct the agent name ([gate:<channel>:<workspace_id>:<user_id>]).  The other
    connector fields are injected into the keeper-visible message body so
    external user identity survives memory and handoff boundaries. *)

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
