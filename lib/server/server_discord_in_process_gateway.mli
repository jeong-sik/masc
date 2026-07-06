(** Server_discord_in_process_gateway — OCaml gateway that replaces
    the deleted [sidecars/discord-bot/] Python connector.

    Spawned once during server bootstrap. Forks a long-running fiber
    on the server-wide [Eio.Switch.t] that:

    1. Opens a WSS connection to Discord Gateway v10
       ({!Discord_gateway_client.run}).
    2. For each accepted [Message_create] event, looks up the
       channel→keeper binding
       ({!Channel_gate_discord_state.keeper_for_channel}), runs the
       keeper turn through {!Channel_gate.handle_inbound_streaming},
       projects redacted text snapshots by posting/editing one Discord
       reply, and falls back to
       {!Channel_gate_discord_state.send_message} when streaming never
       starts or fails.

    Always-on by design: there is no [MASC_DISCORD_BUILTIN]-style
    toggle. The legacy Python sidecar is gone — there is no
    fallback path to switch back to. If
    [DISCORD_BOT_TOKEN] is unset the gateway logs a warning and
    skips startup; the server still boots normally.

    See: docs/rfc/RFC-0203-discord-builtin-gateway.md §Phase 3. *)

val default_trigger_policy : Discord_gateway_client.trigger_policy
(** Policy used when none is configured (empty/unset): the quiet,
    mention-triggered baseline ([Mention_or_thread]). *)

val parse_trigger_policy : string -> Discord_gateway_client.trigger_policy
(** Resolve a configured trigger-policy string. Empty/whitespace is
    treated as unset and returns {!default_trigger_policy}. A non-empty
    value is parsed by the single canonical grammar
    ({!Discord_gateway_state.parse_trigger_policy}); a value that fails
    to parse is logged via [Log.Server] and falls back to the default,
    rather than being silently coerced. Exposed for unit testing the
    config boundary. *)

val start :
  sw:Eio.Switch.t ->
  env:Eio_unix.Stdenv.base ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  state:Mcp_server.server_state ->
  unit
(** Fork the gateway fiber. Returns immediately. Warnings and the
    eventual gateway crash (if any) are emitted via [Log.Server].
    Cancellation propagates through [~sw]. *)

module For_testing : sig
  val handle_ambient :
    base_dir:string ->
    channel_id:string ->
    guild_id:string option ->
    message_id:string ->
    author_id:string ->
    author_name:string option ->
    content:string ->
    unit
  (** Exercise the ambient connector path without opening a Discord gateway
      connection. This preserves the production handler body so tests can pin
      the external-attention record plus typed wake producer. *)
end
