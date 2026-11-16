(** What the wide pane beside a list says while nothing is open in it.

    Code and Resources draw a list in a narrow pane and what is open in the
    wide pane beside it. With nothing open, the wide pane said the same thing
    whatever the list held: Code offered "(Enter opens the selected file)"
    beside a listing that had failed and held nothing to select, and
    Resources drew blank rows. The reason a read failed was drawn only in the
    narrow pane, cut to its width, and the cut tail was the cause.

    Both surfaces choose here from the list's reading, so each answers for
    every state of it, and a reason reaches the pane wide enough to hold it
    whole. *)

type t =
  | List_unread  (** Nothing has asked for the list. *)
  | List_loading  (** Asked, with no answer and nothing read before it. *)
  | List_failed of string
      (** Nothing was read, and this is why, whole. *)
  | List_empty of string option
      (** Read, with nothing to select. [Some reason] when the list says a
          failure beside what it read. *)
  | Rows_ready of string option
      (** Read, with rows to select: the one state with something to open.
          [Some reason] as for {!List_empty}. *)

val of_listing : ('a list, string) Masc_tui_fetched.observation -> t
(** A list read as one fetched source, as Code reads a directory. A refresh
    that failed after a reading keeps that reading's rows and carries the
    refresh's failure as the reason. *)

val of_inventory : rows:'a list option -> reason:string option -> reading:bool -> t
(** A list held as its rows, the reason it states beside them, and whether a
    read of it is pending, as Resources holds its inventory. [rows] is what
    the list draws. With no rows a reason is the failure; with neither,
    [reading] tells a pending read from a list nothing has asked for. *)
