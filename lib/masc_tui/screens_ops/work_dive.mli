(** Breadcrumb deep-inspector views for [Goal_dive], [Task_dive], and
    [Verification_dive]: full pipeline stepper, linked tasks, verifier runs &
    evidence refs ([✓]/[✕]), structured rejection diff ([Diff.draw]), and
    opt-in [[J]] [Json_tree] inspector. *)

val render :
  target:Masc_tui_core.Nav.work_dive_target ->
  model:Masc_tui_store.Model.t ->
  cache:Masc_tui_ui.Card.Cache.t ->
  rect:Masc_tui_core.Rect.t ->
  Masc_tui_term.Cell_grid.t ->
  unit
