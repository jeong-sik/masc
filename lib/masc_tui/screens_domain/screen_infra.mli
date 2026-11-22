(** [[6] Infra] workspace renderer (3 sub-tabs: microVM & SSH Sandboxes, Repos
    & Read-Only Syntax-Highlighted Diffs, Unified Activity & Logs) plus
    [Dive_infra] deep views (Sandbox, Runtime Lane, and Historical Incident
    dives with opt-in [[J]] collapsible {!Masc_tui_ui.Json_tree}).

    Pure projection onto {!Masc_tui_term.Cell_grid.t}: zero Eio/network
    imports, zero global mutable state, zero raw JSON dumps. *)

val render :
  model:Masc_tui_store.Model.t ->
  cache:Masc_tui_ui.Card.Cache.t ->
  rect:Masc_tui_core.Rect.t ->
  Masc_tui_term.Cell_grid.t ->
  unit

val render_dive :
  target:Masc_tui_core.Nav.infra_dive_target ->
  model:Masc_tui_store.Model.t ->
  cache:Masc_tui_ui.Card.Cache.t ->
  rect:Masc_tui_core.Rect.t ->
  Masc_tui_term.Cell_grid.t ->
  unit
