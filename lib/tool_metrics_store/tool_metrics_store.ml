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

(* Serialises every use of [current_store], the open SQLite handle. Opening a
   store suspends the calling fiber: [Fs_compat.mkdir_p] runs the mkdir on a
   worker thread through Eio. The fibers of one domain share one thread, and a
   [Stdlib.Mutex] raises [Sys_error "Mutex.lock: Resource deadlock avoided"]
   when the thread that holds it locks it again, so the next caller of the
   domain raised instead of waiting. [Cross_context_mutex] makes a fiber wait
   cooperatively, and system threads and other domains still wait on the
   underlying mutex. The SQLite calls are blocking C calls and do not suspend. *)
let store_lock = Cross_context_mutex.create ()
let current_store : store option ref = ref None
let database_filename = "tool-metrics.sqlite3"

open Result.Syntax

let database_path ~masc_root = Filename.concat masc_root database_filename

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

(* The bytes of the result a call returned. It is a table of its own: the 800,000
   rows written before it existed have no size, and a row without a size is a
   call whose size was not observed, which is not a call of size zero. *)
let result_sizes_schema_sql =
  {|
CREATE TABLE IF NOT EXISTS tool_metric_result_sizes (
  record_id TEXT PRIMARY KEY NOT NULL,
  result_bytes INTEGER NOT NULL CHECK (result_bytes >= 0)
) WITHOUT ROWID
|}

(* The class of a failed call. Like the size, it is a table of its own: the
   rows written before it existed, and a failure that carried no class, have no
   row here, and a failure without a row is an unclassified failure. The column
   holds [Tool_result.tool_failure_class_to_string] and is parsed back strictly
   when read, so a database never carries a second copy of the set of classes. *)
let failure_classes_schema_sql =
  {|
CREATE TABLE IF NOT EXISTS tool_metric_failure_classes (
  record_id TEXT PRIMARY KEY NOT NULL,
  failure_class TEXT NOT NULL CHECK (failure_class <> '')
) WITHOUT ROWID
|}

