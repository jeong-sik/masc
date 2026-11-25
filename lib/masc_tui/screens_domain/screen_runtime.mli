(** [[5] Runtime] workspace renderer (7 sub-tabs: Quotas & Credits, Efficiency
    & Spend, Failover Lanes, Fusion, Tools & Usage, Connectors, Addons &
    Browser) plus Runtime inspector ([Tool] / [Skill] / [Exact Run]) renderer.

    Strictly observation-only ([constitution.xml#budget_gate]) and
    Provider/Model-Free: distinguishes [$0 Sub] vs [$0 Exhausted] vs
    [? Unreported], paints full-width btop adaptive charts, and isolates
    out-of-lane probe failures from active cascade SSOT availability. *)

val render :
  model:Masc_tui_store.Model.t ->
  cache:Masc_tui_ui.Card.Cache.t ->
  rect:Masc_tui_core.Rect.t ->
  Masc_tui_term.Cell_grid.t ->
  unit

val render_inspector :
  target:[ `Tool of string | `Skill of string | `Exact_run of string ] ->
  model:Masc_tui_store.Model.t ->
  cache:Masc_tui_ui.Card.Cache.t ->
  rect:Masc_tui_core.Rect.t ->
  Masc_tui_term.Cell_grid.t ->
  unit
