(** Visual charting and graphing primitives for the MASC TUI.

    Provides UTF-8 block sparklines, context and resource gauges, tool
    distribution bars, and the 2x4 Braille cell.

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

val meter_bar :
  width:int ->
  value:int ->
  max_value:int ->
  ?cell_style:(index:int -> width:int -> string) ->
  ?track_style:string ->
  ?reset:string ->
  unit ->
  string
(** Bracketless segmented bar of exactly [width] display cells ([""] when
    [width <= 0]): filled cells draw ["■"] with optional per-cell [cell_style]
    (for Oklab gradient ramps), and remaining cells draw ["·"] in [track_style]. *)

val meter :
  width:int ->
  value:int ->
  max_value:int ->
  ?label:string ->
  ?suffix:string ->
  ?cell_style:(index:int -> width:int -> string) ->
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

val braille_levels : ?min:int -> ?max:int -> int list -> int list
(** Maps each input onto the 5-step Braille subcolumn scale ([0..4]) without
    integer overflow. When the lower bound is zero, strictly positive values
    map to at least [1] so non-zero activity never disappears. *)

val braille_pair : left:int -> right:int -> string
(** One 2x4 Braille cell pairing two bottom-up dot heights ([0..4]) into the
    left and right subcolumns (e.g. ["⠀"], ["⢀"], ["⣀"], ["⣠"], ["⣤"], ["⣴"],
    ["⣶"], ["⣾"], ["⣿"]). *)

val braille_bar_mark : level:int -> string
(** Symmetric two-dot-wide Braille column at height [level] ([0..4]):
    ["⠀"], ["⣀"], ["⣤"], ["⣶"], ["⣿"]. *)

val braille_sparkline : ?min:int -> ?max:int -> int list -> string
(** High-density single-row Braille sparkline packing two consecutive samples
    per terminal cell (2x horizontal resolution). An odd sample count left-pads
    with [0] so the newest sample sits in the rightmost subcolumn. *)
