(** Shared composer focus-taking helpers for key and paste/drop handlers. *)

val apply_take_focus
  :  Masc_tui_types.state
  -> base_path:string
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> string
  -> unit

val try_focus_from_key
  :  Masc_tui_types.state
  -> base_path:string
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit
