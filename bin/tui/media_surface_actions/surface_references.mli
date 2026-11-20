(** Cross-surface masc:// reference routing and selection helpers. *)

val follow_target : Masc_tui_link.kind -> string -> (Masc_tui_types.surface * string option) option
val approval_row_reference : Masc_tui_approvals_model.approval_row -> string option
val selected_surface_reference : Masc_tui_types.state -> string option
val next_board_sort : Masc_tui_types.board_sort -> Masc_tui_types.board_sort
val clamp_planning_cursor : Masc_tui_types.state -> unit
