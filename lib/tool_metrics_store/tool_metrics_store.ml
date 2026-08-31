type row = {
  record_id : string;
  ts : float;
  tool_name : string;
  disposition : string;
  duration_ms : float;
}

type summary = {
  path : string;
  exists : bool;
  entry_count : int;
  latest_ts : float option;
}

type store = {
  masc_root : string;
  db : Sqlite3.db;
}

let store_mu = Stdlib.Mutex.create ()
let current_store : store option ref = ref None
let ( let* ) = Result.bind

let database_path ~masc_root = Filename.concat masc_root "tool-metrics.sqlite3"

let sqlite_error db operation rc =
  Printf.sprintf
    "%s: rc=%s detail=%s"
    operation
    (Sqlite3.Rc.to_string rc)
    (Sqlite3.errmsg db)

let exec db ~operation sql =
  let rc = Sqlite3.exec db sql in
  if Sqlite3.Rc.is_success rc
  then Ok ()
  else Error (sqlite_error db operation rc)

let close_db db =
  let closed = Sqlite3.db_close db in
  (* sqlite3-ocaml releases the OCaml runtime during close. Keep the wrapper
     reachable until the C call has returned. *)
  ignore (Sys.opaque_identity db);
  closed

let prepare db ~operation sql =
  try Ok (Sqlite3.prepare db sql) with
  | Sqlite3.Error detail -> Error (operation ^ ": " ^ detail)

let finalize db statement result =
  let cleanup =
    try
      let rc = Sqlite3.finalize statement in
      ignore (Sys.opaque_identity statement);
      if Sqlite3.Rc.is_success rc
      then Ok ()
      else Error (sqlite_error db "finalize statement" rc)
    with
    | Sqlite3.Error detail -> Error ("finalize statement: " ^ detail)
  in
  match result, cleanup with
  | Ok value, Ok () -> Ok value
  | Error _ as error, Ok () -> error
  | Ok _, (Error _ as error) -> error
  | Error first, Error second -> Error (first ^ "; " ^ second)

let with_statement db ~operation sql f =
  let* statement = prepare db ~operation sql in
  let result =
    try f statement with
    | Sqlite3.Error detail -> Error (operation ^ ": " ^ detail)
  in
  finalize db statement result

let bind db statement ~operation index data =
  let rc = Sqlite3.bind statement index data in
  if Sqlite3.Rc.is_success rc
  then Ok ()
  else Error (sqlite_error db operation rc)

let bind_all db statement ~operation values =
  let rec loop index = function
    | [] -> Ok ()
    | value :: rest ->
      let* () = bind db statement ~operation index value in
      loop (index + 1) rest
  in
  loop 1 values

let expect_done db statement ~operation =
  let rc = Sqlite3.step statement in
  if rc = Sqlite3.Rc.DONE
  then Ok ()
  else Error (sqlite_error db operation rc)

let single_text db ~operation sql =
  with_statement db ~operation sql (fun statement ->
    let rc = Sqlite3.step statement in
    if rc <> Sqlite3.Rc.ROW
    then Error (sqlite_error db operation rc)
    else
      let value = Sqlite3.column_text statement 0 in
      let rc = Sqlite3.step statement in
      if rc = Sqlite3.Rc.DONE
      then Ok value
      else Error (sqlite_error db (operation ^ " completion") rc))

let single_int db ~operation sql =
  with_statement db ~operation sql (fun statement ->
    let rc = Sqlite3.step statement in
    if rc <> Sqlite3.Rc.ROW
    then Error (sqlite_error db operation rc)
    else
      let value = Sqlite3.column_int statement 0 in
      let rc = Sqlite3.step statement in
      if rc = Sqlite3.Rc.DONE
      then Ok value
      else Error (sqlite_error db (operation ^ " completion") rc))

let schema_sql =
  {|
CREATE TABLE IF NOT EXISTS tool_metric_events (
  record_id TEXT PRIMARY KEY NOT NULL,
  ts REAL NOT NULL CHECK (ts >= 0),
  tool_name TEXT NOT NULL CHECK (tool_name <> ''),
  disposition TEXT NOT NULL
    CHECK (disposition IN ('completed', 'deferred', 'failed')),
  duration_ms REAL NOT NULL CHECK (duration_ms >= 0)
)
|}

let configure db =
  let* journal_mode =
    single_text db ~operation:"set WAL journal mode" "PRAGMA journal_mode=WAL"
  in
  if not (String.equal (String.lowercase_ascii journal_mode) "wal")
  then Error "SQLite refused journal_mode=WAL"
  else
    let* () =
      exec db ~operation:"set NORMAL synchronous" "PRAGMA synchronous=NORMAL"
    in
    let* synchronous =
      single_int db ~operation:"read synchronous mode" "PRAGMA synchronous"
    in
    if synchronous <> 1
    then Error "SQLite synchronous mode is not NORMAL"
    else
      let* () =
        exec db ~operation:"set busy timeout" "PRAGMA busy_timeout=5000"
      in
      let* () = exec db ~operation:"create tool metric table" schema_sql in
      exec
        db
        ~operation:"create tool metric timestamp index"
        "CREATE INDEX IF NOT EXISTS tool_metric_events_ts \
         ON tool_metric_events(ts)"

let open_store ~masc_root =
  let path = database_path ~masc_root in
  try
    Fs_compat.mkdir_p (Filename.dirname path);
    let db = Sqlite3.db_open path in
    let fail error =
      ignore (close_db db : bool);
      Error error
    in
    (match configure db with
     | Ok () -> Ok { masc_root; db }
     | Error error -> fail error
     | exception Sqlite3.Error detail -> fail ("configure database: " ^ detail)
     | exception Sys_error detail -> fail ("configure database: " ^ detail)
     | exception Unix.Unix_error (error, operation, argument) ->
       fail
         (Printf.sprintf
            "configure database: %s(%s): %s"
            operation
            argument
            (Unix.error_message error)))
  with
  | Sqlite3.Error detail -> Error ("open database: " ^ detail)
  | Sys_error detail -> Error ("open database: " ^ detail)
  | Unix.Unix_error (error, operation, argument) ->
    Error
      (Printf.sprintf
         "open database: %s(%s): %s"
         operation
         argument
         (Unix.error_message error))

let close_current_store_locked () =
  match !current_store with
  | None -> ()
  | Some store ->
    current_store := None;
    ignore (close_db store.db : bool)

let get_or_open_locked ~masc_root =
  match !current_store with
  | Some store when String.equal store.masc_root masc_root -> Ok store
  | Some _ ->
    close_current_store_locked ();
    let* store = open_store ~masc_root in
    current_store := Some store;
    Ok store
  | None ->
    let* store = open_store ~masc_root in
    current_store := Some store;
    Ok store

let with_store ~masc_root f =
  Stdlib.Mutex.protect store_mu (fun () ->
    let* store = get_or_open_locked ~masc_root in
    try f store with
    | Sqlite3.Error detail -> Error ("SQLite operation: " ^ detail)
    | Sys_error detail -> Error ("storage operation: " ^ detail)
    | Unix.Unix_error (error, operation, argument) ->
      Error
        (Printf.sprintf
           "%s(%s): %s"
           operation
           argument
           (Unix.error_message error)))

let reset_for_testing () =
  Stdlib.Mutex.protect store_mu close_current_store_locked

let insert ~masc_root row =
  with_store ~masc_root (fun store ->
    with_statement
      store.db
      ~operation:"insert tool metric"
      "INSERT OR IGNORE INTO tool_metric_events \
       (record_id, ts, tool_name, disposition, duration_ms) \
       VALUES (?1, ?2, ?3, ?4, ?5)"
      (fun statement ->
        let* () =
          bind_all
            store.db
            statement
            ~operation:"bind tool metric row"
            [ Sqlite3.Data.TEXT row.record_id
            ; Sqlite3.Data.FLOAT row.ts
            ; Sqlite3.Data.TEXT row.tool_name
            ; Sqlite3.Data.TEXT row.disposition
            ; Sqlite3.Data.FLOAT row.duration_ms
            ]
        in
        expect_done store.db statement ~operation:"insert tool metric"))

let prune ~masc_root ~retention_days =
  if retention_days <= 0
  then Ok 0
  else
    with_store ~masc_root (fun store ->
      let cutoff =
        Unix.gettimeofday ()
        -. (Float.of_int retention_days *. Masc_time_constants.day)
      in
      with_statement
        store.db
        ~operation:"prune tool metrics"
        "DELETE FROM tool_metric_events WHERE ts < ?1"
        (fun statement ->
          let* () =
            bind_all
              store.db
              statement
              ~operation:"bind tool metric retention cutoff"
              [ Sqlite3.Data.FLOAT cutoff ]
          in
          let* () =
            expect_done store.db statement ~operation:"prune tool metrics"
          in
          Ok (Sqlite3.changes store.db)))

let row_of_statement statement =
  { record_id = Sqlite3.column_text statement 0
  ; ts = Sqlite3.column_double statement 1
  ; tool_name = Sqlite3.column_text statement 2
  ; disposition = Sqlite3.column_text statement 3
  ; duration_ms = Sqlite3.column_double statement 4
  }

let iter_all ~masc_root ~f =
  with_store ~masc_root (fun store ->
    with_statement
      store.db
      ~operation:"read retained tool metrics"
      "SELECT record_id, ts, tool_name, disposition, duration_ms \
       FROM tool_metric_events ORDER BY ts, record_id"
      (fun statement ->
        let count = ref 0 in
        let rec loop () =
          match Sqlite3.step statement with
          | Sqlite3.Rc.ROW ->
            let* () = f (row_of_statement statement) in
            Stdlib.incr count;
            loop ()
          | Sqlite3.Rc.DONE -> Ok !count
          | rc -> Error (sqlite_error store.db "read retained tool metrics" rc)
        in
        loop ()))

let latest_ts db =
  with_statement
    db
    ~operation:"read latest tool metric timestamp"
    "SELECT MAX(ts) FROM tool_metric_events"
    (fun statement ->
      let rc = Sqlite3.step statement in
      if rc <> Sqlite3.Rc.ROW
      then Error (sqlite_error db "read latest tool metric timestamp" rc)
      else
        let value =
          match Sqlite3.column statement 0 with
          | Sqlite3.Data.NULL -> None
          | Sqlite3.Data.FLOAT value -> Some value
          | Sqlite3.Data.INT value -> Some (Int64.to_float value)
          | _ -> None
        in
        let rc = Sqlite3.step statement in
        if rc = Sqlite3.Rc.DONE
        then Ok value
        else
          Error
            (sqlite_error db "read latest tool metric timestamp completion" rc))

let summary ~masc_root =
  let path = database_path ~masc_root in
  if not (Sys.file_exists path)
  then Ok { path; exists = false; entry_count = 0; latest_ts = None }
  else
    with_store ~masc_root (fun store ->
      let* entry_count =
        single_int
          store.db
          ~operation:"count tool metrics"
          "SELECT COUNT(*) FROM tool_metric_events"
      in
      let* latest_ts = latest_ts store.db in
      Ok { path; exists = true; entry_count; latest_ts })

let read_recent ~masc_root ?since_ts ?until_ts ~n () =
  if n <= 0
  then Ok []
  else
    let path = database_path ~masc_root in
    if not (Sys.file_exists path)
    then Ok []
    else
      with_store ~masc_root (fun store ->
        with_statement
          store.db
          ~operation:"read recent tool metrics"
          "SELECT record_id, ts, tool_name, disposition, duration_ms \
           FROM tool_metric_events \
           WHERE (?1 IS NULL OR ts >= ?1) \
             AND (?2 IS NULL OR ts <= ?2) \
           ORDER BY ts DESC, record_id DESC LIMIT ?3"
          (fun statement ->
            let* () =
              bind_all
                store.db
                statement
                ~operation:"bind tool metric read filters"
                [ (match since_ts with
                   | None -> Sqlite3.Data.NULL
                   | Some value -> Sqlite3.Data.FLOAT value)
                ; (match until_ts with
                   | None -> Sqlite3.Data.NULL
                   | Some value -> Sqlite3.Data.FLOAT value)
                ; Sqlite3.Data.INT (Int64.of_int n)
                ]
            in
            let rec loop rows =
              match Sqlite3.step statement with
              | Sqlite3.Rc.ROW -> loop (row_of_statement statement :: rows)
              | Sqlite3.Rc.DONE -> Ok (List.rev rows)
              | rc -> Error (sqlite_error store.db "read recent tool metrics" rc)
            in
            loop []))

let row_to_json row =
  `Assoc
    [ "record_id", `String row.record_id
    ; "ts", `Float row.ts
    ; "tool_name", `String row.tool_name
    ; "disposition", `String row.disposition
    ; "duration_ms", `Float row.duration_ms
    ]
