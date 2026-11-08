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

let get_memory_index (state : Masc_tui_types.state) =
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

let segments (state : Masc_tui_types.state) ~now ~keeper_name ~runtime
  : Masc_tui_keeper_axis_cell.t list =
  let next_run = Masc_tui_keeper_next_run.find (get_schedule_index state) ~keeper_name in
  let schedule_cells =
    match Masc_tui_keeper_next_run.cell ~now next_run with
    | Some cell -> [ cell ]
    | None -> []
  in
  let memory_reading =
    Masc_tui_keeper_memory_reading.find (get_memory_index state) ~keeper_name
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
