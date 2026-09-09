(** Env_config_slack — Slack connector env accessors (RFC-0317).

    Centralizes the Slack Socket Mode env reads at the config boundary so the
    in-process gateway ({!Server_slack_in_process_gateway}) holds no direct
    [Sys.getenv_opt] calls. Values are optional strings: absent/blank ⇒ [None],
    which the gateway treats as "not configured". *)

open Env_config_core

type connector_state =
  | Enabled
  | Disabled
  | Invalid_configuration of string

(* This config leaf cannot depend on the higher-level runtime path resolver.
   Server bootstrap installs the parsed policy after resolving its config root.
   Atomic access is safe for both Eio callers and standalone config tests. *)
let state = Atomic.make Enabled
let connector_state () = Atomic.get state
let configure_connector value = Atomic.set state value

let unavailable_reason () =
  match connector_state () with
  | Enabled -> None
  | Disabled -> Some "Slack connector disabled by [slack] enabled=false"
  | Invalid_configuration detail -> Some detail
;;

let token_opt name =
  match connector_state () with
  | Enabled -> Sys.getenv_opt name |> trim_opt
  | Disabled | Invalid_configuration _ -> None
;;

(* Tokens are unprefixed ([SLACK_APP_TOKEN] / [SLACK_BOT_TOKEN]): this matches
   the Slack SDK convention, the dashboard setup guide, and the Discord
   precedent ([DISCORD_BOT_TOKEN]). The trigger policy keeps the [MASC_SLACK_]
   namespace — it is a MASC-internal policy override, not a credential, and
   mirrors [MASC_DISCORD_TRIGGER_POLICY]. *)
let app_token_opt () = token_opt "SLACK_APP_TOKEN"
let bot_token_opt () = token_opt "SLACK_BOT_TOKEN"
let trigger_policy_opt () = Sys.getenv_opt "MASC_SLACK_TRIGGER_POLICY" |> trim_opt
