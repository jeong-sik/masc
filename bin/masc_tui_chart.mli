(** Visual charting and graphing primitives for the MASC TUI.

    Provides UTF-8 block sparklines, context and resource gauges, tool
    distribution bars, the 2x4 Braille cell, and Braille graphs.

    Pure by construction: no terminal I/O, no mutation, no unhandled exceptions.
    Safe across wide/narrow widths, non-ASCII multi-byte text, and empty/negative inputs. *)

(** {1 Sparklines} *)

val sparkline_levels : ?min:int -> ?max:int -> int list -> int list
(** The zero-based height for each input on the sparkline's shared scale.
    Bounds and scaled differences do not overflow for OCaml integers. *)

val sparkline : ?min:int -> ?max:int -> int list -> string
(** [sparkline ?min ?max values] renders a single-row sparkline string.
    Each value maps to one of the 8 height levels.
    Returns [""] for empty list. *)

val sparkline_marks : ?min:int -> ?max:int -> int list -> string list
(** The same scale as [sparkline], with one mark per value. *)

(** {1 Gauges and Utilization Bars} *)

val format_compact_num : int -> string
(** Compact number formatter: 1200 -> "1.2k", 1500000 -> "1.5M". [min_int]
    prints as its exact integer string: no compact rung states a magnitude
    the value does not have. *)

val bar_filled_cells : width:int -> value:int -> max_value:int -> int
(** How many of [width] cells a bar of [value] against [max_value] fills:
    none for a value or a maximum of zero or below, at least one for a positive
    value, and all of them at [max_value] or above. {!gauge} fills its bar by
    the same rule. *)

val gauge :
  width:int ->
  value:int ->
  max_value:int ->
  ?label:string ->
  unit ->
  string
(** [gauge ~width ~value ~max_value ?label ()] renders a proportional gauge bar
    bounded strictly within [width] display cells. The bar carries no level
    colouring: fill and remainder differ by glyph and dimming only. A domain
    that defines a warning or critical level draws it beside the bar. *)

(** What a meter's maximum is, which decides its colour (RFC
    tui-one-screen-grammar section 7.3). *)
type meter_scale =
  | Declared_limit of Masc_tui_theme.limit_paint
      (** A cap set in settings or stated by a provider, where reaching it
          refuses or holds work: a plan window that blocks model calls when
          full, a context window's used tokens against its maximum. Each
          filled cell takes the colour of its position against the cap. *)
  | Relative
      (** Anything else: a completion ratio, a share of a total, a size
          against the largest, a cap no one has confirmed is a limit. The fill
          draws no colour of its own, so it takes the foreground or whatever
          state colour the caller drew around the bar. *)

val meter_cell_colour :
  meter_scale -> index:int -> width:int -> Masc_tui_theme.meter_cell_colour
(** The colour filled cell [index] of a [width]-cell bar takes:
    {!Masc_tui_theme.limit_cell_colour} at the paint's depth for a declared
    limit, [Cell_plain] for a relative bar at every depth. *)

val meter_cell_style : meter_scale -> index:int -> width:int -> string
(** The SGR drawn before that cell's glyph: {!meter_cell_colour} through
    {!Masc_tui_theme.meter_cell_readable}, and [""] for a relative bar. *)

val meter_bar :
  width:int ->
  value:int ->
  max_value:int ->
  scale:meter_scale ->
  ?track_style:string ->
  ?reset:string ->
  unit ->
  string
(** Bracketless segmented bar of exactly [width] display cells ([""] when
    [width <= 0]): filled cells draw ["■"] coloured by [scale] (see
    {!meter_cell_colour}), and remaining cells draw ["·"] in [track_style]. *)

val meter :
  width:int ->
  value:int ->
  max_value:int ->
  scale:meter_scale ->
  ?label:string ->
  ?suffix:string ->
  ?track_style:string ->
  ?suffix_style:string ->
  ?reset:string ->
  unit ->
  string
(** Bracketless segmented telemetry meter bounded within [width] display cells:
    optional [label], {!meter_bar}, and right readout ([suffix], defaulting to
    aligned ["%3d%%"]). *)

(** {1 Distribution Bars} *)

type bar_item = {
  name : string;
  count : int;
  style : Masc_tui_theme.status;
}

type distribution_share = { percentage : int; filled_cells : int }

val distribution_shares : cells:int -> int list -> distribution_share list
(** Exact integer floors of each nonnegative count's percentage and share of
    [cells], before the renderer's minimum one-cell marker for positive counts.
    Negative counts and cell capacities are treated as zero. An empty or
    all-zero input has zero shares. The denominator and scaled numerators do
    not overflow even when their sums or products exceed [max_int]. *)

val distribution_bars :
  width:int ->
  bar_item list ->
  string list
(** [distribution_bars ~width items] renders counts and shares of the supplied
    nonnegative counts. Every bar uses the same 0–100 percent scale; missing
    categories outside [items] are not part of the denominator. Empty tracks
    use a neutral colour. Shares are rounded down exactly, so displayed
    percentages need not sum to 100; a positive count has at least one filled
    cell when a track is available. Output is bounded within [width] display cells. *)

(** {1 High-Resolution Braille Curve Plots} *)

val braille_cell : mask:int -> string
(** Encodes a Braille pattern (0x2800 + mask) to UTF-8. *)

val braille_pair : left:int -> right:int -> string
(** One 2x4 Braille cell pairing two bottom-up dot heights ([0..4]) into the
    left and right subcolumns (e.g. ["⠀"], ["⢀"], ["⣀"], ["⣠"], ["⣤"], ["⣴"],
    ["⣶"], ["⣾"], ["⣿"]). *)

val braille_bar_mark : level:int -> string
(** Symmetric two-dot-wide Braille column at height [level] ([0..4]):
    ["⠀"], ["⣀"], ["⣤"], ["⣶"], ["⣿"]. *)

(** {1 Braille graphs}

    RFC tui-one-screen-grammar section 5.6. A cell is two dots wide and four
    tall, so it holds two times, oldest on the left. Graphs carry no colour:
    a caller colours the rows only for an anomaly (section 7.3). *)

(** What a graph knows about one time. *)
type sample =
  | Unread
      (** Not read yet. A graph in which nothing has been read draws no dots. *)
  | Absent
      (** No sample at this time, or its read failed: a blank. The failure is
          for the notice area to tell. *)
  | Zero  (** A measured zero: the baseline dots ([⣀] for two zeros). *)
  | Value of int
      (** A measured value above zero. It draws at least one dot above the
          baseline. A [Value] at or below zero sits on the baseline. *)

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

val graph_maximum : sample list -> int
(** The largest [Value], or [0] when there is none: the top of an axis scaled
    to its samples. *)

val braille_level : dots:int -> maximum:int -> sample -> int
(** How many dots a sample fills in a column [dots] dots tall (four per text
    row), on an axis whose top is [maximum]. [Unread] and [Absent] are [0],
    a blank. [Zero] is [1], the baseline. A [Value] is between [2] and
    [dots]: at least one dot above the baseline however small it is, and
    [dots] at or past [maximum]. *)

val braille_graph :
  width:int -> rows:int -> axis:string -> maximum:int -> sample list -> graph
(** A graph [width] cells wide and [rows] text rows tall, growing up from its
    baseline. [maximum] is the top of the axis: the largest sample
    ({!graph_maximum}) or a declared limit. [axis] is that top written with its
    unit ([123K]), placed at the graph's top-left. The newest [2 * cells]
    samples are drawn; a time before the first sample is blank. *)

val braille_mirror :
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
    ([⠉] for two zeros). [Never_read] only when neither side has been read. *)
