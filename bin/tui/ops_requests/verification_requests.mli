(** Verification list row reset and guarded snapshot load launcher. *)

val reset_verification_rows : Masc_tui_types.state -> unit

val launch_verification_load
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit
