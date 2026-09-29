(** The Config > runtime.toml form that declares one more account of a
    Claude Code, Codex, Antigravity or Muse provider the file already declares.

    It holds three fields: which provider to copy, the new provider id, and
    where the new account signs in. The file it was opened on only supplies
    the providers to choose from and the suggested id. The declaration is
    made by {!declare_on} against the file as the server holds it when the
    operator submits, so a change made while the form stood open is kept.
    Saving goes through the pane's own preview and save. Signing in is not
    done here; the form shows how to do it, and after a save it stays open on
    the sign-in command until the operator copies it or closes it. *)

type field =
  | Base
  | Id
  | Location

type t

val open_on : ?home_dir:string -> string -> (t, string) result
(** [Error] says why there is nothing to copy: the text does not parse, or it
    declares no Claude Code, Codex, Antigravity or Muse provider. [home_dir]
    expands a location typed with [~/]. *)

val field : t -> field

type outcome =
  | Editing of t
  | Cancelled
  | Submitted of t
      (** Enter on the last field: declare it with {!declare_on}. *)
  | Copy of t * string
      (** [y] on a saved form: the sign-in command, whole, for the
          clipboard. The form stays open. *)

val key : t -> string -> outcome
(** One decoded key. Printable text goes to the focused text field. On
    [Base], [left] and [right] choose another provider, and the suggested id
    follows unless the id was typed. [up] and [down] or [tab] move between
    fields; Enter moves on and, on the last field, submits. Esc abandons.
    A saved form types nothing: [y] copies its command, Enter or Esc
    closes it, and every other key is ignored. *)

val inherited_home : Runtime_account_declaration.client -> string option
(** The home a Claude Code, Codex or Muse provider without [account-home] runs
    on, read from this process's environment the way the runtime reads it. *)

type sign_in

val command : sign_in -> string
(** One shell command, [(export VAR=home && client)]: the client runs on
    the new home in a subshell. *)

val then_type : sign_in -> string option
(** What to type inside the client once it runs: [/login] for Claude Code;
    none for Codex, whose command logs in itself. *)

type declared =
  { id : string
  ; text : string  (** The current runtime.toml with the new provider. *)
  ; sign_in : sign_in option
      (** How to sign the new account in; none for Antigravity, whose OAuth
          file already exists. *)
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

val saved : t -> id:string -> sign_in -> t
(** The form after the server saved [id]: it shows [sign_in] in place of
    the fields until it is closed. *)

val is_saved : t -> bool

val paste : t -> string -> t
(** Pasted text into the focused text field, without its control
    characters. [Base] takes none. *)

val rows : width:int -> t -> string list
(** The form as rows of a pane [width] cells wide. Names read from the file
    are drawn on one line. The heading, the hints and a refusal wrap to
    [width]: at spaces, under their own indentation, and inside a word only
    where the word alone is wider than a row. The sign-in command is one row
    when it fits and otherwise breaks only after its [&&], where each row
    alone is a syntax error and the two pasted together are the command; a
    first half wider than the pane is cut by the pane rather than broken
    elsewhere. Each field keeps one row, so the label column holds. A saved
    form draws the saved id and the sign-in hints, without the fields. The
    keys it reads are the footer's, not a row; the pane adds the saved
    form's keys under it, where no notice can crowd them out. *)
