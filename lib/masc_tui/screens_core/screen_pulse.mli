(** Workspace [[1] Pulse] — Executive Cockpit & World Pulse.

    Renders the single authoritative Engine Telemetry Ribbon, collapsible
    Channel-1 Needs Attention queue (collapsing to a 1-line [● All clear] pill
    when empty), Autonomous Companies roster with 3-bucket live health and 24h
    sparklines, Daily Achievement Scorecard (including unattributed Candle
    diagnostics), and World Pulse (signal-only Board threads with succession
    chain badges + World Memory briefing and conflict counts). *)

val render :
  model:Masc_tui_store.Model.t ->
  cache:Masc_tui_ui.Card.Cache.t ->
  rect:Masc_tui_core.Rect.t ->
  Masc_tui_term.Cell_grid.t ->
  unit
