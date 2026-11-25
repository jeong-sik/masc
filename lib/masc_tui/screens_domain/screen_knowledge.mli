(** [[3] Knowledge] workspace renderer (4 sub-tabs: Signal-First Board with
    zoomed Thread Reader, Wiki with inline Backlinks/Links/Lint rail,
    Artifacts with in-document search & Revision History, and World & Temporal
    Memory Diff).

    Pure projection onto {!Masc_tui_term.Cell_grid.t}: zero Eio/network
    imports, zero global mutable state, zero raw JSON dumps. *)

val render :
  model:Masc_tui_store.Model.t ->
  cache:Masc_tui_ui.Card.Cache.t ->
  rect:Masc_tui_core.Rect.t ->
  Masc_tui_term.Cell_grid.t ->
  unit
