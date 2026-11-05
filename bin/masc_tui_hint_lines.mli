(** Key hints in an info pane: [Enter: open], [d: full detail].

    A hint is a key and what it does. Rows are packed from whole hints, so a key
    never ends one row while its words begin the next. *)

type item =
  { key : string  (** What the operator presses, as the footer spells it. *)
  ; label : string  (** What it does. *)
  }

val wrap : max_cells:int -> item list -> string list
(** Pack [items] into rows, in the order given, the way
    {!Masc_tui_message_layout.pack_clauses} packs clauses: a row holds whole
    hints joined by {!Masc_tui_message_layout.clause_separator}, takes the next
    hint while the row stays within [max_cells] display cells, and otherwise
    ends there.

    A hint wider than [max_cells] by itself is wrapped at spaces by
    {!Masc_tui_message_layout.wrap_words}, and the hint after it continues on
    its last row when it fits. A budget below one counts as one. No hints give
    no rows. *)
