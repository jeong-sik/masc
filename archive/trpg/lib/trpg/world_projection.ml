type agent_status = [ `Active | `Idle | `Unknown ]

type agent_state = {
  name : string;
  status : agent_status;
  last_action : string option;
}

type source_counts = {
  jsonl : int;
  sqlite : int;
  merged : int;
}

type world_state = {
  room_id : string;
  round : int;
  phase : string;
  agents : agent_state list;
  recent_events : Engine_event.t list;
  source_counts : source_counts;
}

let string_of_agent_status = function
  | `Active -> "active"
  | `Idle -> "idle"
  | `Unknown -> "unknown"

let event_sort (a : Engine_event.t) (b : Engine_event.t) =
  let by_seq = Int.compare a.seq b.seq in
  if by_seq <> 0 then by_seq else String.compare a.ts b.ts

let dedupe_events (events : Engine_event.t list) : Engine_event.t list =
  let seen = Hashtbl.create 64 in
  let key (ev : Engine_event.t) =
    Printf.sprintf
      "%d|%s|%s|%s|%s"
      ev.seq
      (Engine_event.string_of_event_type ev.event_type)
      (Option.value ~default:"" ev.actor_id)
      ev.ts
      (Yojson.Safe.to_string ev.payload)
  in
  List.fold_left
    (fun acc ev ->
      let k = key ev in
      if Hashtbl.mem seen k then acc
      else (
        Hashtbl.add seen k ();
        ev :: acc))
    [] events
  |> List.rev

let phase_from_payload (ev : Engine_event.t) : string option =
  match ev.event_type, ev.payload with
  | Engine_event.Phase_changed, `Assoc fields -> (
      match List.assoc_opt "phase" fields with
      | Some (`String p) when String.trim p <> "" -> Some p
      | _ -> None)
  | _ -> None

let action_label_of_event (ev : Engine_event.t) : string =
  Engine_event.string_of_event_type ev.event_type

let upsert_agent
    (agents : (string, agent_state) Hashtbl.t)
    (name : string)
    (action : string option) =
  let current =
    match Hashtbl.find_opt agents name with
    | Some s -> s
    | None -> { name; status = `Active; last_action = None }
  in
  let updated = { current with status = `Active; last_action = action } in
  Hashtbl.replace agents name updated

let build ~base_dir ~room_id =
  let jsonl_events =
    match Engine_store.read_events ~base_dir ~room_id with
    | Ok events -> events
    | Error _ -> []
  in
  let sqlite_events =
    match Engine_store_sqlite.read_events ~base_dir ~room_id with
    | Ok events -> events
    | Error _ -> []
  in
  let combined =
    List.sort event_sort (jsonl_events @ sqlite_events)
    |> dedupe_events
  in
  let round =
    combined
    |> List.fold_left
         (fun acc (ev : Engine_event.t) ->
           if ev.event_type = Engine_event.Turn_started then acc + 1 else acc)
         0
    |> max 1
  in
  let phase =
    List.fold_left
      (fun acc ev ->
        match phase_from_payload ev with Some p -> p | None -> acc)
      "round"
      combined
  in
  let agent_table : (string, agent_state) Hashtbl.t = Hashtbl.create 16 in
  List.iter
    (fun (ev : Engine_event.t) ->
      match ev.actor_id with
      | Some actor when String.trim actor <> "" ->
          upsert_agent agent_table actor (Some (action_label_of_event ev))
      | _ -> ())
    combined;
  let agents =
    Hashtbl.to_seq_values agent_table
    |> List.of_seq
    |> List.sort (fun a b -> String.compare a.name b.name)
  in
  Ok
    {
      room_id;
      round;
      phase;
      agents;
      recent_events = combined;
      source_counts =
        {
          jsonl = List.length jsonl_events;
          sqlite = List.length sqlite_events;
          merged = List.length combined;
        };
    }
