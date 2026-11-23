(** Pure 24-bin logarithmic Fact Age Ladder and Fact-Count Evolution charts
    painting directly onto {!Masc_tui_term.Cell_grid.t}.

    Bin geometry matches the server SSOT ([Keeper_memory_age_bins], 24 bins
    spanning [<1h] to [>=30d]):
    - Bin [0] is the newest bucket; bin [23] is the oldest ([>=30d]).
    - Canonical boundary bins: [1] ([1h]), [9] ([1d]), [17] ([7d]), [23] ([30d]).
    - Rendered left-to-right from oldest ([30d]) to newest ([1h]) so time flows
      in the same direction as the Braille {!draw_facts_trend} time series.
    - Three semantic color tiers: [<1d] ([Status_active]), [1-7d] ([text_primary]),
      and [>7d] ([text_muted]). *)

module Rect = Masc_tui_core.Rect
module Say = Masc_tui_core.Say
module Theme = Masc_tui_core.Theme
module Cell_grid = Masc_tui_term.Cell_grid
module Color = Masc_tui_term.Color
module Presenter = Masc_tui_term.Presenter

val bin_count : int
(** Fixed 24 logarithmic age bins. *)

type edge =
  | Edge_hour
  | Edge_day
  | Edge_week
  | Edge_month

val edge_bin : edge -> int
(** Exact server bin index: [1], [9], [17], [23]. *)

val edge_label : edge -> string
(** Compact boundary tick label: ["1h"], ["1d"], ["7d"], ["30d"]. *)

type age_tier =
  | Tier_within_day   (** Bins [0..8] ([< 1d]). *)
  | Tier_within_week  (** Bins [9..16] ([1-7d]). *)
  | Tier_past_week    (** Bins [17..23] ([> 7d]). *)

val equal_age_tier : age_tier -> age_tier -> bool
val tier_of_bin : int -> age_tier

type ladder_cell = {
  count : int;
  tier : age_tier;
  newest_bin : int;
  oldest_bin : int;
}

val merge_of_width : int -> int option
(** Responsive cell merging:
    - [width >= 24] -> [Some 1] (24 cells)
    - [12 <= width < 24] -> [Some 2] (12 cells)
    - [6 <= width < 12] -> [Some 4] (6 cells)
    - [width < 6] -> [None] (skip ladder, show summary counts only). *)

val fold_bins : merge:int -> int array -> (ladder_cell list, string) result
(** Fold a 24-element [age_bins] array into [24 / merge] cells ordered
    oldest-left to newest-right. Each merged cell sums its constituent bins and
    inherits the {!age_tier} of its newest bin. *)

val tier_counts : int array -> (int * int * int, string) result
(** Return [(within_day, within_week, past_week)] totals across the 24 bins. *)

val level_glyph : unicode:bool -> count:int -> max_count:int -> string
(** Map a bin count onto a single-cell vertical bar glyph (["·"] for [0],
    8-level block ["▁".."█"] for [count > 0], never flooring non-zero to [0]). *)

val tick_header : width:int -> string
(** Build an exact [width]-column tick header placing ["30d"], ["7d"], ["1d"],
    and ["1h"] at their merged column boundaries without overlap. *)

val aggregate_fleet_age_bins : int array list -> int array option
(** Element-wise sum of valid 24-bin arrays across the fleet ([None] when empty). *)

val draw_age_ladder :
  Cell_grid.t ->
  rect:Rect.t ->
  theme:Theme.t ->
  caps:Presenter.capabilities ->
  lang:Say.lang ->
  ?bg:Color.t ->
  ?title:string ->
  ?observed_derived:(int * int) ->
  int array option ->
  int
(** Paint the 24-bin Age Ladder (title/summary + tick header + colored bars +
    tier counts / optional Observed/Derived split) into [rect] and return rows
    consumed. Renders a calm Tier-4 italic notice when [age_bins] is [None]. *)

val draw_facts_trend :
  Cell_grid.t ->
  rect:Rect.t ->
  theme:Theme.t ->
  caps:Presenter.capabilities ->
  lang:Say.lang ->
  ?bg:Color.t ->
  ?title:Say.t ->
  ?observed_derived:(int * int) ->
  (float * int) list ->
  Chart.Render_mode.layout_mode
(** Paint the Fact-Count Evolution Braille time series using {!Chart.draw}
    ([Chart.Spec.Time_series]) from chronological [(recorded_at_unix, facts)]
    samples, preserving explicit absent vs zero distinction. *)
