(** Resource catalog/report reads, revision check confirmation writes,
    and local report save/browser handoff controls. *)

val launch_artifact_checks_load
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val launch_resources_load
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val open_resource_save_prompt : Masc_tui_types.state -> unit

val save_resource_source
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> Masc_tui_types.resource_save_prompt
  -> unit

val open_resource_in_dashboard
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val launch_resources_read
  :  withdraw_diagram:(Masc_tui_types.state -> unit)
  -> Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> key:Masc_tui_resource_catalog.key
  -> unit

val launch_artifact_check_change
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit
