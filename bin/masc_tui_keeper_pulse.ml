module Pulse = Masc.Keeper_turn_pulse
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

type slot =
  | Slot_unknown
  | Slot_quiet
  | Slot_turn of Pulse.outcome

let seconds_per_hour = 3600

let worse (a : Pulse.outcome) (b : Pulse.outcome) : Pulse.outcome =
  match a, b with
  | Pulse.Turn_failed, (Pulse.Turn_ok | Pulse.Turn_rested | Pulse.Turn_failed) ->
      Pulse.Turn_failed
  | (Pulse.Turn_ok | Pulse.Turn_rested), Pulse.Turn_failed -> Pulse.Turn_failed
  | Pulse.Turn_rested, (Pulse.Turn_ok | Pulse.Turn_rested) -> Pulse.Turn_rested
  | Pulse.Turn_ok, Pulse.Turn_rested -> Pulse.Turn_rested
  | Pulse.Turn_ok, Pulse.Turn_ok -> Pulse.Turn_ok
;;

let worst_of_tally ({ ok; rested; failed } : Pulse.tally) : Pulse.outcome option =
  if failed > 0 then Some Pulse.Turn_failed
  else if rested > 0 then Some Pulse.Turn_rested
  else if ok > 0 then Some Pulse.Turn_ok
  else None
;;

let hour_start seconds = seconds / seconds_per_hour * seconds_per_hour

(* Hours are whole clock hours. Hour 0 holds [now]; a half-hour slot lies
   inside one hour because an hour is two slots. A slot stamped after the hour
   of [now] (the two clocks disagree) belongs to hour 0. *)
let slots ~now pulse =
  let all_unknown () = List.init Mark.pulse_hours (fun _ -> Slot_unknown) in
  match pulse with
  | None -> all_unknown ()
  | Some _ when not (Float.is_finite now) -> all_unknown ()
  | Some { Pulse.known_since; slots } ->
      let now_hour = hour_start (int_of_float (Float.floor now)) in
      let hour_of (slot : Pulse.slot) =
        max 0 ((now_hour - hour_start slot.starts_at) / seconds_per_hour)
      in
      let slot_of_hour hour =
        let worst =
          List.fold_left
            (fun worst (slot : Pulse.slot) ->
              if hour_of slot <> hour then worst
              else
                match worst, worst_of_tally slot.tally with
                | None, outcome -> outcome
                | Some seen, Some outcome -> Some (worse seen outcome)
                | (Some _ as seen), None -> seen)
            None
            slots
        in
        match worst with
        | Some outcome -> Slot_turn outcome
        | None ->
            let starts = Float.of_int (now_hour - (hour * seconds_per_hour)) in
            if starts < known_since then Slot_unknown else Slot_quiet
      in
      List.init Mark.pulse_hours (fun position -> slot_of_hour (Mark.pulse_hours - 1 - position))
;;

let slot_mark = function
  | Slot_unknown -> Mark.unknown_mark
  | Slot_quiet -> Mark.pulse_quiet_mark
  | Slot_turn Pulse.Turn_ok -> Mark.pulse_ok_mark
  | Slot_turn Pulse.Turn_rested -> Mark.pulse_rested_mark
  | Slot_turn Pulse.Turn_failed -> Mark.pulse_failed_mark
;;

let is_quiet = function
  | Slot_quiet -> true
  | Slot_unknown | Slot_turn _ -> false
;;

let is_failed = function
  | Slot_turn Pulse.Turn_failed -> true
  | Slot_turn (Pulse.Turn_ok | Pulse.Turn_rested) | Slot_unknown | Slot_quiet -> false
;;

let cell_of_hours hours =
  { Cell.text = String.concat "" (List.map slot_mark hours)
  ; tone = (if List.exists is_failed hours then Cell.Attention else Cell.Quiet)
  }
;;

let pulse_cell ~now pulse =
  let hours = slots ~now pulse in
  if List.for_all is_quiet hours then None else Some (cell_of_hours hours)
;;
