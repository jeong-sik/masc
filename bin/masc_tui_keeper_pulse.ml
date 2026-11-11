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

type half_hour =
  | Half_hour_unknown
  | Half_hour_quiet
  | Half_hour_ok
  | Half_hour_failed
  | Half_hour_failed_and_ok

let no_turns : Pulse.tally = { Pulse.ok = 0; rested = 0; failed = 0 }

let add_tally (a : Pulse.tally) (b : Pulse.tally) : Pulse.tally =
  { Pulse.ok = a.ok + b.ok; rested = a.rested + b.rested; failed = a.failed + b.failed }
;;

(* The decision log writes a rest as a failure (RFC-0515 §2.1), so a rested
   turn makes a failed half hour. *)
let half_hour_of_tally ~starts_before_known ({ ok; rested; failed } : Pulse.tally) =
  if failed + rested > 0 then if ok > 0 then Half_hour_failed_and_ok else Half_hour_failed
  else if ok > 0 then Half_hour_ok
  else if starts_before_known then Half_hour_unknown
  else Half_hour_quiet
;;

(* Half hour [back] 0 is the server slot that holds [now]. A slot stamped
   after it (the two clocks disagree) belongs to it. *)
let half_hours ~now ~count pulse =
  let count = max 0 count in
  let all_unknown () = List.init count (fun _ -> Half_hour_unknown) in
  match pulse with
  | None -> all_unknown ()
  | Some _ when not (Float.is_finite now) -> all_unknown ()
  | Some { Pulse.known_since; slots } ->
      let now_slot = Pulse.slot_start now in
      let back_of (slot : Pulse.slot) =
        max 0 ((now_slot - slot.starts_at) / Pulse.slot_seconds)
      in
      let tally_of back =
        List.fold_left
          (fun tally (slot : Pulse.slot) ->
            if back_of slot = back then add_tally tally slot.tally else tally)
          no_turns slots
      in
      List.init count (fun position ->
          let back = count - 1 - position in
          let starts = Float.of_int (now_slot - (back * Pulse.slot_seconds)) in
          half_hour_of_tally ~starts_before_known:(starts < known_since) (tally_of back))
;;

let half_hour_mark = function
  | Half_hour_unknown -> Mark.unknown_mark
  | Half_hour_quiet -> Mark.grid_dot_mark
  | Half_hour_ok -> Mark.grid_pulse_ok_mark
  | Half_hour_failed -> Mark.grid_full_mark
  | Half_hour_failed_and_ok -> Mark.grid_pulse_failed_and_ok_mark
;;

let nothing_read = function
  | [] -> false
  | _ :: _ as readings ->
      List.for_all
        (List.for_all (function
           | Half_hour_unknown -> true
           | Half_hour_quiet | Half_hour_ok | Half_hour_failed | Half_hour_failed_and_ok -> false))
        readings
;;

type failure_count = Exact of int | At_least of int | Count_unknown

let failure_count hours =
  let count, unknown = List.fold_left (fun (count, unknown) -> function
    | Half_hour_failed | Half_hour_failed_and_ok -> count + 1, unknown
    | Half_hour_unknown -> count, true
    | Half_hour_quiet | Half_hour_ok -> count, unknown) (0, false) hours in
  if unknown then if count = 0 then Count_unknown else At_least count else Exact count

let failure_lower_bound = function Exact n | At_least n -> n | Count_unknown -> 0

let peak_failure_count counts =
  let lower = List.fold_left (fun peak count -> max peak (failure_lower_bound count)) 0 counts in
  let uncertain = List.exists (function Exact _ -> false | At_least _ | Count_unknown -> true) counts in
  if uncertain then if lower = 0 then Count_unknown else At_least lower else Exact lower
