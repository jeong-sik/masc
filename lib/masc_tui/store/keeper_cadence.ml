open Masc_tui_protocol

type window = {
  turns : int;
  ok : int;
  rested : int;
  failed : int;
  scheduled : int;
  reacted : int;
  chat : int;
  own : int;
  unknown : int;
  known_from : float option;
}

let window_hours = [ 6; 24 ]
let slots_per_hour = 3600 / Wire_fleet.turn_slot_seconds

let window ~now_unix ~hours (pulse : Wire_fleet.turn_pulse) =
  let slot = Wire_fleet.turn_slot_seconds in
  let current_slot = int_of_float now_unix / slot * slot in
  let window_start = current_slot - (((hours * slots_per_hour) - 1) * slot) in
  let empty =
    {
      turns = 0;
      ok = 0;
      rested = 0;
      failed = 0;
      scheduled = 0;
      reacted = 0;
      chat = 0;
      own = 0;
      unknown = 0;
      known_from =
        (if pulse.known_since > Float.of_int window_start then Some pulse.known_since
         else None);
    }
  in
  List.fold_left
    (fun acc (s : Wire_fleet.turn_slot) ->
      if s.starts_at < window_start then acc
      else
        {
          acc with
          turns = acc.turns + s.ok + s.rested + s.failed;
          ok = acc.ok + s.ok;
          rested = acc.rested + s.rested;
          failed = acc.failed + s.failed;
          scheduled = acc.scheduled + s.scheduled;
          reacted = acc.reacted + s.reacted;
          chat = acc.chat + s.chat;
          own = acc.own + s.own;
          unknown = acc.unknown + s.unknown;
        })
    empty pulse.slots

type next_due =
  | No_schedule
  | Due_in of float
  | Late_by of float
  | Due_unknown
  | Past_page_read

let keeper_schedules ~name schedules =
  List.filter
    (fun (sc : Wire_work.schedule_row) ->
      Option.equal String.equal sc.payload_keeper_name (Some name)
      || Option.equal String.equal sc.payload_target (Some name))
    schedules

let next_due ~now_unix ~more_pages schedules =
  match schedules with
  | [] -> if more_pages then Past_page_read else No_schedule
  | _ :: _ -> (
      let earliest =
        List.fold_left
          (fun acc (sc : Wire_work.schedule_row) ->
            match acc, sc.next_due_at_unix with
            | None, due -> due
            | Some a, Some b -> Some (Float.min a b)
            | (Some _ as a), None -> a)
          None schedules
      in
      match earliest with
      | None -> Due_unknown
      | Some due when due >= now_unix -> Due_in (due -. now_unix)
      | Some due -> Late_by (now_unix -. due))

let rows_per_window = 2
let hairline_rows = 1
let next_due_rows = 1
let missing_pulse_rows = 1

let block_rows = function
  | None -> hairline_rows + missing_pulse_rows + next_due_rows
  | Some (_ : Wire_fleet.turn_pulse) ->
      hairline_rows + (rows_per_window * List.length window_hours) + next_due_rows
