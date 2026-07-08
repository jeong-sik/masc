(** Env_config_slack — Slack connector env accessors (RFC-0317).

    Centralizes the Slack Socket Mode env reads at the config boundary so the
    in-process gateway ({!Server_slack_in_process_gateway}) holds no direct
    [Sys.getenv_opt] calls. Values are optional strings: absent/blank ⇒ [None],
    which the gateway treats as "not configured". *)

open Env_config_core

(* Tokens are unprefixed ([SLACK_APP_TOKEN] / [SLACK_BOT_TOKEN]): this matches
   the Slack SDK convention, the Python sidecar (sidecars/slack-bot), the
   dashboard setup guide, and the Discord precedent ([DISCORD_BOT_TOKEN]), so an
   operator sets one token that both the sidecar and this in-process gateway
   read. The trigger policy keeps the [MASC_SLACK_] namespace — it is a
   MASC-internal policy override, not a credential, and mirrors
   [MASC_DISCORD_TRIGGER_POLICY]. *)
let app_token_opt () = Sys.getenv_opt "SLACK_APP_TOKEN" |> trim_opt
let bot_token_opt () = Sys.getenv_opt "SLACK_BOT_TOKEN" |> trim_opt
let trigger_policy_opt () =
  Sys.getenv_opt "MASC_SLACK_TRIGGER_POLICY" |> trim_opt
