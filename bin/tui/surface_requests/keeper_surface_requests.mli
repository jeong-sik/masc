(** Keeper detail surface reads, deletion retries, settings-editor preparation,
    items account revision tracking, sandbox logs, efficiency, and board
    quarantine requeues. *)

type item_revision_snapshot

val launch_keeper_deletions
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> ?retry:Masc_tui_keeper_control.deletion_row
  -> unit
  -> unit

val launch_keeper_config_view
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> string
  -> unit

val withdraw_keeper_items : Masc_tui_types.state -> unit

val keeper_settings_editor_available : Masc_tui_types.state -> bool

val log_keeper_settings_read
  :  phase:string
  -> Masc_tui_types.keeper_settings_request
  -> outcome:string
  -> unit

val launch_keeper_settings_editor_read
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> Masc_tui_types.keeper_settings_request
  -> unit

val launch_keeper_items
  :  ?keep_observed_account:bool
  -> Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> string
  -> unit

val visible_item_revision
  :  Masc_tui_types.state
  -> item_revision_snapshot

val refresh_changed_keeper_items
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> roster_refreshed:bool
  -> item_revision_snapshot
  -> unit

val launch_keeper_sandbox_view
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> string
  -> unit

val launch_keeper_sandbox_logs
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> string
  -> unit

val launch_keeper_board_quarantines
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> string
  -> unit

val launch_keeper_efficiency
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val board_requeue_kept_back_count : ko:bool -> int -> string

val launch_board_quarantine_requeue
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> keeper_name:string
  -> Masc.Keeper_board_attention_quarantine_command.inventory_item
  -> unit

val launch_board_quarantines_bulk_requeue
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> keeper_name:string
  -> Masc.Keeper_board_attention_quarantine_command.inventory_item list
  -> unit
