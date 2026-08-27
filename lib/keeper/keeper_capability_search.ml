type document =
  { id : string
  ; name : string
  ; description : string
  ; category : string
  }

type hit =
  { document : document
  ; rank : float
  }

type error =
  | Empty_query
  | Index_unavailable of string
  | Invalid_query of string

let ( let* ) = Result.bind

let error_to_yojson = function
  | Empty_query -> `Assoc [ "kind", `String "empty_query" ]
  | Index_unavailable detail ->
    `Assoc
      [ "kind", `String "index_unavailable"; "detail", `String detail ]
  | Invalid_query detail ->
    `Assoc [ "kind", `String "invalid_query"; "detail", `String detail ]
;;

let sqlite_error db operation =
  Printf.sprintf
    "%s: %s (%s)"
    operation
    (Sqlite3.errmsg db)
    (Sqlite3.Rc.to_string (Sqlite3.errcode db))
;;

let exec db operation sql =
  let rc = Sqlite3.exec db sql in
  if Sqlite3.Rc.is_success rc
  then Ok ()
  else Error (Index_unavailable (sqlite_error db operation))
;;

let bind_text db statement index value =
  let rc = Sqlite3.bind statement index (Sqlite3.Data.TEXT value) in
  if Sqlite3.Rc.is_success rc
  then Ok ()
  else Error (Index_unavailable (sqlite_error db "bind capability field"))
;;

let with_statement db sql f =
  match Sqlite3.prepare db sql with
  | exception Sqlite3.Error detail -> Error (Index_unavailable detail)
  | statement ->
    let outcome =
      try `Result (f statement) with
      | exn -> `Exception exn
    in
    let finalized =
      match Sqlite3.finalize statement with
      | exception Sqlite3.Error detail ->
        Error (Index_unavailable ("finalize capability statement: " ^ detail))
      | rc when Sqlite3.Rc.is_success rc -> Ok ()
      | rc ->
        (* SQLite always destroys the statement; finalize returns the most
           recent step error again. Preserve the already-classified query or
           runtime failure instead of relabeling it as cleanup failure. A
           non-success finalize after an otherwise successful operation is a
           new index failure. *)
        (match outcome with
         | `Result (Error _) -> Ok ()
         | `Result (Ok _) | `Exception _ ->
           Error
             (Index_unavailable
                (Printf.sprintf
                   "finalize capability statement: %s"
                   (Sqlite3.Rc.to_string rc))))
    in
    (match outcome, finalized with
     | `Result result, Ok () -> result
     | `Result _, (Error _ as error) -> error
     | `Exception exn, _ -> raise exn)
;;

let with_database db f =
  let outcome =
    try `Result (f db) with
    | exn -> `Exception exn
  in
  let closed =
    match Sqlite3.db_close db with
    | exception Sqlite3.Error detail ->
      Error (Index_unavailable ("close capability index: " ^ detail))
    | true -> Ok ()
    | false ->
      Error
        (Index_unavailable
           ("close capability index: " ^ Sqlite3.errmsg db))
  in
  match outcome, closed with
  | `Result result, Ok () -> result
  | `Result _, (Error _ as error) -> error
  | `Exception exn, _ -> raise exn
;;

let insert_document db statement (document : document) =
  let* () = bind_text db statement 1 document.id in
  let* () = bind_text db statement 2 document.name in
  let* () = bind_text db statement 3 document.description in
  let* () = bind_text db statement 4 document.category in
  let rc = Sqlite3.step statement in
  if rc = Sqlite3.Rc.DONE
  then
    let reset = Sqlite3.reset statement in
    if Sqlite3.Rc.is_success reset
    then Ok ()
    else Error (Index_unavailable (sqlite_error db "reset capability insert"))
  else Error (Index_unavailable (sqlite_error db "insert capability"))
;;

let populate db documents =
  with_statement
    db
    "INSERT INTO capability_search(id, name, description, category) VALUES (?, ?, ?, ?)"
    (fun statement ->
       let rec loop = function
         | [] -> Ok ()
         | document :: rest ->
           (match insert_document db statement document with
            | Ok () -> loop rest
            | Error _ as error -> error)
       in
       loop documents)
;;

let query db text =
  with_statement
    db
    "SELECT id, name, description, category, bm25(capability_search) \
     FROM capability_search WHERE capability_search MATCH ? \
     ORDER BY bm25(capability_search), name"
    (fun statement ->
       match bind_text db statement 1 text with
       | Error _ as error -> error
       | Ok () ->
         let rec rows hits =
           match Sqlite3.step statement with
           | exception Sqlite3.Error detail ->
             Error (Index_unavailable ("search capabilities: " ^ detail))
           | Sqlite3.Rc.ROW ->
             let document =
               { id = Sqlite3.column_text statement 0
               ; name = Sqlite3.column_text statement 1
               ; description = Sqlite3.column_text statement 2
               ; category = Sqlite3.column_text statement 3
               }
             in
             rows ({ document; rank = Sqlite3.column_double statement 4 } :: hits)
           | Sqlite3.Rc.DONE -> Ok (List.rev hits)
           | Sqlite3.Rc.ERROR ->
             Error (Invalid_query (sqlite_error db "search capabilities"))
           | rc ->
             Error
               (Index_unavailable
                  (Printf.sprintf
                     "search capabilities: %s (%s)"
                     (Sqlite3.Rc.to_string rc)
                     (Sqlite3.errmsg db)))
         in
         rows [])
;;

let search ~query:text documents =
  if String.equal (String.trim text) ""
  then Error Empty_query
  else
    try
      match Sqlite3.db_open ":memory:" with
      | db ->
        with_database db (fun db ->
             match
               exec
                 db
                 "create capability index"
                 "CREATE VIRTUAL TABLE capability_search USING \
                  fts5(id UNINDEXED, name, description, category, tokenize='unicode61')"
             with
             | Error _ as error -> error
             | Ok () ->
               (match populate db documents with
                | Error _ as error -> error
                | Ok () -> query db text))
    with
    | Sqlite3.Error detail -> Error (Index_unavailable detail)
;;
