(** Surface read-debt markers, retry cadence, and arrival read launchers. *)

val owe_held_calls_read : Masc_tui_types.state -> unit
val owe_tool_modes_read : Masc_tui_types.state -> unit
val owe_keeper_turns_read : Masc_tui_types.state -> unit
val owe_keeper_waiting_read : ?change:Masc_tui_types.keeper_waiting_change -> Masc_tui_types.state -> unit
val owe_verification_read : Masc_tui_types.state -> unit
val owe_repositories_read : Masc_tui_types.state -> unit

val pushed_read
  :  Masc_tui_types.state
  -> Masc_tui_types.Surface_read_source.t
  -> Masc_tui_owed_read.t

val set_pushed_read
  :  Masc_tui_types.state
  -> Masc_tui_types.Surface_read_source.t
  -> Masc_tui_owed_read.t
  -> unit

val owe_pushed_read
  :  Masc_tui_types.state
  -> Masc_tui_types.Surface_read_source.t
  -> unit

val owe_provider_history_day : Masc_tui_types.state -> now:float -> unit
val keeper_execute_stream_reconnect_s : float
val keeper_execute_stream_max_reconnect_s : float
val failed_read : Masc_tui_owed_read.t -> Masc_tui_owed_read.t
val placeholder_read : Masc_tui_owed_read.t -> Masc_tui_owed_read.t
val owe_runtime_config_read : Masc_tui_types.state -> unit
val runtime_config_on_screen : Masc_tui_types.state -> bool
val owe_connectors_read : Masc_tui_types.state -> unit
val owe_harness_read : Masc_tui_types.state -> unit

val launch_owed_machine_live
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val launch_owed_browser_observation
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> pointer_active:bool
  -> unit

val launch_owed_lanes
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val launch_owed_lane_addons
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val owe_machine_live_read : Masc_tui_types.state -> Masc.Machine_lane.t -> unit
val owe_memory_health_read : Masc_tui_types.state -> unit
val owe_memory_world_read : Masc_tui_types.state -> unit
val owe_memory_input_read : Masc_tui_types.state -> unit
val owe_overview_read : Masc_tui_types.state -> unit
val owe_goal_projection_reads : Masc_tui_types.state -> unit
val owe_push_owned_revalidation : Masc_tui_types.state -> unit
val owe_dataset_read : Masc_tui_types.state -> Masc.Workspace_dataset_event.dataset -> unit
val owe_async_requests_read : Masc_tui_types.state -> unit

val launch_surface_reads
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> Masc_tui_types.surface
  -> unit
