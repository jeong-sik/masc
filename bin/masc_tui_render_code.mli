(** Workspace Code surface and the viewport shared with its key handlers. *)

val code_pane_content_height : Masc_tui_types.state -> int
val render_code : Masc_tui_types.state ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option
