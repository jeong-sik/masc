(** Lane inventory reads, Machine/Exact activity configuration reads and
    saves, and durable lane run / measurement artifact observation. *)

val launch_lanes_load
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val launch_lanes_reread
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val launch_machine_activity_read
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> Masc_tui_machine_activity.owner
  -> unit

val launch_machine_activity_save
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> Masc_tui_machine_activity.t
  -> unit

val open_machine_activity
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> Masc.Machine_lane.t
  -> unit

val launch_exact_activity_read
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> Masc_tui_exact_activity.owner
  -> unit

val launch_exact_activity_save
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> Masc_tui_exact_activity.t
  -> unit

val open_exact_activity
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> Standalone_lane.t
  -> unit

val launch_lane_runs_load
  :  ?before:(float * string)
  -> Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> lane:Lane_run_identity.t
  -> unit

val launch_lane_run_detail_load
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> run_id:string
  -> unit

val open_lane_run_list
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> Lane_run_identity.t
  -> unit

val open_selected_lane_run
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> lane:Lane_run_identity.t
  -> unit

val launch_measurement_artifact_load
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> sha256:string
  -> unit

val open_measurement_artifact
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> sha256:string
  -> unit
