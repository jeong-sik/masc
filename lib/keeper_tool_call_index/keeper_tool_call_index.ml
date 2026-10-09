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
let schema_version = 5

let database_path ~ledger_dir = Filename.concat ledger_dir "read-index.sqlite3"

let schema_sql =
  {|
CREATE TABLE IF NOT EXISTS rows (
  ledger_path TEXT NOT NULL,
  ledger_offset INTEGER NOT NULL CHECK (ledger_offset >= 0),
  ledger_length INTEGER NOT NULL CHECK (ledger_length > 0),
  ts REAL NOT NULL,
  keeper_name TEXT NOT NULL,
  execution_id TEXT,
  PRIMARY KEY (ledger_path, ledger_offset)
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS rows_keeper_ts ON rows(keeper_name, ts);
CREATE INDEX IF NOT EXISTS rows_keeper_append ON rows(keeper_name, ledger_path, ledger_offset);
CREATE INDEX IF NOT EXISTS rows_ts ON rows(ts);
CREATE INDEX IF NOT EXISTS rows_keeper_execution ON rows(keeper_name, execution_id);
CREATE TABLE IF NOT EXISTS cursors (
  ledger_path TEXT PRIMARY KEY NOT NULL,
  boundary INTEGER NOT NULL CHECK (boundary >= 0),
  device INTEGER NOT NULL,
  inode INTEGER NOT NULL,
  generation TEXT NOT NULL
) WITHOUT ROWID;
|}

type store =
  { db : Sqlite3.db
  ; observations : (string, Unix.stats) Hashtbl.t
  }

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

(* [generation] names one continuous append run of a file. A rewrite or
   shrink that keeps the same path and inode starts a new run, so a position
   held from the old run never covers a row of the new one. *)
type position =
  { path : string; device : int; inode : int; generation : string; offset : int }
type frontier = position list
type 'a positioned = { position : position; value : 'a }
type 'a batch = { frontier : frontier; retained : frontier; rows : 'a positioned list }

let new_generation =
  let generate = Uuidm.v4_gen (Random.State.make_self_init ()) in
  fun () -> Uuidm.to_string (generate ())

let empty_frontier = []
let identity (p : position) = p.path, p.device, p.inode, p.generation
let covers frontier (position : position) =
  List.exists (fun (held : position) ->
    identity held = identity position && held.offset >= position.offset) frontier

let merge_frontiers left right =
  List.fold_left (fun held (position : position) ->
    let offset = List.fold_left (fun offset (previous : position) ->
      if identity previous = identity position then max offset previous.offset else offset)
      position.offset held in
    { position with offset } :: List.filter (fun previous -> identity previous <> identity position) held)
    left right
  |> List.sort (fun a b -> compare (identity a) (identity b))

let equal_frontiers left right = left = right
let frontier_to_json frontier =
  `List (List.map (fun (p : position) -> `Assoc
    [ "path", `String p.path; "device", `Int p.device; "inode", `Int p.inode;
      "generation", `String p.generation; "offset", `Int p.offset ]) frontier)

let frontier_of_json = function
  | `List rows ->
    let rec decode acc = function
      | [] -> Ok (merge_frontiers [] acc)
      | `Assoc fields :: rest ->
        (match List.assoc_opt "path" fields, List.assoc_opt "device" fields,
           List.assoc_opt "inode" fields, List.assoc_opt "generation" fields,
           List.assoc_opt "offset" fields with
         | Some (`String path), Some (`Int device), Some (`Int inode),
           Some (`String generation), Some (`Int offset)
           when path <> "" && generation <> "" && offset >= 0 ->
           decode ({ path; device; inode; generation; offset } :: acc) rest
         | _ -> Error "invalid tool-call ledger position")
      | _ -> Error "invalid tool-call ledger position"
    in
    decode [] rows
  | _ -> Error "tool-call ledger frontier is not an array"

type cursor =
  { boundary : int
  ; device : int
  ; inode : int
  ; generation : string
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
  | Some db -> Ok { db; observations = Hashtbl.create 8 }
  | None ->
    Sys.remove path;
    let* db = open_database ~path ~initialize:configure in
    Ok { db; observations = Hashtbl.create 8 }
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
    "SELECT ledger_path, boundary, device, inode, generation FROM cursors"
    (fun stmt ->
       let rec loop acc =
         match Sqlite3.step stmt with
         | Sqlite3.Rc.ROW ->
           (match Array.to_list (Sqlite3.row_data stmt) with
            | [ Sqlite3.Data.TEXT path; Sqlite3.Data.INT boundary
              ; Sqlite3.Data.INT device; Sqlite3.Data.INT inode
              ; Sqlite3.Data.TEXT generation ] ->
              let cursor =
                { boundary = Int64.to_int boundary; device = Int64.to_int device
                ; inode = Int64.to_int inode; generation }
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

let execution_id_of_row = function
  | `Assoc fields ->
    (match List.assoc_opt "execution_id" fields with
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
     | Some keeper, Some ts -> Some (keeper, ts, execution_id_of_row json)
     | _ -> None)
;;

let insert_sql =
  "INSERT OR REPLACE INTO rows (ledger_path, ledger_offset, ledger_length, ts, \
   keeper_name, execution_id) VALUES (?, ?, ?, ?, ?, ?)"
;;

let cursor_sql =
  "INSERT OR REPLACE INTO cursors \
   (ledger_path, boundary, device, inode, generation) \
   VALUES (?, ?, ?, ?, ?)"

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
      if not !committed then
        (* fire-and-forget: preserve the original transaction failure. *)
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

type continuity =
  { generation : string
  ; boundary : int
  ; prefix_digest : string
  ; device : int
  ; inode : int
  }

exception Continuity_unavailable of string

let continuity_dir ledger_dir = Filename.concat ledger_dir ".continuity"
let ledger_dir_of_day_path path = Filename.dirname (Filename.dirname path)
let continuity_path path =
  let key = Digestif.SHA256.(to_hex (digest_string path)) ^ ".json" in
  Filename.concat (continuity_dir (ledger_dir_of_day_path path)) key

let same_observed_file (left : Unix.stats) (right : Unix.stats) =
  left.st_dev = right.st_dev && left.st_ino = right.st_ino
  && left.st_kind = right.st_kind && left.st_size = right.st_size
  && left.st_mtime = right.st_mtime && left.st_ctime = right.st_ctime
let empty_digest = Digestif.SHA256.(to_hex (digest_string ""))
let extend_digest digest line = Digestif.SHA256.(to_hex (digest_string (digest ^ line ^ "\n")))

let load_continuity path =
  try
    let _ = Unix.lstat (continuity_path path) in
    let bytes = Fs_compat.load_file (continuity_path path) in
    match Yojson.Safe.from_string bytes with
    | `Assoc fields ->
      (match List.assoc_opt "ledger_path" fields,
             List.assoc_opt "generation" fields, List.assoc_opt "boundary" fields,
             List.assoc_opt "prefix_digest" fields, List.assoc_opt "device" fields,
             List.assoc_opt "inode" fields with
       | Some (`String ledger_path), Some (`String generation), Some (`Int boundary), Some (`String prefix_digest),
         Some (`Int device), Some (`Int inode)
         when String.equal ledger_path path && boundary >= 0 && Option.is_some (Uuidm.of_string generation) ->
         (match Digestif.SHA256.consistent_of_hex_opt prefix_digest with
          | Some digest when String.equal prefix_digest (Digestif.SHA256.to_hex digest) ->
            Ok (Some { generation; boundary; prefix_digest; device; inode })
          | Some _ | None -> Error "invalid continuity digest")
       | _ -> Error "invalid tool-call ledger continuity record")
    | _ -> Error "tool-call ledger continuity is not an object"
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
  | Sys_error detail -> Error detail
  | Yojson.Json_error detail -> Error ("invalid tool-call ledger continuity: " ^ detail)

let save_continuity path (held : continuity) =
  let json = `Assoc
    [ "ledger_path", `String path
    ; "generation", `String held.generation; "boundary", `Int held.boundary
    ; "prefix_digest", `String held.prefix_digest
    ; "device", `Int held.device; "inode", `Int held.inode ] in
  Fs_compat.mkdir_p (continuity_dir (ledger_dir_of_day_path path));
  Fs_compat.save_file_atomic_strict (continuity_path path) (Yojson.Safe.to_string json)

(* Prefix verification runs in the index's blocking worker. Changed files
   require content evidence even for ordinary appends; filesystem timestamps
   alone cannot distinguish an append from a rewritten prefix plus growth. *)
let digest_prefix ~path ~from ~until digest =
  let channel = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in_noerr channel) (fun () ->
    seek_in channel from;
    let rec loop digest =
      let offset = pos_in channel in
      if offset = until then Some digest
      else if offset > until then None
      else match input_line channel with
        | line -> loop (extend_digest digest line)
        | exception End_of_file -> None in
    loop digest)

(* Hash and index the same complete bytes. Blank lines participate in the
   witness even though they are not JSON rows; an incomplete final line does
   not advance either the digest or the indexed boundary. *)
let fold_indexed_lines ~path ~from ~init ~f =
  let channel = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in_noerr channel) (fun () ->
    seek_in channel from;
    let rec loop acc =
      let offset = pos_in channel in
      match input_line channel with
      | line ->
        let next = pos_in channel in
        if next - offset = String.length line + 1 then
          loop (f acc ~offset ~next line)
        else acc, offset
      | exception End_of_file -> acc, offset in
    loop init)

let prefix_matches path (held : continuity) =
  match digest_prefix ~path ~from:0 ~until:held.boundary empty_digest with
  | Some digest -> String.equal digest held.prefix_digest
  | None -> false

let advance_one store ~before_scan ~path ~(cursor : cursor option) =
  let* before = inspect_file path in
  let unchanged_observation =
    Option.exists (fun previous -> same_observed_file previous before)
      (Hashtbl.find_opt store.observations path) in
  let verified_observation = ref None in
  let result =
    let saved = match load_continuity path with
      | Ok saved -> saved
      | Error detail -> raise (Continuity_unavailable detail) in
    let* held = match saved with
      | None when Option.is_some cursor ->
        raise (Continuity_unavailable ("authoritative ledger continuity is missing: " ^ path))
      | Some held
        when held.device = before.st_dev && held.inode = before.st_ino
             && held.boundary <= before.st_size
             && (unchanged_observation || prefix_matches path held) -> Ok held
      | Some _ | None ->
        Ok { generation = new_generation (); boundary = 0; prefix_digest = empty_digest
           ; device = before.st_dev; inode = before.st_ino } in
    let from, invalidate = match cursor with
      | Some cursor when String.equal cursor.generation held.generation
                         && cursor.device = before.st_dev && cursor.inode = before.st_ino
                         && cursor.boundary = held.boundary -> cursor.boundary, false
      | Some _ -> 0, true
      | None -> 0, false in
    transaction store (fun () ->
      let* () = if invalidate then delete_path store ~table:"rows" ~path else Ok () in
      let scan_digest = ref (if from = held.boundary then held.prefix_digest else empty_digest) in
      let captured_prefix = ref (if from = held.boundary then Some held.prefix_digest else None) in
      let* boundary =
        with_stmt store.db ~operation:"insert row" insert_sql (fun insert ->
          before_scan ~path;
          let pending, boundary =
            fold_indexed_lines
              ~path ~from ~init:(Ok ())
              ~f:(fun acc ~offset ~next line ->
                let* () = acc in
                scan_digest := extend_digest !scan_digest line;
                if next = held.boundary then captured_prefix := Some !scan_digest;
                match indexable line with
                | None -> Ok ()
                | Some (keeper, ts, execution_id) ->
                  ignore (Sqlite3.reset insert : Sqlite3.Rc.t);
                  let* () = bind_all store.db ~operation:"bind row" insert
                      [ Sqlite3.Data.TEXT path
                      ; Sqlite3.Data.INT (Int64.of_int offset)
                      ; Sqlite3.Data.INT (Int64.of_int (String.length line))
                      ; Sqlite3.Data.FLOAT ts
                      ; Sqlite3.Data.TEXT keeper
                      ; (match execution_id with
                         | Some value -> Sqlite3.Data.TEXT value
                         | None -> Sqlite3.Data.NULL) ] in
                  step_done store.db ~operation:"insert row" insert)
          in
          let* () = pending in
          Ok boundary)
      in
      let prefix_digest = !scan_digest in
      let* () =
        if !captured_prefix = Some held.prefix_digest then Ok ()
        else Error ("ledger prefix changed while rebuilding: " ^ path) in
      let* after = inspect_file path in
      (* Appenders are not blocked by this scan. Verify the exact indexed
         prefix after scanning; size growth alone is never continuity proof. *)
      let* () =
        if before.st_dev = after.st_dev && before.st_ino = after.st_ino
           && boundary <= after.st_size
           && ((unchanged_observation && from = boundary && same_observed_file before after)
               || digest_prefix ~path ~from:0 ~until:boundary empty_digest = Some prefix_digest)
        then Ok () else Error ("ledger changed during indexing: " ^ path) in
      verified_observation := Some after;
      let next = { held with boundary; prefix_digest } in
      (* Commit authoritative continuity before the disposable SQLite cursor.
         A failed SQLite commit is repaired from this same durable generation. *)
      let () =
        if Some next <> saved then
          match save_continuity path next with
          | Ok () -> ()
          | Error detail -> raise (Continuity_unavailable detail) in
      with_stmt store.db ~operation:"write cursor" cursor_sql (fun stmt ->
        let* () = bind_all store.db ~operation:"bind cursor" stmt
            [ Sqlite3.Data.TEXT path
            ; Sqlite3.Data.INT (Int64.of_int boundary)
            ; Sqlite3.Data.INT (Int64.of_int after.st_dev)
            ; Sqlite3.Data.INT (Int64.of_int after.st_ino)
            ; Sqlite3.Data.TEXT held.generation ] in
        step_done store.db ~operation:"write cursor" stmt)) in
  (match result with
   | Ok () ->
     (match !verified_observation with
      | Some stamp when same_observed_file stamp (Unix.lstat path) ->
        Hashtbl.replace store.observations path stamp
      | Some _ | None -> Hashtbl.remove store.observations path)
   | Error _ -> Hashtbl.remove store.observations path);
  result
;;

let retire_missing_continuities ~ledger_dir =
  let directory = continuity_dir ledger_dir in
  let entries =
    match Unix.lstat directory with
    | stat when stat.st_kind = Unix.S_DIR -> Sys.readdir directory |> Array.to_list
    | _ -> raise (Continuity_unavailable "continuity directory is not a directory")
    | exception Unix.Unix_error (Unix.ENOENT, _, _) -> [] in
  let managed_name name =
    match Filename.extension name with
    | ".json" ->
      let stem = Filename.remove_extension name in
      (match Digestif.SHA256.consistent_of_hex_opt stem with
       | Some digest -> String.equal stem (Digestif.SHA256.to_hex digest)
       | None -> false)
    | _ -> false in
  List.iter (fun name ->
    let record_path = Filename.concat directory name in
    let json =
      try Yojson.Safe.from_string (Fs_compat.load_file record_path) with
      | Yojson.Json_error detail -> raise (Continuity_unavailable detail) in
    let path = match json with
      | `Assoc fields ->
        (match List.assoc_opt "ledger_path" fields with
         | Some (`String path)
           when String.equal (ledger_dir_of_day_path path) ledger_dir
                && String.equal (continuity_path path) record_path -> path
         | _ -> raise (Continuity_unavailable "invalid continuity owner during retirement"))
      | _ -> raise (Continuity_unavailable "invalid continuity record during retirement") in
    match Unix.lstat path with
    | _ -> ()
    | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Unix.unlink record_path)
    (List.filter managed_name entries)
;;

let advance store ~before_scan ~paths ~cursors =
  let* () =
    List.fold_left
      (fun acc (path, _) ->
        let* () = acc in
        if List.mem path paths then Ok ()
        else transaction store (fun () ->
          Hashtbl.remove store.observations path;
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
    "SELECT ledger_path, ledger_offset, ledger_length, keeper_name, ts, execution_id FROM rows%s ORDER BY ts DESC, \
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
           ; Sqlite3.Data.TEXT keeper; Sqlite3.Data.FLOAT ts
           ; (Sqlite3.Data.TEXT _ | Sqlite3.Data.NULL as execution) ] ->
           let execution_id = match execution with
             | Sqlite3.Data.TEXT value -> Some value
             | _ -> None
           in
           loop ((path, Int64.to_int offset, Int64.to_int length, keeper, ts,
                  execution_id) :: acc)
         | _ -> Error "select rows: unexpected column types")
      | Sqlite3.Rc.DONE -> Ok acc
      | rc -> Error (sqlite_error store.db "select rows" rc)
    in
    (* The query is newest first so the limit takes the newest [n]; the
       accumulator reverses it back to oldest first, which is the order the
       ledger readers return. *)
    loop [])
;;

(* ORDER BY ts made SQLite prefer rows_keeper_ts and visit every record for
   the Keeper once per execution ID. The exact predicate uses both columns of
   rows_keeper_execution; sort only the selected matches below. This preserves
   duplicate evidence and its previous chronological order without rebuilding
   the index or growing a cache. *)
let select_execution_sql =
  "SELECT ledger_path, ledger_offset, ledger_length, keeper_name, ts, execution_id \
   FROM rows WHERE keeper_name = ? AND execution_id = ?"

let compare_execution_location
    (path_a, offset_a, _, _, ts_a, _) (path_b, offset_b, _, _, ts_b, _) =
  match Float.compare ts_a ts_b with
  | 0 -> (match String.compare path_a path_b with
      | 0 -> Int.compare offset_a offset_b
      | order -> order)
  | order -> order
;;

let select_execution_locations store ~keeper_name ~execution_ids =
  with_stmt store.db ~operation:"select execution rows" select_execution_sql
    (fun stmt ->
      let rec collect acc =
        match Sqlite3.step stmt with
        | Sqlite3.Rc.ROW ->
          (match Array.to_list (Sqlite3.row_data stmt) with
           | [ Sqlite3.Data.TEXT path; Sqlite3.Data.INT offset; Sqlite3.Data.INT length
             ; Sqlite3.Data.TEXT keeper; Sqlite3.Data.FLOAT ts
             ; Sqlite3.Data.TEXT execution_id ] ->
             collect ((path, Int64.to_int offset, Int64.to_int length, keeper, ts,
                       Some execution_id) :: acc)
           | _ -> Error "select execution rows: unexpected column types")
        | Sqlite3.Rc.DONE -> Ok acc
        | rc -> Error (sqlite_error store.db "select execution rows" rc)
      in
      let* batches =
        List.fold_left
          (fun acc execution_id ->
            let* batches = acc in
            (* fire-and-forget: reset returns the last successful step's code. *)
            ignore (Sqlite3.reset stmt : Sqlite3.Rc.t);
            let* () = bind_all store.db ~operation:"bind execution identity" stmt
                [ Sqlite3.Data.TEXT keeper_name; Sqlite3.Data.TEXT execution_id ] in
            let* locations = collect [] in
            Ok (List.sort compare_execution_location locations :: batches))
          (Ok []) (List.sort_uniq String.compare execution_ids)
      in
      Ok (List.concat (List.rev batches)))
;;

(* Each row is read, checked and handed to [f] before the next one is read,
   so a caller that keeps only a small projection never holds the parsed
   bodies of the whole selection at once. *)
let map_locations ~f locations =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | ((path, offset, length, keeper, ts, execution_id) as location) :: rest ->
      let line = Fs_compat.read_slice ~path ~from:offset ~len:length in
      let* json =
        try Ok (Yojson.Safe.from_string line) with
        | Yojson.Json_error _ -> Error ("indexed ledger row is no longer readable: " ^ path)
      in
      if String.length line = length
         && keeper_of_row json = Some keeper && ts_of_row json = Some ts
         && execution_id_of_row json = execution_id
      then loop (match f location json with Some value -> value :: acc | None -> acc) rest
      else Error ("indexed ledger row no longer matches its identity: " ^ path)
  in
  loop [] locations
;;

let rows_of_locations locations = map_locations ~f:(fun _ json -> Some json) locations

let with_index ~before_scan ~store:ledger ~read =
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
            File_lock_eio.with_durable_lock
              ~lock_path:(Filename.concat ledger_dir ".continuity.lock") (fun () ->
                retire_missing_continuities ~ledger_dir;
                let* () = advance store ~before_scan ~paths ~cursors in
                read store)
            |> Result.map_error File_lock_eio.durable_lock_error_to_string
            |> Result.join
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
        try
          match attempt () with
          | Ok _ as result -> result
          | Error _ ->
            discard ();
            match attempt () with
            | Ok _ as result -> result
            | Error _ as error -> discard (); error
        with Continuity_unavailable detail -> Error detail))
;;

let recent_rows_with ~before_scan ~store ?keeper_name ~n () =
  if n <= 0 then Ok []
  else with_index ~before_scan ~store ~read:(fun index ->
    let* locations = select_locations index ~keeper_name ~n in
    rows_of_locations locations)
;;

let recent_rows = recent_rows_with ~before_scan:(fun ~path:_ -> ())

let by_execution_ids ~store ~keeper_name ~execution_ids =
  match execution_ids with
  | [] -> Ok []
  | _ ->
    with_index ~before_scan:(fun ~path:_ -> ()) ~store ~read:(fun index ->
      let* locations = select_execution_locations index ~keeper_name ~execution_ids in
      rows_of_locations locations)
;;

let select_frontier store ~keeper_name =
  let sql =
    "SELECT r.ledger_path, c.device, c.inode, c.generation, MAX(r.ledger_offset) FROM rows r \
     JOIN cursors c ON c.ledger_path = r.ledger_path WHERE r.keeper_name = ? \
     GROUP BY r.ledger_path, c.device, c.inode, c.generation ORDER BY r.ledger_path" in
  with_stmt store.db ~operation:"select frontier" sql (fun stmt ->
    let* () = bind_all store.db ~operation:"bind frontier" stmt [Sqlite3.Data.TEXT keeper_name] in
    let rec loop acc =
      match Sqlite3.step stmt with
      | Sqlite3.Rc.ROW ->
        (match Array.to_list (Sqlite3.row_data stmt) with
         | [Sqlite3.Data.TEXT path; Sqlite3.Data.INT device; Sqlite3.Data.INT inode;
            Sqlite3.Data.TEXT generation; Sqlite3.Data.INT offset] ->
           loop ({path; device = Int64.to_int device; inode = Int64.to_int inode;
             generation; offset = Int64.to_int offset} :: acc)
         | _ -> Error "select frontier: unexpected column types")
      | Sqlite3.Rc.DONE -> Ok (merge_frontiers [] acc)
      | rc -> Error (sqlite_error store.db "select frontier" rc)
    in loop [])

let current_frontier ~store ~keeper_name =
  with_index ~before_scan:(fun ~path:_ -> ()) ~store ~read:(fun index ->
    select_frontier index ~keeper_name)

let rows_after ~store ~keeper_name ~after ~project =
  with_index ~before_scan:(fun ~path:_ -> ()) ~store ~read:(fun index ->
    let* frontier = select_frontier index ~keeper_name in
    let sql =
      "SELECT ledger_path, ledger_offset, ledger_length, keeper_name, ts, execution_id \
       FROM rows WHERE keeper_name = ? AND ledger_path = ? AND ledger_offset > ? \
       AND ledger_offset <= ? ORDER BY ledger_offset DESC" in
    let* batches =
      List.fold_left (fun acc (head : position) ->
        let* batches = acc in
        let from = List.fold_left (fun offset (prior : position) ->
          if identity prior = identity head && prior.offset <= head.offset
          then max offset prior.offset else offset) (-1) after in
        let* locations = with_stmt index.db ~operation:"select after frontier" sql (fun stmt ->
          let* () = bind_all index.db ~operation:"bind frontier range" stmt
            [Sqlite3.Data.TEXT keeper_name; Sqlite3.Data.TEXT head.path;
             Sqlite3.Data.INT (Int64.of_int from); Sqlite3.Data.INT (Int64.of_int head.offset)] in
          let rec loop acc =
            match Sqlite3.step stmt with
            | Sqlite3.Rc.ROW ->
              (match Array.to_list (Sqlite3.row_data stmt) with
               | [Sqlite3.Data.TEXT path; Sqlite3.Data.INT offset; Sqlite3.Data.INT length;
                  Sqlite3.Data.TEXT keeper; Sqlite3.Data.FLOAT ts; execution] ->
                 let* execution_id = match execution with
                   | Sqlite3.Data.TEXT value -> Ok (Some value)
                   | Sqlite3.Data.NULL -> Ok None
                   | _ -> Error "select after frontier: invalid execution identity" in
                 loop ((path, Int64.to_int offset, Int64.to_int length, keeper, ts, execution_id) :: acc)
               | _ -> Error "select after frontier: unexpected column types")
            | Sqlite3.Rc.DONE -> Ok (List.rev acc)
            | rc -> Error (sqlite_error index.db "select after frontier" rc)
          in loop []) in
        let* positioned = map_locations locations ~f:(fun (_, offset, _, _, _, _) row ->
          Option.map (fun value -> { position = {head with offset}; value }) (project row)) in
        Ok (positioned :: batches)) (Ok []) frontier in
    let retained = List.filter (covers frontier) after in
    Ok {frontier; retained; rows = List.concat batches})
;;

module For_testing = struct
  let select_execution_sql = select_execution_sql
  let recent_rows = recent_rows_with
end
