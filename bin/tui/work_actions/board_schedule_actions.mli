(** Board post/comment voting and Schedule cancellation actions. *)

val schedule_detail_on_screen
  :  Masc_tui_types.state
  -> Masc_tui_types.schedule_row option

val board_read_thread
  :  Masc_tui_types.state
  -> post_id:string
  -> (string list * string option) option

val select_board_comment
  :  Masc_tui_types.state
  -> post_id:string
  -> string option

val handle_board_vote_key
  :  Masc_tui_types.state
  -> cols:int
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> up:bool
  -> unit

val selected_schedule_row
  :  Masc_tui_types.state
  -> Masc_tui_types.schedule_row option

val handle_schedule_cancel_key
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit
