(** Channel connector selection, binding, unbinding, and pause-offer forms. *)

val selected_connector
  :  Masc_tui_types.state
  -> Masc.Tui_decode_connectors.connector option

val handle_connector_bind
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> terminal_session:Masc_tui_shell.Terminal_session.t
  -> unit

val handle_connector_unbind
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> terminal_session:Masc_tui_shell.Terminal_session.t
  -> unit

val handle_connector_unbind_all
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val handle_connector_unbind_offer_accept
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> Masc_tui_connector_unbind.offer
  -> unit

val handle_connector_edit
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> terminal_session:Masc_tui_shell.Terminal_session.t
  -> unit
