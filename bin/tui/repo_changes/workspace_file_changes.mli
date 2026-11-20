(** Workspace repository activity, keeper file changes, acting-pane Changes
    tab loading, and Changes keeper cycling. *)

val launch_workspace_activity
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> repo_id:string
  -> unit

val launch_file_changes_load
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> keeper_name:string
  -> unit

val launch_acting_pane_changes_load
  :  ?force:bool
  -> Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> keeper_name:string
  -> unit

val acting_pane_source_current : Masc_tui_types.state -> bool

val launch_keeper_chat_file_changes_load
  :  ?force:bool
  -> Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> keeper_name:string
  -> unit

val launch_keeper_chat_tool_details_load
  :  ?force:bool
  -> Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> keeper_name:string
  -> unit

val cycle_changes_keeper
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> delta:int
  -> unit
