(** Keepers list, detail pane, and turn logs screen entry points. *)

val render_keeper_list :
  Masc_tui_types.state ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option
(** Render the list-mode state. Selection and fleet width/health summaries read
    the same synchronous ordered row model as the visible list. That model is
    not retained across draws or used by input handlers. *)

val render_keeper_detail :
  Masc_tui_types.state ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option

val render_keeper_logs :
  Masc_tui_types.state ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option
