(** All 7 Universal TUI v2 Overlays:
    1. [Ctrl+K] Universal Command & Entity Palette ([Palette_commands],
       [Palette_keepers], [Palette_models])
    2. [, / Ctrl+,] 7-Tab Categorized Settings ([Masc_tui_ui.Form], typed
       controls, provenance, [reload_scope], secret masking, [dry_run]
       syntax-highlighted TOML diff preview, [snapshot_id] save receipt)
    3. [I / Alt+I] Muted Historical Incident & Diagnostics Drawer (Channel 3,
       structured cards + [Masc_tui_ui.Json_tree] — zero raw JSON dumps)
    4. [Ctrl+T] Keeper Queue, Context & Schedules Drawer (3 tabs)
    5. Inline Action & [/btw] Side-Query Modal (above composer, zero [$EDITOR])
    6. [?] Dynamic SSOT Help (2-column projection from [Masc_tui_keymap])
    7. System / Auth / Media Gate Overlays (Server-Offline, Workspace-Mismatch
       409 recovery, Auth login, Media viewer, Micro viewport guard) *)

val palette_modal_rect :
  rect:Masc_tui_core.Rect.t -> Masc_tui_core.Rect.t
(** Compute the centered [Ctrl+K] Palette modal rectangle ([min 74 cols] when
    viewport allows, [max 22 rows]). *)

val settings_form_of_model : Masc_tui_store.Model.t -> Masc_tui_ui.Form.state
(** Project the active 7-tab Settings category/search view into a typed
    {!Masc_tui_ui.Form.state} with secret masking, provenance, and reload-scope
    badges. *)

val render :
  model:Masc_tui_store.Model.t ->
  cache:Masc_tui_ui.Card.Cache.t ->
  rect:Masc_tui_core.Rect.t ->
  Masc_tui_term.Cell_grid.t ->
  unit
(** Render the active overlay in [model.nav.overlay] over a dimmed canvas
    backdrop (no-op when [model.nav.overlay = None]). *)
