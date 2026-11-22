(** [[2] Work] workspace (4 sub-tabs: [Pipeline], [Tasks & Schedules], [Inbox],
    [Candle & Scorecard]) and [Goal/Task/Verification Dive] renderer. *)

val render :
  model:Masc_tui_store.Model.t ->
  cache:Masc_tui_ui.Card.Cache.t ->
  rect:Masc_tui_core.Rect.t ->
  Masc_tui_term.Cell_grid.t ->
  unit

val render_dive :
  target:Masc_tui_core.Nav.work_dive_target ->
  model:Masc_tui_store.Model.t ->
  cache:Masc_tui_ui.Card.Cache.t ->
  rect:Masc_tui_core.Rect.t ->
  Masc_tui_term.Cell_grid.t ->
  unit
