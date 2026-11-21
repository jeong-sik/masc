(** Runtime configuration documents, lane declaration forms, model/account
    forms, recall/exclusion forms, slot config jumps, and runtime params. *)

val handle_lane_document_editor
  :  Masc_tui_types.state
  -> terminal_session:Masc_tui_shell.Terminal_session.t
  -> unit

val select_lane_document
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> Masc_tui_lane_addons.t
  -> unit

val handle_runtime_config_edit
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> terminal_session:Masc_tui_shell.Terminal_session.t
  -> unit

val handle_runtime_config_draft
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> string
  -> unit

val handle_model_form_open
  :  Masc_tui_types.state
  -> Masc_tui_model_form.mode
  -> unit

val handle_runtime_account_open : Masc_tui_types.state -> unit

val handle_typesafeai_exclusion_form_open : Masc_tui_types.state -> unit

val submit_typesafeai_exclusion_form
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> Masc_tui_typesafeai_exclusion_form.t
  -> unit

val open_runtime_model_settings
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> string
  -> unit

val open_selected_slot_config
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val handle_runtime_param_edit_open
  :  Masc_tui_types.state
  -> advanced:bool
  -> unit

val handle_runtime_param_edit_apply
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val handle_runtime_param_clear
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit
