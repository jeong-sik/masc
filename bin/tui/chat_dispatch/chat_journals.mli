(** Keeper chat navigation, copy-reply read, journal / operation reads,
    runtime catalog loading, and Context Inspector reads. *)

val enter_keeper_chat
  :  ?return_to:Masc_tui_types.keeper_chat_return
  -> Masc_tui_types.state
  -> keeper_name:string
  -> drain_queue:(unit -> unit)
  -> load_history:(string -> unit)
  -> unit

val prepare_item_request
  :  Masc_tui_types.state
  -> drain_queue:(unit -> unit)
  -> load_history:(string -> unit)
  -> unit

val settle_retired_chat_copy : Masc_tui_types.state -> unit

val launch_keeper_chat_copy
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> keeper_name:string
  -> unit

val apply_keeper_chat_operation_state
  :  Masc_tui_types.state
  -> journal_id:string
  -> Masc_tui_types.turn_log
  -> (Keeper_chat_operation.state option, Masc_tui_types.request_failure) result
  -> unit

val launch_unavailable_journal_operations
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> keeper_name:string
  -> unit

val launch_selected_preparation_operation_read
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val launch_keeper_chat_journal_loads
  :  ?follow:bool
  -> Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> keeper_name:string
  -> ( Masc_tui_keeper_chat_log.journal_source
     * float
     * Masc.Keeper_chat_event_log.replay_position )
     list
  -> unit

val launch_current_autonomous_journals
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> keeper_name:string
  -> unit

val launch_runtime_catalog_load
  :  ?intent:Masc_tui_types.Snapshot_read.intent
  -> Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val launch_context_inspector_load
  :  ?forecast:(Masc_tui_context_inspector.forecast, string) result
  -> ?reuse:bool
  -> Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> keeper_name:string
  -> unit

val reconcile_context_inspector_part
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val open_context_inspector
  :  ?target:Masc_tui_context_inspector.target
  -> Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> keeper_name:string
  -> unit

val switch_to_next_keeper_message
  :  Masc_tui_types.state
  -> drain_queue:(unit -> unit)
  -> load_history:(string -> unit)
  -> unit
