(** Connector snapshot loading, pause unbind offers/execution, and Tools pane
    Docker volume GC requests. *)

val settle_connector_unbind_offers
  :  Masc_tui_types.state
  -> Masc.Tui_decode_connectors.connector_snapshot
  -> unit

val retire_connector_read
  :  Masc_tui_types.state
  -> Masc_tui_types.Connector_read.retirement
  -> unit

val launch_connectors_load
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val reload_connectors_after_write
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val launch_connector_unbind_all
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> keeper_name:string
  -> Masc_tui_connector_unbind.target list
  -> unit

val press_tools_volume_gc
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val settle_volume_gc
  :  Masc_tui_types.state
  -> Masc_tui_volume_gc.request
  -> (Masc_tui_volume_gc.answer, Masc_tui_types.request_failure) result
  -> unit
