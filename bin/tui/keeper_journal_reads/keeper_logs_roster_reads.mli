(** Keeper metrics/logs, execute output stream, and Keeper roster owed-read launchers. *)

val log_keeper_log_read
  :  phase:string
  -> Masc_tui_types.keeper_log_request
  -> outcome:string
  -> unit

val settle_logs_owed
  :  Masc_tui_types.state
  -> keeper_name:string
  -> (Masc_tui_owed_read.t -> Masc_tui_owed_read.t)
  -> unit

val launch_current_keeper_logs
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> intent:Masc_tui_types.Snapshot_read.intent
  -> bool

val launch_owed_keeper_logs
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val owe_keeper_logs_read
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> keeper_name:string
  -> unit

val reconcile_keeper_logs
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> bool

val owe_whole_keeper_roster_read : Masc_tui_types.state -> unit

val owe_keeper_roster_change
  :  Masc_tui_types.state
  -> Masc_tui_observer.roster_change
  -> unit

val fail_keeper_roster_read : Masc_tui_types.state -> Masc_tui_roster_owed.read -> unit

val launch_owed_keeper_roster
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> needs_keeper_roster:bool
  -> unit
