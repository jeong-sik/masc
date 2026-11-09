type t =
  { row : Masc_tui_types.schedule_row
  ; at : float
  }

let row wake = wake.row
let at wake = wake.at

type reading =
  | No_wake
  | Not_on_first_page
  | Newest of t
  | Newest_on_first_page of t
  | Unplaced

(* The server writes the [last_wake] object whole, so a row with a status or a
   start time has a wake. *)
let has_wake (row : Masc_tui_types.schedule_row) =
  Option.is_some row.sch_last_wake_status || Option.is_some row.sch_last_wake_started_at_iso
;;

let started_at (row : Masc_tui_types.schedule_row) =
  Option.bind row.sch_last_wake_started_at_iso Time_codec.parse_rfc3339_opt
;;

let of_page ~truncated rows =
  let newest, unplaced =
    List.fold_left
      (fun (newest, unplaced) row ->
         if not (has_wake row) then newest, unplaced
         else
           match started_at row, newest with
           | None, (Some _ | None) -> newest, true
           | Some at, Some { at = newest_at; _ } when at <= newest_at -> newest, unplaced
           | Some at, (Some _ | None) -> Some { row; at }, unplaced)
      (None, false) rows
  in
  match newest, unplaced, truncated with
  | (Some _ | None), true, (true | false) -> Unplaced
  | Some wake, false, true -> Newest_on_first_page wake
  | Some wake, false, false -> Newest wake
  | None, false, true -> Not_on_first_page
  | None, false, false -> No_wake
;;
