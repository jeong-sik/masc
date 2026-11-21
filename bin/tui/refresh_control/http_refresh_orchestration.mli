(** Full and scoped HTTP surface refresh dispatch and owed refresh scheduling. *)

type read_authority = {
  read_workspace : Masc_tui_types.workspace_authority;
  read_detail : unit ref;
}

type refresh_hooks = {
  settlement : Server_identity_settlement.hooks;
  observer_browser_scope : Masc_tui_types.state -> Masc.Workspace_dataset_event.browser_scope option;
  current_surface_needs : Masc_tui_types.state -> Masc_tui_types.surface_needs;
}

val read_authority : Masc_tui_types.state -> read_authority

val launch_owed_ask_followup
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val launch_tick_side_reads
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> needs:Masc_tui_types.surface_needs
  -> unit

val log_http_surface_read_finished
  :  Masc_tui_types.state
  -> Masc_tui_types.Surface_read_context.t
  -> unit

val start_http_refresh
  :  hooks:refresh_hooks
  -> server_contact:Masc_tui_transport.Server_contact.t
  -> Masc_tui_types.state
  -> host:string
  -> port:int
  -> intent:Masc_tui_refresh_pace.ask
  -> refresh_inflight:bool ref
  -> scoped_refresh_inflight:bool ref
  -> scoped_refresh_followup:Masc_tui_types.scoped_refresh_followup ref
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val apply_http_scoped_refresh_success
  :  hooks:refresh_hooks
  -> resume_reads_after_authority_change:(server_contact:Masc_tui_transport.Server_contact.t -> Masc_tui_types.state -> mailbox:Masc_tui_transport.Workspace_admission.mailbox -> refresh_inflight:bool ref -> scoped_refresh_inflight:bool ref -> scoped_refresh_followup:Masc_tui_types.scoped_refresh_followup ref -> before:read_authority -> unit)
  -> server_contact:Masc_tui_transport.Server_contact.t
  -> Masc_tui_types.state
  -> currency_authority:Masc_tui_async_protocol.currency_authority_request
  -> base_path:string
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> refresh_inflight:bool ref
  -> scoped_refresh_inflight:bool ref
  -> scoped_refresh_followup:Masc_tui_types.scoped_refresh_followup ref
  -> Masc_tui_async_protocol.http_scoped_surface_results
  -> unit

val start_http_scoped_refresh
  :  hooks:refresh_hooks
  -> resume_reads_after_authority_change:(server_contact:Masc_tui_transport.Server_contact.t -> Masc_tui_types.state -> mailbox:Masc_tui_transport.Workspace_admission.mailbox -> refresh_inflight:bool ref -> scoped_refresh_inflight:bool ref -> scoped_refresh_followup:Masc_tui_types.scoped_refresh_followup ref -> before:read_authority -> unit)
  -> server_contact:Masc_tui_transport.Server_contact.t
  -> Masc_tui_types.state
  -> host:string
  -> port:int
  -> ask:Masc_tui_refresh_pace.screen_ask
  -> refresh_inflight:bool ref
  -> full_refresh_inflight:bool ref
  -> scoped_refresh_followup:Masc_tui_types.scoped_refresh_followup ref
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> needs:Masc_tui_types.surface_needs
  -> unit

val launch_owed_pushed_reads
  :  hooks:refresh_hooks
  -> resume_reads_after_authority_change:(server_contact:Masc_tui_transport.Server_contact.t -> Masc_tui_types.state -> mailbox:Masc_tui_transport.Workspace_admission.mailbox -> refresh_inflight:bool ref -> scoped_refresh_inflight:bool ref -> scoped_refresh_followup:Masc_tui_types.scoped_refresh_followup ref -> before:read_authority -> unit)
  -> server_contact:Masc_tui_transport.Server_contact.t
  -> Masc_tui_types.state
  -> refresh_inflight:bool ref
  -> full_refresh_inflight:bool ref
  -> scoped_refresh_followup:Masc_tui_types.scoped_refresh_followup ref
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val launch_owed_board_list
  :  hooks:refresh_hooks
  -> resume_reads_after_authority_change:(server_contact:Masc_tui_transport.Server_contact.t -> Masc_tui_types.state -> mailbox:Masc_tui_transport.Workspace_admission.mailbox -> refresh_inflight:bool ref -> scoped_refresh_inflight:bool ref -> scoped_refresh_followup:Masc_tui_types.scoped_refresh_followup ref -> before:read_authority -> unit)
  -> server_contact:Masc_tui_transport.Server_contact.t
  -> Masc_tui_types.state
  -> refresh_inflight:bool ref
  -> full_refresh_inflight:bool ref
  -> scoped_refresh_followup:Masc_tui_types.scoped_refresh_followup ref
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val launch_owed_planning
  :  hooks:refresh_hooks
  -> resume_reads_after_authority_change:(server_contact:Masc_tui_transport.Server_contact.t -> Masc_tui_types.state -> mailbox:Masc_tui_transport.Workspace_admission.mailbox -> refresh_inflight:bool ref -> scoped_refresh_inflight:bool ref -> scoped_refresh_followup:Masc_tui_types.scoped_refresh_followup ref -> before:read_authority -> unit)
  -> server_contact:Masc_tui_transport.Server_contact.t
  -> Masc_tui_types.state
  -> refresh_inflight:bool ref
  -> full_refresh_inflight:bool ref
  -> scoped_refresh_followup:Masc_tui_types.scoped_refresh_followup ref
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val start_scoped_refresh_followup
  :  hooks:refresh_hooks
  -> server_contact:Masc_tui_transport.Server_contact.t
  -> Masc_tui_types.state
  -> host:string
  -> port:int
  -> refresh_inflight:bool ref
  -> scoped_refresh_inflight:bool ref
  -> scoped_refresh_followup:Masc_tui_types.scoped_refresh_followup ref
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val launch_owed_refresh_pass
  :  hooks:refresh_hooks
  -> server_contact:Masc_tui_transport.Server_contact.t
  -> Masc_tui_types.state
  -> refresh_inflight:bool ref
  -> scoped_refresh_inflight:bool ref
  -> scoped_refresh_followup:Masc_tui_types.scoped_refresh_followup ref
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit
