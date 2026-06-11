(** Channel_gate_discord_state — Discord connector state.

    Implements the {!Channel_gate_connector.S} module signature so it
    can be registered at server startup via
    [Channel_gate_connector.register (module Channel_gate_discord_state)].

    Internal helpers (the [U] / [Names] aliases, the [binding] /
    [audit_event] records, the [default_*_path] / [legacy_*_path] /
    [status_path] / [status_write_path] / [binding_store_path] /
    [binding_store_read_path] / [binding_audit_path] /
    [binding_audit_read_path] resolvers, [stale_after_sec],
    [read_json_file_opt], [normalize_bindings_json],
    [read_bindings] / [save_bindings] / [binding_json] /
    [audit_event_json] / [append_audit_event] / [read_recent_audit] /
    [drop_left], the [string_member] / [int_member] / [bool_member] /
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

val bound_channels : keeper_name:string -> string list
(** Channel snowflakes bound to [keeper_name], freshly read from the
    binding store on each call. Empty on blank name or unreadable
    store. RFC-0223 P2 presence. *)

val connected : unit -> bool
(** Whether the in-process gateway's run loop currently reports
    [Connected]. Reads {!Discord_gateway_client.connection_state};
    no file indirection. RFC-0223 P2 presence. *)

(** Typed failure modes for {!send_message}. Closed sum — adding
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
