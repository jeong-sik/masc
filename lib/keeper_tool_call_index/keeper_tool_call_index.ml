(* A derived read index over the keeper tool-call ledger. See the .mli and
   RFC-0437. The SQLite settings match Tool_metrics_store, which has run this
   shape since RFC-0398: WAL so a reader does not block the writer, NORMAL
   because losing the index to a crash costs a rebuild rather than data, and
   a busy timeout so two fibers racing the same advance wait instead of
   failing. *)

let ( let* ) = Result.bind

(* Bumped when the schema below changes. A file that does not carry this
   number is deleted and rebuilt: the index is derived, so there is nothing
   to migrate. *)
let schema_version = 1

let database_path ~ledger_dir = Filename.concat ledger_dir "read-index.sqlite3"

let schema_sql =
  {|
CREATE TABLE IF NOT EXISTS rows (
  ledger_path TEXT NOT NULL,
  ledger_offset INTEGER NOT NULL CHECK (ledger_offset >= 0),
  ledger_length INTEGER NOT NULL CHECK (ledger_length > 0),
  ts REAL NOT NULL,
  keeper_name TEXT NOT NULL,
  PRIMARY KEY (ledger_path, ledger_offset)
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS rows_keeper_ts ON rows(keeper_name, ts);
CREATE INDEX IF NOT EXISTS rows_ts ON rows(ts);
CREATE TABLE IF NOT EXISTS cursors (
  ledger_path TEXT PRIMARY KEY NOT NULL,
  boundary INTEGER NOT NULL CHECK (boundary >= 0)
) WITHOUT ROWID;
|}

type store = { db : Sqlite3.db }

let store_mu = Stdlib.Mutex.create ()
let stores : (string, store) Hashtbl.t = Hashtbl.create 4

let sqlite_error db operation rc =
  Printf.sprintf
    "%s: rc=%s detail=%s"
    operation
    (Sqlite3.Rc.to_string rc)
    (Sqlite3.errmsg db)
;;

let exec db ~operation sql =
  let rc = Sqlite3.exec db sql in
  if Sqlite3.Rc.is_success rc then Ok () else Error (sqlite_error db operation rc)
;;

let close_db db =
  let closed = Sqlite3.db_close db in
  (* sqlite3-ocaml releases the OCaml runtime during close. Keep the wrapper
     reachable until the C call has returned. *)
  (* fire-and-forget: the value is only kept reachable, never read. *)
  ignore (Sys.opaque_identity db);
  closed
;;

(* A finalize that fails leaves nothing for a caller to do, and the statement
   is unreachable either way. *)
let finalize stmt =
  (* fire-and-forget: nothing to do with the code. *)
  ignore (Sqlite3.finalize stmt : Sqlite3.Rc.t)
;;

(* Every statement runs through here so a caller cannot forget to finalize;
   an abandoned statement holds the WAL read lock open. *)
let with_stmt db ~operation sql f =
  match Sqlite3.prepare db sql with
  | exception Sqlite3.Error detail -> Error (operation ^ ": prepare failed: " ^ detail)
  | stmt ->
    let result = try f stmt with Sqlite3.Error detail -> Error (operation ^ ": " ^ detail) in
    finalize stmt;
    result
;;

let step_done db ~operation stmt =
  match Sqlite3.step stmt with
  | Sqlite3.Rc.DONE -> Ok ()
  | rc -> Error (sqlite_error db operation rc)
;;

let single_int db ~operation sql =
  with_stmt db ~operation sql (fun stmt ->
    match Sqlite3.step stmt with
    | Sqlite3.Rc.ROW ->
      (match Sqlite3.column stmt 0 with
       | Sqlite3.Data.INT value -> Ok (Int64.to_int value)
       | _ -> Error (operation ^ ": expected an integer"))
    | rc -> Error (sqlite_error db operation rc))
;;

let configure db =
  let* _ =
    with_stmt db ~operation:"set WAL journal mode" "PRAGMA journal_mode=WAL" (fun stmt ->
      match Sqlite3.step stmt with
      | Sqlite3.Rc.ROW | Sqlite3.Rc.DONE -> Ok ()
      | rc -> Error (sqlite_error db "set WAL journal mode" rc))
  in
  let* () = exec db ~operation:"set NORMAL synchronous" "PRAGMA synchronous=NORMAL" in
  let* () = exec db ~operation:"set busy timeout" "PRAGMA busy_timeout=5000" in
  let* () = exec db ~operation:"create index schema" schema_sql in
  exec
    db
    ~operation:"stamp schema version"
    (Printf.sprintf "PRAGMA user_version=%d" schema_version)
;;

let open_fresh ~path =
  try
    Fs_compat.mkdir_p (Filename.dirname path);
    let db = Sqlite3.db_open path in
    match configure db with
    | Ok () -> Ok db
    | Error detail ->
      (* fire-and-forget: the open already failed. *)
      ignore (close_db db : bool);
      Error detail
  with
  | Sqlite3.Error detail -> Error ("open index: " ^ detail)
  | Sys_error detail -> Error ("open index: " ^ detail)
;;

(* A file whose version does not match is not migrated. It is removed and
   made again from the ledger, which is the only authority either way. *)
let open_store ~ledger_dir =
  let path = database_path ~ledger_dir in
  let* db = open_fresh ~path in
  let* version = single_int db ~operation:"read schema version" "PRAGMA user_version" in
  if version = schema_version
  then Ok { db }
  else begin
    (* fire-and-forget: the file is removed next. *)
    ignore (close_db db : bool);
    (try Sys.remove path with Sys_error _ -> ());
    let* db = open_fresh ~path in
    Ok { db }
  end
;;

let get_store ~ledger_dir =
  match Hashtbl.find_opt stores ledger_dir with
  | Some store -> Ok store
  | None ->
    let* store = open_store ~ledger_dir in
    Hashtbl.replace stores ledger_dir store;
    Ok store
;;

let drop_store ~ledger_dir =
  match Hashtbl.find_opt stores ledger_dir with
  | None -> ()
  | Some store ->
    Hashtbl.remove stores ledger_dir;
    (* fire-and-forget: the handle is already out of the table. *)
    ignore (close_db store.db : bool)
;;

let forget_for_ledger ~ledger_dir =
  Stdlib.Mutex.protect store_mu (fun () -> drop_store ~ledger_dir)
;;

let read_cursors store =
  with_stmt
    store.db
    ~operation:"read cursors"
    "SELECT ledger_path, boundary FROM cursors"
    (fun stmt ->
       let rec loop acc =
         match Sqlite3.step stmt with
         | Sqlite3.Rc.ROW ->
           (match Sqlite3.column stmt 0, Sqlite3.column stmt 1 with
            | Sqlite3.Data.TEXT path, Sqlite3.Data.INT boundary ->
              loop ((path, Int64.to_int boundary) :: acc)
            | _ -> Error "read cursors: unexpected column types")
         | Sqlite3.Rc.DONE -> Ok acc
         | rc -> Error (sqlite_error store.db "read cursors" rc)
       in
       loop [])
;;

let keeper_of_row json =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt "keeper" fields with
     | Some (`String value) -> Some value
     | Some _ | None -> None)
  | _ -> None
;;

let ts_of_row json =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt "ts" fields with
     | Some (`Float value) -> Some value
     | Some (`Int value) -> Some (Float.of_int value)
     | Some _ | None -> None)
  | _ -> None
;;

(* A row with no keeper or no timestamp cannot answer either query, so it is
   not indexed. It stays in the ledger, which is where it is authoritative. *)
let indexable line =
  match Yojson.Safe.from_string line with
  | exception Yojson.Json_error _ -> None
  | json ->
    (match keeper_of_row json, ts_of_row json with
     | Some keeper, Some ts -> Some (keeper, ts)
     | _ -> None)
;;

let insert_sql =
  "INSERT OR REPLACE INTO rows (ledger_path, ledger_offset, ledger_length, ts, \
   keeper_name) VALUES (?, ?, ?, ?, ?)"
;;

let cursor_sql = "INSERT OR REPLACE INTO cursors (ledger_path, boundary) VALUES (?, ?)"

let bind_all db ~operation stmt values =
  let rec loop index = function
    | [] -> Ok ()
    | value :: rest ->
      (match Sqlite3.bind stmt index value with
       | rc when Sqlite3.Rc.is_success rc -> loop (index + 1) rest
       | rc -> Error (sqlite_error db operation rc))
  in
  let* () = loop 1 values in
  Ok ()
;;

let advance_one store ~path ~from =
  let* () = exec store.db ~operation:"begin advance" "BEGIN IMMEDIATE" in
  let rollback detail =
    (* fire-and-forget: the reported failure is the one worth keeping. *)
    ignore (exec store.db ~operation:"rollback advance" "ROLLBACK" : (unit, string) result);
    Error detail
  in
  match
    with_stmt store.db ~operation:"insert row" insert_sql (fun insert ->
      let pending, boundary =
        Fs_compat.fold_appended_lines_with_offsets
          ~path
          ~from
          ~init:(Ok ())
          ~f:(fun acc ~offset line ->
            match acc with
            | Error _ -> acc
            | Ok () ->
              (match indexable line with
               | None -> acc
               | Some (keeper, ts) ->
                 (* fire-and-forget: reset returns the last step's code. *)
                 ignore (Sqlite3.reset insert : Sqlite3.Rc.t);
                 let* () =
                   bind_all
                     store.db
                     ~operation:"bind row"
                     insert
                     [ Sqlite3.Data.TEXT path
                     ; Sqlite3.Data.INT (Int64.of_int offset)
                     ; Sqlite3.Data.INT (Int64.of_int (String.length line))
                     ; Sqlite3.Data.FLOAT ts
                     ; Sqlite3.Data.TEXT keeper
                     ]
                 in
                 step_done store.db ~operation:"insert row" insert))
      in
      let* () = pending in
      Ok boundary)
  with
  | Error detail -> rollback detail
  | Ok boundary ->
    (match
       with_stmt store.db ~operation:"write cursor" cursor_sql (fun stmt ->
         let* () =
           bind_all
             store.db
             ~operation:"bind cursor"
             stmt
             [ Sqlite3.Data.TEXT path; Sqlite3.Data.INT (Int64.of_int boundary) ]
         in
         step_done store.db ~operation:"write cursor" stmt)
     with
     | Error detail -> rollback detail
     | Ok () ->
       let* () = exec store.db ~operation:"commit advance" "COMMIT" in
       Ok (from, boundary))
;;

(* A day file shorter than its cursor was rotated or rewritten, and
   [fold_appended_lines_with_offsets] re-reads it from zero. The rows it just
   wrote are keyed by (path, offset) and replaced in place, but rows the old
   file had past the new end are stale, so they go. *)
let drop_rows_past store ~path ~boundary =
  with_stmt
    store.db
    ~operation:"drop stale rows"
    "DELETE FROM rows WHERE ledger_path = ? AND ledger_offset >= ?"
    (fun stmt ->
       let* () =
         bind_all
           store.db
           ~operation:"bind stale rows"
           stmt
           [ Sqlite3.Data.TEXT path; Sqlite3.Data.INT (Int64.of_int boundary) ]
       in
       step_done store.db ~operation:"drop stale rows" stmt)
;;

let advance store ~paths ~cursors =
  List.fold_left
    (fun acc path ->
       let* () = acc in
       let from = match List.assoc_opt path cursors with Some n -> n | None -> 0 in
       let* previous, boundary = advance_one store ~path ~from in
       if boundary < previous
       then drop_rows_past store ~path ~boundary
       else Ok ())
    (Ok ())
    paths
;;

let select_sql ~filtered =
  Printf.sprintf
    "SELECT ledger_path, ledger_offset, ledger_length FROM rows%s ORDER BY ts DESC, \
     ledger_path DESC, ledger_offset DESC LIMIT ?"
    (if filtered then " WHERE keeper_name = ?" else "")
;;

let select_locations store ~keeper_name ~n =
  let filtered = Option.is_some keeper_name in
  with_stmt store.db ~operation:"select rows" (select_sql ~filtered) (fun stmt ->
    let bindings =
      match keeper_name with
      | Some name -> [ Sqlite3.Data.TEXT name; Sqlite3.Data.INT (Int64.of_int n) ]
      | None -> [ Sqlite3.Data.INT (Int64.of_int n) ]
    in
    let* () = bind_all store.db ~operation:"bind select" stmt bindings in
    let rec loop acc =
      match Sqlite3.step stmt with
      | Sqlite3.Rc.ROW ->
        (match Sqlite3.column stmt 0, Sqlite3.column stmt 1, Sqlite3.column stmt 2 with
         | Sqlite3.Data.TEXT path, Sqlite3.Data.INT offset, Sqlite3.Data.INT length ->
           loop ((path, Int64.to_int offset, Int64.to_int length) :: acc)
         | _ -> Error "select rows: unexpected column types")
      | Sqlite3.Rc.DONE -> Ok acc
      | rc -> Error (sqlite_error store.db "select rows" rc)
    in
    (* The query is newest first so the limit takes the newest [n]; the
       accumulator reverses it back to oldest first, which is the order the
       ledger readers return. *)
    loop [])
;;

let rows_of_locations locations =
  List.filter_map
    (fun (path, offset, length) ->
       let line = Fs_compat.read_slice ~path ~from:offset ~len:length in
       if String.equal line ""
       then None
       else (
         match Yojson.Safe.from_string line with
         | json -> Some json
         | exception Yojson.Json_error _ -> None))
    locations
;;

let recent_rows ~store:ledger ?keeper_name ~n () =
  if n <= 0
  then Ok []
  else begin
    let ledger_dir = Dated_jsonl.base_dir ledger in
    Stdlib.Mutex.protect store_mu (fun () ->
      let attempt () =
        let* store = get_store ~ledger_dir in
        let* cursors = read_cursors store in
        let paths =
          Dated_jsonl.range_day_file_paths
            ledger
            ~since:"1970-01-01"
            ~until:(Jsonl_writer.day_key ~ts:(Unix.gettimeofday ()))
        in
        let* () = advance store ~paths ~cursors in
        let* locations = select_locations store ~keeper_name ~n in
        Ok (rows_of_locations locations)
      in
      match attempt () with
      | Ok rows -> Ok rows
      | Error _ ->
        (* One retry on a fresh file: a half-written or externally replaced
           index is thrown away rather than read around. *)
        drop_store ~ledger_dir;
        (try Sys.remove (database_path ~ledger_dir) with Sys_error _ -> ());
        attempt ())
  end
;;
