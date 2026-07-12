(** Channel_gate_discord_state — Discord connector state.

    Implements the {!Channel_gate_connector.S} module signature so it
    can be registered at server startup via
    [Channel_gate_connector.register (module Channel_gate_discord_state)].

    Internal helpers (the [U] / [Names] / [Store] aliases, the
    [binding] record, the [default_*_path] / [legacy_*_path] /
    path resolvers, the shared binding-store wrappers, the
    [string_member] / [int_member] / [bool_member] /
    [bool_option_member] yojson lookups, [stale_of_updated_at],
    [connector_state_label], [list_assoc_field],
    [find_assoc_by_string_field], and [rollback_bindings]) are
    hidden — only the {!Channel_gate_connector.S} surface is
    public. *)

(** {1 Connector identity} *)

val connector_id : string
(** ["discord"]. *)

val display_name : string
(** ["Discord"]. *)

val channel : string
(** ["discord"]. *)

(** {1 Connector status} *)

val status_json : ?audit_limit:int -> unit -> Yojson.Safe.t
(** Runtime status snapshot — bindings, recent audit events,
    staleness flag, and connector liveness. [audit_limit] caps the
    audit-history slice (default [10]). *)

val connector_json :
  ?gate_status_json:Yojson.Safe.t ->
  ?audit_limit:int ->
  unit ->
  Yojson.Safe.t
(** Full connector descriptor for the dashboard, layering
    [gate_status_json] (if provided) on top of {!status_json}. *)

(** {1 Binding lifecycle} *)

val bind :
  channel_id:string ->
  keeper_name:string ->
  actor_name:string ->
  (Yojson.Safe.t, string) result
(** Create or update a channel→keeper binding, append an audit
    event, and return the resulting binding row as JSON. *)

val unbind :
  channel_id:string ->
  actor_name:string ->
  (Yojson.Safe.t, string) result
(** Remove a channel→keeper binding, append an audit event, and
    return the removed binding row as JSON. *)

(** {1 In-process gateway support}

    Used by {!Server_discord_in_process_gateway}, the OCaml gateway
    that replaces the deleted [sidecars/discord-bot/] Python
    connector. *)

val keeper_for_channel : channel_id:string -> string option
(** Look up the keeper bound to a Discord channel snowflake.
    Returns [None] when no binding exists, when the channel id is
    blank, or when the binding store is unreadable. *)

type keeper_binding_resolution = {
  keeper_name : string;
  incoming_channel_id : string;
  bound_channel_id : string;
  via_parent : bool;
}

val resolve_keeper_for_channel :
  channel_id:string -> keeper_binding_resolution option
(** Resolve the keeper for [channel_id]. Exact bindings win. If no
    exact binding exists and [channel_id] is a Discord thread known
    in the names side-store, its parent channel binding is used. *)

val thread_provenance_metadata :
  channel_id:string -> keeper_binding_resolution -> (string * string) list
(** Emit the live thread/parent identifiers proven by the binding resolution.
    A top-level channel has no thread provenance. *)

val bound_channels : keeper_name:string -> string list
(** Channel snowflakes bound to [keeper_name], freshly read from the
    binding store on each call. Empty on blank name or unreadable
    store. RFC-0223 P2 presence. *)

val connected : unit -> bool
(** Whether the in-process gateway's run loop currently reports
    [Connected]. Reads {!Discord_gateway_client.connection_state};
    no file indirection. RFC-0223 P2 presence. *)

val record_ready : bot_user_id:string -> unit
(** Called by the in-process gateway's READY handler. Stores the bot
    identity and timestamp that {!status_json} reports as
    [bot_user_id] / [last_ready_at]. Atomic write — safe to call from
    the gateway fiber while HTTP handlers read. *)

(** {2 Thread registry}

    Thread→parent channel mapping populated from THREAD_CREATE gateway
    events. Used by {!resolve_keeper_for_channel} to resolve bindings
    for messages in Discord threads (whose [channel_id] is the thread's
    snowflake, distinct from the parent channel). *)

val register_thread : thread_id:string -> parent_channel_id:string -> unit
(** Register a Discord thread's parent channel. Called from the gateway's
    [Thread_tracked] event handler. Overwrites on duplicate. *)

val parent_channel_of_thread : channel_id:string -> string option
(** If [channel_id] is a known thread, return its parent channel ID. *)

val is_known_thread : channel_id:string -> bool
(** [true] when [channel_id] has been registered as a Discord thread. *)

val registered_thread_count : unit -> int
(** Number of threads currently in the registry. For diagnostics. *)

val unregister_thread : thread_id:string -> unit
(** Remove a Discord thread from the registry. Called when the gateway
    receives a THREAD_DELETE dispatch or a THREAD_UPDATE with
    [thread_metadata.archived = true]. No-op for blank or unknown ids. *)

(** {2 Trigger policy}

    Set once at gateway startup, read by [connectors_json] for dashboard
    display. Same mutable-ref pattern as [record_ready]. *)

val set_trigger_policy : Discord_gateway_state.trigger_policy -> unit
(** Store the resolved trigger policy. Called once at gateway startup. *)

val get_trigger_policy : unit -> Discord_gateway_state.trigger_policy option
(** Current trigger policy. [None] before gateway startup. *)

(** Typed failure modes for Discord REST actions. Closed sum — adding
    a new variant forces every consumer to handle it. *)
type send_error =
  | Missing_token
    (** [DISCORD_BOT_TOKEN] is unset or empty. *)
  | Rest_error of Discord_rest_client.error
    (** Discord REST returned a typed failure. *)

val pp_send_error : Format.formatter -> send_error -> unit

val send_message :
  channel_id:string ->
  content:string ->
  ?reply_to_message_id:string ->
  unit ->
  (string, send_error) result
(** Post a single message to a Discord channel.  When
    [reply_to_message_id] is provided, the message is sent as a
    reply (Discord threads the conversation).  Returns the created
    message id on success.  Bot token is resolved from
    [DISCORD_BOT_TOKEN] at call time so a token rotation doesn't
    require a server restart.

    Must be called inside an Eio context (the underlying REST
    client uses the piaf-backed http pool). *)

val edit_message :
  channel_id:string ->
  message_id:string ->
  content:string ->
  unit ->
  (unit, send_error) result
(** Patch a previously-created Discord message. Used by the in-process
    gateway to project keeper streaming snapshots into one edited reply.
    Content exceeding Discord's message limit is truncated by
    {!Discord_rest_client.edit_message}; callers that need overflow delivery
    must send follow-up messages separately. *)

val trigger_typing :
  channel_id:string ->
  unit ->
  (unit, send_error) result
(** Trigger Discord's typing indicator for [channel_id]. Bot token is
    resolved from [DISCORD_BOT_TOKEN] at call time, matching
    {!send_message}. *)
