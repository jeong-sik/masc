(** Reconciliation of session-authored chat rows against loaded server
    transcript history and row-to-display-entry decoding. *)

val forget_session_rows_the_transcript_holds
  :  Masc_tui_types.state
  -> string
  -> Masc_tui_keeper_chat_history.row list
  -> fresh:Masc_tui_types.msg_entry list
  -> unit

val msg_entries_of_history_rows
  :  Masc_tui_types.state
  -> string
  -> Masc_tui_keeper_chat_history.row list
  -> Masc_tui_types.msg_entry list
