(** System / Runtime, Tools, Usage / Metrics, and Keeper runtime picker
    screen entry points. *)

val render_runtime_detail :
  Masc_tui_types.state ->
  Masc_tui_types.runtime_detail_target ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option

val render_runtime :
  Masc_tui_types.state ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option

val tools_scrolled : Masc_tui_types.state -> Masc_tui_types.scrolled

val render_tools :
  Masc_tui_types.state ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option

val render_metrics :
  Masc_tui_types.state ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option

val render_runtime_pick :
  Masc_tui_types.state ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option
