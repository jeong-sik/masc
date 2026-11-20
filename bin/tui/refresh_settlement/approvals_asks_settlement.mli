(** Confirm-queue (approvals) and Keeper/installation question (asks) settlement. *)

val apply_approvals_load
  :  Masc_tui_types.state
  -> (Masc_tui_types.approval_snapshot, Masc_tui_types.request_failure) result
  -> unit

val apply_asks_load
  :  Masc_tui_types.state
  -> (Masc.Tui_decode_asks.asks_snapshot, string) result
  -> unit

val settle_asks
  :  Masc_tui_types.state
  -> (Masc.Tui_decode_asks.asks_snapshot, string) result
  -> unit

val apply_asks_read
  :  Masc_tui_types.state
  -> (Masc.Tui_decode_asks.asks_snapshot, Masc_tui_types.request_failure) result
  -> unit

val apply_asks_observation : Masc_tui_types.state -> Masc_tui_types.asks_observation -> unit

val admit_approval_listing
  :  Masc_tui_types.state
  -> Masc_tui_operator_projection.Listing_order.ticket
  -> bool

val take_approval_observation
  :  Masc_tui_types.state
  -> Masc_tui_async_protocol.approval_observation
  -> (Masc_tui_types.approval_snapshot, string) result option

val apply_approvals_read
  :  Masc_tui_types.state
  -> (Masc_tui_types.approval_snapshot, Masc_tui_types.request_failure) result
  -> unit

val apply_approval_observation
  :  Masc_tui_types.state
  -> Masc_tui_async_protocol.approval_observation
  -> unit

val apply_approvals_answer
  :  Masc_tui_types.state
  -> (Masc_tui_types.approval_snapshot, Masc_tui_types.request_failure) result
  -> unit

val apply_approval_answer_observation
  :  Masc_tui_types.state
  -> Masc_tui_async_protocol.approval_observation
  -> unit

val dispatch_approvals_listing
  :  Masc_tui_types.state
  -> Masc_tui_operator_projection.Listing_order.ticket option

val apply_approvals_summary_load
  :  Masc_tui_types.state
  -> listing_ticket:Masc_tui_operator_projection.Listing_order.ticket
  -> expected_workspace:Masc.Tui_decode.server_identity
  -> Masc_tui_types.Snapshot_read.request
  -> (Masc_tui_types.approval_snapshot, Masc_tui_types.request_failure) result
  -> unit

val launch_approvals_summary_load
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val launch_owed_pending_confirms
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit
