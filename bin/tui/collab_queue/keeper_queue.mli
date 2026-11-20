(** Keeper queue panel / inbox inspection, priority updates, and directive
    launchers. *)

val settle_retired_queue_inspections : Masc_tui_types.state -> unit

val launch_keeper_queue
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> keeper_name:string
  -> Masc_tui_queue_inspection.action
  -> unit

val open_keeper_queue_panel
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> keeper_name:string
  -> unit

val refresh_queue_after_priority
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> keeper_name:string
  -> unit
