(** Env_config_imessage — iMessage connector env accessors.

    Centralizes the iMessage env reads at the config boundary so neither the
    connector state module nor the in-process gateway holds a direct
    [Sys.getenv_opt] call. *)

(* All five keep the [MASC_IMESSAGE_] namespace. iMessage has no credential —
   it is authorized by macOS grants on the process, not by a token — so the
   unprefixed spelling that Slack and Discord use for their SDK-conventional
   token names has nothing to name here. Everything below is MASC policy.

   The variable names live in [Env_setting.String_opt_knob], which is also what
   [Env_config_snapshot] reports, so the operator surface cannot fall behind
   the reader. *)
(* Apple's fixed location, relative to the account's home. *)
let chat_db_relative_path = "Library/Messages/chat.db"

let chat_db_path () =
  match Env_setting.String_opt_knob.get Imessage_chat_db_path with
  | Some path -> path
  | None ->
    let home = Option.value (Sys.getenv_opt "HOME") ~default:"" in
    Filename.concat home chat_db_relative_path
;;

let reply_mode_opt () = Env_setting.String_opt_knob.get Imessage_reply_mode

let self_chat_guid_opt () =
  Env_setting.String_opt_knob.get Imessage_self_chat_guid
;;

let poll_interval_sec_opt () =
  Env_setting.String_opt_knob.get Imessage_poll_interval_sec
;;

let cursor_path_opt () = Env_setting.String_opt_knob.get Imessage_cursor_path
