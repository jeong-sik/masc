(** Keeper lifecycle action gate, step execution, and result settlement. *)

val apply_keeper_action_result
  :  Masc_tui_types.state
  -> base_path:string
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> string
  -> Masc_tui_keeper_control.action
  -> (Masc_tui_keeper_control.outcome, Masc_tui_keeper_control.failure) result
  -> unit

val no_keeper_under_cursor : ko:bool -> string

val handle_keeper_action
  :  Masc_tui_types.state
  -> base_path:string
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> Masc_tui_keeper_control.action
  -> unit
