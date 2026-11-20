(** HTTP surface bundle collection and refresh progress timing, without UI
    state reducers. *)

val finish_observed_refresh
  :  Masc_tui_types.state
  -> ticket:Masc_tui_types.Http_refresh_order.ticket
  -> unit

val load_scoped_surface_reads
  :  on_progress:(Masc_tui_types.Http_refresh_progress.event -> unit) option
  -> on_dataset:(Masc.Tui_decode.server_identity -> Masc_tui_async_protocol.http_dataset -> unit) option
  -> surface_request:Masc_tui_types.Surface_read_order.request
  -> ask_request:Masc_tui_types.Snapshot_read.request option
  -> refresh_ticket:Masc_tui_types.Http_refresh_order.ticket
  -> server_identity:(Masc.Tui_decode.server_identity, string) result
  -> host:string
  -> port:int
  -> approval_ticket:Masc_tui_operator_projection.Listing_order.ticket option
  -> board_query:Masc_tui_types.board_query
  -> provider_history_days:int
  -> tool_series_days:int option
  -> needs:Masc_tui_types.surface_needs
  -> unit Masc_tui_async_protocol.http_scoped_surface_readings

val load_surfaces
  :  probe_only:bool
  -> surface_request:Masc_tui_types.Surface_read_order.request
  -> on_initial_identity:(Masc.Tui_decode.server_identity -> Masc_tui_async_protocol.http_read_requests option) option
  -> on_progress:(Masc_tui_types.Http_refresh_progress.event -> unit) option
  -> on_dataset:(Masc.Tui_decode.server_identity -> Masc_tui_async_protocol.http_dataset -> unit) option
  -> on_asks:(Masc.Tui_decode.server_identity -> Masc_tui_types.asks_observation -> unit) option
  -> on_approvals:(Masc.Tui_decode.server_identity -> Masc_tui_async_protocol.approval_observation -> unit) option
  -> on_roster:(Masc.Tui_decode.server_identity -> Masc_tui_types.keeper_roster_observation -> unit) option
  -> ask_request:Masc_tui_types.Snapshot_read.request option
  -> roster_request:Masc_tui_types.Snapshot_read.request option
  -> refresh_ticket:Masc_tui_types.Http_refresh_order.ticket
  -> host:string
  -> port:int
  -> approval_ticket:Masc_tui_operator_projection.Listing_order.ticket option
  -> board_query:Masc_tui_types.board_query
  -> provider_history_days:int
  -> tool_series_days:int option
  -> needs:Masc_tui_types.surface_needs
  -> Masc_tui_async_protocol.http_refresh_outcome
