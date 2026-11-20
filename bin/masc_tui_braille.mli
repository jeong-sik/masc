(** Braille cells and Braille graphs for the MASC TUI (RFC
    tui-one-screen-grammar section 5.6).

    A cell is two dots wide and four tall, so it holds two times, oldest on the
    left. A graph takes its colours from a tint, the colour a height share
    draws in (section 7.3).

    Pure by construction: no terminal I/O, no mutation, no unhandled
    exceptions. *)

(** {1 Cells} *)

val braille_cell : mask:int -> string
(** Encodes a Braille pattern (0x2800 + mask) to UTF-8. *)

val braille_pair : left:int -> right:int -> string
(** One 2x4 Braille cell pairing two bottom-up dot heights ([0..4]) into the
    left and right subcolumns (e.g. ["⠀"], ["⢀"], ["⣀"], ["⣠"], ["⣤"], ["⣴"],
    ["⣶"], ["⣾"], ["⣿"]). *)

val braille_pair_down : left:int -> right:int -> string
(** Top-down counterpart to {!braille_pair}, hanging dots down from the top
    of a 2x4 Braille cell ([0..4], e.g. ["⠀"], ["⠈"], ["⠉"], ["⠙"], ["⠛"],
    ["⠟"], ["⠿"], ["⣿"]). Used for falling failure waves and downward mirrored
    halves so downward series stay visually distinct without colour. *)

val braille_bar_mark : level:int -> string
(** Symmetric two-dot-wide Braille column at height [level] ([0..4]):
    ["⠀"], ["⣀"], ["⣤"], ["⣶"], ["⣿"]. Level [1], ["⣀"], is the baseline a
    measured zero draws. *)

val braille_bar_rows : rows:int -> level:int -> string list
(** A column [rows] cells tall drawn to [level] dots, top cell first. The
    base cell holds levels 1 to 4, the next one up 5 to 8, and so on; a cell
    the column does not reach is the blank Braille cell. *)

val value_share : dots:int -> int -> float
(** Where a column [level] dots tall on a [dots]-dot scale stands on a
    ramp, in [[0, 1]]: the lowest value, one level above the baseline, at
    [0], the top at [1]. The baseline itself, a zero, also reads [0]. Every
    graph that colours a column by its own height reads it here. *)

(** {1 Samples} *)

type positive = private int
(** A count above zero. *)

val positive : int -> positive option
(** [Some] for a count above zero, [None] otherwise. *)

(** What a graph knows about one time. *)
type sample =
  | Unread
      (** Not read yet. A graph in which nothing has been read draws no dots. *)
  | Absent
      (** No sample at this time, or its read failed: a blank. The failure is
          for the notice area to tell. *)
  | Zero  (** A measured zero: the baseline dots ([⣀] for two zeros). *)
  | Value of positive
      (** A measured value above zero. It draws at least one dot above the
          baseline. *)

val of_count : int -> sample
(** A measured count: [0] is [Zero] and a count above zero a [Value]. A count
    below zero is no reading, so it is [Absent], the blank a failed read
    draws. *)

val of_milliseconds : float -> sample
(** A measured duration in milliseconds, as a count of whole microseconds
    rounded up, so a duration above zero stays above zero on the scale. A
    duration that is not a number is no reading ([Absent]); one past the
    integer range stands at the top. *)

(** {1 Graphs} *)

(** What a graph draws. *)
type graph =
  | Never_read
      (** No sample has been read: the caller writes the unread mark [◌]
          ([Masc_tui_value.Unknown.Unread]) alone at the graph's left. *)
  | Too_narrow
      (** Fewer than {!graph_min_cells} cells are left for dots: the caller
          writes the number instead of the graph. *)
  | Drawn of string list
      (** The rows, top first, each [width] cells: the axis text in its own
          column on the top row, then the dots, newest time at the right. *)

val graph_min_cells : int
(** [4]: a graph needs this many cells of dots or it is replaced by its
    number. *)

val graph_times : width:int -> axis_cells:int -> int
(** How many times {!braille_graph} draws in [width] cells when its axis text
    is [axis_cells] wide: two a cell of dots, after the axis column and the
    one-cell gap beside it. [0] when nothing is left for dots. *)

val graph_maximum : sample list -> int
(** The largest [Value], or [0] when there is none: the top of an axis scaled
    to its samples. *)

val braille_level : dots:int -> maximum:int -> sample -> int
(** How many dots a sample fills in a column [dots] dots tall (four per text
    row), on an axis whose top is [maximum]. [Unread] and [Absent] are [0],
    a blank. [Zero] is [1], the baseline. A [Value] is between [2] and
    [dots]: at least one dot above the baseline however small it is, and
    [dots] at or past [maximum]. *)

(** The SGR a cell draws at a height share in [[0, 1]], from a picture ramp
    ([Masc_tui_ansi.Theme.series_tint]). A tint that returns [""] draws no colour. *)
type tint = float -> string

val braille_graph :
  ?baseline_style:string ->
  ?axis_style:string ->
  tint:tint ->
  width:int -> rows:int -> axis:string -> maximum:int -> sample list -> graph
(** A graph [width] cells wide and [rows] text rows tall, growing up from its
    baseline. [maximum] is the top of the axis: the largest sample
    ({!graph_maximum}), a declared limit, or a top the caller holds; a sample
    above it draws at the top. [axis] is that top written with its
    unit ([123K]), placed at the graph's top-left. The newest [2 * cells]
    samples are drawn; a time before the first sample is blank.

    A graph more than one row tall colours each row by its height, from [0]
    at the base row to [1] at the top; a one-row graph colours each cell by
    the taller of its two times through {!value_share}. When [baseline_style]
    is non-empty, cells holding only measured-zero baseline dots ([⣀]/[⢀]/[⡀])
    draw in [baseline_style] instead of [tint 0.0]. When [axis_style] is
    non-empty and [axis] is non-blank, the axis text wraps in [axis_style] and
    closes with a reset.
    A colour code goes out only where it changes, a blank cell opens none, an
    empty tint after a colour resets to the foreground, and each row that
    opened a colour ends with a reset. *)

val braille_mirror :
  up_tint:tint ->
  down_tint:tint ->
  width:int ->
  half_rows:int ->
  axis:string ->
  maximum:int ->
  up:sample list ->
  down:sample list ->
  graph
(** Two paired readings on one shared axis (calls and failures, receive and
    send): [up] grows up from the middle in [half_rows] rows, [down] grows
    down from it in as many. Both sides scale to the same [maximum], and each
    follows {!braille_level}, so a smaller side above zero still shows a dot
    past its baseline. The lower half's baseline is its top row of dots
    ([⠉] for two zeros). [Never_read] only when neither side has been read.
    Each half takes its own tint, by distance from the middle. *)

val interpolate_pairs : cells:int -> int option list -> (int * int) list
(** [interpolate_pairs ~cells samples] stretches discrete bucket dot heights
    ([None] for idle/unread gaps, [Some h] for active heights) smoothly across
    [cells] Braille cells ([2 * cells] horizontal subcolumns). Consecutive
    [Some] buckets are linearly interpolated subcolumn by subcolumn, isolated
    [Some] buckets form soft-shouldered peaks, and [None] buckets remain
    [(0, 0)] without cross-gap interpolation. *)

val braille_curve_rows :
  ?down:bool ->
  tint:tint ->
  rows:int ->
  (int * int) list ->
  string list
(** Renders pre-computed 2-subcolumn dot heights [(left, right)] (clamped to
    [0 .. 4 * rows]) as [rows] styled Braille text lines, growing upward from
    the bottom unless [~down:true] is set for a downward mirror wave. *)
