(** Rendering and viewport entry points for approval and question screens. *)

val answer_feedback_reading : Masc_tui_types.state -> Masc_tui_detail_reading.t option
(** Capture the last answer's receipt, original question identity and retained
    follow-up as an immutable reading in the current workspace. Original
    error text is preserved; this does not start or repeat a request. *)

val render_approvals : Masc_tui_types.state -> Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option
val render_approval_detail : Masc_tui_types.state -> Masc_tui_approvals_model.approval_row -> Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option
val render_question_reader : Masc_tui_types.state -> Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option
val ask_question_page_size : Masc_tui_types.state -> int
val ask_question_scroll_limit : Masc_tui_types.state -> int
