(** Play-room spectator polling/sending and live machine view progression. *)

val poll_play_room
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val send_play_room
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val msx_frame_of_live
  :  previous_live:Masc_tui_machine_live.view
  -> previous_frame:Masc_tui_types.msx_frame option
  -> Masc_tui_machine_live.view
  -> Masc_tui_machine_live.view * Masc_tui_types.msx_frame option

val advance_machine_live
  :  Masc_tui_types.state
  -> request:Masc_tui_words.Kept_request.t
  -> Masc_tui_machine_live.view
  -> (Masc_tui_machine_live.answer, Masc_tui_types.request_failure) result
  -> Masc_tui_machine_live.view option

val with_msx_observation
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> request:Masc_tui_words.Kept_request.t
  -> (unit -> 'a)
  -> ('a -> unit)
  -> unit

val observe_msx_carts
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit
