
(** Bars and band headers for the Context inspector.

    Its own library so the arithmetic and the shapes run under a test without a
    TTY, the same reason {!Masc_tui_server_lifecycle} is split out. It draws
    with the static SGR codes and box characters from {!Masc_tui_theme};
    palette-resolved colours belong to the caller and arrive as arguments.

    The Context screen carries three measurements of one turn: the bytes a
    provider accepted, how far back over the conversation the turn reached, and
    how that turn's content divides by kind. None is a breakdown of another.
    The band headers exist to say so, because stacked without them the screen
    reads as one nested report, and then the largest share reads as the volume
    shipped on every turn. *)

val fill_cells : width:int -> numerator:int -> denominator:int -> int
(** [fill_cells ~width ~numerator ~denominator] is the filled length of a
    single-ratio bar, floored, and clamped into \[0, [width]\].

    A positive [numerator] returns at least one cell. Flooring alone draws an
    empty bar for a small-but-real share, and an empty bar states that nothing
    was sent, which is a different claim from "too little to plot". The history
    bar reports 61 atoms out of 3,337, so this is the ordinary case rather than
    an edge one.

    Returns 0 when [width], [numerator], or [denominator] is not positive.
    Returns [width] once [numerator] reaches [denominator]. *)

val apportion : width:int -> weights:int list -> int list
(** [apportion ~width ~weights] splits [width] cells across [weights] by
    largest remainder, so the result sums to exactly [width] whenever the
    weights sum above zero. Negative weights count as zero. Ties go to the
    earlier weight, which keeps the split a function of the weights alone.

    Unlike {!fill_cells} a small weight can receive no cells: the segments
    share one fixed row, so a guaranteed minimum would have to take a cell from
    a larger neighbour and overstate the small share instead. The table under
    the bar carries every component's own percentage, so a component that plots
    as nothing is still legible there.

    Returns all zeros when [width] is not positive or the weights sum to zero.
    The result always has the same length as [weights]. *)

val segment_glyph : int -> string
(** [segment_glyph index] is the shade for the [index]th segment of a stacked
    bar, cycling full, dark, medium, light. Shade as well as colour, so the
    segments stay apart in a terminal that reports no colour support. The cycle
    repeats past the fourth segment; by then the shares are small and the row
    order still pairs a segment with its line. *)

val band : width:int -> title:string -> caption:string -> string
(** [band ~width ~title ~caption] is a rule of exactly [width] cells carrying
    [title] at the left and [caption] at the right, with no leading indent.
    [title] and [caption] are expected to be ASCII. A width too small for both
    drops the caption and keeps the title; a width too small for the title
    alone leaves a plain rule. The row is exactly [width] cells in all three
    cases, so the frame never has to cut it. *)

val wrap : width:int -> string -> string list
(** [wrap ~width text] breaks ASCII [text] on spaces into lines of at most
    [width] cells. Used for the rows under a bar, which say what the number
    above them means and so are the worst thing on the screen to lose to a
    truncated row.

    A run of spaces inside a line is kept at its original length, because the
    screen separates figures with a wide "  " dot and a folded row that
    narrowed it would read as a different kind of row. A single word longer
    than [width] takes its own line and overruns. Never returns the empty
    list. *)

val ratio_bar : width:int -> numerator:int -> denominator:int -> string
(** [ratio_bar ~width ~numerator ~denominator] fills from the left, because the
    question it answers is how much of a declared ceiling is gone. Exactly
    [width] cells. *)

val reach_bar :
  width:int -> transmitted:int -> total:int -> sent_style:string -> string
(** [reach_bar ~width ~transmitted ~total ~sent_style] fills from the right:
    the transmitted atoms are the newest ones, and drawing them at the left
    would put the omitted history in the future. Exactly [width] cells, with
    [sent_style] applied to the filled run. *)

val reach_pointer : width:int -> transmitted:int -> total:int -> string
(** [reach_pointer ~width ~transmitted ~total] labels the cut in the bar that
    {!reach_bar} draws for the same three arguments. The flag hangs to the left
    of the cut and ends on it, which is the usual shape because the sent run is
    a cell or two; when the sent run leaves no room on the left, the label sits
    to the right of the cut instead. *)

val stacked_bar : width:int -> segments:(string * int) list -> string
(** [stacked_bar ~width ~segments] draws one row of [width] cells split across
    [segments] by {!apportion}, where each segment is its style and its weight.
    Segment [i] uses [segment_glyph i]. *)
