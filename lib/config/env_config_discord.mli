(** Env_config_discord — Discord connector env accessor.

    Config-boundary read for every Discord surface. *)

val bot_token_opt : unit -> string option
(** [DISCORD_BOT_TOKEN] — bot token for REST and gateway auth. Returns [None]
    when unset or blank. Unprefixed to match the Discord convention and the
    Slack precedent ([SLACK_BOT_TOKEN]). *)

(** [MASC_DISCORD_TRIGGER_POLICY] — raw policy override, parsed by
    {!Discord_gateway_state.parse_trigger_policy} via the gateway. Returns
    [None] when unset or blank, so a blank value falls through to the
    runtime.toml plane. *)
val trigger_policy_opt : unit -> string option
