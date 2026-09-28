(* Lexical ranking of memory texts (RFC-memory-search-beyond-substring 3.1).
   The SQLite plumbing follows [Keeper_capability_search]; see the interface
   for what the ranking is and is not. *)

type error = Index_unavailable of string

let error_to_string (Index_unavailable detail) = detail
let ( let* ) = Result.bind

let sqlite_error db operation =
  Index_unavailable
    (Printf.sprintf
       "%s: %s (%s)"
       operation
       (Sqlite3.errmsg db)
       (Sqlite3.Rc.to_string (Sqlite3.errcode db)))
;;

let check db operation rc = if Sqlite3.Rc.is_success rc then Ok () else Error (sqlite_error db operation)

(* Statements are finalized and the database closed whatever the body did,
   and an exception from the body goes on unchanged. A step error is already
   the body's result, and SQLite destroys the statement even when finalize
   repeats that error, so a cleanup failure does not replace the result; it
   is written to the log instead. *)
let log_cleanup what outcome = Log.Keeper.warn "memory search index: %s failed: %s" what outcome

let with_statement db sql f =
  match Sqlite3.prepare db sql with
  | exception Sqlite3.Error detail -> Error (Index_unavailable detail)
  | statement ->
    Fun.protect
      ~finally:(fun () ->
        match Sqlite3.finalize statement with
        | rc when Sqlite3.Rc.is_success rc -> ()
        | rc -> log_cleanup "finalize" (Sqlite3.Rc.to_string rc)
        | exception Sqlite3.Error detail -> log_cleanup "finalize" detail)
      (fun () -> f statement)
;;

let with_database db f =
  Fun.protect
    ~finally:(fun () ->
      match Sqlite3.db_close db with
      | true -> ()
      | false -> log_cleanup "close" (Sqlite3.errmsg db)
      | exception Sqlite3.Error detail -> log_cleanup "close" detail)
    (fun () -> f db)
;;

(* Every term becomes one FTS5 string (a double quote inside it doubled, as
   the FTS5 query syntax defines), joined by OR, so no text a Keeper types is
   read as query syntax. *)
let match_expression query =
  match String_util.query_tokens query with
  | [] -> None
  | terms ->
    let quote term =
      let buffer = Buffer.create (String.length term + 2) in
      Buffer.add_char buffer '"';
      String.iter
        (fun c ->
           if Char.equal c '"' then Buffer.add_string buffer "\"\"" else Buffer.add_char buffer c)
        term;
      Buffer.add_char buffer '"';
      Buffer.contents buffer
    in
    Some (String.concat " OR " (List.map quote terms))
;;

let populate db texts =
  with_statement db "INSERT INTO memory_search(ordinal, claim) VALUES (?, ?)" (fun statement ->
    let rec loop ordinal = function
      | [] -> Ok ()
      | text :: rest ->
        let* () =
          check db "bind memory ordinal"
            (Sqlite3.bind statement 1 (Sqlite3.Data.INT (Int64.of_int ordinal)))
        in
        let* () = check db "bind memory text" (Sqlite3.bind statement 2 (Sqlite3.Data.TEXT text)) in
        (match Sqlite3.step statement with
         | Sqlite3.Rc.DONE ->
           let* () = check db "reset memory insert" (Sqlite3.reset statement) in
           loop (ordinal + 1) rest
         | _ -> Error (sqlite_error db "insert memory text"))
    in
    loop 0 texts)
;;

let search db ~count expression =
  with_statement
    db
    "SELECT ordinal, bm25(memory_search) FROM memory_search WHERE memory_search MATCH ? \
     ORDER BY bm25(memory_search), ordinal"
    (fun statement ->
       let* () = check db "bind memory query" (Sqlite3.bind statement 1 (Sqlite3.Data.TEXT expression)) in
       let rec rows hits =
         match Sqlite3.step statement with
         | exception Sqlite3.Error detail -> Error (Index_unavailable ("search memory: " ^ detail))
         | Sqlite3.Rc.ROW ->
           let ordinal = Sqlite3.column_int statement 0 in
           if ordinal < 0 || ordinal >= count
           then Error (Index_unavailable "memory index returned an ordinal outside its input")
           else rows ((ordinal, Sqlite3.column_double statement 1) :: hits)
         | Sqlite3.Rc.DONE -> Ok (List.rev hits)
         | _ -> Error (sqlite_error db "search memory")
       in
       rows [])
;;

let rank ~query texts =
  match match_expression query, texts with
  | None, _ | Some _, [] -> Ok []
  | Some expression, _ :: _ ->
    (try
       with_database (Sqlite3.db_open ":memory:") (fun db ->
         let* () =
           match
             Sqlite3.exec
               db
               "CREATE VIRTUAL TABLE memory_search USING \
                fts5(ordinal UNINDEXED, claim, tokenize='trigram')"
           with
           | rc when Sqlite3.Rc.is_success rc -> Ok ()
           | _ -> Error (sqlite_error db "create memory search index")
         in
         let* () = populate db texts in
         search db ~count:(List.length texts) expression)
     with
     | Sqlite3.Error detail -> Error (Index_unavailable detail))
;;
