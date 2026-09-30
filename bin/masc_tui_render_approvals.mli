(** Rendering and viewport entry points for approval and question screens. *)

val render_approvals : Masc_tui_types.state -> string
val render_approval_detail : Masc_tui_types.state -> Masc_tui_approvals_model.approval_row -> string
val render_question_reader : Masc_tui_types.state -> string
val ask_question_page_size : Masc_tui_types.state -> int
val ask_question_scroll_limit : Masc_tui_types.state -> int
