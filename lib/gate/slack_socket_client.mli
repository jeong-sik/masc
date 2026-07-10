(** Slack_socket_client — I/O layer that drives {!Slack_gateway_state}.

    Thin wrapper, mirroring {!Discord_gateway_client}: fetch a WSS URL via
    [apps.connections.open], open it with {!Discord_wss_connection} (the same
    ws-direct+TLS transport Discord uses — Slack WSS URLs are the same shape),
    parse envelopes, feed them to {!Slack_gateway_state.step}, and run the
    returned effects (ack each envelope, emit events, reconnect on backoff).

    See: docs/rfc/RFC-0xxx-slack-builtin-gateway.md *)

(** Re-export the caller-facing types so callers don't reach into the state
    machine module directly. *)
type slack_event = Slack_gateway_state.slack_event
type trigger_policy = Slack_gateway_state.trigger_policy
type connection_state = Slack_gateway_state.connection_state

val run :
  sw:Eio.Switch.t ->
  env:Eio_unix.Stdenv.base ->
  bot_user_id:string option ->
  app_token:string ->
  trigger_policy:trigger_policy ->
  on_event:(slack_event -> unit) ->
  unit ->
  unit
(** Connect to Slack Socket Mode and dispatch events that pass
    [trigger_policy] to [on_event]. Blocks until [sw] is closed.

    - [app_token] is the Slack app-level token ([xapp-...]) used for
      [apps.connections.open] (the WSS URL fetch). It is never sent over the
      wire to Slack after that — the URL itself carries the credential.
    - [bot_user_id] is the bot's own Slack user id; it gates [mentions_bot] on
      inbound [message] events. The bot token ([xoxb-...]) for outbound REST is
      read by [Channel_gate_slack_state] at send time, not here.
    - [on_event] receives [Message_create] / [App_mention] events that pass the
      trigger policy. [Reaction_added] and ignored events do not start a turn.

    Internally:
    1. Create {!Slack_gateway_state.t} with [trigger_policy].
    2. [Apps_connections_open] effect → [Masc_http_client.get_sync] with the
       app token → fresh WSS URL → {!Discord_wss_connection.connect}.
    3. Reader fiber on the connection's session switch: [read] →
       [Slack_gateway_state.parse_envelope] → [Envelope_received] → [step] →
       run effects ([Send_ack] via [send_text], [Emit_event] via [on_event]).
    4. On [Close_wss]/[Schedule_backoff]: tear down, sleep, re-open.

    No-ops (logs a warning, returns immediately) when [app_token] is empty, so a
    server without Slack configured is unaffected. *)

(** {1 Connection state} *)

val connection_state : unit -> connection_state
(** Last connection state published by the {!run} loop's state machine.
    [Disconnected] until [run] has started. One Slack gateway per process;
    written only by [run], safe to read from any fiber. Feeds connector presence
    ([Channel_gate_slack_state]). *)

module For_testing : sig
  val reader_should_continue_after_input :
    Slack_gateway_state.input -> bool
end
