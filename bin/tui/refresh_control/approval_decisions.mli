(** Operator approval decisions, ask-origin toggle, and identity notices. *)

val apply_approval_decision_completion
  :  Masc_tui_types.state
  -> Masc_tui_operator_projection.Flow.generation
  -> Masc_tui_operator_projection.approval_item
  -> Masc_tui_operator_projection.approval_decision
  -> (Masc_tui_operator_projection.confirm_outcome, Masc_tui_types.request_failure) result
  -> (Masc_tui_operator_projection.approval_snapshot, string) result
  -> unit

val handle_approval_decision
  :  Masc_tui_types.state
  -> Masc_tui_operator_projection.approval_item
  -> Masc_tui_operator_projection.approval_decision
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit

val toggle_selected_ask_origin : Masc_tui_types.state -> unit

val present_identity_notice
  :  Masc_tui_types.state
  -> keeper_name:string option
  -> Masc_tui_identity_model.identity_notice_kind * string
  -> unit
