(** [[4] Keepers] workspace and 5-tab [Keeper Dive] renderer.

    Adaptive Master-Detail layout:
    - [Wide] (>= 140x36): Left Company-Grouped Fleet Roster (~44 cols) + Right
      Live [Keeper Dive] side-by-side (or zoomed full-width Dive when
      [model.nav.zoomed = true]).
    - [Standard] (100-139) and [Compact] (80-99): Full-width Fleet Roster across
      3 grouping modes ([Companies] | [Attention 3-Bucket] | [24h Wall]);
      [render_dive] paints full-width breadcrumb Dive ([Keepers > <name>]).

    Enforces strict 3-Channel State Honesty: live SSOT glyphs never turn
    yellow/red from historical 12h incidents; past failures appear strictly as
    muted [◂N] trail indicators. *)

val render :
  model:Masc_tui_store.Model.t ->
  cache:Masc_tui_ui.Card.Cache.t ->
  rect:Masc_tui_core.Rect.t ->
  Masc_tui_term.Cell_grid.t ->
  unit

val render_dive :
  name:string ->
  tab:Masc_tui_core.Nav.keeper_tab ->
  model:Masc_tui_store.Model.t ->
  cache:Masc_tui_ui.Card.Cache.t ->
  rect:Masc_tui_core.Rect.t ->
  Masc_tui_term.Cell_grid.t ->
  unit

val render_with_history_rows :
  history_rows:Keeper_dive.History_rows.t option ->
  model:Masc_tui_store.Model.t ->
  cache:Masc_tui_ui.Card.Cache.t ->
  rect:Masc_tui_core.Rect.t ->
  Masc_tui_term.Cell_grid.t ->
  unit

val render_dive_with_history_rows :
  history_rows:Keeper_dive.History_rows.t option ->
  name:string ->
  tab:Masc_tui_core.Nav.keeper_tab ->
  model:Masc_tui_store.Model.t ->
  cache:Masc_tui_ui.Card.Cache.t ->
  rect:Masc_tui_core.Rect.t ->
  Masc_tui_term.Cell_grid.t ->
  unit
(** [render] and [render_dive] are [render_with_history_rows] and
    [render_dive_with_history_rows] with [~history_rows:None]: they lay the
    chat history of the Keeper out again on every call. The program that runs
    the TUI passes the rows it keeps; see [Keeper_dive.History_rows]. *)
