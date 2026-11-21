(** Server identity settlement, workspace authority transitions, and refresh outcome application. *)

type hooks = {
  withdraw_diagram : Masc_tui_types.state -> unit;
  retire_remote_image : Masc_tui_types.state -> unit;
  settle_retired_sent_image : Masc_tui_types.state -> unit;
  withdraw_keeper_presentation :
    Masc_tui_types.state ->
    previous:Masc_tui_types.workspace_input_identity option ->
    keep_detail_navigation:bool ->
    draft:Masc_tui_message_input.snapshot ->
    unit;
}

val selected_planning_goal_id : Masc_tui_types.state -> string option

val apply_server_identity_reading
  :  ?withdraw_on_error:bool
  -> hooks:hooks
  -> Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> (Masc.Tui_decode.server_identity, string) result
  -> unit

val apply_refused_workspace_identity
  :  hooks:hooks
  -> Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> detail:string
  -> (Masc.Tui_decode.server_identity, string) result option
  -> unit

val apply_http_scoped_surfaces
  :  hooks:hooks
  -> Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> currency_authority:Masc_tui_async_protocol.currency_authority_request
  -> Masc_tui_async_protocol.http_scoped_surface_results
  -> bool

val resume_authorized_input_after_refresh
  :  Masc_tui_types.state
  -> was_unavailable:bool
  -> base_path:string
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val apply_http_scoped_refresh_failure
  :  hooks:hooks
  -> Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> refresh_ticket:Masc_tui_types.Http_refresh_order.ticket
  -> approval_ticket:Masc_tui_operator_projection.Listing_order.ticket option
  -> latest:(Masc.Tui_decode.server_identity, string) result option
  -> Masc_tui_types.request_failure
  -> unit

val apply_http_surfaces
  :  hooks:hooks
  -> Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> Masc_tui_async_protocol.http_surface_results
  -> unit

val apply_server_booting
  :  hooks:hooks
  -> Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> refresh_ticket:Masc_tui_types.Http_refresh_order.ticket
  -> identity:(Masc.Tui_decode.server_identity, string) result
  -> approval_ticket:Masc_tui_operator_projection.Listing_order.ticket option
  -> unit

val apply_account_server
  :  hooks:hooks
  -> server_contact:Masc_tui_transport.Server_contact.t
  -> Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> refresh_ticket:Masc_tui_types.Http_refresh_order.ticket
  -> version:string
  -> approval_ticket:Masc_tui_operator_projection.Listing_order.ticket option
  -> unit

val apply_workspace_unconfirmed
  :  hooks:hooks
  -> Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> detail:string
  -> unreachable:bool
  -> approval_ticket:Masc_tui_operator_projection.Listing_order.ticket option
  -> latest_identity:(Masc.Tui_decode.server_identity, string) result
  -> unit

val apply_http_refresh_outcome
  :  hooks:hooks
  -> server_contact:Masc_tui_transport.Server_contact.t
  -> Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> Masc_tui_async_protocol.http_refresh_outcome
  -> unit
