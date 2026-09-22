(** Column widths for the standalone lane table.

    Every column but two has a width the screen sets. The lane's name and its
    slot list are sized from the rows, and the observed histogram takes what is
    left, so a narrow frame drops a column instead of handing the line's own
    cut a value to eat. *)

type reading = {
  label : string;
  slots : string;
}
(** What one lane contributes to the measurement: the name it is called by and
    its slot list, both already fit for a terminal line -- a reading measured
    with an escape or a newline in it would place every column after it
    somewhere the row does not draw. *)

type columns = private {
  label_cells : int;
  slots_cells : int;
  observed_cells : int;
}
(** The measured widths, [0] where the column has no room and is left out.
    Private so the widths are the ones {!columns} derived from a frame and a
    set of readings, never a pair of numbers assembled at the call site. *)

val status_cells : int
val ok_fail_cancel_cells : int
val p50_cells : int
val active_cells : int
val runs_cells : int
(** The fixed columns, in cells. A row lays its own readings out on these, so
    it sits under the header rather than beside it. *)

val fixed_cells : label_cells:int -> int
(** Cells a row spends before its two measured columns: every fixed column, the
    mark's field, the name at the given width, and the gap between each. It
    ends at p50, so a measured column pays for the gap that brings it. What is
    left of the frame is what {!columns} has to divide. *)

val pad_left : string -> int -> string
(** [pad_left text cells] is [text] right-aligned in [cells], cut to fit when
    it is wider. The count columns sit this way, header and row alike. *)

val columns : inner:int -> reading list -> columns
(** [columns ~inner readings] measures the table for a frame [inner] cells
    wide.

    The name column is the widest name, floored at its own header and capped so
    one long name cannot take the row.

    The other two are decided together. While the observed histogram has room
    for a runtime id and a count, it is drawn and the slot list is held to a
    cap so it cannot take the histogram's cells. When it does not, the slot
    list has the rest of the row to itself and takes what it needs of it, down
    to a floor that still names a runtime; under that floor it leaves too and
    the block below the table is where both are read. *)

val tail : columns -> slots:string -> observed:string -> string
(** [tail columns ~slots ~observed] is the two measured columns as a row ends
    them, the gap before each included and the dropped ones absent. *)

val header : columns -> int -> string
(** [header columns width] is the column names, laid out on the same widths the
    rows use. *)
