(** Server_slack_in_process_gateway — in-process Slack Socket Mode gateway
    (RFC-0317 PR-3). The Slack mirror of {!Server_discord_in_process_gateway}.

    Spawned once during server bootstrap. Forks a long-running fiber on the
    server-wide [Eio.Switch.t] that:

    1. Resolves the bot identity via [auth.test] (non-fatal) and connects to
       Slack Socket Mode ({!Slack_socket_client.run}).
    2. For each triggered [Message_create] / [App_mention] event, looks up the
       channel→keeper binding and durably accepts the exact source event before
       the socket callback returns. Network ACK delivery then runs on the
       Keeper-scoped connector lane; the durable chat-queue consumer owns the
       eventual Keeper turn and connector reply.

    Off by default: if [SLACK_APP_TOKEN] is unset the gateway logs a
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

type trigger_policy_toml_load =
  | Runtime_toml_missing
  | Trigger_policy_missing
  | Trigger_policy_loaded of Slack_gateway_state.trigger_policy
(** Typed result of reading the optional Slack trigger policy from
    [runtime.toml]. Missing file/key are deliberate no-config outcomes; a
    present value has already passed the canonical policy parser. *)

type trigger_policy_load_error =
  | Runtime_toml_unreadable of { path : string; detail : string }
  | Runtime_toml_invalid of { path : string; detail : string }
  | Trigger_policy_invalid of { path : string; detail : string }
(** Fail-closed configuration errors. They are never converted to the env or
    default policy. *)

val load_trigger_policy_from_toml :
  path:string -> (trigger_policy_toml_load, trigger_policy_load_error) result
(** Read and validate the Slack trigger policy at [path]. *)

val trigger_policy_load_error_to_string : trigger_policy_load_error -> string

module For_testing : sig
  val submit_event :
    ?deliver:(unit -> unit) ->
    Connector_ingress_lane.t ->
    dispatch:Channel_gate.dispatch_fn ->
    clock:_ Eio.Time.clock ->
    Slack_socket_client.slack_event ->
    unit
end

val start :
  sw:Eio.Switch.t ->
  env:Eio_unix.Stdenv.base ->
  state:Mcp_server.server_state ->
  unit
(** Fork the gateway fiber. Returns immediately. Warnings and the eventual
    gateway crash (if any) are emitted via [Log.Server]. Cancellation
    propagates through [~sw]. *)
