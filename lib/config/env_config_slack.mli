(** Env_config_slack — Slack connector env accessors (RFC-0317).

    Config-boundary reads for the in-process Slack Socket Mode gateway. Each
    returns [None] when the variable is unset or blank. *)

val app_token_opt : unit -> string option
(** [SLACK_APP_TOKEN] — app-level token ([xapp-...]) for Socket Mode
    [apps.connections.open]. Absent ⇒ the gateway does not start. Unprefixed to
    match the Slack SDK convention, the sidecar, and the dashboard guide. *)

val bot_token_opt : unit -> string option
(** [SLACK_BOT_TOKEN] — bot token ([xoxb-...]) for REST outbound and
    [auth.test] bot-identity resolution. *)

val trigger_policy_opt : unit -> string option
(** [MASC_SLACK_TRIGGER_POLICY] — raw policy override, parsed by
    {!Slack_gateway_state.parse_trigger_policy} via the gateway. *)
