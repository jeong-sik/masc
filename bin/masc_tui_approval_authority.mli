type resolved = private {
  row : Masc_tui_approvals_model.approval_row;
  decision : Masc_tui_types.approval_decision;
}

val resolve :
  presented:Masc_tui_approvals_model.approval_row option ->
  current:Masc_tui_approvals_model.approval_row list ->
  Masc_tui_types.approval_decision ->
  resolved option
(** Resolve an approval effect by the identity last presented, never by the
    mutable cursor's current index. A presented identity absent from [current]
    produces no effect. *)

val authority_changed :
  presented:Masc_tui_approvals_model.approval_row option ->
  candidate:Masc_tui_approvals_model.approval_row option ->
  bool
(** Whether a candidate frame carries a different operator token or Keeper
    [(keeper, tool_call_id, approval_id)] than the last accepted frame. *)

val resolve_chat :
  presented:(Masc_tui_types.workspace_authority * unit ref)
    Masc_tui_chat_row_actions.approval option ->
  current:(Masc_tui_types.workspace_authority * unit ref)
    Masc_tui_chat_row_actions.approval option ->
  (Masc_tui_types.workspace_authority * unit ref)
    Masc_tui_chat_row_actions.approval option
(** A slash-command decision belongs to the prompt in an accepted frame.
    A missing or replaced prompt grants no authority. *)

val after_answer :
  keeper_name:string ->
  tool_call_id:string ->
  approval_id:string ->
  result:(Masc_tui_http.tool_approval_answer, string) result ->
  Masc_tui_types.Tui_decode.keeper_tool_approval list ->
  Masc_tui_types.Tui_decode.keeper_tool_approval list
(** Remove only the answered waiter after the server confirms settlement or
    remembrance. Failed and stale answers leave all pending rows intact. *)
