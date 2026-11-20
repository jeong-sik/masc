(** Collab overlay notices, invite refresh, and play-invite issue/revoke launchers. *)

val collab_notice
  :  Masc_tui_types.state
  -> unit ref
  -> kind:Chat_notice.notice_kind
  -> string
  -> unit

val play_notice
  :  Masc_tui_types.state
  -> sink:Masc_tui_async_protocol.play_sink
  -> kind:Chat_notice.notice_kind
  -> string
  -> unit

val settle_play_mutation
  :  Masc_tui_types.state
  -> Masc_tui_async_protocol.play_sink
  -> unit

val sync_collab_access : Masc_tui_types.state -> unit

val refresh_collab
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit ref
  -> unit

val refresh_current_collab
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val open_collab
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val launch_play_issue
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> sink:Masc_tui_async_protocol.play_sink
  -> name:string
  -> hours:int
  -> bool

val launch_play_revoke
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> sink:Masc_tui_async_protocol.play_sink
  -> name:string
  -> bool
