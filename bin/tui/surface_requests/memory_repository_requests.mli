(** Runtime surface, repository list, Keeper memory health/input/turns,
    and per-keeper/fleet memory fact loaders. *)

val launch_runtime_surface_load
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> force:bool
  -> unit

val launch_repositories_load
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val launch_memory_input_load
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> refresh:bool
  -> unit

val launch_keeper_story_turns_load
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> keeper_name:string
  -> refresh:bool
  -> unit

val launch_memory_activity_read
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> keeper_name:string
  -> refresh:bool
  -> (string, 'a) Masc_tui_fetched.t
  -> Masc_tui_owed_read.t
  -> set_source:((string, 'a) Masc_tui_fetched.t -> unit)
  -> set_owed:(Masc_tui_owed_read.t -> unit)
  -> deliver:(string Masc_tui_fetched.request -> ('b, Masc_tui_types.request_failure) result -> Masc_tui_async_protocol.keeper_msg)
  -> (unit -> ('b, string) result)
  -> unit

val launch_memory_health_load
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val launch_owed_memory_health_row
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val launch_memory_facts_load
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> keeper_name:string
  -> unit

val launch_all_memory_facts_load
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val open_all_fleet_memory
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val launch_memory_act
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> keeper:string
  -> Masc.Tui_decode_memory_act.act
  -> unit
