(** Keeper chat transcript, native tasks, child content, composite, and calls owed-read launchers. *)

val launch_keeper_older_page
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> keeper_name:string
  -> cursor:string option
  -> unit

val launch_keeper_native_tasks_load
  :  ?mode:Masc_tui_native_tasks.read_mode
  -> Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> keeper_name:string
  -> unit

val launch_keeper_child_content_load
  :  ?mode:Masc_tui_child_content.read_mode
  -> Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> keeper_name:string
  -> unit

val update_history_owed
  :  ?audit:bool
  -> Masc_tui_types.state
  -> keeper_name:string
  -> (Masc_tui_owed_read.t -> Masc_tui_owed_read.t)
  -> unit

val launch_keeper_history_load
  :  ?load_file_changes:bool
  -> ?force:bool
  -> Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> keeper_name:string
  -> unit

val launch_owed_history
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val launch_owed_fusion
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val settle_composite_owed
  :  Masc_tui_types.state
  -> keeper_name:string
  -> (Masc_tui_owed_read.t -> Masc_tui_owed_read.t)
  -> unit

val launch_owed_keeper_composite
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val owe_keeper_composite_read
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> keeper_name:string
  -> unit

val settle_calls_owed
  :  Masc_tui_types.state
  -> keeper_name:string
  -> (Masc_tui_owed_read.t -> Masc_tui_owed_read.t)
  -> unit

val launch_owed_keeper_calls
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val owe_keeper_calls_read
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> keeper_name:string
  -> unit
