(** MCP resource inventory and document reading. The caller presents the frame
    before committing its normalized resource scroll. *)

val render_resources : Masc_tui_types.state ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option
