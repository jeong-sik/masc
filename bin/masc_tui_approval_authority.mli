type resolved = private {
  row : Masc_tui_types.approval_row;
  decision : Masc_tui_types.approval_decision;
}

val resolve :
  presented:Masc_tui_types.approval_row option ->
  current:Masc_tui_types.approval_row list ->
  Masc_tui_types.approval_decision ->
  resolved option
(** Resolve an approval effect by the identity last presented, never by the
    mutable cursor's current index. A presented identity absent from [current]
    produces no effect. *)

val authority_changed :
  presented:Masc_tui_types.approval_row option ->
  candidate:Masc_tui_types.approval_row option ->
  bool
(** Whether a candidate frame carries a different operator token or Keeper
    [(keeper, tool_call_id)] than the last accepted frame. *)
