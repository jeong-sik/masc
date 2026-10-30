open Masc_tui_types

type resolved = {
  row : Masc_tui_approvals_model.approval_row;
  decision : approval_decision;
}

let same_identity left right =
  match left, right with
  | Masc_tui_approvals_model.Keeper_tool_row left, Masc_tui_approvals_model.Keeper_tool_row right ->
      String.equal left.kta_keeper right.kta_keeper
      && String.equal left.kta_tool_call_id right.kta_tool_call_id
  | Masc_tui_approvals_model.Gate_row left, Masc_tui_approvals_model.Gate_row right ->
      String.equal left.Tui_decode.gp_id right.Tui_decode.gp_id
  | Masc_tui_approvals_model.Operator_row left, Masc_tui_approvals_model.Operator_row right ->
      String.equal left.ap_token right.ap_token
  | Masc_tui_approvals_model.Keeper_tool_row _, (Masc_tui_approvals_model.Operator_row _ | Masc_tui_approvals_model.Gate_row _)
  | Masc_tui_approvals_model.Gate_row _, (Masc_tui_approvals_model.Keeper_tool_row _ | Masc_tui_approvals_model.Operator_row _)
  | Masc_tui_approvals_model.Operator_row _, (Masc_tui_approvals_model.Keeper_tool_row _ | Masc_tui_approvals_model.Gate_row _) ->
      false

let resolve ~presented ~current decision =
  Option.bind presented (fun row ->
      Option.map
        (fun current_row -> { row = current_row; decision })
        (List.find_opt (same_identity row) current))

let authority_changed ~presented ~candidate =
  not (Option.equal same_identity presented candidate)
