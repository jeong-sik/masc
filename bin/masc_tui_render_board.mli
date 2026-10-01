(** Board screen entry points. Each returns a frame and optional normalized
    scroll for the caller to apply. *)

val render_board_list : Masc_tui_types.state ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option
val render_board_compose : Masc_tui_types.state ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option
val render_board_read : Masc_tui_types.state -> Masc_tui_types.board_post ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option
