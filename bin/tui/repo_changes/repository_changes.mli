(** Repository change-list and working-tree diff launchers, panel state
    transitions, and Code surface navigation helpers. *)

val tree_diff_base_ref : string

val pr_number_of_subject : string -> int option

val repository_change_scope_equal
  :  Masc.Tui_decode.repository_change_scope
  -> Masc.Tui_decode.repository_change_scope
  -> bool

val launch_repository_changes_load
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> scope:Masc.Tui_decode.repository_change_scope
  -> unit

val launch_repository_changes_diff_load
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> scope:Masc.Tui_decode.repository_change_scope
  -> path:string
  -> unit

val open_repository_change_diff
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> scope:Masc.Tui_decode.repository_change_scope
  -> Masc.Tui_decode.repository_change
  -> unit

val close_repository_changes_diff : Masc_tui_types.state -> unit

val open_repository_changes
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> scope:Masc.Tui_decode.repository_change_scope
  -> unit

val refresh_repository_changes
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val open_repository_change_in_code
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> scope:Masc.Tui_decode.repository_change_scope
  -> Masc.Tui_decode.repository_change
  -> unit

val step_code_back
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> leave:(unit -> unit)
  -> unit
