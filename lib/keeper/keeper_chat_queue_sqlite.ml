let error ~operation db rc =
  Printf.sprintf
    "SQLite %s failed: rc=%s error=%s"
    operation
    (Sqlite3.Rc.to_string rc)
    (Sqlite3.errmsg db)

let exec db ~operation sql =
  let rc = Sqlite3.exec db sql in
  if Sqlite3.Rc.is_success rc then Ok () else Error (error ~operation db rc)

let bind db stmt ~operation index value =
  let rc = Sqlite3.bind stmt index value in
  if Sqlite3.Rc.is_success rc then Ok () else Error (error ~operation db rc)

let bind_text db stmt ~operation index value =
  let rc = Sqlite3.bind_text stmt index value in
  if Sqlite3.Rc.is_success rc then Ok () else Error (error ~operation db rc)

let bind_int64 db stmt ~operation index value =
  let rc = Sqlite3.bind_int64 stmt index value in
  if Sqlite3.Rc.is_success rc then Ok () else Error (error ~operation db rc)

let expect_done db stmt ~operation =
  match Sqlite3.step stmt with
  | Sqlite3.Rc.DONE -> Ok ()
  | rc -> Error (error ~operation db rc)

(* Sqlite3.finalize may raise SqliteError as well as returning an error rc.
   Keep statement cleanup total so it cannot erase a body error or replace
   Eio cancellation. The opaque identity also pins the wrapper across the C
   call, whose runtime-lock release otherwise opens a GC finalizer race. *)
let finalize db stmt =
  let result =
    match Sqlite3.finalize stmt with
    | rc ->
      if Sqlite3.Rc.is_success rc
      then Ok ()
      else Error (error ~operation:"statement finalize" db rc)
    | exception exn ->
      Error ("SQLite statement finalize raised: " ^ Printexc.to_string exn)
  in
  (* See the statement-liveness invariant above. *)
  ignore (Sys.opaque_identity stmt);
  result

let combine_cleanup_error primary cleanup =
  match primary, cleanup with
  | Ok value, Ok () -> Ok value
  | Error detail, Ok () -> Error detail
  | Ok _, Error detail -> Error detail
  | Error primary, Error cleanup ->
    Error (primary ^ "; cleanup also failed: " ^ cleanup)

let with_statement db sql body =
  match
    try Ok (Sqlite3.prepare db sql) with
    | exn -> Error ("SQLite statement prepare failed: " ^ Printexc.to_string exn)
  with
  | Error _ as error -> error
  | Ok stmt ->
    let body_result =
      try body stmt with
      | Eio.Cancel.Cancelled _ as exception_ ->
        (match finalize db stmt with
         | Ok () -> ()
         | Error detail ->
           Log.Keeper.error
             "chat queue statement finalize failed during cancellation: %s"
             detail);
        raise exception_
      | exn -> Error (Printexc.to_string exn)
    in
    combine_cleanup_error body_result (finalize db stmt)

let single_int64 db ~operation sql =
  with_statement db sql (fun stmt ->
      match Sqlite3.step stmt with
      | Sqlite3.Rc.ROW ->
        let value = Sqlite3.column_int64 stmt 0 in
        (match Sqlite3.step stmt with
         | Sqlite3.Rc.DONE -> Ok value
         | rc -> Error (error ~operation db rc))
      | rc -> Error (error ~operation db rc))

let single_text db ~operation sql =
  with_statement db sql (fun stmt ->
      match Sqlite3.step stmt with
      | Sqlite3.Rc.ROW ->
        let value = Sqlite3.column_text stmt 0 in
        (match Sqlite3.step stmt with
         | Sqlite3.Rc.DONE -> Ok value
         | rc -> Error (error ~operation db rc))
      | rc -> Error (error ~operation db rc))
