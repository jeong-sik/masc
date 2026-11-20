(** Queueing, /steer interruption, run-next reordering, and Keeper chat
    dispatch coordination. *)

val launch_keeper_interrupt
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> Masc_tui_keeper_chat_projection.request
  -> unit

val interrupt_observed_keeper
  :  ?explicit:bool
  -> Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> string
  -> bool option

val interrupt_active_chat_turn
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> bool

val run_next_busy_for : Masc_tui_types.state -> string -> bool

val queue_run_next_on_admission
  :  ?automatic:bool
  -> Masc_tui_types.state
  -> Masc_tui_keeper_chat_projection.request
  -> unit

val add_auto_priority_request
  :  Masc_tui_types.state
  -> Masc_tui_keeper_chat_projection.request
  -> unit

val launch_keeper_run_next
  :  ?automatic:bool
  -> Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> Masc_tui_keeper_chat_projection.request
  -> unit

val dispatch_ready_run_next
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> string
  -> unit

val inflight_for
  :  Masc_tui_types.state
  -> string
  -> Masc_tui_keeper_chat_projection.request option

val launch_keeper_request
  :  promoted:Masc_tui_keeper_chat_queue.item
  -> ?admission_intent:Masc_tui_keeper_chat_projection.admission_intent
  -> Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> Masc_tui_keeper_chat_projection.request
  -> unit

val update_queued_history_text
  :  Masc_tui_types.state
  -> Masc_tui_keeper_chat_projection.request
  -> unit

val dispatch_waiting_keeper_input
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> keeper_name:string
  -> Masc_tui_types.drawn_effect

val launch_waiting_keeper_input
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> keeper_name:string
  -> unit

val start_keeper_steer
  :  ?keeper_name:string
  -> ?spill:Masc_tui_types.saved_message_spill
  -> Masc_tui_types.state
  -> base_path:string
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> string
  -> unit

val start_keeper_message
  :  ?keeper_name:string
  -> ?spill:Masc_tui_types.saved_message_spill
  -> Masc_tui_types.state
  -> base_path:string
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> string
  -> unit

val drain_queued_message
  :  Masc_tui_types.state
  -> base_path:string
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit
