(** Rendering and viewport entry points for approval and question screens. *)

val list_window_overflows : body_rows:int -> total:int -> bool
(** A queue longer than the rows it has, with a row to spare for the line that
    says which rows are drawn. *)

val list_window_hides_rows : body_rows:int -> total:int -> bool
(** Some rows are not drawn, whether or not there is a row for the line. *)

val list_window_rows : body_rows:int -> total:int -> int
(** The rows the queue's window draws: [body_rows], less the one the window
    line takes when it is drawn. *)

val list_window_note : scroll:int -> height:int -> total:int -> string
(** The window line: the rows drawn over the total, and how many lie each way. *)

val render_approvals : Masc_tui_types.state -> Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option
val render_approval_detail : Masc_tui_types.state -> Masc_tui_approvals_model.approval_row -> Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option
val render_question_reader : Masc_tui_types.state -> Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option
val ask_question_page_size : Masc_tui_types.state -> int
val ask_question_scroll_limit : Masc_tui_types.state -> int
