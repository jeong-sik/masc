(** Server_slack_in_process_gateway — in-process Slack Socket Mode gateway
    (RFC-0317 PR-3). The Slack mirror of {!Server_discord_in_process_gateway}.

    Spawned once during server bootstrap. Forks a long-running fiber on the
    server-wide [Eio.Switch.t] that:

    1. Resolves the bot identity via [auth.test] (non-fatal) and connects to
       Slack Socket Mode ({!Slack_socket_client.run}).
    2. For each triggered [Message_create] / [App_mention] event, looks up the
       channel→keeper binding and durably accepts the exact source event before
       the socket callback returns. Network ACK delivery then runs on the
       Keeper-scoped connector lane; the Keeper Owner operation owns the
       eventual turn and connector reply.

    Ambient parity with the Discord gateway (RFC-0226): a human message that
    fails the trigger policy is persisted as durable external attention plus a
    single chat-store user line, committed as a durable [Connector_attention]
    stimulus, and followed by a best-effort wake hint for the bound keeper.
    Reactions are record-only observability signal on both connectors; a
    reaction never starts a turn.

    Off by default: if [SLACK_APP_TOKEN] is unset the gateway logs a
    warning and skips startup; the server still boots normally. A message
    arriving while the keeper is in flight is enqueued with the leaf-owned
    Slack delivery source for deferred delivery, not dropped.

    See: docs/rfc/RFC-0317-slack-builtin-gateway.md. *)

val default_trigger_policy : Slack_gateway_state.trigger_policy
(** Policy used when none is configured (empty/unset): the quiet,
    mention-triggered baseline ([Mention_or_thread]). *)

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
  | Trigger_policy_env_invalid of { detail : string }
(** Fail-closed configuration errors. They are never converted to the env or
    default policy. Both configured planes fail the same way: an unparseable
    [MASC_SLACK_TRIGGER_POLICY] is an error exactly like an unparseable
    [slack.trigger_policy] in runtime.toml. *)

val load_trigger_policy_from_toml :
  path:string -> (trigger_policy_toml_load, trigger_policy_load_error) result
(** Read and validate the Slack trigger policy at [path]. *)

val trigger_policy_load_error_to_string : trigger_policy_load_error -> string

val resolved_trigger_policy :
  unit -> (Slack_gateway_state.trigger_policy, trigger_policy_load_error) result
(** Env > TOML > default, the same precedence the Discord sibling applies.
    [MASC_SLACK_TRIGGER_POLICY] wins when set and valid; an invalid env value
    is a load error (never a silent default); a blank/unset env falls through
    to the [slack.trigger_policy] runtime.toml key, and a missing file/key
    yields {!default_trigger_policy}. *)

module For_testing : sig
  val submit_event :
    ?deliver:(unit -> unit) ->
    ?team_id:string ->
    ?user_directory:Slack_user_directory.t ->
    Connector_ingress_lane.t ->
    dispatch_for_delivery:
      (Gate_keeper_backend.connector_delivery -> Channel_gate.dispatch_fn) ->
    clock:_ Eio.Time.clock ->
    base_dir:string ->
    Slack_socket_client.slack_event ->
    unit

  val resolve_event_identity :
    ?user_directory:Slack_user_directory.t ->
    Slack_socket_client.slack_event ->
    Slack_socket_client.slack_event
  (** Inbound identity rendering (issue #28376): author display label plus
      [<@U…>] mention rewriting, applied by both submit lanes. Exposed so
      tests can pin the mapping without a live socket. *)

  val record_external_attention :
    base_dir:string ->
    keeper_name:string ->
    team_id:string option ->
    channel_id:string ->
    channel_name:string option ->
    thread_ts:string option ->
    ts:string ->
    user_id:string ->
    user_name:string option ->
    content:string ->
    mentions_bot:bool ->
    route:string ->
    urgency:Keeper_external_attention.urgency ->
    string option
  (** The durable attention producer used by both the triggered and ambient
      lanes; exposed for durable round-trip tests. *)
end

val start :
  sw:Eio.Switch.t ->
  env:Eio_unix.Stdenv.base ->
  state:Mcp_server.server_state ->
  unit
(** Fork the gateway fiber. Returns immediately. Warnings and the eventual
    gateway crash (if any) are emitted via [Log.Server]. Cancellation
    propagates through [~sw]. *)
