(** Read an image file from disk into a keeper-chat attachment.

    The TUI composer stages images with [:attach <path>] and sends them with the
    next message. Everything a bad path can be wrong about is decided here,
    before the request is built, so the operator learns which file failed and
    why instead of reading a rejection from the endpoint. *)

type error =
  | Unreadable of { path : string; detail : string }
  | Empty of { path : string }
  | Too_large of { path : string; size : int; max : int }
  | Unsupported of { path : string; detail : string }

val max_bytes : int
(** Largest image accepted, matching the dashboard composer's cap so the same
    file is attachable from either surface. *)

val of_file
  :  path:string
  -> (Masc_tui_keeper_chat_projection.attachment, error) result
(** Read [path], identify its media type from the leading bytes, and encode it.
    The media type comes from the bytes, never the file extension: a renamed
    file would otherwise be announced to the endpoint as something it is not. *)

val error_to_string : error -> string
(** One line naming the file and what was wrong with it. *)
