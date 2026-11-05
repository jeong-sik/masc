(** Key hints in an info pane: [Enter: open], [d: full detail].

    A hint line used to be one string, ["Enter: open · d: full detail"], and
    wrapped at spaces like prose. When the row ran out at a space between a
    key and its words, the key stayed at the end of one row and its words began
    the next. A hint is a value here, and rows are packed from whole hints. *)

type item =
  { key : string  (** What the operator presses, as the footer spells it. *)
  ; label : string  (** What it does. *)
  }

val separator : string
(** The text between two hints on one row. *)

val wrap : max_cells:int -> item list -> string list
(** Pack [items] into rows, in the order given. A row holds whole hints joined
    by {!separator}, takes the next hint while the row stays within [max_cells]
    display cells, and otherwise ends there.

    A hint wider than [max_cells] by itself is wrapped at spaces by
    {!Masc_tui_message_layout.wrap_words} into rows of its own, and the hints
    on either side start new rows. A budget below one counts as one. No hints
    give no rows. *)
