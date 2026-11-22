(** Column-priority responsive table widget painting onto
    {!Masc_tui_term.Cell_grid.t}.

    v2.5 features:
    - Gracefully drops lowest-priority (highest {!column.priority} > 0) columns
      before truncating primary identifiers ([priority = 0]).
    - Never drops hidden columns silently: surfaces an explicit italic hidden-column
      indicator ([+N cols] / [외 N열]) and returns {!layout_result.dropped_columns}.
    - Calm selection row: elevated [selection_bg] tint + 1-cell {!Glyph.Left_rail}
      ([▎]) in [theme.accent] + Tier-1 Bold [text_bright] on primary column while
      preserving semantic [Badge] and [Gauge] colors on selected rows!
    - Crisp Tier-3 Bold column header on [surface_2] with subtle [border_subtle]
      hairline separator beneath header and generous column spacing ([col_gap = 2]
      when width permits).
    - Returns immutable viewport scroll geometry (zero global mutable refs). *)

module Glyph = Masc_tui_core.Glyph
module Rect = Masc_tui_core.Rect
module Say = Masc_tui_core.Say
module Theme = Masc_tui_core.Theme
module Attr = Masc_tui_term.Attr
module Color = Masc_tui_term.Color
module Cell_grid = Masc_tui_term.Cell_grid
module Presenter = Masc_tui_term.Presenter

type align =
  | Left
  | Right
  | Center

type column = {
  id : string;
  header : Say.t;
  priority : int;      (** [0] = primary identifier (never dropped); higher drops first. *)
  min_width : int;
  max_width : int option;
  weight : int;
  align : align;
}

type cell_content =
  | Text of { text : string; fg : Color.t option; attrs : Attr.t }
  | Badge of { glyph : Glyph.t option; text : string; tone : Theme.status_token }
  | Sparkline of { samples : Chart.Series.sample array; gradient : Chart.Gradient.t }
  | Gauge of { ratio : float; gradient : Chart.Gradient.t; label : string option }

type row = {
  id : string;
  cells : (string * cell_content) list;
}

type layout_result = {
  visible_columns : (column * int) list;
  dropped_columns : column list;
  viewport_start : int;
  viewport_rows : int;
  total_rows : int;
  selected_visible : bool;
}

val text_cell : ?fg:Color.t -> ?attrs:Attr.t -> string -> cell_content

val resolve_columns :
  ?col_gap:int ->
  avail_w:int ->
  column list ->
  (column * int) list * column list
(** Compute [(visible_with_widths, dropped_columns)] for [avail_w] (including
    the 2-cell selection gutter, 1-cell right breathing margin when [avail_w >= 20],
    and column gaps defaulting to [2] when [avail_w >= 52] or [1] otherwise). *)

val compute_viewport :
  total_rows:int ->
  viewport_rows:int ->
  scroll:int ->
  selected:int option ->
  int * bool
(** Compute [(clamped_start, selected_visible)] keeping [selected] in view when
    present. *)

val draw :
  Cell_grid.t ->
  rect:Rect.t ->
  theme:Theme.t ->
  caps:Presenter.capabilities ->
  lang:Say.lang ->
  ?scroll:int ->
  ?selected:int ->
  ?zebra:bool ->
  ?col_gap:int ->
  ?header_separator:bool ->
  columns:column list ->
  row list ->
  layout_result
