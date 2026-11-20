(** Fusion runs, launch presets, observer recovery, and guarded launch
    submission. *)

val launch_fusion_runs_load
  :  ?demand:Masc_tui_fusion_updates.demand
  -> Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val revalidate_visible_fusion
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val resume_fusion_after_observer_failure
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val launch_fusion_launch_options_load
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val start_fusion_run
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> request:Masc_tui_fusion_launch.request
  -> unit
