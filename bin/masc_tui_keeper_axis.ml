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

let segments (state : Masc_tui_types.state) ~now ~keeper_name : Masc_tui_keeper_axis_cell.t list =
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
  schedule_cells @ memory_cells
;;
