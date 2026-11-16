type resolved = private {
  row : Masc_tui_approvals_model.approval_row;
  decision : Masc_tui_types.approval_decision;
}

(** Where the row the last accepted frame presented stands in the current
    list. {!resolve} and {!retry_target} both answer with it, so y/n and [R]
    tell the same three cases apart in the same way. *)
type 'listed target =
  | No_row_presented
      (** The last frame showed no approval row, so a key has nothing to act
          on, whatever the current list holds now. *)
  | Presented_row_gone
      (** The last frame showed a row that the current list no longer holds. *)
  | Listed of 'listed
      (** The presented row, as the current list now holds it. *)

val resolve :
  presented:Masc_tui_approvals_model.approval_row option ->
  current:Masc_tui_approvals_model.approval_row list ->
  Masc_tui_types.approval_decision ->
  resolved target
(** Resolve an approval effect by the identity last presented, never by the
    mutable cursor's current index. Only [Listed] carries an effect. *)

type retry =
  | Retry_gate of Masc_tui_types.Tui_decode.gate_pending
      (** The presented Gate row, as the current list now holds it. *)
  | Not_retryable
      (** The presented row is still listed, but it is an operator
          confirmation or a held Keeper tool call: Auto Judge never ruled on
          it, so there is nothing to retry. *)

val retry_target :
  presented:Masc_tui_approvals_model.approval_row option ->
  current:Masc_tui_approvals_model.approval_row list ->
  retry target
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
  result:(Masc_tui_http.tool_approval_answer, 'error) result ->
  Masc_tui_types.Tui_decode.keeper_tool_approval list ->
  Masc_tui_types.Tui_decode.keeper_tool_approval list
(** Remove only the answered waiter after the server confirms settlement or
    remembrance. Failed and stale answers leave all pending rows intact. *)
