(** Env_config_slack — Slack connector env accessors (RFC-0317).

    Centralizes the Slack Socket Mode env reads at the config boundary so the
    in-process gateway ({!Server_slack_in_process_gateway}) holds no direct
    [Sys.getenv_opt] calls. Values are optional strings: absent/blank ⇒ [None],
    which the gateway treats as "not configured". *)

open Env_config_core

let app_token_opt () = Sys.getenv_opt "MASC_SLACK_APP_TOKEN" |> trim_opt
let bot_token_opt () = Sys.getenv_opt "MASC_SLACK_BOT_TOKEN" |> trim_opt
let trigger_policy_opt () =
  Sys.getenv_opt "MASC_SLACK_TRIGGER_POLICY" |> trim_opt
