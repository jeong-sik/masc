(** The framed box's geometry: one border, and the numbers that describe it.

    Every helper that draws the box and every caller that lays a row out before
    handing it over has to agree on the same measurements. They did not agree
    by sharing a number; they agreed by each spelling one out. [cols - 4]
    appeared fifteen times, [cols - 2] four, [rows - 5] ten more, across three
    modules that could not see each other's copy.

    The agenda panel is what made the case. Its rows were measured against the
    terminal's width and then cut on the way through the frame, which fits them
    to the inner width -- the number it had to match was four lines away in
    another module, unnamed. *)

(** A row is drawn as border, pad, content, pad, border, and it spans the
    terminal. The two cells of border and two of padding are not exported:
    nothing outside needs to count them, and a caller that wants the content's
    width should ask {!inner_width} rather than assemble it. *)

val chrome_rows : int
(** Top border, title, divider, bottom border, footer: the rows a framed panel
    spends on itself whatever its content holds. *)

val rule_width : cols:int -> int
(** Cells a horizontal rule fills between two corner glyphs. *)

val inner_width : cols:int -> int
(** Cells a row's content gets. Measure against this before handing a row to
    the frame, or the frame cuts what it did not know it had to fit. *)

val content_height : rows:int -> int
(** Rows a framed panel's content gets. [max 1] rather than [max 0]: a panel
    drawn at all draws something. A caller that would rather show nothing than
    one crowded row subtracts {!chrome_rows} itself and says so. *)
