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

type placement =
  | In_hour of int
  | Before_window

let seconds_per_hour = 3600.0

(* [at] is finite and [now] is finite. Hour 0 is the one just ended. *)
let placement ~now at =
  let age = now -. at in
  if age < 0.0 then In_hour 0
  else begin
    let hours = Float.floor (age /. seconds_per_hour) in
    if hours >= Float.of_int Mark.pulse_hours then Before_window
    else In_hour (Float.to_int hours)
  end
;;

let worse (a : Pulse.outcome) (b : Pulse.outcome) : Pulse.outcome =
  match a, b with
  | Pulse.Turn_failed, (Pulse.Turn_ok | Pulse.Turn_rested | Pulse.Turn_failed) ->
      Pulse.Turn_failed
  | (Pulse.Turn_ok | Pulse.Turn_rested), Pulse.Turn_failed -> Pulse.Turn_failed
  | Pulse.Turn_rested, (Pulse.Turn_ok | Pulse.Turn_rested) -> Pulse.Turn_rested
  | Pulse.Turn_ok, Pulse.Turn_rested -> Pulse.Turn_rested
  | Pulse.Turn_ok, Pulse.Turn_ok -> Pulse.Turn_ok
;;

let is_before_window = function
  | Before_window -> true
  | In_hour _ -> false
;;

let slots ~now pulse =
  let all_unknown () = List.init Mark.pulse_hours (fun _ -> Slot_unknown) in
  match pulse with
  | None -> all_unknown ()
  | Some _ when not (Float.is_finite now) -> all_unknown ()
  | Some { Pulse.samples; truncated } ->
      let placed =
        List.filter_map
          (fun { Pulse.at; outcome } ->
            if Float.is_finite at then Some (placement ~now at, outcome) else None)
          samples
      in
      (* The oldest hour, counted back from [now], that the server's record
         covers. A cut pulse lost its older turns, so it covers back to the
         oldest turn it kept; one that kept a turn from before the window
         covers the whole window. An empty hour older than this is unknown. *)
      let oldest_known_hour =
        let reaches_past_window = List.exists (fun (place, _) -> is_before_window place) placed in
        if (not truncated) || reaches_past_window then Mark.pulse_hours - 1
        else
          List.fold_left
            (fun oldest (place, _) ->
              match place with
              | In_hour hour -> max oldest hour
              | Before_window -> oldest)
            (-1)
            placed
      in
      let slot_of_hour hour =
        let worst =
          List.fold_left
            (fun worst (place, outcome) ->
              match place with
              | In_hour here when here = hour ->
                  (match worst with
                   | None -> Some outcome
                   | Some seen -> Some (worse seen outcome))
              | In_hour _ | Before_window -> worst)
            None
            placed
        in
        match worst with
        | Some outcome -> Slot_turn outcome
        | None -> if hour > oldest_known_hour then Slot_unknown else Slot_quiet
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

let pulse_cell ~now pulse =
  let hours = slots ~now pulse in
  if List.for_all is_quiet hours then None
  else
    Some
      { Cell.text = String.concat "" (List.map slot_mark hours)
      ; tone = (if List.exists is_failed hours then Cell.Attention else Cell.Quiet)
      }
;;
