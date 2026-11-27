(* HIGH-RISK-UNREVIEWED: storage-integrity boundary (#36195). Every reader of a
   file masc writes opens here; a person reviews a change before it merges. *)

type journal =
  | Wal
  | Delete

type t =
  | Owned of journal
  | External

type journal_error =
  | Journal_pragma_failed of string
  | Journal_kept of { requested : journal; reply : string }

let reader_busy_timeout_ms = 5000

let journal_mode_sql = function
  | Wal -> "PRAGMA journal_mode=WAL"
  | Delete -> "PRAGMA journal_mode=DELETE"
;;

let journal_error_to_string = function
  | Journal_pragma_failed detail -> detail
  | Journal_kept { requested; reply } ->
    Printf.sprintf "%s: SQLite kept journal_mode=%s" (journal_mode_sql requested) reply
;;

let failure db operation rc =
  Printf.sprintf
    "%s: rc=%s extended_rc=%d detail=%s"
    operation
    (Sqlite3.Rc.to_string rc)
    (Sqlite3.extended_errcode_int db)
    (Sqlite3.errmsg db)
;;

(* PRAGMA journal_mode answers with the mode in force, in lower case. *)
let journal_of_reply reply =
  match String.lowercase_ascii reply with
  | "wal" -> Some Wal
  | "delete" -> Some Delete
  | _ -> None
;;

let confirm requested reply =
  match journal_of_reply reply, requested with
  | Some Wal, Wal | Some Delete, Delete -> Ok ()
  | Some Wal, Delete | Some Delete, Wal | None, (Wal | Delete) ->
    Error (Journal_kept { requested; reply })
;;

let set_journal db journal =
  let sql = journal_mode_sql journal in
  match Sqlite3.prepare db sql with
  | exception (Sqlite3.Error detail | Sqlite3.SqliteError detail) ->
    Error (Journal_pragma_failed (sql ^ ": " ^ detail))
  | stmt ->
    let reply =
      match Sqlite3.step stmt with
      | rc when rc = Sqlite3.Rc.ROW -> Ok (Sqlite3.column_text stmt 0)
      | rc -> Error (failure db sql rc)
      | exception (Sqlite3.Error detail | Sqlite3.SqliteError detail) ->
        Error (sql ^ ": " ^ detail)
    in
    let finalized = Sqlite3.finalize stmt in
    (match reply with
     | Error detail -> Error (Journal_pragma_failed detail)
     | Ok _ when not (Sqlite3.Rc.is_success finalized) ->
       Error (Journal_pragma_failed (failure db sql finalized))
     | Ok reply -> confirm journal reply)
;;

let exec db sql =
  match Sqlite3.exec db sql with
  | rc when Sqlite3.Rc.is_success rc -> Ok ()
  | rc -> Error (failure db sql rc)
  | exception (Sqlite3.Error detail | Sqlite3.SqliteError detail) ->
    Error (sql ^ ": " ^ detail)
;;

let open_mode = function
  | Owned Delete -> `NO_CREATE
  | Owned Wal | External -> `READONLY
;;

let setup db file =
  match Sqlite3.busy_timeout db reader_busy_timeout_ms with
  | exception (Sqlite3.Error detail | Sqlite3.SqliteError detail) ->
    Error ("busy_timeout: " ^ detail)
  | () ->
    (match file with
     | Owned Delete -> exec db "PRAGMA query_only=1"
     | Owned Wal | External -> Ok ())
;;

let open_reader file path =
  match Sqlite3.db_open ~mode:(open_mode file) path with
  | exception (Sqlite3.Error detail | Sqlite3.SqliteError detail) -> Error detail
  | db ->
    let close () = ignore (Sqlite3.db_close db : bool) in
    (match setup db file with
     | Ok () -> Ok db
     | Error _ as error ->
       close ();
       error)
;;
