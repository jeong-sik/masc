(** Harness calibration labels, verification rejection, task cancellation,
    Keeper creation, repository registration, and schedule forms. *)

val handle_harness_agree
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val handle_harness_overrule
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> terminal_session:Masc_tui_shell.Terminal_session.t
  -> unit

val handle_verification_reject
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> terminal_session:Masc_tui_shell.Terminal_session.t
  -> unit

val handle_task_cancel
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> terminal_session:Masc_tui_shell.Terminal_session.t
  -> unit

val handle_keeper_create
  :  ?return_to:Masc_tui_types.keeper_chat_return
  -> Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> terminal_session:Masc_tui_shell.Terminal_session.t
  -> show_keeper_list:(unit -> unit)
  -> unit

val handle_repository_add
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> terminal_session:Masc_tui_shell.Terminal_session.t
  -> unit

val handle_schedule_create
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> terminal_session:Masc_tui_shell.Terminal_session.t
  -> unit

val handle_schedule_modify
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> terminal_session:Masc_tui_shell.Terminal_session.t
  -> unit
