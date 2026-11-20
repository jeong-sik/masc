(** Board compose key handler (external editor launch, attachment staging,
    hearth cycling, and post/comment submission). *)

val handle_board_compose_key
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> ?restore:(unit -> unit)
  -> ?reenter:(unit -> unit)
  -> string
  -> bool
