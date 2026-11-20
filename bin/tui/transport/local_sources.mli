(** Local workspace source reads (keepers and work backlog) and live Keeper
    context loading with supersession and workspace cancellation ownership. *)

val launch_keeper_read
  :  Masc_tui_types.state
  -> mailbox:Workspace_admission.mailbox
  -> intent:Masc_tui_types.Snapshot_read.intent
  -> string
  -> unit

val launch_work_read
  :  Masc_tui_types.state
  -> mailbox:Workspace_admission.mailbox
  -> intent:Masc_tui_types.Snapshot_read.intent
  -> string
  -> unit

val launch_workspace_read
  :  Masc_tui_types.state
  -> mailbox:Workspace_admission.mailbox
  -> intent:Masc_tui_types.Snapshot_read.intent
  -> string
  -> unit

val launch_followup
  :  Masc_tui_types.state
  -> mailbox:Workspace_admission.mailbox
  -> Masc_tui_types.local_read_source
  -> unit

val observe_source
  :  Masc_tui_types.state
  -> source:Masc_tui_types.local_read_source
  -> is_observed:('a -> bool)
  -> Masc_tui_types.local_workspace_request
  -> ('a, string) result
  -> ('a, string) result option

val log_live_context_read
  :  phase:string
  -> Masc_tui_context_state.request
  -> started_ns:int64
  -> outcome:string
  -> unit

val launch_current_live_context
  :  Masc_tui_types.state
  -> mailbox:Workspace_admission.mailbox
  -> bool

val reconcile_live_context
  :  Masc_tui_types.state
  -> mailbox:Workspace_admission.mailbox
  -> bool
