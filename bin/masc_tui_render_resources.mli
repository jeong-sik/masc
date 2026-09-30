(** MCP resource inventory and document reading. Returns a frame and optional
    normalized resource scroll for the caller to apply. *)

val render_resources : Masc_tui_types.state ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option
