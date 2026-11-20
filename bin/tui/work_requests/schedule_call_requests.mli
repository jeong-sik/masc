(** Schedule wake/agenda/keeper-schedule loaders, durable keeper call log
    loading, and chat call-detail reader orchestration. *)

val launch_schedule_wake_history_load
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> schedule_id:string
  -> unit

val launch_keeper_schedules_load
  :  ?page:Masc_tui_types.schedule_page
  -> Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> keeper_name:string
  -> unit

val launch_keeper_chat_schedules_load
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> keeper_name:string
  -> unit

val launch_schedules_load
  :  ?intent:Masc_tui_types.Snapshot_read.intent
  -> ?page:Masc_tui_types.schedule_page
  -> Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val launch_schedule_agenda_load
  :  ?intent:Masc_tui_types.Snapshot_read.intent
  -> Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val launch_keeper_calls_load
  :  ?force:bool
  -> Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> string
  -> unit

val cancel_chat_call_pending : Masc_tui_types.state -> unit

val close_chat_call_reader : Masc_tui_types.state -> unit

val launch_chat_call_read
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val open_chat_call_reader
  :  ?execution_id:string
  -> Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> string
  -> unit