let busy_timeout_ms = 5000
let busy_timeout_sql = Printf.sprintf "PRAGMA busy_timeout=%d" busy_timeout_ms

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
      let* () = exec db ~operation:"set busy timeout" busy_timeout_sql in
      let* () = exec db ~operation:"create tool metric table" schema_sql in
      let* () =
        exec
          db
          ~operation:"create tool metric result size table"
          result_sizes_schema_sql
      in
      let* () =
        exec
          db
          ~operation:"create tool metric failure class table"
          failure_classes_schema_sql
      in
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
  Cross_context_mutex.with_lock store_lock (fun () ->
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
  Cross_context_mutex.with_lock store_lock close_current_store_locked

(* Runs [f] between BEGIN and COMMIT on the connection [with_store] holds, so
   a call's event and its size are written together or not at all. *)
let in_transaction db ~operation f =
  let* () = exec db ~operation:(operation ^ ": begin") "BEGIN IMMEDIATE" in
  let rollback () = ignore (Sqlite3.exec db "ROLLBACK" : Sqlite3.Rc.t) in
  match f () with
  | Ok value ->
    (match exec db ~operation:(operation ^ ": commit") "COMMIT" with
     | Ok () -> Ok value
     | Error _ as error ->
       rollback ();
       error)
  | Error _ as error ->
    rollback ();
    error
  | exception exn ->
    rollback ();
    raise exn

let insert ~masc_root ~result_bytes ~failure_class row =
  if result_bytes < 0
  then Error (Printf.sprintf "tool metric %s has a negative result size" row.record_id)
  else
    with_store ~masc_root (fun store ->
      in_transaction store.db ~operation:"insert tool metric" (fun () ->
        let* () =
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
              expect_done store.db statement ~operation:"insert tool metric")
        in
        let* () =
          with_statement
            store.db
            ~operation:"insert tool metric result size"
            "INSERT OR IGNORE INTO tool_metric_result_sizes (record_id, result_bytes) \
             VALUES (?1, ?2)"
            (fun statement ->
              let* () =
                bind_all
                  store.db
                  statement
                  ~operation:"bind tool metric result size"
                  [ Sqlite3.Data.TEXT row.record_id
                  ; Sqlite3.Data.INT (Int64.of_int result_bytes)
                  ]
              in
              expect_done
                store.db
                statement
                ~operation:"insert tool metric result size")
        in
        match failure_class with
        | None -> Ok ()
        | Some failure_class ->
          with_statement
            store.db
            ~operation:"insert tool metric failure class"
            "INSERT OR IGNORE INTO tool_metric_failure_classes \
             (record_id, failure_class) VALUES (?1, ?2)"
            (fun statement ->
              let* () =
                bind_all
                  store.db
                  statement
                  ~operation:"bind tool metric failure class"
                  [ Sqlite3.Data.TEXT row.record_id
                  ; Sqlite3.Data.TEXT
                      (Tool_result.tool_failure_class_to_string failure_class)
                  ]
              in
              expect_done
                store.db
                statement
                ~operation:"insert tool metric failure class")))

let prune ~masc_root ~retention_days =
  if retention_days <= 0
  then Ok 0
  else
    with_store ~masc_root (fun store ->
      let cutoff =
        Unix.gettimeofday ()
        -. (Float.of_int retention_days *. Masc_time_constants.day)
      in
      let delete ~operation sql =
        with_statement store.db ~operation sql (fun statement ->
          let* () =
            bind_all
              store.db
              statement
              ~operation:"bind tool metric retention cutoff"
              [ Sqlite3.Data.FLOAT cutoff ]
          in
          let* () = expect_done store.db statement ~operation in
          Ok (Sqlite3.changes store.db))
      in
      in_transaction store.db ~operation:"prune tool metrics" (fun () ->
        let* _sizes =
          delete
            ~operation:"prune tool metric result sizes"
            "DELETE FROM tool_metric_result_sizes WHERE record_id IN \
             (SELECT record_id FROM tool_metric_events WHERE ts < ?1)"
        in
        let* _classes =
          delete
            ~operation:"prune tool metric failure classes"
            "DELETE FROM tool_metric_failure_classes WHERE record_id IN \
             (SELECT record_id FROM tool_metric_events WHERE ts < ?1)"
        in
        delete
          ~operation:"prune tool metrics"
          "DELETE FROM tool_metric_events WHERE ts < ?1"))

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
          | (Sqlite3.Rc.OK | Sqlite3.Rc.ERROR | Sqlite3.Rc.INTERNAL | Sqlite3.Rc.PERM | Sqlite3.Rc.ABORT | Sqlite3.Rc.BUSY | Sqlite3.Rc.LOCKED | Sqlite3.Rc.NOMEM | Sqlite3.Rc.READONLY | Sqlite3.Rc.INTERRUPT | Sqlite3.Rc.IOERR | Sqlite3.Rc.CORRUPT | Sqlite3.Rc.NOTFOUND | Sqlite3.Rc.FULL | Sqlite3.Rc.CANTOPEN | Sqlite3.Rc.PROTOCOL | Sqlite3.Rc.EMPTY | Sqlite3.Rc.SCHEMA | Sqlite3.Rc.TOOBIG | Sqlite3.Rc.CONSTRAINT | Sqlite3.Rc.MISMATCH | Sqlite3.Rc.MISUSE | Sqlite3.Rc.NOFLS | Sqlite3.Rc.AUTH | Sqlite3.Rc.FORMAT | Sqlite3.Rc.RANGE | Sqlite3.Rc.NOTADB | Sqlite3.Rc.UNKNOWN _) as rc -> Error (sqlite_error store.db "read retained tool metrics" rc)
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
          | Sqlite3.Data.NONE | Sqlite3.Data.TEXT _ | Sqlite3.Data.BLOB _ -> None
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
        (* Optional-bound OR predicates force an index scan even when the
           requested window has no rows. Keep each supplied range visible to
           SQLite's planner. SQLite binds NaN as NULL, which is an absent
           bound under this reader's existing NULL semantics. *)
        let predicate column operator = function
          | None -> [], []
          | Some value when Float.is_nan value -> [], []
          | Some value -> [column ^ " " ^ operator ^ " ?"], [Sqlite3.Data.FLOAT value]
        in
        let lower, lower_values = predicate "ts" ">=" since_ts in
        let upper, upper_values = predicate "ts" "<=" until_ts in
        let where = match lower @ upper with
          | [] -> ""
          | predicates -> " WHERE " ^ String.concat " AND " predicates
        in
        with_statement
          store.db
          ~operation:"read recent tool metrics"
          ("SELECT record_id, ts, tool_name, disposition, duration_ms \
            FROM tool_metric_events"
           ^ where ^ " ORDER BY ts DESC, record_id DESC LIMIT ?")
          (fun statement ->
            let* () =
              bind_all
                store.db
                statement
                ~operation:"bind tool metric read filters"
                (lower_values @ upper_values
                 @ [Sqlite3.Data.INT (Int64.of_int n)])
            in
            let rec loop rows =
              match Sqlite3.step statement with
              | Sqlite3.Rc.ROW -> loop (row_of_statement statement :: rows)
              | Sqlite3.Rc.DONE -> Ok (List.rev rows)
              | (Sqlite3.Rc.OK | Sqlite3.Rc.ERROR | Sqlite3.Rc.INTERNAL | Sqlite3.Rc.PERM | Sqlite3.Rc.ABORT | Sqlite3.Rc.BUSY | Sqlite3.Rc.LOCKED | Sqlite3.Rc.NOMEM | Sqlite3.Rc.READONLY | Sqlite3.Rc.INTERRUPT | Sqlite3.Rc.IOERR | Sqlite3.Rc.CORRUPT | Sqlite3.Rc.NOTFOUND | Sqlite3.Rc.FULL | Sqlite3.Rc.CANTOPEN | Sqlite3.Rc.PROTOCOL | Sqlite3.Rc.EMPTY | Sqlite3.Rc.SCHEMA | Sqlite3.Rc.TOOBIG | Sqlite3.Rc.CONSTRAINT | Sqlite3.Rc.MISMATCH | Sqlite3.Rc.MISUSE | Sqlite3.Rc.NOFLS | Sqlite3.Rc.AUTH | Sqlite3.Rc.FORMAT | Sqlite3.Rc.RANGE | Sqlite3.Rc.NOTADB | Sqlite3.Rc.UNKNOWN _) as rc -> Error (sqlite_error store.db "read recent tool metrics" rc)
            in
            loop []))

(* The series is read on a connection of its own. A scan over a month of rows
   then neither holds [store_lock] nor makes [insert] wait, and WAL mode lets
   the reader run beside the writer. *)
let with_read_only_db ~path f =
  let run db =
    let* () = exec db ~operation:"set busy timeout" busy_timeout_sql in
    f db
  in
  match Sqlite3.db_open ~mode:`READONLY path with
  | exception Sqlite3.Error detail -> Error ("open read-only database: " ^ detail)
  | db ->
    let result =
      try run db with
      | Sqlite3.Error detail -> Error ("SQLite read: " ^ detail)
    in
    let closed = close_db db in
    (match result, closed with
     | Ok _, false -> Error "close read-only database: SQLite kept the handle open"
     | Ok _, true | Error _, (true | false) -> result)
;;

(* Calls [f] for every row [statement] yields and returns how many rows it
   yielded. *)
let fold_statement db statement ~operation ~f =
  let rec loop count =
    match Sqlite3.step statement with
    | Sqlite3.Rc.ROW ->
      let* () = f statement in
      loop (count + 1)
    | Sqlite3.Rc.DONE -> Ok count
    | (Sqlite3.Rc.OK | Sqlite3.Rc.ERROR | Sqlite3.Rc.INTERNAL | Sqlite3.Rc.PERM | Sqlite3.Rc.ABORT | Sqlite3.Rc.BUSY | Sqlite3.Rc.LOCKED | Sqlite3.Rc.NOMEM | Sqlite3.Rc.READONLY | Sqlite3.Rc.INTERRUPT | Sqlite3.Rc.IOERR | Sqlite3.Rc.CORRUPT | Sqlite3.Rc.NOTFOUND | Sqlite3.Rc.FULL | Sqlite3.Rc.CANTOPEN | Sqlite3.Rc.PROTOCOL | Sqlite3.Rc.EMPTY | Sqlite3.Rc.SCHEMA | Sqlite3.Rc.TOOBIG | Sqlite3.Rc.CONSTRAINT | Sqlite3.Rc.MISMATCH | Sqlite3.Rc.MISUSE | Sqlite3.Rc.NOFLS | Sqlite3.Rc.AUTH | Sqlite3.Rc.FORMAT | Sqlite3.Rc.RANGE | Sqlite3.Rc.NOTADB | Sqlite3.Rc.UNKNOWN _) as rc -> Error (sqlite_error db operation rc)
  in
  loop 0
;;

let series_select =
  "SELECT e.ts, e.tool_name, e.disposition, e.duration_ms, s.result_bytes, \
   c.failure_class \
   FROM tool_metric_events e \
   LEFT JOIN tool_metric_result_sizes s ON s.record_id = e.record_id \
   LEFT JOIN tool_metric_failure_classes c ON c.record_id = e.record_id \
   WHERE e.ts >= ?1 AND e.ts < ?2"
;;

let series_sql = function
  | None -> series_select
  | Some _ -> series_select ^ " AND e.tool_name = ?3"
;;

let sample_of_statement statement =
  let* disposition =
    Tool_metrics_series.disposition_of_string (Sqlite3.column_text statement 2)
  in
  (* NULL is a call whose size was not recorded, not a call of size zero. *)
  let* result_bytes =
    match Sqlite3.column statement 4 with
    | Sqlite3.Data.NULL -> Ok None
    | Sqlite3.Data.INT bytes -> Ok (Some (Int64.to_int bytes))
    | (Sqlite3.Data.NONE | Sqlite3.Data.FLOAT _ | Sqlite3.Data.TEXT _ | Sqlite3.Data.BLOB _) as other ->
      Error
        ("tool metric result size is not an integer: " ^ Sqlite3.Data.to_string_debug other)
  in
  (* NULL is a failure whose class was not recorded, or a call that did not fail. *)
  let* failure_class =
    match Sqlite3.column statement 5 with
    | Sqlite3.Data.NULL -> Ok None
    | Sqlite3.Data.TEXT text ->
      (match Tool_result.tool_failure_class_of_string text with
       | Some failure_class -> Ok (Some failure_class)
       | None -> Error ("unknown persisted tool metric failure class: " ^ text))
    | (Sqlite3.Data.NONE | Sqlite3.Data.INT _ | Sqlite3.Data.FLOAT _ | Sqlite3.Data.BLOB _) as other ->
      Error
        ("tool metric failure class is not text: " ^ Sqlite3.Data.to_string_debug other)
  in
  Ok
    { Tool_metrics_series.ts = Sqlite3.column_double statement 0
    ; tool_name = Sqlite3.column_text statement 1
    ; disposition
    ; duration_ms = Sqlite3.column_double statement 3
    ; result_bytes
    ; failure_class
    }
;;

let read_series_rows db ~window ?tool_name add =
  let since, until = Tool_metrics_series.window_bounds window in
  let bounds = [ Sqlite3.Data.FLOAT since; Sqlite3.Data.FLOAT until ] in
  let values = match tool_name with
    | None -> bounds
    | Some name -> bounds @ [ Sqlite3.Data.TEXT name ] in
  let operation = "read tool metric series" in
  with_statement db ~operation (series_sql tool_name) (fun statement ->
    let* () = bind_all db statement ~operation:"bind tool metric series filters" values in
    fold_statement db statement ~operation ~f:(fun row ->
      let* sample = sample_of_statement row in
      add sample))
;;

let read_series ~masc_root ~window ?tool_name () =
  let builder = Tool_metrics_series.builder window in
  let path = database_path ~masc_root in
  if not (Sys.file_exists path)
  then Ok (Tool_metrics_series.finish builder)
  else (
    let* _row_count =
      with_read_only_db ~path (fun db -> read_series_rows db ~window ?tool_name
        (Tool_metrics_series.add builder))
    in
    Ok (Tool_metrics_series.finish builder))
;;

type series_observation = {
  series : Tool_metrics_series.t;
  next_change_at : float;
}

let first_future_sample db ~until ?tool_name () =
  let sql = "SELECT MIN(ts) FROM tool_metric_events WHERE ts >= ?1" in
  let sql, values = match tool_name with
    | None -> sql, [Sqlite3.Data.FLOAT until]
    | Some name -> sql ^ " AND tool_name = ?2", [Sqlite3.Data.FLOAT until; Sqlite3.Data.TEXT name] in
  let operation = "read next tool metric admission" in
  with_statement db ~operation sql (fun statement ->
    let* () = bind_all db statement ~operation values in
    let found = ref None in
    let* _ = fold_statement db statement ~operation ~f:(fun row ->
      if Sqlite3.column row 0 = Sqlite3.Data.NULL then Ok ()
      else
        let ts = Sqlite3.column_double row 0 in
        if Float.is_finite ts then (found := Some ts; Ok ())
        else Error "next tool metric timestamp is not finite") in
    Ok !found)
;;

let observe_series ~masc_root ~window ?tool_name () =
  let builder = Tool_metrics_series.builder window in
  let oldest = ref None in
  let finish next_sample =
    { series = Tool_metrics_series.finish builder
    ; next_change_at = Tool_metrics_series.next_change_at window
        ~oldest_sample:!oldest ~next_sample } in
  let path = database_path ~masc_root in
  if not (Sys.file_exists path) then Ok (finish None)
  else with_read_only_db ~path (fun db ->
    let* () = exec db ~operation:"begin series observation" "BEGIN" in
    let result =
      let* _ = read_series_rows db ~window ?tool_name (fun sample ->
        let* () = Tool_metrics_series.add builder sample in
        oldest := Some (match !oldest with None -> sample.ts | Some ts -> min ts sample.ts);
        Ok ()) in
      let _, until = Tool_metrics_series.window_bounds window in
      let* next_sample = first_future_sample db ~until ?tool_name () in
      Ok (finish next_sample) in
    match result with
    | Ok _ ->
        let* () = exec db ~operation:"finish series observation" "COMMIT" in
        result
    | Error _ ->
        ignore (exec db ~operation:"rollback series observation" "ROLLBACK");
        result)
;;

let row_to_json row =
  `Assoc
    [ "record_id", `String row.record_id
    ; "ts", `Float row.ts
    ; "tool_name", `String row.tool_name
    ; "disposition", `String row.disposition
    ; "duration_ms", `Float row.duration_ms
    ]
