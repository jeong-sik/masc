(** Audio/MIDI playback and music-editor preparation from chat attachments. *)

val listen_newest_media
  :  ?destination:Masc_tui_types.listen_destination
  -> Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> media:Masc_tui_chat_media.t list
  -> unit

val withdraw_pending_music_editor : Masc_tui_types.state -> unit
