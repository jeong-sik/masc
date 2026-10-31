open Fixture_types
module Masc_tui_keeper_control = Control_candidate
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

module Keeper_projection_names = Map.Make (String)

let first_keeper_projection_rows name_of rows =
  List.fold_left
    (fun index row ->
      Keeper_projection_names.update (name_of row)
        (function None -> Some row | Some _ as first -> first) index)
    Keeper_projection_names.empty rows

let keeper_list_rows (state : state) : Masc_tui_keeper_list_model.row list =
  match state.keepers with
  | [] -> []
  | keepers ->
  (* All indexes belong to this synchronous preparation. Keepers remain the
     traversal source: duplicate rows and stable sort ties retain their original
     identities, while source lists keep their first matching reading. *)
  let liveness = Masc_tui_keeper_control.liveness_reader state.keeper_roster in
  let turns = first_keeper_projection_rows
      (fun (row : Tui_decode.keeper_turn_row) -> row.ktr_keeper_name) state.keeper_turns in
  let waiting_rows = first_keeper_projection_rows
      (fun (row : Tui_decode.keeper_waiting_row) -> row.kwr_keeper_name) state.keeper_waiting in
  let approvals = first_keeper_projection_rows
      (fun (row : Tui_decode.keeper_tool_approval) -> row.kta_keeper) state.keeper_tool_approvals in
  let tasks = first_keeper_projection_rows
      (fun (task : Tui_decode.task) -> task.id) state.tasks in
  let verifying =
    List.fold_left
      (fun index (task : Tui_decode.task) ->
        match task.status with
        | Masc_domain.AwaitingVerification { assignee; _ } ->
            Keeper_projection_names.add assignee () index
        | Masc_domain.Todo | Masc_domain.Claimed _ | Masc_domain.InProgress _
        | Masc_domain.Done _ | Masc_domain.Cancelled _ -> index)
      Keeper_projection_names.empty state.tasks
  in
  let questions =
    match state.asks_snapshot with
    | None -> Keeper_projection_names.empty
    | Some snapshot ->
        List.fold_left
          (fun index row ->
            match row.Masc.Tui_decode_asks.ar_asker with
            | Masc.Tui_decode_asks.Ask_keeper name ->
                Keeper_projection_names.update name
                  (function None -> Some 1 | Some count -> Some (count + 1)) index
            | Masc.Tui_decode_asks.Ask_installation _ -> index)
          Keeper_projection_names.empty snapshot.Masc.Tui_decode_asks.asn_rows
  in
  let async_by_keeper =
    match state.tools_async_observation with
    | Some (Tui_decode.Async_ready { requests; _ }) ->
        List.fold_left
          (fun index (row : Tui_decode.async_request_row) ->
            Keeper_projection_names.add_to_list row.ar_keeper_name row index)
          Keeper_projection_names.empty requests
        |> Keeper_projection_names.map List.rev
    | Some (Tui_decode.Async_unavailable _) | None -> Keeper_projection_names.empty
  in
  List.map
    (fun (keeper : keeper) ->
      let name = keeper.k_name in
      let turn =
        Option.map (fun (row : Tui_decode.keeper_turn_row) -> row.ktr_state)
          (Keeper_projection_names.find_opt name turns)
      in
      let observed_waiting =
        Keeper_projection_names.find_opt name waiting_rows
      in
      let waiting, activity_waiting =
        match state.keeper_waiting_failure, observed_waiting with
        | Some _, _ -> Masc_tui_keeper_list_model.Waiting_unavailable, None
        | None, Some row -> Masc_tui_keeper_list_model.Waiting_observed row, Some row
        | None, None -> Masc_tui_keeper_list_model.Waiting_unobserved, None
      in
      let approval =
        Keeper_projection_names.find_opt name approvals
      in
      let task =
        match keeper.k_activity with
        | Some { Tui_decode.k_current_task_id = Some task_id; _ } ->
            Keeper_projection_names.find_opt task_id tasks
        | Some { Tui_decode.k_current_task_id = None; _ } | None -> None
      in
      let async_requests =
        match Keeper_projection_names.find_opt name async_by_keeper with
        | Some requests -> requests
        | None -> []
      in
      { Masc_tui_keeper_list_model.keeper
      ; reading =
          { name; paused = keeper.k_paused
          ; liveness =
              (match keeper.k_origin with
               | Tui_decode.Declared_keeper _ -> Masc_tui_keeper_control.Absent
               | Persisted_keeper | Remote_keeper -> liveness name)
          }
      ; turn
      ; waiting
      ; approval
      ; task
      ; awaiting_verification =
          Keeper_projection_names.mem name verifying
      ; open_questions =
          (match Keeper_projection_names.find_opt name questions with
           | Some count -> count
           | None -> 0)
      ; async_requests
      ; last_activity_at = keeper_activity_at ~turn ~waiting:activity_waiting keeper
      })
    keepers
  |> Masc_tui_keeper_list_model.order_rows ~layout:state.keeper_list_layout
       ~sort:state.keeper_list_sort

