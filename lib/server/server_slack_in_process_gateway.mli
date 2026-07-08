(** Server_slack_in_process_gateway — in-process Slack Socket Mode gateway
    (RFC-0317 PR-3). The Slack mirror of {!Server_discord_in_process_gateway}.

    Spawned once during server bootstrap. Forks a long-running fiber on the
    server-wide [Eio.Switch.t] that:

    1. Resolves the bot identity via [auth.test] (non-fatal) and connects to
       Slack Socket Mode ({!Slack_socket_client.run}).
    2. For each triggered [Message_create] / [App_mention] event, looks up the
       channel→keeper binding
       ({!Channel_gate_slack_state.resolve_keeper_for_channel}), runs the keeper
       turn through {!Channel_gate.handle_inbound_streaming}, and projects
       redacted text snapshots by posting/editing one threaded reply via
       {!Channel_gate_slack_state.send_message} / [edit_message].

    Off by default: if [MASC_SLACK_APP_TOKEN] is unset the gateway logs a
    warning and skips startup; the server still boots normally. A message
    arriving while the keeper is in flight is enqueued (connector_kind [Slack])
    for deferred delivery, not dropped.

    Not covered this pass (RFC-0317 follow-up): ambient recording + idle-keeper
    wake on non-triggering messages, and reaction-as-trigger.

    See: docs/rfc/RFC-0317-slack-builtin-gateway.md. *)

val default_trigger_policy : Slack_gateway_state.trigger_policy
(** Policy used when none is configured (empty/unset): the quiet,
    mention-triggered baseline ([Mention_or_thread]). *)

val parse_trigger_policy : string -> Slack_gateway_state.trigger_policy
(** Resolve a configured trigger-policy string. Empty/whitespace is treated as
    unset and returns {!default_trigger_policy}. A non-empty value is parsed by
    the single canonical grammar ({!Slack_gateway_state.parse_trigger_policy});
    a value that fails to parse is logged via [Log.Server] and falls back to the
    default rather than being silently coerced. Exposed for unit testing the
    config boundary. *)

val start :
  sw:Eio.Switch.t ->
  env:Eio_unix.Stdenv.base ->
  state:Mcp_server.server_state ->
  unit
(** Fork the gateway fiber. Returns immediately. Warnings and the eventual
    gateway crash (if any) are emitted via [Log.Server]. Cancellation
    propagates through [~sw]. *)
