(** [[3] Knowledge] workspace renderer (3 sub-tabs: Signal-First Board, Wiki &
    Artifacts, World & Temporal Memory Diff) plus [Dive_knowledge] deep views
    (Thread w/ succession chain navigator, Wiki reader/backlinks, Artifact
    revision viewer, and Temporal Memory Diff dive).

    Pure projection onto {!Masc_tui_term.Cell_grid.t}: zero Eio/network
    imports, zero global mutable state, zero raw JSON dumps. *)

val render :
  model:Masc_tui_store.Model.t ->
  cache:Masc_tui_ui.Card.Cache.t ->
  rect:Masc_tui_core.Rect.t ->
  Masc_tui_term.Cell_grid.t ->
  unit

val render_dive :
  target:Masc_tui_core.Nav.knowledge_dive_target ->
  model:Masc_tui_store.Model.t ->
  cache:Masc_tui_ui.Card.Cache.t ->
  rect:Masc_tui_core.Rect.t ->
  Masc_tui_term.Cell_grid.t ->
  unit
