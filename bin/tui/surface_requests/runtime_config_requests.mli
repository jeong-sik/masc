(** Asynchronous reads and workspace-admitted saves for runtime configuration
    and Keeper settings. *)

val launch_runtime_config_load
  :  ?force:bool
  -> Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val save_runtime_config_text
  :  ?prior_contact:Masc_tui_server_lifecycle.contact
  -> Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> authority:Masc_tui_types.workspace_authority
  -> identity:Masc.Tui_decode.server_identity option
  -> expected_source_path:string
  -> expected_source_revision:string
  -> string
  -> (Masc_tui_runtime_config_receipt.t,
      [ `Kept_back of Masc_tui_types.workspace_refusal
      | `Save of Masc_tui_http.runtime_config_save_error
      ]) result

val launch_keeper_settings_save
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> Masc_tui_types.keeper_settings_save_request
  -> unit

val launch_runtime_form_save
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> Masc_tui_types.runtime_form_save_request
  -> unit

val launch_runtime_params_load
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit
