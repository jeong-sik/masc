let sqlite_error error db operation rc =
  error ~operation ~detail:(Sqlite3.Rc.to_string rc ^ ": " ^ Sqlite3.errmsg db)
let exec ~error db ~operation sql =
  match Sqlite3.exec db sql with
  | rc when Sqlite3.Rc.is_success rc -> Ok ()
  | rc -> Error (sqlite_error error db operation rc)
  | exception (Sqlite3.Error detail | Sqlite3.SqliteError detail) -> Error (error ~operation ~detail)
let statement ~error ~on_cleanup db ~operation sql f =
  match Sqlite3.prepare db sql with
  | exception (Sqlite3.Error detail | Sqlite3.SqliteError detail) -> Error (error ~operation ~detail)
  | stmt ->
      Fun.protect ~finally:(fun () ->
        match Sqlite3.finalize stmt with
        | rc when Sqlite3.Rc.is_success rc -> ()
        | rc -> on_cleanup ~operation:("finalize " ^ operation) ~detail:(Sqlite3.Rc.to_string rc)
        | exception (Sqlite3.Error detail | Sqlite3.SqliteError detail) ->
            on_cleanup ~operation:("finalize " ^ operation) ~detail)
        (fun () -> try f stmt with
          (Sqlite3.Error detail | Sqlite3.SqliteError detail) -> Error (error ~operation ~detail))
let bind ~error db stmt values =
  let rec loop index = function
    | [] -> Ok ()
    | value::rest ->
        let rc=Sqlite3.bind stmt index value in
        if Sqlite3.Rc.is_success rc then loop (index+1) rest
        else Error (sqlite_error error db "bind" rc) in
  loop 1 values
let with_database ~label ~before_open ~error ~on_cleanup ~close ~create ~path f =
  Eio_guard.run_in_systhread ~label (fun () ->
    match before_open () with
    | Error error -> Error error
    | Ok () ->
    let db=if create then Sqlite3.db_open path else Sqlite3.db_open ~mode:`READONLY path in
    Fun.protect ~finally:(fun () ->
      (match close db with
       | true -> ()
       | false -> on_cleanup ~operation:"close" ~detail:"SQLite close failed"
       | exception (Sqlite3.Error detail | Sqlite3.SqliteError detail) ->
           on_cleanup ~operation:"close" ~detail);
      ignore (Sys.opaque_identity db)) (fun () ->
        if create then Unix.chmod path 0o600;
        try f db with (Sqlite3.Error detail | Sqlite3.SqliteError detail) ->
          Error (error ~operation:"SQLite" ~detail)))
let commit ~error ~unconfirmed ~show_error ~commit db =
  match commit db with
  | rc when Sqlite3.Rc.is_success rc -> Ok ()
  | rc -> Error (unconfirmed (show_error (sqlite_error error db "commit" rc)))
  | exception (Sqlite3.Error detail | Sqlite3.SqliteError detail) -> Error (unconfirmed detail)
