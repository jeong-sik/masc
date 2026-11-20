(** Keeper message composer draft targeting, image preview collection, queued
    input cancellation, history recall, and draft submission. *)

val reset_message_file_changes : Masc_tui_types.state -> string option -> unit

val forget_recall : Masc_tui_types.state -> unit

val clear_keeper_history_projection : Masc_tui_types.state -> unit

val open_message_for_keeper
  :  ?return_to:Masc_tui_types.keeper_chat_return
  -> ?remember_home_chat:bool
  -> Masc_tui_types.state
  -> string
  -> drain_queue:(unit -> unit)
  -> unit

val leave_keeper_message
  :  Masc_tui_types.state
  -> drain_queue:(unit -> unit)
  -> unit

val clear_current_message_draft : Masc_tui_types.state -> unit

val set_composer_text : Masc_tui_types.state -> string -> unit

val image_session_rows
  :  Masc_tui_types.state
  -> Masc_tui_types.msg_entry list

val image_conversation_rows
  :  Masc_tui_types.state
  -> Masc_tui_types.msg_entry list

val image_log_observations
  :  Masc_tui_types.state
  -> ( Masc_tui_keeper_chat_log.journal_source
     * ( Masc_tui_keeper_chat_transcript.drawn_origin
       * Masc_tui_image_preview.preview list )
       list )
     list

val image_preview_candidates
  :  terminal_size:(unit -> int * int)
  -> Masc_tui_types.state
  -> ( Masc_tui_keeper_chat_log.journal_source
     * ( Masc_tui_keeper_chat_transcript.drawn_origin
       * Masc_tui_image_preview.preview list )
       list )
     list
  -> ( Masc_tui_types.chat_search_anchor
     * Masc_tui_image_preview.preview list )
     list

val note_attachment_staged : Masc_tui_types.state -> unit

val recall_older : Masc_tui_types.state -> unit

val recall_newer : Masc_tui_types.state -> unit

val forget_queued_history
  :  Masc_tui_types.state
  -> Masc_tui_keeper_chat_projection.request
  -> unit

val clear_staged_attachments : Masc_tui_types.state -> unit

val drop_unsent_request
  :  Masc_tui_types.state
  -> Masc_tui_keeper_chat_projection.request
  -> bool

val edit_latest_queued_input : Masc_tui_types.state -> unit

val move_recall
  :  Masc_tui_types.state
  -> drain_queue:(unit -> unit)
  -> (Masc_tui_types.state -> unit)
  -> unit

val submit_chat_draft
  :  Masc_tui_types.state
  -> submit_message:(Masc_tui_message_input.snapshot -> unit)
  -> drain_queue:(unit -> unit)
  -> unit
