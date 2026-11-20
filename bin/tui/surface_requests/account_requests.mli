(** Account login state persistence and asynchronous login/setup actions. *)

val remember_account_login
  :  Masc_tui_types.state
  -> Masc_tui_account_login.t
  -> unit

val restore_account_login
  :  Masc_tui_types.state
  -> Masc_tui_account_login.t
  -> unit

val launch_account_login_action
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> Masc_tui_account_login.t
  -> Masc_tui_account_login.action
  -> unit
