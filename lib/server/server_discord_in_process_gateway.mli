(** Server_discord_in_process_gateway — OCaml gateway that replaces
    the deleted [sidecars/discord-bot/] Python connector.

    Spawned once during server bootstrap. Forks a long-running fiber
    on the server-wide [Eio.Switch.t] that:

    1. Opens a WSS connection to Discord Gateway v10
       ({!Discord_gateway_client.run}).
    2. For each accepted [Message_create] event, looks up the
       channel→keeper binding
       ({!Channel_gate_discord_state.keeper_for_channel}), runs the
       keeper turn through {!Channel_gate.handle_inbound}, and posts
       the reply back to the same channel via
       {!Channel_gate_discord_state.send_message}.

    Always-on by design: there is no [MASC_DISCORD_BUILTIN]-style
    toggle. The legacy Python sidecar is gone — there is no
    fallback path to switch back to. If
    [DISCORD_BOT_TOKEN] is unset the gateway logs a warning and
    skips startup; the server still boots normally.

    See: docs/rfc/RFC-0203-discord-builtin-gateway.md §Phase 3. *)

val start :
  sw:Eio.Switch.t ->
  env:Eio_unix.Stdenv.base ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  state:Mcp_server.server_state ->
  unit
(** Fork the gateway fiber. Returns immediately. Warnings and the
    eventual gateway crash (if any) are emitted via [Log.Server].
    Cancellation propagates through [~sw]. *)
