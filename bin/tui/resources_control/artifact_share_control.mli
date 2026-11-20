(** Published report external-share intents, recovery lookup, and
    settlement helpers. *)

val open_resource_report
  :  Masc_tui_types.state
  -> (Masc_tui_resource_catalog.report, string) result

val report_resource_share_kept_back
  :  Masc_tui_types.state
  -> Masc_tui_types.resource_share_request
  -> Masc_tui_types.workspace_refusal
  -> unit

val toggle_resource_external_share
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> dispatch_allowed:(unit -> bool)
  -> unit

val recover_resource_external_share
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> confirm:bool
  -> dispatch_allowed:(unit -> bool)
  -> unit

val resource_share_is_owned
  :  Masc_tui_types.state
  -> Masc_tui_types.resource_share_request
  -> bool

val resource_public_copy_is_current
  :  Masc_tui_types.state
  -> Masc_tui_types.resource_public_copy
  -> bool

val finish_resource_share
  :  withdraw_diagram:(Masc_tui_types.state -> unit)
  -> Masc_tui_types.state
  -> Masc_tui_types.resource_share_request
  -> (Masc_tui_types.resource_share_outcome, Masc_tui_types.resource_share_failure) result
  -> Masc_tui_resource_catalog.key option
