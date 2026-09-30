(** Board screen entry points. The caller presents the returned frame and
    commits its normalized scroll only after successful presentation. *)

val render_board_list : Masc_tui_types.state ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option
val render_board_compose : Masc_tui_types.state ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option
val render_board_read : Masc_tui_types.state -> Masc_tui_types.board_post ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option
