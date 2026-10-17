(** Verification (Task Review) and Harness (Task Verdicts) screen entry points.
    Each returns a frame and optional normalized scroll for the caller to apply. *)

val render_verification :
  Masc_tui_types.state ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option

val render_harness :
  Masc_tui_types.state ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option
