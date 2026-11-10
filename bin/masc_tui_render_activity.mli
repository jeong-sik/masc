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

val acting_page_rows : Masc_tui_types.state -> terminal_rows:int -> int
(** Page step of the activity list, using the same exceptional feed/replay
    notices and body allocation as [render_acting]. Evidence keeps its
    existing separate scroll domain. *)
