(** The lines one edit removed and added.

    A keeper's [Edit] is recorded as the exact text it replaced and the exact
    text it wrote, so what an operator wants to see is the difference between
    those two, line by line. That is what this produces.

    {1 What it is not}

    Not a general diff. Both sides come from one tool call, so they are the
    two halves of a single replacement rather than two revisions of a file --
    there is no rename to follow, no context to fetch, and no hunk to
    assemble. The common prefix and suffix are shared lines and everything
    between them changed; that is the whole shape.

    Not a minimal edit script either. A Myers diff would find fewer changed
    lines inside the middle, and for a replacement whose middle is usually a
    handful of lines it would spend that work to move a row or two. If a
    middle ever grows large enough for the difference to show, this is where
    a real algorithm goes. *)

type row =
  | Context of string  (** Unchanged, and in both halves. *)
  | Removed of string
  | Added of string

val rows : before:string -> after:string -> row list
(** The two halves as one sequence, removals before additions in the middle.

    A trailing newline does not make an empty last line: text ending in one is
    the same lines as text without it, and treating them differently would
    show a change nobody made. *)

val counts : row list -> int * int
(** Removed and added line counts, for a caller that wants to say how large a
    change is before drawing it. *)

val preview : context:int -> max_rows:int -> row list -> row list * int
(** [preview ~context ~max_rows rows] keeps at most [context] unchanged lines
    on either side of the changed middle and never returns more than
    [max_rows] rows. Changed rows take the budget before context; if the
    changed middle alone is longer, its leading [max_rows] rows are kept.

    The second result is the exact number of omitted rows from [rows]. A
    caller must draw that count rather than letting a bounded preview read as
    the whole recorded change. Non-positive limits return no rows. *)

val line_number_cell : int option -> string
(** One line-number column, five cells wide.

    Absence is spelled rather than left blank: an added line has no number on
    the old side, and a blank there reads as an alignment slip while a zero
    reads as line zero. Both are claims the row does not make. *)

type numbered = {
  nrow : row;
  old_line : int option;
  new_line : int option;
}
(** A row with the file coordinates it carries. [Context] advances both files;
    [Removed] advances only the old one; [Added] only the new one. [None] is
    the side the row is not on, rendered by {!line_number_cell} as a dash. *)

val number : old_start:int -> new_start:int option -> row list -> numbered list
(** File coordinates for each row, counting from the occurrence the producer
    recorded. [new_start = None] is a deletion: every row's [new_line] is
    [None]. Callers pass producer starts (at least one); out-of-range starts
    are counted from as given rather than clamped, so bad coordinates stay
    visible instead of silently becoming line one. *)

val preview_numbered :
  context:int -> max_rows:int -> numbered list -> numbered list * int
(** [preview] for rows that already carry coordinates: the same window —
    the changed middle first, then neighbouring context — so a numbered
    preview shows the same rows [preview] would, with their numbers. Takes
    numbered rows rather than renumbering a window because the coordinates
    count from the change's first row, and a window does not say how many
    rows precede it. *)

val numbered_gutter_cells : int
(** Display cells of {!numbered_gutter}: two {!line_number_cell} columns, the
    diff marker, and their three separating spaces. *)

val numbered_gutter :
  old_line:int option -> new_line:int option -> marker:char -> string
(** [old new marker], the same gutter the Changes tree diff draws, as plain
    text for a ["```diff"] fence the lexer reads back: the marker sits at a
    fixed offset so the fence colours the row, and the two cells name the file
    coordinates the marker alone cannot. [marker] is the row's own [' '],
    ['-'], or ['+']. A six-digit line overflows its five-cell column the way
    {!line_number_cell} does, and the marker then sits one cell right of where
    the lexer looks — the row keeps its marker in text but loses its colour,
    which is visible rather than wrong. *)
