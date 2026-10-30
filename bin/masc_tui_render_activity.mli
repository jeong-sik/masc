(** Activity (Acting events + evidence, System_logs + detail, and Keeper_calls)
    screen entry points. *)

val render_system_log_detail :
  Masc_tui_types.state ->
  int ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option

val render_system_logs :
  Masc_tui_types.state ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option

val render_keeper_calls :
  Masc_tui_types.state ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option

val render_acting :
  Masc_tui_types.state ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option
