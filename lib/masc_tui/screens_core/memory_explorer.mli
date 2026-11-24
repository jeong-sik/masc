(** Shared pure Memory Explorer renderer for both [3 -> 기억]
    ([Screen_knowledge]) and [4 -> Keeper -> 기억] ([Keeper_dive]).

    Renders:
    - Mode switch bar ([변천 과정 (Evolution)] · [전체 기억 (Facts)] · [기간 Diff])
    - Color & glyph-coded Evolution table ([+ ↻ ~ ⊕ - ✕ ! ?])
    - Ordinary + Source-bound Facts explorer with Recency/Retrieved sort toggle
    - Word-wrapped multi-line Temporal Diff
    - Scrollable full-reading pane for complete claims, before/after, metadata,
      basis/derivations, and lineage. *)

open Masc_tui_core
open Masc_tui_term
open Masc_tui_ui
open Masc_tui_store

val wrap_lines : max_width:int -> string -> string list
(** Grapheme-aware UTF-8/CJK multi-line text wrapping for memory claims. *)

val diff_viewport_skip :
  total_rows:int ->
  avail_h:int ->
  scroll:int ->
  selected_range:(int * int) option ->
  int
(** Pure viewport skip projection for multi-row diff entries: keeps the
    selected item's visual row block [[sel_start, min sel_end (sel_start + vis_h - 1)]]
    within [[skip, skip + vis_h - 1]] and clamped to [[0, max_skip]]. *)

val render_full_reading :
  grid:Cell_grid.t ->
  rect:Rect.t ->
  theme:Theme.t ->
  lang:Say.lang ->
  now_unix:float ->
  entry:Knowledge_store.memory_reading_entry ->
  scroll:int ->
  unit

val active_diagram_body_rect : Model.t -> Rect.t option
(** Pure layout projection returning the exact terminal-grid [Rect.t] of the
    open Memory Diagram's inner body area across [3 -> 기억] and
    [4 -> Keeper -> 기억] (including zoomed mode), or [None] when inactive. *)

val render_memory_diagram :
  grid:Cell_grid.t ->
  rect:Rect.t ->
  theme:Theme.t ->
  lang:Say.lang ->
  diagram:Knowledge_store.memory_diagram_state ->
  unit

val render_keeper_health_charts :
  grid:Cell_grid.t ->
  rect:Rect.t ->
  theme:Theme.t ->
  model:Model.t ->
  keeper:string ->
  int
(** Draw the optional age distribution and trend in spare health view rows.
    Returns the number of rows used. *)

val render_keeper_memory :
  grid:Cell_grid.t ->
  rect:Rect.t ->
  theme:Theme.t ->
  bp:Layout.breakpoint ->
  model:Model.t ->
  keeper:string ->
  focused:bool ->
  diff_scroll:int ->
  unit

val render_world_diff_body :
  grid:Cell_grid.t ->
  rect:Rect.t ->
  theme:Theme.t ->
  lang:Say.lang ->
  now_unix:float ->
  k:Knowledge_store.t ->
  focused:bool ->
  diff_scroll:int ->
  unit
