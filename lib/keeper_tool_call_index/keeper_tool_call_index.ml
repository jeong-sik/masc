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
let schema_version = 2

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
  boundary INTEGER NOT NULL CHECK (boundary >= 0),
  device INTEGER NOT NULL,
  inode INTEGER NOT NULL,
  observed_size INTEGER NOT NULL,
  mtime REAL NOT NULL,
  ctime REAL NOT NULL
) WITHOUT ROWID;
|}

type store = { db : Sqlite3.db }

let store_mu = Stdlib.Mutex.create ()
let stores : (string, store) Hashtbl.t = Hashtbl.create 4

(* A system thread has no Eio effect handler: Fs_compat's filesystem helpers
   take their synchronous fallback even when the server installed global_fs.
   Acquire the mutex inside that thread, never on the scheduler thread. *)
let blocking f =
  match Fs_compat.execution_context () with
  | Fs_compat.Non_eio -> f ()
  | Fs_compat.Eio_fiber ->
    Eio_unix.run_in_systhread ~label:"keeper tool-call read index" f
;;

type cursor =
  { boundary : int
  ; device : int
  ; inode : int
  ; observed_size : int
  ; mtime : float
  ; ctime : float
  }

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
    Fun.protect ~finally:(fun () -> finalize stmt) (fun () ->
      try f stmt with Sqlite3.Error detail -> Error (operation ^ ": " ^ detail))
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

let open_database ~path ~initialize =
  try
    Fs_compat.mkdir_p (Filename.dirname path);
    let db = Sqlite3.db_open path in
    let keep = ref false in
    Fun.protect
      ~finally:(fun () ->
        (* fire-and-forget: the open failed or this handle will be replaced. *)
        if not !keep then ignore (close_db db : bool))
      (fun () ->
        match initialize db with
        | Ok () -> keep := true; Ok db
        | Error _ as error -> error)
  with
  | Sqlite3.Error detail -> Error ("open index: " ^ detail)
  | Sys_error detail -> Error ("open index: " ^ detail)
;;

(* A file whose version does not match is not migrated. It is removed and
   made again from the ledger, which is the only authority either way. *)
let open_store ~ledger_dir =
  let path = database_path ~ledger_dir in
  let* db = open_database ~path ~initialize:(fun _ -> Ok ()) in
  let keep = ref false in
  let* existing =
    Fun.protect
      ~finally:(fun () ->
        (* fire-and-forget: the open failed or this handle will be replaced. *)
        if not !keep then ignore (close_db db : bool))
      (fun () ->
        let* version = single_int db ~operation:"read schema version" "PRAGMA user_version" in
        if version <> schema_version then Ok None
        else
          let* () = configure db in
          keep := true;
          Ok (Some db))
  in
  match existing with
  | Some db -> Ok { db }
  | None ->
    Sys.remove path;
    let* db = open_database ~path ~initialize:configure in
    Ok { db }
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
  blocking (fun () -> Stdlib.Mutex.protect store_mu (fun () -> drop_store ~ledger_dir))
;;

