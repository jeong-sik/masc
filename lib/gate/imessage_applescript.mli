(** Imessage_applescript -- send a reply through Messages.app.

    iMessage has no REST API. The one supported way to send is AppleScript
    against Messages.app, which means [osascript] and an Automation grant.

    The script takes the chat id and the body as [on run argv] arguments, so
    both arrive as native AppleScript text rather than being spliced into the
    source. A message body containing quotes, newlines or AppleScript syntax
    is therefore data, never code. {!send_argv} is pure so that property is
    tested without a Mac. *)

type error =
  | Missing_chat_guid
      (** No chat to address. The connector declines rather than guessing one. *)
  | Osascript_failed of { exit_code : int; stderr : string }
  | Osascript_timed_out of float

val error_to_string : error -> string

val script : string
(** The AppleScript source. Constant — the varying parts are arguments. *)

val send_argv : chat_guid:string -> text:string -> string list
(** The exact argv handed to [Eio.Process]. Pure. *)

val send :
  ?timeout_sec:float -> chat_guid:string -> text:string -> unit -> (unit, error) result
(** Send [text] to the Messages.app chat identified by [chat_guid]. *)
