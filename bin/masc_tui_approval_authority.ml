open Masc_tui_types

type resolved = {
  row : Masc_tui_approvals_model.approval_row;
  decision : approval_decision;
}

let same_keeper_waiter ~keeper_name ~tool_call_id ~approval_id
    (held : Tui_decode.keeper_tool_approval) =
  String.equal held.kta_keeper keeper_name
  && String.equal held.kta_tool_call_id tool_call_id
  && String.equal held.kta_approval_id approval_id

let same_identity left right =
  match left, right with
  | Masc_tui_approvals_model.Keeper_tool_row left, Masc_tui_approvals_model.Keeper_tool_row right ->
      same_keeper_waiter ~keeper_name:left.kta_keeper
        ~tool_call_id:left.kta_tool_call_id ~approval_id:left.kta_approval_id right
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

let resolve_chat ~presented ~current =
  match presented, current with
  | Some shown, Some current
    when Masc_tui_chat_row_actions.same_approval ~same_scope:same_acting_pane_scope
           shown current -> Some shown
  | Some _, Some _ | None, (Some _ | None) | Some _, None -> None

let after_answer ~keeper_name ~tool_call_id ~approval_id ~result pending =
  match result with
  | Ok { Masc_tui_http.settled = true; _ }
  | Ok { Masc_tui_http.remembered = true; _ } ->
      List.filter
        (fun held ->
          not (same_keeper_waiter ~keeper_name ~tool_call_id ~approval_id held))
        pending
  | Ok { Masc_tui_http.settled = false; remembered = false } | Error _ -> pending
