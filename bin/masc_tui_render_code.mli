(** Workspace Code surface and the viewport shared with its key handlers. *)

val code_pane_content_height : Masc_tui_types.state -> int
val code_notes_viewport : Masc_tui_types.state -> int * int
(** Wrapped memo row count and visible row budget at the current file-pane width. *)
val code_history_viewport : Masc_tui_types.state -> int * int
(** Physical history row count and visible row budget at the file-pane width. *)
val code_history_selected : Masc_tui_types.state -> Masc_tui_types.code_history_entry option
(** The record owning the top visible row; coverage and failure rows have no owner. *)
val toggle_history_change : Masc_tui_types.state -> bool
(** Expand or collapse the selected Keeper record's recorded text. Returns false
    for commits and unowned rows. The cursor remains on that listing occurrence,
    even when another record has the same payload. *)
val render_code : Masc_tui_types.state ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option
