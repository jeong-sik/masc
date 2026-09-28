(** The Config > runtime.toml form that declares one more account of a
    Claude Code, Codex or Antigravity provider the file already declares.

    It holds three fields: which provider to copy, the new provider id, and
    where the new account signs in. The file it was opened on only supplies
    the providers to choose from and the suggested id. The declaration is
    made by {!declare_on} against the file as the server holds it when the
    operator submits, so a change made while the form stood open is kept.
    Saving goes through the pane's own preview and save. Signing in is not
    done here; the form shows the command that does it. *)

type field =
  | Base
  | Id
  | Location

type t

val open_on : ?home_dir:string -> string -> (t, string) result
(** [Error] says why there is nothing to copy: the text does not parse, or it
    declares no Claude Code, Codex or Antigravity provider. [home_dir]
    expands a location typed with [~/]. *)

val field : t -> field

type outcome =
  | Editing of t
  | Cancelled
  | Submitted of t
      (** Enter on the last field: declare it with {!declare_on}. *)

val key : t -> string -> outcome
(** One decoded key. Printable text goes to the focused text field. On
    [Base], [left] and [right] choose another provider, and the suggested id
    follows unless the id was typed. [up] and [down] or [tab] move between
    fields; Enter moves on and, on the last field, submits. Esc abandons. *)

val inherited_home : Runtime_account_declaration.client -> string option
(** The home a Claude Code or Codex provider without [account-home] runs on,
    read from this process's environment the way the runtime reads it. *)

type declared =
  { id : string
  ; text : string  (** The current runtime.toml with the new provider. *)
  ; sign_in : string option
      (** The shell command that signs the new account in; none for
          Antigravity, whose OAuth file already exists. *)
  }

val declare_on :
  inherited_home:(Runtime_account_declaration.client -> string option) ->
  t -> string -> (declared, t) result
(** Declares the form's account against [current], the file as it is now.
    A refusal comes back as the form with the reason on it and the cursor on
    the field it is about -- including a chosen provider that is no longer
    in the file. *)

val refused : t -> string -> t
(** The form kept open with a reason the server gave for not saving. *)

val paste : t -> string -> t
(** Pasted text into the focused text field, without its control
    characters. [Base] takes none. *)

val rows : t -> string list
(** The form as pane rows. Names read from the file are drawn on one line.
    The keys it reads are the footer's, not a row. *)
