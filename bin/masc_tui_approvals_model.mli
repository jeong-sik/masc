(** Rows and per-source read status for the Approvals surface. *)

type approval_row =
  | Keeper_tool_row of Masc.Tui_decode.keeper_tool_approval
  | Gate_row of Masc.Tui_decode.gate_pending
  | Operator_row of Masc_tui_operator_projection.approval_item

type approval_not_read =
  | Approval_unread
  | Approval_failed of string
  | Approval_stale of string
  | Approval_unavailable of string

type approval_list_reading =
  | List_read
  | List_not_read of approval_not_read

type approvals_reading =
  { confirm_queue : approval_list_reading
  ; held_calls : approval_list_reading
  ; gate_queue : approval_list_reading
  ; questions : approval_list_reading
  }

type approvals_empty_queue =
  | Nothing_pending
  | Lists_not_read of (string * approval_not_read) list

val operator_approval_items : Masc_tui_types.state -> Masc_tui_operator_projection.approval_item list
val approval_items : Masc_tui_types.state -> approval_row list
val approvals_open_questions : Masc_tui_types.state -> Masc.Tui_decode_asks.ask_row list option
(** [None] means no successful question snapshot has been observed. [Some []]
    means an observed snapshot has no open questions. *)
val approvals_open_question_count : Masc_tui_types.state -> int
val approvals_questions_reading : Masc_tui_types.state -> approval_list_reading
val approvals_reading : Masc_tui_types.state -> approvals_reading
val approvals_surface_pending : Masc_tui_types.state -> int
val approvals_reading_current : Masc_tui_types.state -> bool
val approvals_count_label : Masc_tui_types.state -> string
val approval_list_note : name:string -> approval_list_reading -> string
val approvals_title_notes : approvals_reading -> string
val approvals_empty_queue : approvals_reading -> approvals_empty_queue

val list_is_read : approval_list_reading -> bool
val approval_row_lists : approvals_reading -> (string * approval_list_reading) list
val approval_item_needs_person : approval_row -> bool
val approvals_human_pending : Masc_tui_types.state -> int
