(** Turn image bytes into a keeper-chat attachment.

    The TUI composer stages images from a path ([:attach <path>], a dropped
    file) and from the system clipboard, and sends them with the next message.
    Everything an image can be wrong about is decided here, before the request
    is built, so the operator learns which one failed and why instead of
    reading a rejection from the endpoint.

    One set of rules for both origins: a clipboard image too large to attach is
    refused on the same terms as a file too large to attach. *)

(* [source] is what the operator would recognise -- a path for a file, a
   generated name for clipboard bytes. It is not always a path, so it is not
   called one: a reader who opened it as a file would find nothing. *)
type error =
  | Unreadable of { source : string; detail : string }
  | Empty of { source : string }
  | Too_large of { source : string; size : int; max : int }
  | Unsupported of { source : string; detail : string }

val max_bytes : int
(** Largest image accepted, matching the dashboard composer's cap so the same
    file is attachable from either surface. *)

val of_file
  :  path:string
  -> (Masc_tui_keeper_chat_projection.attachment, error) result
(** Read [path], identify its media type from the leading bytes, and encode it.
    The media type comes from the bytes, never the file extension: a renamed
    file would otherwise be announced to the endpoint as something it is not. *)

val of_bytes
  :  name:string
  -> string
  -> (Masc_tui_keeper_chat_projection.attachment, error) result
(** Same decisions as {!of_file} on bytes that never had a path -- what the
    clipboard hands over. [name] is what the operator and the endpoint see;
    the media type still comes from the bytes. *)

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
