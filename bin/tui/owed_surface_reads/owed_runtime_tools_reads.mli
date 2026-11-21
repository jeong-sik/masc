(** Engine, Memory, Harness, Verification, Keeper-turns, Tools, and Schedules owed-read launchers. *)

val launch_engine_sample_read
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val launch_owed_memory_health
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val launch_owed_memory_world
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val launch_owed_memory_input
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val launch_owed_identity_logins
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val launch_owed_clients
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val launch_owed_harness
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val launch_owed_verification
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val launch_owed_keeper_turns
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val launch_owed_keeper_waiting
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val launch_owed_tool_modes
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val launch_owed_async_requests
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val owe_tools_async_detail_read : Masc_tui_types.state -> string -> unit
val owe_selected_tools_async_detail_read : Masc_tui_types.state -> unit

val launch_owed_tools_async_detail
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val owe_tools_async_task_read : Masc_tui_types.state -> unit

val launch_owed_tools_async_task
  :  terminal_size:(unit -> int * int)
  -> Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val launch_owed_tools
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val owe_schedules_read : Masc_tui_types.state -> unit
val owe_agenda_revalidation : Masc_tui_types.state -> unit
val settled_schedule_read : Masc_tui_owed_read.t -> ('a, 'b) result -> Masc_tui_owed_read.t

val launch_owed_schedules
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit
