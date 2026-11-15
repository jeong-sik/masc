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

type retry_target =
  | Retry_gate of Masc_tui_types.Tui_decode.gate_pending
      (** The presented Gate row, as the current list now holds it. *)
  | Row_gone
      (** The current list holds no row the last frame presented: that frame
          showed none, or the one it showed has left the list. *)
  | Not_retryable
      (** The presented row is still listed, but it is an operator
          confirmation or a held Keeper tool call: Auto Judge never ruled on
          it, so there is nothing to retry. *)

val retry_target :
  presented:Masc_tui_approvals_model.approval_row option ->
  current:Masc_tui_approvals_model.approval_row list ->
  retry_target
(** What [R] acts on, found by the identity last presented like {!resolve}. *)

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
