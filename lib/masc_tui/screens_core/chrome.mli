(** Persistent TUI v2 Chrome frame: Top Live SSOT Rail, conditional Sub-Tab /
    Breadcrumb Bar, Dynamic Fast-Path Approval Strip, Persistent Composer with
    Compact 3-row auto-fold, 1-line priority-fitted SSOT Context Footer, and
    Micro (<80x24) non-corrupting cockpit guard. *)

type frame_layout = {
  breakpoint : Masc_tui_ui.Layout.breakpoint;
  top_rail : Masc_tui_core.Rect.t;
  sub_tab_bar : Masc_tui_core.Rect.t option;
  sidebar : Masc_tui_core.Rect.t option;
  sidebar_is_drawer : bool;
  body : Masc_tui_core.Rect.t;
  approval_strip : Masc_tui_core.Rect.t option;
  composer : Masc_tui_core.Rect.t option;
  footer : Masc_tui_core.Rect.t;
  chrome_rows : int;
  composer_folded : bool;
  is_micro_guard : bool;
  is_too_small : bool;
}

val has_sub_tab_bar : Masc_tui_store.Model.t -> bool
(** [true] when the active workspace or dive displays a 1-row sub-tab or
    breadcrumb bar ([Pulse] without a dive returns [false]). *)

val compute_layout :
  model:Masc_tui_store.Model.t -> cols:int -> rows:int -> frame_layout
(** Pure deterministic frame geometry calculation for [(cols, rows)]. *)

val render_frame :
  model:Masc_tui_store.Model.t ->
  cache:Masc_tui_ui.Card.Cache.t ->
  render_body:(Masc_tui_core.Rect.t -> Masc_tui_term.Cell_grid.t -> unit) ->
  render_overlay:(Masc_tui_core.Rect.t -> Masc_tui_term.Cell_grid.t -> unit) ->
  Masc_tui_term.Cell_grid.t ->
  Masc_tui_term.Presenter.cursor
(** Render the entire persistent frame, invoke [render_body] on the computed
    workspace canvas, paint any active toast pill, invoke [render_overlay] when
    an overlay is open, and return the exact terminal cursor descriptor. *)
