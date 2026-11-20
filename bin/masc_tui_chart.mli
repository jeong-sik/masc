(** Visual charting and graphing primitives for the MASC TUI.

    Provides UTF-8 block sparklines, context and resource gauges, meters,
    and tool distribution bars. Braille cells and graphs are
    {!Masc_tui_braille}.

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

(** What a meter's maximum is, which decides the ramp its cells walk (RFC
    tui-one-screen-grammar section 7.3). *)
type meter_scale =
  | Declared_limit of Masc_tui_theme.paint
      (** A cap set in settings or stated by a provider, where reaching it
          refuses or holds work: a plan window that blocks model calls when
          full, a context window's used tokens against its maximum. Each
          filled cell takes the status colour of its position against the cap. *)
  | Series of { paint : Masc_tui_theme.paint; series : Masc_tui_theme.series }
      (** Anything else: a completion ratio, a share of a total, a size
          against the largest. Each filled cell takes [series]'s hue at its
          position along the bar, deep at the start and bright at the end. *)
  | Anomaly of { paint : Masc_tui_theme.paint; alarm : alarm }
      (** An anomaly the bar reports -- every call failed, a stalled reader
          -- whose status colour comes before any ramp: every filled cell
          draws in [alarm]'s status colour through
          {!Masc_tui_theme.status_readable}. *)

(** The two colours an anomaly takes. A good or neutral status is not an
    anomaly, so it has no constructor here. *)
and alarm =
  | Alarm_warn  (** Waiting too long: a stalled reader. *)
  | Alarm_bad  (** Failing: every call in a bucket failed. *)

val meter_cell_style :
  meter_scale -> index:int -> width:int -> value:int -> max_value:int -> string
(** The SGR drawn before filled cell [index] of a [width]-cell bar drawing
    [value] against [max_value]. A declared limit draws
    {!Masc_tui_theme.limit_cell_colour} through
    {!Masc_tui_theme.meter_cell_readable}; a series draws
    {!Masc_tui_theme.ramp_style} at the cell's reach, the smaller of its far
    edge and [value / max_value]; an anomaly draws its status colour. *)

val meter_tip_style :
  meter_scale -> value:int -> max_value:int -> string
(** The text-readable SGR for a meter's numeric readout (btop readout
    colouring). For {!Declared_limit} and {!Anomaly} it matches the rightmost
    filled cell at [value / max_value] (already lifted to 4.5:1 text contrast).
    For {!Series} it reads the bright end of the series ramp so the readout
    carries the series hue while staying above the 4.5:1 text contrast floor
    even at low values. Returns [""] when [value <= 0], [max_value <= 0], or
    colours are disabled. *)

val meter_fill_run :
  scale:meter_scale ->
  width:int ->
  value:int ->
  max_value:int ->
  reset:string ->
  string list ->
  string
(** The filled glyphs, cell [0] first, each coloured by {!meter_cell_style}.
    A colour code goes out only where it differs from the cell before, and
    [reset] closes the run when any code went out. *)

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
    [width <= 0]): filled cells draw ["■"] through {!meter_fill_run}, and
    remaining cells draw ["·"] in [track_style]. *)

val meter :
  width:int ->
  value:int ->
  max_value:int ->
  scale:meter_scale ->
  ?label:string ->
  ?label_style:string ->
  ?suffix:string ->
  ?track_style:string ->
  ?suffix_style:string ->
  ?reset:string ->
  unit ->
  string
(** Bracketless segmented telemetry meter bounded within [width] display cells:
    optional [label] (styled with [label_style] when provided so labels recede
    behind the bar and readout), {!meter_bar}, and right readout ([suffix],
    defaulting to aligned ["%3d%%"]). When [suffix_style] is omitted, the
    readout takes {!meter_tip_style} so the figure matches the bar's tip
    colour; pass [~suffix_style:""] for plain foreground or an explicit SGR to
    override. *)

val dot_meter_bar :
  width:int ->
  value:int ->
  max_value:int ->
  scale:meter_scale ->
  ?track_style:string ->
  ?reset:string ->
  unit ->
  string
(** Fine Braille micro-dot counterpart to {!meter_bar} ([btop] mem/CPU style):
    draws [2 * width] horizontal sub-cells using full 8-dot Braille (["⣿"])
    plus half-column Braille (["⡇"]) and middle-dot track (["·"]) in
    [track_style], styled through {!meter_fill_run}. *)

val dot_meter :
  width:int ->
  value:int ->
  max_value:int ->
  scale:meter_scale ->
  ?label:string ->
  ?label_style:string ->
  ?suffix:string ->
  ?track_style:string ->
  ?suffix_style:string ->
  ?reset:string ->
  unit ->
  string
(** Fine Braille micro-dot counterpart to {!meter}, using {!dot_meter_bar}
    between optional [label] and [suffix]. *)

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
