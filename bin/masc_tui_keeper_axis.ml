type schedule_cache_entry =
  { snap : Masc_tui_types.schedule_snapshot option
  ; freshness : Masc_tui_agenda.schedule_freshness
  ; index : Masc_tui_keeper_next_run.index
  }

type memory_cache_entry =
  { snap : Masc.Tui_decode_memory_health.memory_health_snapshot option
  ; index : Masc_tui_keeper_memory_reading.index
  }

let last_schedule_index : schedule_cache_entry option ref = ref None
let last_memory_index : memory_cache_entry option ref = ref None

let get_schedule_index (state : Masc_tui_types.state) =
  match !last_schedule_index with
  | Some entry
    when entry.snap == state.schedules_agenda
         && entry.freshness = state.schedules_agenda_freshness ->
      entry.index
  | _ ->
      let index =
        Masc_tui_keeper_next_run.index_of_agenda
          ~freshness:state.schedules_agenda_freshness
          state.schedules_agenda
      in
      last_schedule_index :=
        Some
          { snap = state.schedules_agenda
          ; freshness = state.schedules_agenda_freshness
          ; index
          };
      index
;;

let memory_index (state : Masc_tui_types.state) =
  match !last_memory_index with
  | Some entry when entry.snap == state.memory_health ->
      entry.index
  | _ ->
      let index =
        Masc_tui_keeper_memory_reading.index_of_snapshot state.memory_health
      in
      last_memory_index :=
        Some { snap = state.memory_health; index };
      index
;;

(* The cells that come from the roster row of the keeper itself. A keeper the
   roster did not read has no row to draw them from. *)
let runtime_cells ~now = function
  | None -> [], []
  | Some (runtime : Masc.Tui_decode.keeper_runtime) ->
      let failing =
        Masc_tui_keeper_pulse.failing_of_health
          ~health:(Masc.Tui_decode.keeper_health_reading runtime.Masc.Tui_decode.kr_health)
          ~failing_since:runtime.Masc.Tui_decode.kr_failing_since
      in
      ( Option.to_list (Masc_tui_keeper_pulse.failing_cell ~now failing)
      , Option.to_list
          (Masc_tui_keeper_pulse.pulse_cell ~now runtime.Masc.Tui_decode.kr_recent_turns) )
;;

let run_cell (state : Masc_tui_types.state) ~now ~keeper_name =
  Masc_tui_keeper_next_run.cell ~now
    (Masc_tui_keeper_next_run.find (get_schedule_index state) ~keeper_name)
;;

(* A failed agenda read keeps the last list, so the strip says nothing about
   it until a read succeeds (RFC-0515 §2.4.4). *)
let wake_strip (state : Masc_tui_types.state) ~now ~ahead ~keeper_name =
  match state.schedules_agenda_error with
  | Some _ -> Masc_tui_keeper_next_run.unknown_strip ~ahead
  | None ->
      Masc_tui_keeper_next_run.wake_strip (get_schedule_index state) ~now ~ahead ~keeper_name
;;

let segments (state : Masc_tui_types.state) ~now ~keeper_name ~runtime
  : Masc_tui_keeper_axis_cell.t list =
  let schedule_cells = Option.to_list (run_cell state ~now ~keeper_name) in
  let memory_reading =
    Masc_tui_keeper_memory_reading.find (memory_index state) ~keeper_name
  in
  let memory_cells = Masc_tui_keeper_memory_reading.cells ~now memory_reading in
  let failing_cells, pulse_cells = runtime_cells ~now runtime in
  (* Last, so a row too narrow for every cell drops the ladder first. Only a
     health row carries a ladder; for the other three readings the [mem] cell,
     or no cell at all, is the whole statement. *)
  let age_cells =
    match memory_reading with
    | Masc_tui_keeper_memory_reading.Row { age_bins; _ } ->
        [ Masc_tui_keeper_age_ladder.cell age_bins ]
    | Masc_tui_keeper_memory_reading.Unknown
    | Masc_tui_keeper_memory_reading.No_row
    | Masc_tui_keeper_memory_reading.Refused _ -> []
  in
  failing_cells @ schedule_cells @ memory_cells @ pulse_cells @ age_cells
;;

let hour = 3600.
let due_soon_seconds = hour
let due_half_day_seconds = 12. *. hour
let age_recent_seconds = 3. *. hour
let age_day_seconds = 24. *. hour
let age_three_days_seconds = 72. *. hour

let due_of_next_run ~now = function
  | Masc_tui_keeper_next_run.No_schedule -> Masc_tui_keeper_list_model.Due_none
  | Masc_tui_keeper_next_run.Unknown -> Masc_tui_keeper_list_model.Due_unknown
  | Masc_tui_keeper_next_run.Late_since _ -> Masc_tui_keeper_list_model.Due_late
  | Masc_tui_keeper_next_run.Held_current _ | Masc_tui_keeper_next_run.Held_as_of _ ->
      Masc_tui_keeper_list_model.Due_held
  | Masc_tui_keeper_next_run.Scheduled_at at ->
      let ahead = at -. now in
      if ahead <= due_soon_seconds then Masc_tui_keeper_list_model.Due_within_hour
      else if ahead <= due_half_day_seconds then Masc_tui_keeper_list_model.Due_within_half_day
      else Masc_tui_keeper_list_model.Due_later
  | Masc_tui_keeper_next_run.Not_before at ->
      if at -. now > due_half_day_seconds then Masc_tui_keeper_list_model.Due_later
      else Masc_tui_keeper_list_model.Due_unknown
;;

let follow_of_memory = function
  | Masc_tui_keeper_memory_reading.Unknown | Masc_tui_keeper_memory_reading.No_row ->
      Masc_tui_keeper_list_model.Memory_unread
  | Masc_tui_keeper_memory_reading.Refused _ -> Masc_tui_keeper_list_model.Memory_refused
  | Masc_tui_keeper_memory_reading.Row { gap; lag; _ } ->
      (match gap, lag with
       | (Masc_tui_keeper_memory_reading.Gap _ | Masc_tui_keeper_memory_reading.Gap_unmeasured), _ ->
           Masc_tui_keeper_list_model.Memory_gap
       | Masc_tui_keeper_memory_reading.No_gap, Masc_tui_keeper_memory_reading.Lag turns ->
           if turns > 0 then Masc_tui_keeper_list_model.Memory_lagging
           else Masc_tui_keeper_list_model.Memory_following
       | Masc_tui_keeper_memory_reading.No_gap, Masc_tui_keeper_memory_reading.Lag_unmeasured ->
           Masc_tui_keeper_list_model.Memory_unread)
;;

let age_of_memory ~now = function
  | Masc_tui_keeper_memory_reading.Unknown | Masc_tui_keeper_memory_reading.No_row
  | Masc_tui_keeper_memory_reading.Refused _ -> Masc_tui_keeper_list_model.Age_unknown
  | Masc_tui_keeper_memory_reading.Row { updated_at = None; _ } -> Masc_tui_keeper_list_model.Age_unknown
  | Masc_tui_keeper_memory_reading.Row { updated_at = Some at; _ } ->
      let age = now -. at in
      if age <= age_recent_seconds then Masc_tui_keeper_list_model.Age_within_3h
      else if age <= age_day_seconds then Masc_tui_keeper_list_model.Age_within_day
      else if age <= age_three_days_seconds then Masc_tui_keeper_list_model.Age_within_3d
      else Masc_tui_keeper_list_model.Age_older
;;

let outside (state : Masc_tui_types.state) ~now ~keeper_name : Masc_tui_keeper_list_model.outside =
  let memory = Masc_tui_keeper_memory_reading.find (memory_index state) ~keeper_name in
  { due =
      due_of_next_run ~now
        (Masc_tui_keeper_next_run.find (get_schedule_index state) ~keeper_name)
  ; follow = follow_of_memory memory
  ; age = age_of_memory ~now memory
  }
;;

let next_run (state : Masc_tui_types.state) ~keeper_name =
  Masc_tui_keeper_next_run.find (get_schedule_index state) ~keeper_name
;;

let next_recurrence (state : Masc_tui_types.state) ~keeper_name =
  match state.schedules_agenda_error, state.schedules_agenda, next_run state ~keeper_name with
  | None, Some snapshot, Masc_tui_keeper_next_run.Scheduled_at due
    when snapshot.scs_read_error = None ->
      let matching = List.filter (fun (row : Masc_tui_types.schedule_row) ->
        row.sch_payload_keeper_name = Some keeper_name && row.sch_runner_hold = None
        && Masc_tui_types.schedule_row_due_time row = Some due
        && (match Schedule_domain.schedule_status_of_string row.sch_status with
            | Ok (Schedule_domain.Scheduled | Schedule_domain.Running) | Error _ -> true
            | Ok (Schedule_domain.Due | Schedule_domain.Succeeded | Schedule_domain.Failed
                 | Schedule_domain.Cancelled | Schedule_domain.Expired) -> false)) snapshot.scs_rows in
      (match matching with
       | [row] -> (match Schedule_domain.schedule_status_of_string row.sch_status, row.sch_recurrence with
           | Ok (Schedule_domain.Scheduled | Schedule_domain.Running), Ok recurrence -> Some recurrence
           | Ok (Schedule_domain.Scheduled | Schedule_domain.Running), Error _
           | Ok (Schedule_domain.Due | Schedule_domain.Succeeded | Schedule_domain.Failed
                | Schedule_domain.Cancelled | Schedule_domain.Expired), (Ok _ | Error _)
           | Error _, (Ok _ | Error _) -> None)
       | [] | _ :: _ :: _ -> None)
  | (Some _ | None), (Some _ | None),
      (Masc_tui_keeper_next_run.Scheduled_at _ | Masc_tui_keeper_next_run.No_schedule
       | Masc_tui_keeper_next_run.Late_since _ | Masc_tui_keeper_next_run.Held_current _
       | Masc_tui_keeper_next_run.Held_as_of _ | Masc_tui_keeper_next_run.Not_before _
       | Masc_tui_keeper_next_run.Unknown) -> None
