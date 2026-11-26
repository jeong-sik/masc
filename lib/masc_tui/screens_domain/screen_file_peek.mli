(** File inspector: a read-only view of one Keeper workspace file, opened from
    a Keeper tool-call row at the line the call touched. *)

val render :
  peek:Masc_tui_core.Nav.file_peek ->
  model:Masc_tui_store.Model.t ->
  cache:Masc_tui_ui.Card.Cache.t ->
  rect:Masc_tui_core.Rect.t ->
  Masc_tui_term.Cell_grid.t ->
  unit
