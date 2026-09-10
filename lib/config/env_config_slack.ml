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
   precedent ([DISCORD_BOT_TOKEN]). Credentials are all this leaf reads: the
   trigger policy is a stance the operator writes down, so it comes from
   [slack.trigger_policy] in runtime.toml and has no env plane. *)
let app_token_opt () = token_opt "SLACK_APP_TOKEN"
let bot_token_opt () = token_opt "SLACK_BOT_TOKEN"
