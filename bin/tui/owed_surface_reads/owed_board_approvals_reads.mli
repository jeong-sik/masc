(** Board, Planning, Approvals, Overview, Connectors, Runtime, and Repositories owed-read launchers. *)

val board_post_on_screen : Masc_tui_types.state -> string option

val settle_board_post_owed
  :  Masc_tui_types.state
  -> post_id:string
  -> (Masc_tui_owed_read.t -> Masc_tui_owed_read.t)
  -> unit

val launch_owed_board_post
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val owe_board_post_read
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> post_id:string
  -> unit

val owe_board_list_read : Masc_tui_types.state -> unit
val unanswered_read : Masc_tui_owed_read.t -> Masc_tui_owed_read.t
val owe_planning_reads : Masc_tui_types.state -> unit
val note_owed_surface_reads_started : Masc_tui_types.state -> Masc_tui_types.surface_needs -> unit
val note_pushed_reads_started : Masc_tui_types.state -> Masc_tui_types.surface_needs -> unit
val owe_asks_read : Masc_tui_types.state -> unit
val owe_pending_confirms_read : Masc_tui_types.state -> unit

val launch_owed_asks
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val owe_gate_snapshot_read : Masc_tui_types.state -> unit
val fail_gate_snapshot_read : Masc_tui_types.state -> unit

val launch_owed_gate_snapshot
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val launch_owed_held_calls
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val launch_owed_connectors
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val launch_owed_overview
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val launch_owed_runtime_surface
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val launch_owed_runtime_config
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val launch_owed_repositories
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit
