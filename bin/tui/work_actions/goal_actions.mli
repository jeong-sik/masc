(** Goal detail inspection, confirmation proof loading, and lifecycle /
    confirmation actions. *)

val goal_detail_on_screen
  :  Masc_tui_types.state
  -> Masc_tui_types.planning_goal option

val goal_detail_action
  :  Masc_tui_types.state
  -> string
  -> Goal_phase.Public_action.t option

val launch_goal_confirmation_read
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> goal_id:string
  -> unit

val goal_kept_back_notice
  :  Masc_tui_types.state
  -> goal_id:string
  -> current:bool
  -> Masc_tui_types.workspace_refusal
  -> string

val start_goal_transition
  :  ?note:string
  -> ?retry_binding:Masc.Tui_decode.goal_retry_binding
  -> Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> goal_id:string
  -> action:Goal_phase.Public_action.t
  -> unit

val handle_goal_confirmation_key
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val handle_goal_action_key
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> action:Goal_phase.Public_action.t
  -> unit
