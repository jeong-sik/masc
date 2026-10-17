(** Lanes and System / Runtime / Clients screen entry points and shared helpers. *)

type lane_run_tool_counts = {
  completed : int;
  deferred : int;
  failed : int;
  other : int;
}

val runtime_lane_notice_style : Masc_tui_types.runtime_lane_notice -> string

val render_client_detail :
  Masc_tui_types.state ->
  Masc.Tui_decode.client_row ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option

val render_clients :
  Masc_tui_types.state ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option

val render_lanes :
  Masc_tui_types.state ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option
