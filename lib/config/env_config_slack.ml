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
let config_toml_path () =
  Filename.concat (base_path ()) ".gate/runtime/slack/config.toml"

(* Read a simple key = "value" from config.toml (no table header needed). *)
let read_toml_string_value path key =
  let ic = open_in path in
  Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
    let rec loop () =
      match input_line ic with
      | line ->
        let trimmed = String.trim line in
        (try
          let prefix = Printf.sprintf "%s = \"" key in
          let len = String.length prefix in
          if String.length trimmed >= len && String.sub trimmed 0 len = prefix
          then begin
            let rest = String.sub trimmed len (String.length trimmed - len) in
            let close = String.rindex rest '"' in
            Some (String.sub rest 0 close)
          end else loop ()
        with Not_found -> loop ())
      | exception End_of_file -> None
    in loop ())

let app_token_opt () =
  match Sys.getenv_opt "SLACK_APP_TOKEN" |> trim_opt with
  | Some _ as tok -> tok
  | None ->
    (try read_toml_string_value (config_toml_path ()) "slack_app_token"
         |> trim_opt
     with _ -> None)

let bot_token_opt () =
  match Sys.getenv_opt "SLACK_BOT_TOKEN" |> trim_opt with
  | Some _ as tok -> tok
  | None ->
    (try read_toml_string_value (config_toml_path ()) "slack_bot_token"
         |> trim_opt
     with _ -> None)
(* Write (or update) a top-level key = "value" in config.toml.
   Creates the file+directory if missing. *)
let write_toml_string_value path key value =
  let dir = Filename.dirname path in
  (try Unix.mkdirp dir 0o755 with _ -> ());
  let content =
    try
      let ic = open_in path in
      Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
        let buf = Buffer.create 4096 in
        let rec loop () =
          match input_line ic with
          | exception End_of_file -> Buffer.contents buf
          | line ->
            let trimmed = String.trim line in
            (try
              let prefix = Printf.sprintf "%s = \"" key in
              let len = String.length prefix in
              if String.length trimmed >= len && String.sub trimmed 0 len = prefix
              then (* replace this line *)
                Buffer.add_string buf
                  (Printf.sprintf "%s = \"%s\"" key value)
              else Buffer.add_string buf line
            with Not_found -> Buffer.add_string buf line);
            Buffer.add_char buf '\n';
            loop ()
        in loop ())
    with _ -> ""
  in
  (* If key not found, append it *)
  let content =
    if String.contains content ('=' : char) &&
       let lines = String.split_on_char '\n' content in
       List.exists (fun l ->
         let t = String.trim l in
         try
           let p = Printf.sprintf "%s = \"" key in
           let n = String.length p in
           String.length t >= n && String.sub t 0 n = p
         with Not_found -> false
       ) lines
    then content
    else content ^ Printf.sprintf "%s = \"%s\"\n" key value
  in
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () ->
    output_string oc content)

let save_tokens ~(bot_token : string) ~(app_token : string) =
  let path = config_toml_path () in
  write_toml_string_value path "slack_bot_token" bot_token;
  write_toml_string_value path "slack_app_token" app_token

let trigger_policy_opt () =
  Sys.getenv_opt "MASC_SLACK_TRIGGER_POLICY" |> trim_opt
