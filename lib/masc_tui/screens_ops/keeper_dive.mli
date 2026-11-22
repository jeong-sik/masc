(** 5-Tab Keeper Dive renderer shared between full-width [Screen_keepers.render_dive]
    and the [Wide] right-hand side-by-side live detail pane.

    Tabs:
    1. [Keeper_chat]: [Origin_bare]/[Origin_inline]/[Origin_row] transcript via
       [Markdown] + [Code_lexer], 1-line folded Thinking, 1-line collapsible
       Tool Cards, honest pending transmission rows, and a single 1-line Keeper
       Status Strip.
    2. [Keeper_memory]: Scoped Temporal Memory Diff Scrubber ([24h]/[7d]/[30d]/rev),
       retrieval heat ([HOT]/[WARM]/[COLD]), and Librarian writer recovery acts.
    3. [Keeper_work_candle]: Assigned Tasks, Schedules (with last wake
       disposition), recent Board posts, Candle balance + decay gauge, and
       Portrait Ornaments inventory.
    4. [Keeper_sandbox]: Live [apple_container] microVM or [remote_ssh] pool
       telemetry, 24h tool failure breakdown, and live sandbox tail logs.
    5. [Keeper_config]: Scoped In-TUI Keeper Settings rendered via
       [Masc_tui_ui.Form] with masked secrets and TOML diff preview. *)

val render_tabs_body :
  embedded:bool ->
  name:string ->
  tab:Masc_tui_core.Nav.keeper_tab ->
  model:Masc_tui_store.Model.t ->
  cache:Masc_tui_ui.Card.Cache.t ->
  rect:Masc_tui_core.Rect.t ->
  Masc_tui_term.Cell_grid.t ->
  unit
