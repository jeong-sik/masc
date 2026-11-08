module Mark = Masc_tui_keeper_mark
module Cell = Masc_tui_keeper_axis_cell

type failing =
  | Not_failing
  | Failing_since of float
  | Failing_unrecorded

let failing_of_health ~health ~failing_since =
  match health, failing_since with
  | Masc.Tui_decode.Health_failing, Some since -> Failing_since since
  | Masc.Tui_decode.Health_failing, None -> Failing_unrecorded
  | ( ( Masc.Tui_decode.Health_running
      | Masc.Tui_decode.Health_idle
      | Masc.Tui_decode.Health_offline )
    , (Some _ | None) ) -> Not_failing
;;

let failing_text value = Mark.failing_since_word ^ " " ^ value

let failing_cell ~now = function
  | Not_failing -> None
  | Failing_since since ->
      let lasted =
        match Masc_tui_message_layout.age_text ~now ~since with
        | Some span -> span
        | None -> Mark.unknown_mark
      in
      Some { Cell.text = failing_text lasted; tone = Cell.Failure }
  | Failing_unrecorded ->
      Some { Cell.text = failing_text Mark.unknown_mark; tone = Cell.Failure }
;;
