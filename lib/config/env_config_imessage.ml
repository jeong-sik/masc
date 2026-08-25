(** Env_config_imessage — iMessage connector env accessors.

    Centralizes the iMessage env reads at the config boundary so neither the
    connector state module nor the in-process gateway holds a direct
    [Sys.getenv_opt] call. *)

open Env_config_core

(* All five keep the [MASC_IMESSAGE_] namespace. iMessage has no credential —
   it is authorized by macOS grants on the process, not by a token — so the
   unprefixed spelling that Slack and Discord use for their SDK-conventional
   token names has nothing to name here. Everything below is MASC policy. *)
(* Apple's fixed location, relative to the account's home. *)
let chat_db_relative_path = "Library/Messages/chat.db"

let chat_db_path () =
  match Sys.getenv_opt "MASC_IMESSAGE_CHAT_DB_PATH" |> trim_opt with
  | Some path -> path
  | None ->
    let home = Option.value (Sys.getenv_opt "HOME") ~default:"" in
    Filename.concat home chat_db_relative_path
;;
let reply_mode_opt () = Sys.getenv_opt "MASC_IMESSAGE_REPLY_MODE" |> trim_opt

let self_chat_guid_opt () =
  Sys.getenv_opt "MASC_IMESSAGE_SELF_CHAT_GUID" |> trim_opt
;;

let poll_interval_sec_opt () =
  Sys.getenv_opt "MASC_IMESSAGE_POLL_INTERVAL_SEC" |> trim_opt
;;

let cursor_path_opt () = Sys.getenv_opt "MASC_IMESSAGE_CURSOR_PATH" |> trim_opt
