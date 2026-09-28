(** The Config > runtime.toml form that declares one more account of a
    Claude Code, Codex or Antigravity provider the file already declares.

    It holds the text it was opened on and three fields: which provider to
    copy, the new provider id, and where the new account signs in.
    {!Runtime_account_declaration} writes the provider; saving goes through
    the pane's own preview and save, the path [e] already uses. Signing in is
    not done here. The form shows the command that does it. *)

type field =
  | Base
  | Id
  | Location

type t

val open_on : string -> (t, string) result
(** [Error] says why there is nothing to copy: the text does not parse, or it
    declares no Claude Code, Codex or Antigravity provider. *)

val field : t -> field

type outcome =
  | Editing of t
  | Cancelled
  | Declared of
      { id : string
      ; text : string  (** The whole runtime.toml with the new provider. *)
      ; sign_in : string
      }

val inherited_home : Runtime_account_declaration.client -> string option
(** The home a Claude Code or Codex provider without [account-home] runs on,
    read from this process's environment the way the runtime reads it. *)

val key :
  ?home_dir:string ->
  inherited_home:(Runtime_account_declaration.client -> string option) ->
  t -> string -> outcome
(** One decoded key. Printable text goes to the focused text field. On
    [Base], [left] and [right] choose another provider, and the suggested id
    follows unless the id was typed. [up] and [down] or [tab] move between
    fields; Enter moves on and, on the last field, declares. A refused
    declaration stays [Editing], shows the reason and focuses the field it is
    about. Esc abandons. *)

val refused : t -> string -> t
(** The form kept open with a reason the server gave for not saving. *)

val paste : t -> string -> t
(** Pasted text into the focused text field, without its control
    characters. [Base] takes none. *)

val rows : t -> string list
(** The form as pane rows. Names read from the file are drawn on one line. *)
