(** Visual charting and graphing primitives for the MASC TUI.

    Provides UTF-8 block sparklines, context and resource gauges, activity
    heatmaps, tool distribution bars, and high-resolution 2x4 Braille
    time-series plots.

    Pure by construction: no terminal I/O, no mutation, no unhandled exceptions.
    Safe across wide/narrow widths, non-ASCII multi-byte text, and empty/negative inputs. *)

(** {1 Sparklines} *)

val sparkline : ?min:int -> ?max:int -> int list -> string
(** [sparkline ?min ?max values] renders a single-row sparkline string.
    Each value maps to one of the 8 height levels.
    Returns [""] for empty list. *)

(** {1 Gauges and Utilization Bars} *)

val format_compact_num : int -> string
(** Compact number formatter: 1200 -> "1.2k", 1500000 -> "1.5M". Safe on min_int. *)

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

(** {1 Activity Heatmaps} *)

val heatmap_24h :
  ?label:string ->
  int list ->
  string list
(** [heatmap_24h ?label hours] renders a 2-line 24-hour activity widget normalized across
    the entire 24-hour peak. *)

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

val braille_plot :
  width:int ->
  height:int ->
  ?min_val:float ->
  ?max_val:float ->
  float list ->
  string list
(** [braille_plot ~width ~height points] renders a continuous, linearly interpolated
    high-resolution 2x4 dot matrix curve of [height] terminal rows and [width] columns. *)
