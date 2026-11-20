(** Chat operation sequence tracking, dispatch watchers, and Keeper
    preparation / waiting / turns launchers. *)

val next_chat_operation_seq : Masc_tui_types.state -> string -> int

val append_chat_history
  :  ?at:float
  -> ?submitted_at:float
  -> ?turn_phase:Masc_tui_types.chat_turn_phase
  -> ?operation_seq:int
  -> Masc_tui_types.state
  -> Masc_tui_keeper_chat_projection.request
  -> Masc_tui_types.msg_role
  -> string
  -> unit

val append_user_history_once
  :  submitted_at:float
  -> Masc_tui_types.state
  -> Masc_tui_keeper_chat_projection.request
  -> unit

val enqueue_dispatch_ack
  :  enqueue:
       (Masc_tui_transport.Workspace_admission.mailbox
        -> Masc_tui_async_protocol.async_msg
        -> unit)
  -> Masc_tui_transport.Workspace_admission.mailbox
  -> (unit Eio.Promise.u -> Masc_tui_async_protocol.async_msg)
  -> unit

val enqueue_dispatch_start
  :  enqueue:
       (Masc_tui_transport.Workspace_admission.mailbox
        -> Masc_tui_async_protocol.async_msg
        -> unit)
  -> Masc_tui_transport.Workspace_admission.mailbox
  -> Masc_tui_keeper_chat_projection.request
  -> bool
  -> bool

val post_keeper_chat_watching
  :  waiting_inventory:Masc_tui_waiting_inventory.t
  -> expected_workspace:Masc.Tui_decode.server_identity
  -> check_request:(unit -> (unit, Masc_tui_types.workspace_refusal) result)
  -> start_first_post:(unit -> bool)
  -> follow_kept_back:
       (Masc_tui_types.workspace_refusal -> Masc_tui_keeper_chat_projection.error)
  -> enqueue:
       (Masc_tui_transport.Workspace_admission.mailbox
        -> Masc_tui_async_protocol.async_msg
        -> unit)
  -> control_generation:int
  -> admission_intent:Masc_tui_keeper_chat_projection.admission_intent
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> port:int
  -> log:Masc_tui_keeper_chat_log.t
  -> Masc_tui_keeper_chat_projection.request
  -> Masc_tui_types.keeper_chat_dispatch

val launch_keeper_preparation_load
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> bool

val launch_keeper_waiting_load
  :  ?change:Masc_tui_types.keeper_waiting_change
  -> ?exclusive:bool
  -> Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val launch_keeper_turns_load
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit
