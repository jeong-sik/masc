open Masc_tui_types

type resolved = {
  row : approval_row;
  decision : approval_decision;
}

let same_identity left right =
  match left, right with
  | Keeper_tool_row left, Keeper_tool_row right ->
      String.equal left.kta_keeper right.kta_keeper
      && String.equal left.kta_tool_call_id right.kta_tool_call_id
  | Operator_row left, Operator_row right ->
      String.equal left.ap_token right.ap_token
  | Keeper_tool_row _, Operator_row _ | Operator_row _, Keeper_tool_row _ ->
      false

let resolve ~presented ~current decision =
  Option.bind presented (fun row ->
      Option.map
        (fun current_row -> { row = current_row; decision })
        (List.find_opt (same_identity row) current))

let authority_changed ~presented ~candidate =
  not (Option.equal same_identity presented candidate)
