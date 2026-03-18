open Engine_types
open Engine_event

type snapshot = {
  last_seq : int;
  ts : string;
  state : room_state;
}

let room_id_re = Str.regexp "^[A-Za-z0-9._-]+$"

let validate_room_id (room_id : string) : (unit, string) result =
  if room_id = "" then Error "room_id cannot be empty"
  else if Str.string_match room_id_re room_id 0 then Ok ()
  else Error (Printf.sprintf "invalid room_id: %s" room_id)

let room_dir ~base_dir ~room_id =
  match validate_room_id room_id with
  | Error e -> Error e
  | Ok () ->
      Ok (Filename.concat (Filename.concat (Filename.concat base_dir "trpg") "rooms") room_id)

let events_path ~base_dir ~room_id =
  match room_dir ~base_dir ~room_id with
  | Error e -> Error e
  | Ok dir -> Ok (Filename.concat dir "events.jsonl")

let snapshot_path ~base_dir ~room_id =
  match room_dir ~base_dir ~room_id with
  | Error e -> Error e
  | Ok dir -> Ok (Filename.concat dir "snapshot.json")

let ensure_room_dir ~base_dir ~room_id =
  match room_dir ~base_dir ~room_id with
  | Error _ as e -> e
  | Ok dir ->
      (try
         Util.mkdir_p dir;
         Ok ()
       with e -> Error (Printf.sprintf "failed to mkdir %s: %s" dir (Printexc.to_string e)))

let append_event ~base_dir ~(event : Engine_event.t) =
  match ensure_room_dir ~base_dir ~room_id:event.room_id with
  | Error _ as e -> e
  | Ok () -> (
      match events_path ~base_dir ~room_id:event.room_id with
      | Error _ as e -> e
      | Ok path ->
          let line = Yojson.Safe.to_string (Engine_event.to_yojson event) ^ "\n" in
          try
            Fs_compat.append_file path line;
            Ok ()
          with e -> Error (Printf.sprintf "append_event failed: %s" (Printexc.to_string e)))

let read_event_lines (path : string) : (string list, string) result =
  if not (Sys.file_exists path) then Ok []
  else
    try
      let content = Fs_compat.load_file path in
      let lines = String.split_on_char '\n' content
                  |> List.filter (fun line -> String.length line > 0) in
      Ok lines
    with e -> Error (Printf.sprintf "read_event_lines failed: %s" (Printexc.to_string e))

let parse_events_from_lines (lines : string list) : (Engine_event.t list, string) result =
  let rec aux idx acc = function
    | [] -> Ok (List.rev acc)
    | line :: rest ->
        if String.trim line = "" then aux (idx + 1) acc rest
        else
          let parsed =
            try
              let json = Yojson.Safe.from_string line in
              Engine_event.of_yojson json
            with Yojson.Json_error e -> Error e
          in
          (match parsed with
          | Ok ev -> aux (idx + 1) (ev :: acc) rest
          | Error e ->
              Error
                (Printf.sprintf
                   "failed to parse event line %d: %s"
                   idx
                   e))
  in
  aux 1 [] lines

let read_events ~base_dir ~room_id =
  match events_path ~base_dir ~room_id with
  | Error _ as e -> e
  | Ok path -> (
      match read_event_lines path with
      | Error _ as e -> e
      | Ok lines -> parse_events_from_lines lines)

let read_events_after ~base_dir ~room_id ~after_seq =
  match read_events ~base_dir ~room_id with
  | Error _ as e -> e
  | Ok events -> Ok (List.filter (fun ev -> ev.seq > after_seq) events)

let write_snapshot ~base_dir ~room_id ~last_seq ~ts ~state =
  match ensure_room_dir ~base_dir ~room_id with
  | Error _ as e -> e
  | Ok () -> (
      match snapshot_path ~base_dir ~room_id with
      | Error _ as e -> e
      | Ok path ->
          let json =
            `Assoc
              [
                ("last_seq", `Int last_seq);
                ("ts", `String ts);
                ("state", Engine_types.room_state_to_yojson state);
              ]
          in
          try
            Fs_compat.save_file path (Yojson.Safe.pretty_to_string json);
            Ok ()
          with e -> Error (Printf.sprintf "write_snapshot failed: %s" (Printexc.to_string e)))

let read_snapshot ~base_dir ~room_id =
  match snapshot_path ~base_dir ~room_id with
  | Error _ as e -> e
  | Ok path ->
      if not (Sys.file_exists path) then Ok None
      else
        (match Util.read_json_file_safe path with
        | Error e -> Error e
        | Ok json ->
            let module U = Yojson.Safe.Util in
            try
              let last_seq = json |> U.member "last_seq" |> U.to_int in
              let ts = json |> U.member "ts" |> U.to_string in
              let state_json = json |> U.member "state" in
              (match Engine_types.room_state_of_yojson state_json with
              | Ok state -> Ok (Some { last_seq; ts; state })
              | Error e -> Error (Printf.sprintf "snapshot state parse failed: %s" e))
            with e -> Error (Printf.sprintf "snapshot parse failed: %s" (Printexc.to_string e)))

let load_recovery ~base_dir ~room_id =
  match read_snapshot ~base_dir ~room_id with
  | Error _ as e -> e
  | Ok None -> (
      match read_events ~base_dir ~room_id with
      | Error _ as e -> e
      | Ok events -> Ok (None, events))
  | Ok (Some snap) -> (
      match read_events_after ~base_dir ~room_id ~after_seq:snap.last_seq with
      | Error _ as e -> e
      | Ok events -> Ok (Some snap, events))
