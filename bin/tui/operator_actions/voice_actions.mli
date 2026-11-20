(** Keeper voice recording failure reporting and background microphone capture
    launchers. *)

val report_voice_failure
  :  Masc_tui_types.state
  -> keeper:string
  -> string
  -> unit

val launch_voice_capture
  :  ?calibrate:bool
  -> Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> keeper:string
  -> unit

val rearm_continuous_capture
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> keeper:string
  -> unit