let read_cursors store =
  with_stmt
    store.db
    ~operation:"read cursors"
    "SELECT ledger_path, boundary, device, inode, observed_size, mtime, ctime FROM cursors"
    (fun stmt ->
       let rec loop acc =
         match Sqlite3.step stmt with
         | Sqlite3.Rc.ROW ->
           (match Array.to_list (Sqlite3.row_data stmt) with
            | [ Sqlite3.Data.TEXT path; Sqlite3.Data.INT boundary
              ; Sqlite3.Data.INT device; Sqlite3.Data.INT inode
              ; Sqlite3.Data.INT observed_size; Sqlite3.Data.FLOAT mtime
              ; Sqlite3.Data.FLOAT ctime ] ->
              let cursor =
                { boundary = Int64.to_int boundary; device = Int64.to_int device
                ; inode = Int64.to_int inode; observed_size = Int64.to_int observed_size
                ; mtime; ctime }
              in
              loop ((path, cursor) :: acc)
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

let cursor_sql =
  "INSERT OR REPLACE INTO cursors \
   (ledger_path, boundary, device, inode, observed_size, mtime, ctime) \
   VALUES (?, ?, ?, ?, ?, ?, ?)"

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

let delete_path store ~table ~path =
  with_stmt store.db ~operation:"invalidate ledger path"
    ("DELETE FROM " ^ table ^ " WHERE ledger_path = ?")
    (fun stmt ->
      let* () = bind_all store.db ~operation:"bind ledger path" stmt
          [ Sqlite3.Data.TEXT path ] in
      step_done store.db ~operation:"invalidate ledger path" stmt)
;;

let transaction store f =
  let* () = exec store.db ~operation:"begin advance" "BEGIN IMMEDIATE" in
  let committed = ref false in
  Fun.protect
    ~finally:(fun () ->
      (* fire-and-forget: preserve the original transaction failure. *)
      if not !committed then
        ignore (exec store.db ~operation:"rollback advance" "ROLLBACK"
                : (unit, string) result))
    (fun () ->
      let* value = f () in
      let* () = exec store.db ~operation:"commit advance" "COMMIT" in
      committed := true;
      Ok value)
;;

let inspect_file path =
  let stat = Unix.lstat path in
  if stat.Unix.st_kind = Unix.S_REG then Ok stat
  else Error ("ledger path is not a regular file: " ^ path)
;;

let append_continues (cursor : cursor) (stat : Unix.stats) =
  cursor.device = stat.st_dev
  && cursor.inode = stat.st_ino
  && stat.st_size >= cursor.observed_size
  && (stat.st_size > cursor.observed_size
      || (stat.st_mtime = cursor.mtime && stat.st_ctime = cursor.ctime))
;;

let advance_one store ~before_scan ~path ~cursor =
  let* before = inspect_file path in
  let from, invalidate =
    match cursor with
    | Some cursor when append_continues cursor before -> cursor.boundary, false
    | Some _ -> 0, true
    | None -> 0, false
  in
  transaction store (fun () ->
    let* () = if invalidate then delete_path store ~table:"rows" ~path else Ok () in
    let* boundary =
      with_stmt store.db ~operation:"insert row" insert_sql (fun insert ->
        before_scan ~path;
        let pending, boundary =
          Fs_compat.fold_appended_lines_with_offsets
            ~path ~from ~init:(Ok ())
            ~f:(fun acc ~offset line ->
              let* () = acc in
              match indexable line with
              | None -> Ok ()
              | Some (keeper, ts) ->
                (* fire-and-forget: reset returns the last step's code. *)
                ignore (Sqlite3.reset insert : Sqlite3.Rc.t);
                let* () = bind_all store.db ~operation:"bind row" insert
                    [ Sqlite3.Data.TEXT path
                    ; Sqlite3.Data.INT (Int64.of_int offset)
                    ; Sqlite3.Data.INT (Int64.of_int (String.length line))
                    ; Sqlite3.Data.FLOAT ts
                    ; Sqlite3.Data.TEXT keeper ] in
                step_done store.db ~operation:"insert row" insert)
        in
        let* () = pending in
        Ok boundary)
    in
    let* after = inspect_file path in
    (* An append may race the scan. The cursor boundary still names the
       complete lines consumed, independently of the observed file size.
       Replacement or shrink during this read invalidates the transaction. *)
    let* () =
      if before.st_dev = after.st_dev && before.st_ino = after.st_ino
         && after.st_size >= before.st_size && after.st_size >= boundary
         && (after.st_size > before.st_size
             || (after.st_mtime = before.st_mtime && after.st_ctime = before.st_ctime))
      then Ok ()
      else Error ("ledger changed identity during indexing: " ^ path)
    in
    with_stmt store.db ~operation:"write cursor" cursor_sql (fun stmt ->
      let* () = bind_all store.db ~operation:"bind cursor" stmt
          [ Sqlite3.Data.TEXT path
          ; Sqlite3.Data.INT (Int64.of_int boundary)
          ; Sqlite3.Data.INT (Int64.of_int after.st_dev)
          ; Sqlite3.Data.INT (Int64.of_int after.st_ino)
          ; Sqlite3.Data.INT (Int64.of_int after.st_size)
          ; Sqlite3.Data.FLOAT after.st_mtime
          ; Sqlite3.Data.FLOAT after.st_ctime ] in
      step_done store.db ~operation:"write cursor" stmt))
;;

let advance store ~before_scan ~paths ~cursors =
  let* () =
    List.fold_left
      (fun acc (path, _) ->
        let* () = acc in
        if List.mem path paths then Ok ()
        else transaction store (fun () ->
          let* () = delete_path store ~table:"rows" ~path in
          delete_path store ~table:"cursors" ~path))
      (Ok ()) cursors
  in
  List.fold_left
    (fun acc path ->
      let* () = acc in
      advance_one store ~before_scan ~path ~cursor:(List.assoc_opt path cursors))
    (Ok ()) paths
;;

let select_sql ~filtered =
  Printf.sprintf
    "SELECT ledger_path, ledger_offset, ledger_length, keeper_name, ts FROM rows%s ORDER BY ts DESC, \
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
        (match Array.to_list (Sqlite3.row_data stmt) with
         | [ Sqlite3.Data.TEXT path; Sqlite3.Data.INT offset; Sqlite3.Data.INT length
           ; Sqlite3.Data.TEXT keeper; Sqlite3.Data.FLOAT ts ] ->
           loop ((path, Int64.to_int offset, Int64.to_int length, keeper, ts) :: acc)
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
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | (path, offset, length, keeper, ts) :: rest ->
      let line = Fs_compat.read_slice ~path ~from:offset ~len:length in
      let* json =
        try Ok (Yojson.Safe.from_string line) with
        | Yojson.Json_error _ -> Error ("indexed ledger row is no longer readable: " ^ path)
      in
      if String.length line = length
         && keeper_of_row json = Some keeper && ts_of_row json = Some ts
      then loop (json :: acc) rest
      else Error ("indexed ledger row no longer matches its identity: " ^ path)
  in
  loop [] locations
;;

let recent_rows_with ~before_scan ~store:ledger ?keeper_name ~n () =
  if n <= 0 then Ok []
  else
    blocking (fun () ->
      let ledger_dir = Dated_jsonl.base_dir ledger in
      Stdlib.Mutex.protect store_mu (fun () ->
        let attempt () =
          try
            let* store = get_store ~ledger_dir in
            let* cursors = read_cursors store in
            let* paths =
              Dated_jsonl.range_day_file_paths_result ledger ~since:"1970-01-01"
                ~until:(Jsonl_writer.day_key ~ts:(Unix.gettimeofday ()))
              |> Result.map_error Dated_jsonl.read_error_to_string
            in
            let* () = advance store ~before_scan ~paths ~cursors in
            let* locations = select_locations store ~keeper_name ~n in
            rows_of_locations locations
          with
          | Sys_error detail -> Error ("read index: " ^ detail)
          | Unix.Unix_error (error, operation, path) ->
            Error (Printf.sprintf "%s %s: %s" operation path (Unix.error_message error))
          | Sqlite3.Error detail -> Error ("read index: " ^ detail)
        in
        let discard () =
          drop_store ~ledger_dir;
          try Sys.remove (database_path ~ledger_dir) with Sys_error _ -> ()
        in
        match attempt () with
        | Ok _ as result -> result
        | Error _ ->
          discard ();
          match attempt () with
          | Ok _ as result -> result
          | Error _ as error -> discard (); error))
;;

let recent_rows = recent_rows_with ~before_scan:(fun ~path:_ -> ())

module For_testing = struct
  let recent_rows = recent_rows_with
end
