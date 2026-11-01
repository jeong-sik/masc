open Fixture_types
module Masc_tui_keeper_control = Control_baseline
module Masc_tui_keeper_list_model = Model
let keeper_reading (state : state) (keeper : keeper) :
    Masc_tui_keeper_control.reading =
  { name = keeper.k_name
  ; paused = keeper.k_paused
  ; liveness =
      (match keeper.k_origin with
       | Tui_decode.Declared_keeper _ -> Masc_tui_keeper_control.Absent
       | Persisted_keeper | Remote_keeper ->
         Masc_tui_keeper_control.liveness_of_roster state.keeper_roster keeper.k_name)
  }

let keeper_open_question_count state keeper_name =
  match state.asks_snapshot with
  | None -> 0
  | Some snapshot ->
      List.fold_left
        (fun count row ->
          match row.Masc.Tui_decode_asks.ar_asker with
          | Masc.Tui_decode_asks.Ask_keeper name when String.equal name keeper_name -> count + 1
          | Masc.Tui_decode_asks.Ask_keeper _ | Masc.Tui_decode_asks.Ask_installation _ -> count)
        0 snapshot.Masc.Tui_decode_asks.asn_rows

let keeper_list_rows (state : state) : Masc_tui_keeper_list_model.row list =
  List.map
    (fun (keeper : keeper) ->
      let name = keeper.k_name in
      let turn =
        List.find_map
          (fun (row : Tui_decode.keeper_turn_row) ->
            if String.equal row.ktr_keeper_name name then Some row.ktr_state else None)
          state.keeper_turns
      in
      let observed_waiting =
        List.find_opt
          (fun (row : Tui_decode.keeper_waiting_row) -> String.equal row.kwr_keeper_name name)
          state.keeper_waiting
      in
      let waiting, activity_waiting =
        match state.keeper_waiting_failure, observed_waiting with
        | Some _, _ -> Masc_tui_keeper_list_model.Waiting_unavailable, None
        | None, Some row -> Masc_tui_keeper_list_model.Waiting_observed row, Some row
        | None, None -> Masc_tui_keeper_list_model.Waiting_unobserved, None
      in
      let approval =
        List.find_opt
          (fun (row : Tui_decode.keeper_tool_approval) -> String.equal row.kta_keeper name)
          state.keeper_tool_approvals
      in
      let task =
        match keeper.k_activity with
        | Some { Tui_decode.k_current_task_id = Some task_id; _ } ->
            List.find_opt (fun (task : Tui_decode.task) -> String.equal task.id task_id) state.tasks
        | Some { Tui_decode.k_current_task_id = None; _ } | None -> None
      in
      let async_requests =
        match state.tools_async_observation with
        | Some (Tui_decode.Async_ready { requests; _ }) ->
            List.filter
              (fun (row : Tui_decode.async_request_row) -> String.equal row.ar_keeper_name name)
              requests
        | Some (Tui_decode.Async_unavailable _) | None -> []
      in
      { Masc_tui_keeper_list_model.keeper
      ; reading = keeper_reading state keeper
      ; turn
      ; waiting
      ; approval
      ; task
      ; awaiting_verification =
          Masc_tui_keeper_list_model.holds_awaiting_verification ~keeper_name:name state.tasks
      ; open_questions = keeper_open_question_count state name
      ; async_requests
      ; last_activity_at = keeper_activity_at ~turn ~waiting:activity_waiting keeper
      })
    state.keepers
  |> Masc_tui_keeper_list_model.order_rows ~layout:state.keeper_list_layout
       ~sort:state.keeper_list_sort

