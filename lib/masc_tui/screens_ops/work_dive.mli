(** Depth-1 inspector view for [Verification_inspector]: evidence refs
    ([✓]/[✕]), structured rejection diff ([Diff.draw]), summary/specs/TLC tabs,
    and opt-in [[Space]] [Json_tree] inspector. *)

val render :
  req_id:string ->
  model:Masc_tui_store.Model.t ->
  cache:Masc_tui_ui.Card.Cache.t ->
  rect:Masc_tui_core.Rect.t ->
  Masc_tui_term.Cell_grid.t ->
  unit
