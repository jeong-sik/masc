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

type drop =
  | Attach of Masc_tui_keeper_chat_projection.attachment
      (** An image. Staging it is what the drop meant. *)
  | Keep_path
      (** Not an image. The operator dropped a file to name it, so the path is
          the point and belongs in the draft. *)
  | Refuse of error
      (** An image that cannot be staged -- too large, unreadable, empty.
          Answering with its path instead would leave no sign that the image
          was refused. *)

val classify_drop : path:string -> drop
(** What a dropped file should become. Separated from the input loop so the
    three-way choice can be read and tested without a terminal. *)
