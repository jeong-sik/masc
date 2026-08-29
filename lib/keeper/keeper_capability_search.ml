type 'a document =
  { payload : 'a
  ; name : string
  ; description : string
  ; invocation_name : string option
  }

type 'a hit =
  { document : 'a document
  ; bm25 : float
  }

type error =
  | Empty_query
  | Frozen_surface_required
  | Index_unavailable of string
  | Invalid_query of string

let ( let* ) = Result.bind

let error_to_yojson = function
  | Empty_query -> `Assoc [ "kind", `String "empty_query" ]
  | Frozen_surface_required ->
    `Assoc [ "kind", `String "frozen_surface_required" ]
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

let bind_int db statement index value =
  let rc =
    Sqlite3.bind statement index (Sqlite3.Data.INT (Int64.of_int value))
  in
  if Sqlite3.Rc.is_success rc
  then Ok ()
  else Error (Index_unavailable (sqlite_error db "bind capability ordinal"))
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

let insert_document db statement ordinal document =
  let* () = bind_int db statement 1 ordinal in
  let* () = bind_text db statement 2 document.name in
  let* () = bind_text db statement 3 document.description in
  let* () =
    bind_text db statement 4 (Option.value ~default:"" document.invocation_name)
  in
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
    "INSERT INTO capability_search(ordinal, name, description, invocation_name) VALUES (?, ?, ?, ?)"
    (fun statement ->
       let rec loop ordinal = function
         | [] -> Ok ()
         | document :: rest ->
           (match insert_document db statement ordinal document with
            | Ok () -> loop (ordinal + 1) rest
            | Error _ as error -> error)
       in
       loop 0 documents)
;;

let query db documents text =
  let documents = Array.of_list documents in
  with_statement
    db
    "SELECT ordinal, bm25(capability_search) \
     FROM capability_search WHERE capability_search MATCH ? \
     ORDER BY bm25(capability_search), ordinal"
    (fun statement ->
       match bind_text db statement 1 text with
       | Error _ as error -> error
       | Ok () ->
         let rec rows hits =
           match Sqlite3.step statement with
           | exception Sqlite3.Error detail ->
             Error (Index_unavailable ("search capabilities: " ^ detail))
           | Sqlite3.Rc.ROW ->
             let ordinal = Sqlite3.column_int statement 0 in
             if ordinal < 0 || ordinal >= Array.length documents
             then
               Error
                 (Index_unavailable
                    "capability index returned an ordinal outside its frozen input")
             else
               let document = documents.(ordinal) in
               rows
                 ({ document; bm25 = Sqlite3.column_double statement 1 } :: hits)
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
                  fts5(ordinal UNINDEXED, name, description, invocation_name, tokenize='unicode61')"
             with
             | Error _ as error -> error
             | Ok () ->
               (match populate db documents with
                | Error _ as error -> error
                | Ok () -> query db documents text))
    with
    | Sqlite3.Error detail -> Error (Index_unavailable detail)
;;
