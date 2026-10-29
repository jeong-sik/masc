(** The Config > runtime.toml form for memory recall: whether the recall
    judgment asks Jev about a Keeper's stored facts, and for which Keepers.

    It sets three keys of [\[typesafeai\]] -- [memory_recall],
    [memory_recall_scope] and [memory_recall_keepers] -- and nothing else.
    What the file says now is read with [Runtime_toml], the reader the server
    loads the file with, so the form and the server cannot disagree about what
    a combination of the three keys means.

    The form does not save. {!text_on} gives the file's text after the choice,
    and the pane hands that text to the same preview and save a hand edit of
    runtime.toml goes through. The server reads the saved table at once, so
    recall changes from the next model request on. *)

type mode =
  | Off  (** [memory_recall = false]: nobody is asked. *)
  | Listed  (** Only the Keepers picked in the list. *)
  | All  (** Every Keeper that [excluded_keepers] does not name. *)

(** Whether a Keeper is running, as far as the TUI knows. The form only
    marks a stopped one: a Keeper that is not running is not judged, and
    picking it does nothing until it runs. *)
type presence =
  | Running
  | Stopped
  | Unknown

type roster_entry =
  { name : string
  ; presence : presence
  }

(** What the server says about the recall gate now, drawn beside the choice.
    It is display only: it changes neither what the form writes nor what
    {!change} says. It is the server's gate as loaded, so a file edited on
    disk and not loaded shows as a picked Keeper the server does not reach. *)
type server =
  | Server_unread  (** Asked, not answered yet. *)
  | Server_unavailable of string
      (** The answer could not be read; the reason, as the loader worded it. *)
  | Server_read of Masc.Tui_decode_memory_recall.memory_recall_reading

type t

val open_on : ?source_revision:string -> keepers:roster_entry list -> string -> (t, string) result
(** The form on runtime.toml [text]. [keepers] are the Keepers the TUI knows;
    names the file lists that are not among them stay in the list, marked.
    A file that switched recall off by hand keeps its list of Keepers, and
    the form starts with that list picked, so switching recall back on
    restores it. [Error] says why there is nothing to edit: the file does not
    parse as a runtime configuration. *)

val with_server : t -> server -> t
(** The form with the server's answer. The pane gives it when the answer
    arrives, for the form it was asked for. *)

val server : t -> server
(** What the form holds of the server's answer. *)

val stop_waiting : t -> string -> t
(** A form still waiting for the server's answer stops waiting and says
    why ([Server_unavailable]); one that has an answer, or has already
    given up, is unchanged. The pane calls it when the answer cannot
    come: the reply would be retired. *)

(** What the Keeper list says of one Keeper beside the server's reading. *)
type mark =
  | No_mark  (** Nothing: no answer, or a Keeper that is neither picked nor admitted. *)
  | Reached  (** The gate admits the Keeper. It does not say the Keeper runs. *)
  | Not_reached of Masc.Keeper_memory_recall_standing.reason
      (** Picked, and the gate does not admit it. *)
  | No_declaration
      (** Picked, and the server's reading does not list it: the server has no
          declaration file under that name. *)

val mark : t -> string -> mark
(** The mark of the Keeper by that name. *)

val mark_text : mark -> string
(** The words the list draws for a mark; empty for {!No_mark}. *)

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
(** One decoded key. [up] and [down] (or [k] and [j]) move between the range
    row and the Keeper rows. On the range row [left] and [right] choose
    another range and Space chooses the next one. The Keeper rows exist only
    in {!Listed}; Space on one picks or drops that Keeper. Enter submits and
    Esc abandons. *)

val refused : t -> string -> t
(** The form kept open with a reason the pane gives for not saving it. *)

(** What saving would do to the file, from the file as it was opened. *)
type detail =
  { before : mode  (** What the file says now. *)
  ; after : mode
  ; added : string list
        (** Picked now and not in the list the file holds. Empty unless [after] is {!Listed}. *)
  ; dropped : string list
        (** In the list the file holds and not picked now. Empty unless [after] is {!Listed}. *)
  ; list_kept : int
        (** How many Keepers a list the file holds stays at, when [after] is {!Off}. *)
  ; list_removed : int
        (** How many Keepers a list the file holds go, when [after] is {!All}: the file
            refuses a list next to scope "all". *)
  }

type change =
  | Unchanged  (** The choice is what the file already says; saving writes nothing. *)
  | Nobody_picked  (** {!Listed} with nobody picked; saving is refused. *)
  | Changed of detail

val change : t -> change
(** The decision {!text_on} makes about the choice, without writing. A list
    that names the same Keepers in another order is {!Unchanged}. It does not
    try the write: for a [\[typesafeai\]] the line editor cannot change,
    {!text_on} still refuses a choice this calls {!Changed}. *)

val text_on : t -> (string, t) result
(** The text the form was opened on, with the form's choice written into
    [\[typesafeai\]]. Every line outside the three keys stays as it was.

    The text is unchanged when {!change} is {!Unchanged}. A key that already
    holds what the choice needs is not rewritten, because a rewrite drops the
    comment on its line; switching recall back on over the list a switched-off
    file kept writes the switch alone. A list that does change is written
    whole, and the comments inside it go. A key the file does not have yet is
    added at the end of the table's lines, after a comment that sits above
    the next table's header ([Toml_line_editor] puts every new key there).

    Switching off writes only [memory_recall = false], so a Keeper list the
    file keeps stays there for the next time recall is switched on. {!All}
    writes [memory_recall_scope = "all"] and drops the list, which the file
    refuses next to it.

    [Error] is the form with the reason on it: {!Listed} with nobody picked,
    or a [\[typesafeai\]] written in a shape the line editor cannot change
    (the edited text is read back, and anything but the chosen value is
    refused rather than written). The read-back compares lists as sets of
    Keepers, like {!change}: a list the file keeps in another order, or with a
    name twice, is the chosen list. *)

val rows : width:int -> height:int -> t -> string list
(** The form as rows of a pane [width] cells wide. The Keeper list gets the
    rows left under [height] after the others, and a list longer than that is
    cut to a window that follows the cursor, with a row saying how many are
    above and below. At least one Keeper row is always drawn. *)
