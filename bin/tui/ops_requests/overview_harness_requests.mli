(** Asynchronous snapshot launchers for Overview, Harness, and Clients
    surfaces. *)

val launch_harness_load
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val launch_overview_load
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val launch_clients_load
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit
