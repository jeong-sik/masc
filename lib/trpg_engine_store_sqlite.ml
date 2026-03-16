open Trpg_engine_types
open Trpg_engine_event

let ( let* ) = Result.bind

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

let db_path_of_base_dir ~base_dir =
  Filename.concat (Filename.concat base_dir "trpg") "events.sqlite3"

let ensure_db_dir ~base_dir =
  let dir = Filename.concat base_dir "trpg" in
  try
    Room_utils.mkdir_p dir;
    Ok ()
  with e -> Error (Printf.sprintf "failed to create db dir: %s" (Printexc.to_string e))

let with_db ~base_dir f =
  match ensure_db_dir ~base_dir with
  | Error _ as e -> e
  | Ok () ->
      let path = db_path_of_base_dir ~base_dir in
      let db = Sqlite3.db_open path in
      Common.protect
        ~module_name:"trpg_engine_store_sqlite"
        ~finally_label:"close_db"
        ~finally:(fun () -> ignore (Sqlite3.db_close db))
        (fun () ->
          (* Reduce transient `SQLITE_BUSY` failures under read/write contention. *)
          Sqlite3.busy_timeout db 3000;
          f db)

let exec_sql db sql =
  match Sqlite3.exec db sql with
  | Sqlite3.Rc.OK -> Ok ()
  | rc ->
      Error
        (Printf.sprintf
           "sqlite exec failed (%s): %s"
           (Sqlite3.Rc.to_string rc)
           (Sqlite3.errmsg db))

let init ~base_dir =
  with_db ~base_dir (fun db ->
      let* () = exec_sql db "PRAGMA journal_mode=WAL" in
      let* () = exec_sql db "PRAGMA synchronous=NORMAL" in
      let* () =
        exec_sql db
          "CREATE TABLE IF NOT EXISTS trpg_events (\
           room_id TEXT NOT NULL, \
           seq INTEGER NOT NULL, \
           ts TEXT NOT NULL, \
           event_type TEXT NOT NULL, \
           actor_id TEXT, \
           payload TEXT NOT NULL, \
           PRIMARY KEY (room_id, seq)\
           )"
      in
      let* () =
        exec_sql db
          "CREATE INDEX IF NOT EXISTS idx_trpg_events_room_seq \
           ON trpg_events(room_id, seq)"
      in
      let* () =
        exec_sql db
          "CREATE TABLE IF NOT EXISTS trpg_snapshots (\
           room_id TEXT PRIMARY KEY, \
           last_seq INTEGER NOT NULL, \
           ts TEXT NOT NULL, \
           state TEXT NOT NULL\
           )"
      in
      Ok ())

let bind_text stmt idx v =
  match Sqlite3.bind stmt idx (Sqlite3.Data.TEXT v) with
  | Sqlite3.Rc.OK -> Ok ()
  | rc -> Error (Printf.sprintf "sqlite bind text failed: %s" (Sqlite3.Rc.to_string rc))

let bind_int stmt idx v =
  match Sqlite3.bind stmt idx (Sqlite3.Data.INT (Int64.of_int v)) with
  | Sqlite3.Rc.OK -> Ok ()
  | rc -> Error (Printf.sprintf "sqlite bind int failed: %s" (Sqlite3.Rc.to_string rc))

let bind_nullable_text stmt idx = function
  | None ->
      (match Sqlite3.bind stmt idx Sqlite3.Data.NULL with
      | Sqlite3.Rc.OK -> Ok ()
      | rc -> Error (Printf.sprintf "sqlite bind null failed: %s" (Sqlite3.Rc.to_string rc)))
  | Some v -> bind_text stmt idx v

let string_of_data = function
  | Sqlite3.Data.TEXT s -> Some s
  | Sqlite3.Data.BLOB s -> Some s
  | Sqlite3.Data.INT n -> Some (Int64.to_string n)
  | Sqlite3.Data.FLOAT f -> Some (string_of_float f)
  | Sqlite3.Data.NULL | Sqlite3.Data.NONE -> None

let int_of_data = function
  | Sqlite3.Data.INT n -> Some (Int64.to_int n)
  | Sqlite3.Data.TEXT s -> (try Some (int_of_string s) with Failure _ -> None)
  | _ -> None

let append_event ~base_dir ~(event : Trpg_engine_event.t) =
  let* () = validate_room_id event.room_id in
  let* () = init ~base_dir in
  with_db ~base_dir (fun db ->
      let stmt =
        Sqlite3.prepare db
          "INSERT INTO trpg_events(room_id, seq, ts, event_type, actor_id, payload) \
           VALUES (?1, ?2, ?3, ?4, ?5, ?6)"
      in
      Common.protect
        ~module_name:"trpg_engine_store_sqlite"
        ~finally_label:"finalize_insert_event"
        ~finally:(fun () -> ignore (Sqlite3.finalize stmt))
        (fun () ->
          let* () = bind_text stmt 1 event.room_id in
          let* () = bind_int stmt 2 event.seq in
          let* () = bind_text stmt 3 event.ts in
          let* () = bind_text stmt 4 (Trpg_engine_event.string_of_event_type event.event_type) in
          let* () = bind_nullable_text stmt 5 event.actor_id in
          let payload_s = Yojson.Safe.to_string event.payload in
          let* () = bind_text stmt 6 payload_s in
          match Sqlite3.step stmt with
          | Sqlite3.Rc.DONE -> Ok ()
          | rc ->
              Error
                (Printf.sprintf
                   "sqlite insert event failed (%s): %s"
                   (Sqlite3.Rc.to_string rc)
                   (Sqlite3.errmsg db))))

let parse_event_row ~seq ~room_id ~ts ~event_type_s ~actor_id ~payload_s =
  match Trpg_engine_event.event_type_of_string event_type_s with
  | Error e ->
      Error
        (Printf.sprintf
           "seq=%d room=%s event_type=%S parse failed: %s"
           seq room_id event_type_s e)
  | Ok event_type -> (
      try
        let payload = Yojson.Safe.from_string payload_s in
        Ok { seq; room_id; ts; event_type; actor_id; payload }
      with Yojson.Json_error e ->
        Error
          (Printf.sprintf
             "seq=%d room=%s payload parse failed: %s"
             seq room_id e))

let read_events_query ~base_dir ~room_id ~after_seq_opt =
  let* () = validate_room_id room_id in
  let* () = init ~base_dir in
  with_db ~base_dir (fun db ->
      let sql =
        match after_seq_opt with
        | None ->
            "SELECT seq, room_id, ts, event_type, actor_id, payload \
             FROM trpg_events \
             WHERE room_id = ?1 \
             ORDER BY seq ASC"
        | Some _ ->
            "SELECT seq, room_id, ts, event_type, actor_id, payload \
             FROM trpg_events \
             WHERE room_id = ?1 AND seq > ?2 \
             ORDER BY seq ASC"
      in
      let stmt =
        Sqlite3.prepare db sql
      in
      Common.protect
        ~module_name:"trpg_engine_store_sqlite"
        ~finally_label:"finalize_read_events"
        ~finally:(fun () -> ignore (Sqlite3.finalize stmt))
        (fun () ->
          let* () = bind_text stmt 1 room_id in
          let* () =
            match after_seq_opt with
            | None -> Ok ()
            | Some after_seq -> bind_int stmt 2 (max 0 after_seq)
          in
          let rec loop acc skipped =
            match Sqlite3.step stmt with
            | Sqlite3.Rc.ROW ->
                let seq = Sqlite3.column stmt 0 |> int_of_data |> Option.value ~default:0 in
                let room_id = Sqlite3.column stmt 1 |> string_of_data |> Option.value ~default:"" in
                let ts = Sqlite3.column stmt 2 |> string_of_data |> Option.value ~default:"" in
                let event_type_s = Sqlite3.column stmt 3 |> string_of_data |> Option.value ~default:"" in
                let actor_id = Sqlite3.column stmt 4 |> string_of_data in
                let payload_s = Sqlite3.column stmt 5 |> string_of_data |> Option.value ~default:"{}" in
                (match parse_event_row ~seq ~room_id ~ts ~event_type_s ~actor_id ~payload_s with
                | Ok ev -> loop (ev :: acc) skipped
                | Error e ->
                    Log.Trpg.info "skipping malformed event row: %s"
                      e;
                    loop acc (skipped + 1))
            | Sqlite3.Rc.DONE ->
                if skipped > 0 then
                  Log.Trpg.info "skipped %d malformed event row(s) for room %s"
                    skipped room_id;
                Ok (List.rev acc)
            | rc ->
                Error
                  (Printf.sprintf
                     "sqlite read events failed (%s): %s"
                     (Sqlite3.Rc.to_string rc)
                     (Sqlite3.errmsg db))
          in
          loop [] 0))

let read_events ~base_dir ~room_id =
  read_events_query ~base_dir ~room_id ~after_seq_opt:None

let read_events_after ~base_dir ~room_id ~after_seq =
  read_events_query ~base_dir ~room_id ~after_seq_opt:(Some after_seq)

let write_snapshot ~base_dir ~room_id ~last_seq ~ts ~state =
  let* () = validate_room_id room_id in
  let* () = init ~base_dir in
  with_db ~base_dir (fun db ->
      let stmt =
        Sqlite3.prepare db
          "INSERT INTO trpg_snapshots(room_id, last_seq, ts, state) \
           VALUES(?1, ?2, ?3, ?4) \
           ON CONFLICT(room_id) DO UPDATE SET \
             last_seq=excluded.last_seq, ts=excluded.ts, state=excluded.state"
      in
      Common.protect
        ~module_name:"trpg_engine_store_sqlite"
        ~finally_label:"finalize_write_snapshot"
        ~finally:(fun () -> ignore (Sqlite3.finalize stmt))
        (fun () ->
          let* () = bind_text stmt 1 room_id in
          let* () = bind_int stmt 2 last_seq in
          let* () = bind_text stmt 3 ts in
          let state_s = Yojson.Safe.to_string (Trpg_engine_types.room_state_to_yojson state) in
          let* () = bind_text stmt 4 state_s in
          match Sqlite3.step stmt with
          | Sqlite3.Rc.DONE -> Ok ()
          | rc ->
              Error
                (Printf.sprintf
                   "sqlite write snapshot failed (%s): %s"
                   (Sqlite3.Rc.to_string rc)
                   (Sqlite3.errmsg db))))

let read_snapshot ~base_dir ~room_id =
  let* () = validate_room_id room_id in
  let* () = init ~base_dir in
  with_db ~base_dir (fun db ->
      let stmt =
        Sqlite3.prepare db
          "SELECT last_seq, ts, state \
           FROM trpg_snapshots \
           WHERE room_id = ?1"
      in
      Common.protect
        ~module_name:"trpg_engine_store_sqlite"
        ~finally_label:"finalize_read_snapshot"
        ~finally:(fun () -> ignore (Sqlite3.finalize stmt))
        (fun () ->
          let* () = bind_text stmt 1 room_id in
          match Sqlite3.step stmt with
          | Sqlite3.Rc.ROW ->
              let last_seq = Sqlite3.column stmt 0 |> int_of_data |> Option.value ~default:0 in
              let ts = Sqlite3.column stmt 1 |> string_of_data |> Option.value ~default:"" in
              let state_s = Sqlite3.column stmt 2 |> string_of_data |> Option.value ~default:"{}" in
              (try
                 let state_json = Yojson.Safe.from_string state_s in
                 (match Trpg_engine_types.room_state_of_yojson state_json with
                 | Ok state -> Ok (Some { last_seq; ts; state })
                 | Error e -> Error (Printf.sprintf "snapshot state parse failed: %s" e))
               with Yojson.Json_error e ->
                 Error (Printf.sprintf "snapshot json parse failed: %s" e))
          | Sqlite3.Rc.DONE -> Ok None
          | rc ->
              Error
                (Printf.sprintf
                   "sqlite read snapshot failed (%s): %s"
                   (Sqlite3.Rc.to_string rc)
                   (Sqlite3.errmsg db))))

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
      | Ok tail -> Ok (Some snap, tail))
