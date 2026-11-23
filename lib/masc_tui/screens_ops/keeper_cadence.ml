type window = {
  turns : int;
  scheduled : int;
  reacted : int;
  chat : int;
  own : int;
  unknown : int;
  known_from : float option;
}

let seconds_per_hour = 3600

let window ~now_unix ~hours (pulse : Wire_fleet.turn_pulse) =
  let window_start = now_unix -. Float.of_int (hours * seconds_per_hour) in
  let empty =
    {
      turns = 0;
      scheduled = 0;
      reacted = 0;
      chat = 0;
      own = 0;
      unknown = 0;
      known_from =
        (if pulse.known_since > window_start then Some pulse.known_since else None);
    }
  in
  List.fold_left
    (fun acc (slot : Wire_fleet.turn_slot) ->
      if Float.of_int slot.starts_at < window_start then acc
      else
        {
          acc with
          turns = acc.turns + slot.ok + slot.rested + slot.failed;
          scheduled = acc.scheduled + slot.scheduled;
          reacted = acc.reacted + slot.reacted;
          chat = acc.chat + slot.chat;
          own = acc.own + slot.own;
          unknown = acc.unknown + slot.unknown;
        })
    empty pulse.slots

type next_due =
  | No_schedule
  | Due_in of float
  | Late_by of float
  | Due_unknown

let keeper_schedules ~name schedules =
  List.filter
    (fun (sc : Wire_work.schedule_row) ->
      Option.equal String.equal sc.payload_keeper_name (Some name)
      || Option.equal String.equal sc.payload_target (Some name))
    schedules

let next_due ~now_unix schedules =
  match schedules with
  | [] -> No_schedule
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
