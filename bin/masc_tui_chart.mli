(** Visual charting and graphing primitives for the MASC TUI.

    Provides UTF-8 block sparklines, context and resource gauges, activity
    heatmaps, tool distribution bars, and high-resolution 2x4 Braille
    time-series plots.

    Pure by construction: no terminal I/O, no mutation, no unhandled exceptions.
    Safe across wide/narrow widths, non-ASCII multi-byte text, and empty/negative inputs. *)

(** Typed style for chart glyphs and bars. *)
type style =
  | Status of Masc_tui_theme.status
  | Tone of Masc_tui_theme.tone

(** {1 Sparklines} *)

val sparkline : ?min:int -> ?max:int -> int list -> string
(** [sparkline ?min ?max values] renders a single-row sparkline string.
    Each value maps to one of the 8 height levels.
    Returns [""] for empty list. *)

val sparkline_colored :
  ?min:int ->
  ?max:int ->
  style_of_level:(int -> style) ->
  int list ->
  string
(** [sparkline_colored] applies a typed [style] based on level (0..7),
    resetting with [Masc_tui_theme.Sgr.reset] after each glyph. *)

(** {1 Gauges and Utilization Bars} *)

type gauge_thresholds = {
  warn_percent : int;
  bad_percent : int;
}

val format_compact_num : int -> string
(** Compact number formatter: 1200 -> "1.2k", 1500000 -> "1.5M". Safe on min_int. *)

val gauge :
  width:int ->
  value:int ->
  max_value:int ->
  ?thresholds:gauge_thresholds ->
  ?label:string ->
  unit ->
  string
(** [gauge ~width ~value ~max_value ?thresholds ?label ()] renders a proportional gauge bar
    bounded strictly within [width] display cells. *)

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
  style : style option;
}

val distribution_bars :
  width:int ->
  bar_item list ->
  string list
(** [distribution_bars ~width items] renders ranked horizontal bars with counts and percentages,
    bounded strictly within [width] display cells. *)

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
