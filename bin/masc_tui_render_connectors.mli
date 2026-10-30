(** Connectors table, Browser Lane, and Browser History screen entry points
    and scroll bounds. *)

val browser_lane_scroll_limit :
  Masc_tui_types.state ->
  terminal_rows:int ->
  cols:int ->
  Masc_tui_types.Browser_lane_view.t ->
  int

val browser_lane_selection_scroll :
  Masc_tui_types.state ->
  terminal_rows:int ->
  cols:int ->
  Masc_tui_types.Browser_lane_view.t ->
  int
(** Reveal the selected node's first wrapped row after explicit selection. *)

val browser_history_scroll_limit :
  Masc_tui_types.state ->
  terminal_rows:int ->
  cols:int ->
  Masc_tui_types.Browser_history.t ->
  int

val render_connectors :
  Masc_tui_types.state ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option
