(** Where a mouse press lands on the frame the terminal is showing.

    A renderer builds strings, not positioned cells. Its rows are joined,
    padded, cut and shifted by several helpers before they reach the terminal,
    so a column counted while drawing is a column some later helper can move.
    Instead a renderer wraps the text a press should act on with {!mark}, and
    {!extract} reads where that text ended up once the frame's rows are final.

    A mark is a pair of zero-width CSI sequences ending in [m]. Every width
    measure, cut and SGR stripper in the TUI already treats a CSI ending in
    [m] as a style that spends no cells, so the marks travel with the text
    they wrap without any of those helpers knowing about them. {!extract}
    removes them before the rows are presented; the terminal never sees one.

    The same approach is how bubblezone finds zones in Bubble Tea output. *)

type 'target registry
(** The targets marked while one frame is drawn, numbered in marking order.
    The number is all a mark carries; the target stays here. *)

val registry : unit -> 'target registry
(** A registry with its own pair of mark codes. Marks of two registries can
    wrap the same text; each {!extract} reads and removes only its own and
    leaves the other's in place, still zero-width. *)

val reset : 'target registry -> unit
(** Forget every target. Call before drawing a frame, so a mark's number
    names a target from that frame only. *)

val mark : 'target registry -> 'target -> string -> string
(** [mark registry target text] is [text] wrapped so that a press on any
    cell it occupies in the final frame resolves to [target]. Wrap text that
    is already sanitised: a sanitiser that removes escapes would leave the
    marks' parameter bytes behind as visible characters. *)

type 'target zones
(** Where each marked text landed in one frame. Immutable, so the frame the
    terminal accepted can keep answering presses after the next frame is
    drawn. *)

val no_zones : 'target zones

val extract : 'target registry -> string list -> string list * 'target zones
(** [extract registry lines] is [lines] with every mark removed, and the
    cells the marked texts occupy. Line [i] of the list is terminal row
    [i + 1]; columns are the terminal's 1-based cells.

    Marks do not nest. A mark that opens while another is open closes the
    open one at that cell. A mark whose close was cut off with the end of its
    row runs to the row's last cell. A mark that covers no cell records
    nothing. *)

val target_at : 'target zones -> row:int -> column:int -> 'target option
(** The target under the 1-based terminal cell a mouse report names. *)

val to_list : 'target zones -> (int * int * int * 'target) list
(** Every zone as [(row, first_column, last_column, target)], in the order
    the rows were read. *)
