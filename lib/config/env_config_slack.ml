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
(** Fallback: read a key from the Slack runtime TOML config written by the
    dashboard Save form at [.gate/runtime/slack/config.toml]. *)
let toml_key_opt key =
  match Config_dir_resolver.current_env_base_path_opt () with
  | None -> None
  | Some base ->
    let path = Filename.concat (Filename.concat (Filename.concat base ".gate") "runtime")
                 (Filename.concat "slack" "config.toml") in
    if not (Sys.file_exists path) then None
    else
      let ic = open_in path in
      let rec find () =
        match input_line ic with
        | exception End_of_file -> close_in ic; None
        | line ->
          let s = String.trim line in
          if String.length s > 0 && s.[0] <> '#' && String.length s > String.length key + 1
             && String.sub s 0 (String.length key + 1) = key ^ " ="
          then begin
            let rest = String.trim (String.sub s (String.length key + 1) (String.length s - String.length key - 1)) in
            close_in ic;
            (* Strip surrounding quotes *)
            if String.length rest >= 2 && rest.[0] = '"' && rest.[String.length rest - 1] = '"'
            then Some (String.sub rest 1 (String.length rest - 2))
            else if String.length rest >= 2 && rest.[0] = '\'' && rest.[String.length rest - 1] = '\''
            then Some (String.sub rest 1 (String.length rest - 2))
            else Some rest
          end
          else find ()
      in find ()

let app_token_opt () =
  match Sys.getenv_opt "SLACK_APP_TOKEN" |> trim_opt with
  | Some v -> Some v
  | None -> toml_key_opt "slack_app_token"

let bot_token_opt () =
  match Sys.getenv_opt "SLACK_BOT_TOKEN" |> trim_opt with
  | Some v -> Some v
  | None -> toml_key_opt "slack_bot_token"

let trigger_policy_opt () =
  match Sys.getenv_opt "MASC_SLACK_TRIGGER_POLICY" |> trim_opt with
  | Some v -> Some v
  | None -> toml_key_opt "trigger_policy"
