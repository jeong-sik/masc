(** The rows the help overlay draws, and the height it draws them in.

    The overlay folds its lines into two columns once the terminal is wide
    enough, so what it draws is fewer rows than it was written as. The key
    handler bounded the scroll with the line count and no height at all, and
    the drawing clamped the result on the way past -- the shape
    {!Masc_tui_scroll} was written to end. On a wide terminal the sheet
    stopped at its last row while the state counted on to twice that, so
    scrolling back up paid off the surplus one press at a time before the
    reader saw anything move.

    Both sides ask this module now, so they answer with the same number. *)

val line_cells : cols:int -> int
(** The cells one sheet line has at this width: the frame's inner width while
    the sheet is one column, a column's width once it is two. Lines wider than
    this are cut where they are drawn, so the lines are wrapped to it first. *)

val two_column_minimum_cols : int
(** The terminal width where [sheet] folds to two columns; the frame folds
    at the same width so its height answer matches what it draws. *)

val column_width : cols:int -> int
(** The cells one column of the folded sheet has. The feature sheet folds to
    the same columns and draws its lines at the same width, so a reader sees
    one layout on both sheets. *)

val sheet : ?header:string list -> cols:int -> string list -> string list
(** The rows drawn at this width: optional full-width header rows, followed by
    the lines as written, or -- once a terminal is wide enough to hold two
    columns -- the sections between blank lines set side by side two at a
    time, each whole, with a blank row between pairs. *)

val filter_sections :
  query:string ->
  heading:(string -> string) ->
  (string * (string * string) list) list ->
  (string * (string * string) list) list
(** The sections a typed query leaves, as (title, (key, action) entries). An
    entry stays when its key or its action holds [query], ignoring case. A
    section whose [heading title] holds [query] stays whole, and a section left
    with no entry goes. [heading] is the part of a title a reader would type: a
    title that carries a mark beside its name gives the name back, so the mark
    does not answer a query. An empty [query] leaves every section as it was. *)
