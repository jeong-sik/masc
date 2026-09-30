(** Fusion list, retained/historical detail and launch-form frames.
    Each entry point returns its frame and optional normalized scroll value. *)

val render_fusion_list : Masc_tui_types.state -> Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option
val render_fusion_detail : Masc_tui_types.state -> string -> Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option
val render_fusion_launch : Masc_tui_types.state -> form:Masc_tui_fusion_launch.t option -> Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option
