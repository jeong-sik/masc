(** Skill creation/edit/deletion, async-request lookup, prompt preset overrides,
    and Keeper settings/sandbox editor forms. *)

val handle_skill_create
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> terminal_session:Masc_tui_shell.Terminal_session.t
  -> composition:bool
  -> unit

val handle_skill_source_key
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> terminal_session:Masc_tui_shell.Terminal_session.t
  -> page:int
  -> string
  -> unit

val handle_async_request_lookup
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> terminal_session:Masc_tui_shell.Terminal_session.t
  -> unit

val handle_skill_edit
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> terminal_session:Masc_tui_shell.Terminal_session.t
  -> unit

val handle_skill_delete
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val handle_librarian_input_read
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val handle_prompt_edit
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> terminal_session:Masc_tui_shell.Terminal_session.t
  -> unit

val handle_prompt_clear
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val handle_keeper_settings_edit
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> format:Masc_tui_keeper_config.editor_format
  -> unit

val continue_keeper_settings_editor
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> terminal_session:Masc_tui_shell.Terminal_session.t
  -> input_pending:bool
  -> unit

val set_sandbox_backend
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> profile:Keeper_sandbox_config.sandbox_profile
  -> unit
