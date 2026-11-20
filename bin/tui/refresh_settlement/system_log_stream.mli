(** Server system log stream lifecycle and in-flight read snapshot. *)

type reads_in_flight

val refresh_client_system_logs : Masc_tui_types.state -> unit

val reconcile_system_log_stream
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val reads_in_flight : Masc_tui_types.state -> reads_in_flight

val take_system_log_stream
  :  Masc_tui_types.state
  -> Masc_tui_types.system_log_follow
  -> Masc_tui_types.system_log_follow_event
  -> unit

val refresh_system_logs_source : Masc_tui_types.state -> unit
