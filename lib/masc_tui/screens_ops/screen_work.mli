(** [[2] Work] workspace (6 sub-tabs: [Goals], [Tasks], [Schedules], [Inbox],
    [Candle & Scorecard], [Harness]) and [Verification_inspector] renderer. *)

val render :
  model:Masc_tui_store.Model.t ->
  cache:Masc_tui_ui.Card.Cache.t ->
  rect:Masc_tui_core.Rect.t ->
  Masc_tui_term.Cell_grid.t ->
  unit

val render_verification :
  req_id:string ->
  model:Masc_tui_store.Model.t ->
  cache:Masc_tui_ui.Card.Cache.t ->
  rect:Masc_tui_core.Rect.t ->
  Masc_tui_term.Cell_grid.t ->
  unit
