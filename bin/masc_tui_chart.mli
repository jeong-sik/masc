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

(** {1 Distribution Bars} *)

type bar_item = {
  name : string;
  count : int;
  style : Masc_tui_theme.status option;
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
