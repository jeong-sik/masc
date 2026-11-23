(** Pure terminal box/tree renderer for {!Memory_lineage.chart} formation trees.

    Renders the connected memory-ID neighbourhood as width-bounded terminal
    rows with explicit visual distinction between confirmed transitions (solid
    edges [│], [├─], [└─], [──▶]) and unconfirmed [Relation_unavailable]
    transitions (dotted edges [┆], [├┄], [└┄], [┄┄▶]), deduplicated scope notes,
    full wrapped claims, and a [★] star marker on the selected change.

    Pure module: zero terminal or filesystem I/O. *)

module Rect = Masc_tui_core.Rect
module Theme = Masc_tui_core.Theme
module Cell_grid = Masc_tui_term.Cell_grid

type edge_style =
  | Confirmed
  | Unconfirmed

type line_kind =
  | Header
  | Scope
  | Note
  | Event_selected
  | Event_other
  | Edge of edge_style
  | Fact_before
  | Fact_after
  | Reason
  | Separator

type line = {
  kind : line_kind;
  text : string;
}

val render_lines :
  ?tz_offset_sec:int ->
  ko:bool ->
  ?now:float ->
  ?keeper_name:string ->
  max_width:int ->
  Memory_lineage.chart ->
  line list
(** Render [chart] into semantic {!line}s, each strictly fitting within
    [max 1 max_width] terminal columns measured by
    {!Masc_tui_term.Grapheme.display_width}. *)

val render :
  ?tz_offset_sec:int ->
  ko:bool ->
  ?now:float ->
  ?keeper_name:string ->
  max_width:int ->
  Memory_lineage.chart ->
  string list
(** Render [chart] into plain UTF-8 box/tree lines bounded by [max_width]. *)

val draw :
  Cell_grid.t ->
  rect:Rect.t ->
  theme:Theme.t ->
  ?tz_offset_sec:int ->
  ko:bool ->
  ?now:float ->
  ?keeper_name:string ->
  ?scroll:int ->
  Memory_lineage.chart ->
  int
(** Paint the formation tree directly onto [Cell_grid.t] inside [rect] with
    WCAG-verified {!Typography} styles. Returns total rendered line count. *)
