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
val current_value_reading : Masc_tui_types.state -> Masc_tui_approval_value_reading.t option
val detail_presentation : Masc_tui_types.state -> Masc_tui_types.approval_detail_presentation option
val detail_presentation_changed :
  presented:Masc_tui_types.approval_detail_presentation option ->
  current:Masc_tui_types.approval_detail_presentation option -> bool
val reconcile_value_reading : Masc_tui_types.state -> unit
val accept_gate_snapshot : Masc_tui_types.state -> Masc.Tui_decode.gate_snapshot -> unit
val value_reading_available : Masc_tui_types.state -> approval_row -> bool
val close_value_reading : Masc_tui_types.state -> bool
type value_reading_toggle =
  | Value_reading_opened | Value_reading_closed | Value_reading_unavailable
  | Value_reading_changed | Value_reading_waiting_for_source
val toggle_value_reading : Masc_tui_types.state -> presented:approval_row option -> value_reading_toggle
val page_detail : Masc_tui_types.state -> forward:bool -> count:int -> height:int -> bool
val step_detail : Masc_tui_types.state -> forward:bool -> count:int -> height:int -> bool
val detail_edge : Masc_tui_types.state -> to_bottom:bool -> bool
val approvals_open_questions : Masc_tui_types.state -> Masc.Tui_decode_asks.ask_row list option
(** [None] means no successful question snapshot has been observed. [Some []]
    means an observed snapshot has no open questions. *)
val approvals_open_question_count : Masc_tui_types.state -> int
val approvals_questions_reading : Masc_tui_types.state -> approval_list_reading
val approvals_reading : Masc_tui_types.state -> approvals_reading
val confirm_queue_reading : Masc_tui_types.state -> approval_list_reading
val approvals_surface_pending : Masc_tui_types.state -> int
val approvals_reading_current : Masc_tui_types.state -> bool
val approval_list_note : name:string -> approval_list_reading -> string
val approvals_empty_queue : approvals_reading -> approvals_empty_queue

val list_is_read : approval_list_reading -> bool
val approval_row_lists : approvals_reading -> (string * approval_list_reading) list
val approval_item_needs_person : approval_row -> bool
