(** Env_config_slack — Slack connector env accessors (RFC-0317).

    Config-boundary reads for the in-process Slack connector. Disabled or
    invalid configuration suppresses both tokens even when inherited. *)

type connector_state =
  | Enabled
  | Disabled
  | Invalid_configuration of string

val connector_state : unit -> connector_state

(** Installed from the resolved runtime.toml during server bootstrap, before
    any connector starts. Missing [slack.enabled] preserves [Enabled]. *)
val configure_connector : connector_state -> unit

(** Operator-facing configuration reason, without credential values. *)
val unavailable_reason : unit -> string option

(** [SLACK_APP_TOKEN] — app-level token ([xapp-...]) for Socket Mode
    [apps.connections.open]. Absent ⇒ the gateway does not start. Unprefixed to
    match the Slack SDK convention and the dashboard guide. *)
val app_token_opt : unit -> string option

(** [SLACK_BOT_TOKEN] — bot token ([xoxb-...]) for REST outbound and
    [auth.test] bot-identity resolution. *)
val bot_token_opt : unit -> string option

(** [MASC_SLACK_TRIGGER_POLICY] — raw policy override, parsed by
    {!Slack_gateway_state.parse_trigger_policy} via the gateway. *)
val trigger_policy_opt : unit -> string option
