(** Ask follow-up observation, Ask answering UX, and Ask answer receipt /
    completion handlers. *)

val launch_ask_followup_load
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val inspect_selected_ask_origin
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val leave_ask_answering : Masc_tui_types.state -> unit

val enter_ask_answering : Masc_tui_types.state -> unit

val move_ask_cursor : Masc_tui_types.state -> int -> unit

val move_ask_question_cursor : Masc_tui_types.state -> int -> unit

val toggle_ask_choice : Masc_tui_types.state -> int -> unit

val begin_ask_text_entry : Masc_tui_types.state -> unit

val edit_ask_text : Masc_tui_types.state -> (string -> string) -> unit

val commit_ask_text_entry : Masc_tui_types.state -> unit

val cancel_ask_text_entry : Masc_tui_types.state -> unit

val skip_ask_question : Masc_tui_types.state -> unit

val clear_ask_question : Masc_tui_types.state -> unit

val apply_ask_answer_receipt
  :  Masc_tui_types.state
  -> Masc_tui_types.ask_submission
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val apply_ask_answer_completion
  :  settle_asks:(Masc_tui_types.state -> (Masc.Tui_decode_asks.asks_snapshot, string) result -> unit)
  -> Masc_tui_types.state
  -> Masc_tui_types.ask_submission
  -> (Masc.Tui_decode_asks.answer_receipt, Masc_tui_types.request_failure) result
  -> (Masc.Tui_decode_asks.asks_snapshot, string) result
  -> unit

val handle_ask_submit
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit
