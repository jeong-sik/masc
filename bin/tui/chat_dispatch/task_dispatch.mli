(** Original task / verification inspection readers and /task creation
    dispatch. *)

val cancel_task_inspection_read : Masc_tui_types.state -> unit

val close_task_inspection_reader : Masc_tui_types.state -> unit

val launch_task_creation_read
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val launch_original_task_read
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val launch_original_history_read
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> earlier:bool
  -> limit:int
  -> unit

val launch_original_evidence_read
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> next:bool
  -> unit

val launch_task_dispatch
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> keeper_name:string
  -> title:string
  -> body:string
  -> original:string
  -> unit
