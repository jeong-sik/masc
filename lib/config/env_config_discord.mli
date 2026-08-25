(** Env_config_discord — Discord connector env accessor.

    Config-boundary read for every Discord surface. *)

val bot_token_opt : unit -> string option
(** [DISCORD_BOT_TOKEN] — bot token for REST and gateway auth. Returns [None]
    when unset or blank. Unprefixed to match the Discord convention and the
    Slack precedent ([SLACK_BOT_TOKEN]). *)
