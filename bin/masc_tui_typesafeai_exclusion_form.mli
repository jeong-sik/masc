(** The Config > runtime.toml form for [\[typesafeai\] excluded_keepers]: which
    Keepers the [typesafeai] gates never ask a System One destination about.
    It sets that one key and nothing else.

    What the file says now is read with [Runtime_toml], the reader the server
    loads the file with, so the form and the server cannot disagree about which
    Keepers a list excludes.

    The form does not save. {!text_on} gives the file's text after the choice,
    and the pane hands that text to the same preview and save a hand edit of
    runtime.toml goes through. The server reads the saved table at once. *)

(** Whether a Keeper is running, as far as the TUI knows. The form only marks
    a stopped one. *)
type presence =
  | Running
  | Stopped
  | Unknown

type roster_entry =
  { name : string
  ; presence : presence
  }

type t

val open_on : ?source_revision:string -> keepers:roster_entry list -> string -> (t, string) result
(** The form on runtime.toml [text]. [keepers] are the Keepers the TUI knows,
    drawn in name order; names the file excludes that are not among them stay
    in the list after them, marked, so a name that excludes nobody can be
    dropped. [Error] says why there is nothing to edit: the file does not
    parse as a runtime configuration. *)

val source_revision : t -> string option
(** The revision the form was opened on. Editing a draft never advances it;
    the pane compares it with the file it would write over, and asks for a
    fresh form when they differ. *)

type outcome =
  | Editing of t
  | Cancelled
  | Submitted of t
      (** Enter: take the choice with {!text_on}. *)

val key : t -> string -> outcome
(** One decoded key. [up] and [down] (or [k] and [j], [shift-tab] and [tab])
    move between the Keeper rows, and Space picks or drops the Keeper under
    the cursor. Enter submits and Esc abandons. Every other key leaves the
    form as it is. *)

val refused : t -> string -> t
(** The form kept open with a reason the pane gives for not saving it. *)

(** What saving would do to the list the file holds. *)
type detail =
  { added : string list  (** Picked now and not in the file's list. *)
  ; dropped : string list  (** In the file's list and not picked now. *)
  }

type change =
  | Unchanged  (** The choice excludes the Keepers the file already excludes; saving writes nothing. *)
  | Changed of detail

val change : t -> change
(** The decision {!text_on} makes about the choice, without writing. A list
    that names the same Keepers in another order is {!Unchanged}. *)

val text_on : t -> (string, t) result
(** The text the form was opened on, with the choice written into
    [\[typesafeai\]]. Every line outside [excluded_keepers] stays as it was.

    The text is unchanged when {!change} is {!Unchanged}. A list that does
    change is written whole, one name per line, and the comments inside it
    go. Nobody picked removes the key, which excludes nobody, as a file
    without it does. A file with no [\[typesafeai\]] table gets one.

    The edited text is read back with the server's reader. [Error] is the form
    with the reason on it: a [\[typesafeai\]] written in a shape the line
    editor cannot change, or an edit the reader refuses. *)

val rows : width:int -> height:int -> t -> string list
(** The form as rows of a pane [width] cells wide: what exclusion keeps from
    which destinations, the Keeper list, what saving would do, and that the
    Board attention judgment still runs on the exact lane for an excluded
    Keeper. The Keeper list gets the rows left under [height] after the
    others, and a list longer than that is cut to a window that follows the
    cursor, with a row saying how many are above and below. *)
