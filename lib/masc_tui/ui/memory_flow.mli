(** Pure observed Memory Flow time-series bucketing & Braille chart builder.

    Zero synthetic/fabricated points:
    - Empty observed revisions emit empty sample arrays ([| |]) plus an honest
      window-expansion subtitle.
    - Single observed revision emits a single sample plus an explicit
      ["1 observed revision (rN)"] whisper subtitle.
    - [Flow_io] renders a mirrored {!Chart.Spec.Dual_inverted} Braille chart
      ([added] UP in [Efficiency] gradient; [removed + invalidated] /
      [retracted] DOWN in [Warm_flow] gradient).
    - [Net_total] renders a {!Chart.Spec.Time_series} Braille chart anchored
      backward from [total_now] so stock trajectory matches observed net deltas. *)

open Masc_tui_core
open Masc_tui_term

type revision_tick = {
  rev : int;
  at_unix : float;
  added : int;
  removed : int;
}

type window_kind =
  | Window_24h
  | Window_7d
  | Window_30d
  | Window_revs of { from_rev : int; to_rev : int }

type chart_mode =
  | Flow_io
  | Net_total

type input = {
  revisions : revision_tick list;
  from_unix : float option;
  to_unix : float option;
  total_now : int;
  is_world : bool;
  window : window_kind;
}

type built = {
  spec : Chart.Spec.t;
  subtitle : Say.t option;
  observed_count : int;
}

val equal_chart_mode : chart_mode -> chart_mode -> bool
val toggle_mode : chart_mode -> chart_mode
val mode_label : chart_mode -> Say.t

val chart_height_for : avail_h:int -> int
(** Exact vertical row reservation shared by renderers and [Update_nav]:
    returns [7] when [avail_h >= 15], [2] when [avail_h >= 6], else [0]. *)

val build : now_unix:float -> mode:chart_mode -> input -> built

val draw :
  Cell_grid.t ->
  rect:Rect.t ->
  theme:Theme.t ->
  caps:Presenter.capabilities ->
  lang:Say.lang ->
  now_unix:float ->
  mode:chart_mode ->
  input ->
  unit
(** Render the observed Memory Flow chart (or honest empty/single-point notice)
    into [rect]. *)
