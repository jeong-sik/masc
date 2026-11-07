type cache_entry =
  { snap : Masc_tui_types.schedule_snapshot option
  ; freshness : Masc_tui_agenda.schedule_freshness
  ; index : Masc_tui_keeper_next_run.index
  }

let last_index : cache_entry option ref = ref None

let get_index (state : Masc_tui_types.state) =
  match !last_index with
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
      last_index :=
        Some
          { snap = state.schedules_agenda
          ; freshness = state.schedules_agenda_freshness
          ; index
          };
      index
;;

let segments (state : Masc_tui_types.state) ~now ~keeper_name : Masc_tui_keeper_axis_cell.t list =
  let next_run = Masc_tui_keeper_next_run.find (get_index state) ~keeper_name in
  match Masc_tui_keeper_next_run.cell ~now next_run with
  | Some cell -> [ cell ]
  | None -> []
;;
