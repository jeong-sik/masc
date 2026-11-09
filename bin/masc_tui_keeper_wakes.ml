type t =
  { row : Masc_tui_types.schedule_row
  ; at : float
  }

let row wake = wake.row
let at wake = wake.at

type coverage =
  | Whole_page
  | First_page

type reading =
  | Wakes of
      { newest_first : t list
      ; coverage : coverage
      }
  | Unplaced

(* The server writes the [last_wake] object whole, so a row with a status or a
   start time has a wake. *)
let has_wake (row : Masc_tui_types.schedule_row) =
  Option.is_some row.sch_last_wake_status || Option.is_some row.sch_last_wake_started_at_iso
;;

let started_at (row : Masc_tui_types.schedule_row) =
  Option.bind row.sch_last_wake_started_at_iso Time_codec.parse_rfc3339_opt
;;

(* Every wake on the page in row order, or [None] when one of them has no time
   to be placed by. *)
let placed rows =
  List.fold_left
    (fun placed row ->
       match placed with
       | None -> None
       | Some wakes ->
           if not (has_wake row) then Some wakes
           else
             (match started_at row with
              | None -> None
              | Some at -> Some ({ row; at } :: wakes)))
    (Some []) rows
  |> Option.map List.rev
;;

let of_page ~truncated rows =
  match placed rows with
  | None -> Unplaced
  | Some wakes ->
      (* Stable, so that of two wakes at one instant the first row stays first. *)
      Wakes
        { newest_first = List.stable_sort (fun left right -> Float.compare right.at left.at) wakes
        ; coverage = (if truncated then First_page else Whole_page)
        }
;;
