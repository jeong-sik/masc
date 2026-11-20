(** Bracketed-paste spill staging and dropped-image attachment for the composer. *)

val attach_dropped_image
  :  ?protect_recovered:bool
  -> Masc_tui_types.state
  -> base_path:string
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> Masc_tui_keeper_chat_projection.attachment
  -> unit

val handle_paste
  :  ?protect_recovered:bool
  -> Masc_tui_types.state
  -> base_path:string
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> paste:Masc_tui_paste.t
  -> unit
