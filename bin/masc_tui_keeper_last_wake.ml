type t =
  { row : Masc_tui_types.schedule_row
  ; at : float
  }

let started_at (row : Masc_tui_types.schedule_row) =
  Option.bind row.sch_last_wake_started_at_iso Time_codec.parse_rfc3339_opt
;;

let newest rows =
  List.fold_left
    (fun best row ->
       match started_at row, best with
       | None, (Some _ | None) -> best
       | Some at, Some { at = best_at; _ } when at <= best_at -> best
       | Some at, (Some _ | None) -> Some { row; at })
    None rows
;;
