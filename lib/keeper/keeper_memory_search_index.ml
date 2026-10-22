(* Lexical ranking of memory texts (RFC-memory-search-beyond-substring 3.1).
   The SQLite plumbing follows [Keeper_capability_search]; see the interface
   for what the ranking is and is not. *)

type error = Index_unavailable of string
type batch_stats = { index_builds : int; indexed_rows : int; queries_executed : int }

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
  with_statement db "INSERT INTO memory_search(ordinal, owner, claim) VALUES (?, ?, ?)" (fun statement ->
    let rec loop ordinal = function
      | [] -> Ok ()
      | (owner, text) :: rest ->
        let* () =
          check db "bind memory ordinal"
            (Sqlite3.bind statement 1 (Sqlite3.Data.INT (Int64.of_int ordinal)))
        in
        let* () = check db "bind memory owner" (Sqlite3.bind statement 2 (Sqlite3.Data.TEXT owner)) in
        let* () = check db "bind memory text" (Sqlite3.bind statement 3 (Sqlite3.Data.TEXT text)) in
        (match Sqlite3.step statement with
         | Sqlite3.Rc.DONE ->
           let* () = check db "reset memory insert" (Sqlite3.reset statement) in
           loop (ordinal + 1) rest
         | Sqlite3.Rc.OK | Sqlite3.Rc.ERROR | Sqlite3.Rc.INTERNAL | Sqlite3.Rc.PERM
         | Sqlite3.Rc.ABORT | Sqlite3.Rc.BUSY | Sqlite3.Rc.LOCKED | Sqlite3.Rc.NOMEM
         | Sqlite3.Rc.READONLY | Sqlite3.Rc.INTERRUPT | Sqlite3.Rc.IOERR | Sqlite3.Rc.CORRUPT
         | Sqlite3.Rc.NOTFOUND | Sqlite3.Rc.FULL | Sqlite3.Rc.CANTOPEN | Sqlite3.Rc.PROTOCOL
         | Sqlite3.Rc.EMPTY | Sqlite3.Rc.SCHEMA | Sqlite3.Rc.TOOBIG | Sqlite3.Rc.CONSTRAINT
         | Sqlite3.Rc.MISMATCH | Sqlite3.Rc.MISUSE | Sqlite3.Rc.NOFLS | Sqlite3.Rc.AUTH
         | Sqlite3.Rc.FORMAT | Sqlite3.Rc.RANGE | Sqlite3.Rc.NOTADB | Sqlite3.Rc.ROW
         | Sqlite3.Rc.UNKNOWN _ -> Error (sqlite_error db "insert memory text"))
    in
    loop 0 texts)
;;

let search db ~count ~exclude_owner ~max_results expression =
  let sql = match exclude_owner, max_results with
    | None, None ->
      "SELECT ordinal, bm25(memory_search) FROM memory_search WHERE memory_search MATCH ? \
       ORDER BY bm25(memory_search), ordinal"
    | Some _, Some _ ->
      "SELECT ordinal, bm25(memory_search) FROM memory_search WHERE memory_search MATCH ? \
       AND owner != ? ORDER BY bm25(memory_search), ordinal LIMIT ?"
    | None, Some _ | Some _, None ->
      "SELECT ordinal, bm25(memory_search) FROM memory_search WHERE memory_search MATCH ? \
       ORDER BY bm25(memory_search), ordinal"
  in
  with_statement
    db
    sql
    (fun statement ->
       let* () = check db "bind memory query" (Sqlite3.bind statement 1 (Sqlite3.Data.TEXT expression)) in
       let* () = match exclude_owner, max_results with
         | Some owner, Some limit ->
           let* () = check db "bind excluded memory owner"
             (Sqlite3.bind statement 2 (Sqlite3.Data.TEXT owner)) in
           check db "bind memory result limit"
             (Sqlite3.bind statement 3 (Sqlite3.Data.INT (Int64.of_int limit)))
         | None, None | None, Some _ | Some _, None -> Ok () in
       let rec rows hits =
         match Sqlite3.step statement with
         | exception Sqlite3.Error detail -> Error (Index_unavailable ("search memory: " ^ detail))
         | Sqlite3.Rc.ROW ->
           let ordinal = Sqlite3.column_int statement 0 in
           if ordinal < 0 || ordinal >= count
           then Error (Index_unavailable "memory index returned an ordinal outside its input")
           else rows ((ordinal, Sqlite3.column_double statement 1) :: hits)
         | Sqlite3.Rc.DONE -> Ok (List.rev hits)
         | Sqlite3.Rc.OK | Sqlite3.Rc.ERROR | Sqlite3.Rc.INTERNAL | Sqlite3.Rc.PERM
         | Sqlite3.Rc.ABORT | Sqlite3.Rc.BUSY | Sqlite3.Rc.LOCKED | Sqlite3.Rc.NOMEM
         | Sqlite3.Rc.READONLY | Sqlite3.Rc.INTERRUPT | Sqlite3.Rc.IOERR | Sqlite3.Rc.CORRUPT
         | Sqlite3.Rc.NOTFOUND | Sqlite3.Rc.FULL | Sqlite3.Rc.CANTOPEN | Sqlite3.Rc.PROTOCOL
         | Sqlite3.Rc.EMPTY | Sqlite3.Rc.SCHEMA | Sqlite3.Rc.TOOBIG | Sqlite3.Rc.CONSTRAINT
         | Sqlite3.Rc.MISMATCH | Sqlite3.Rc.MISUSE | Sqlite3.Rc.NOFLS | Sqlite3.Rc.AUTH
         | Sqlite3.Rc.FORMAT | Sqlite3.Rc.RANGE | Sqlite3.Rc.NOTADB | Sqlite3.Rc.UNKNOWN _ -> Error (sqlite_error db "search memory")
       in
       rows [])
;;

let create_table db texts =
  let* () =
    match
      Sqlite3.exec
        db
        "CREATE VIRTUAL TABLE memory_search USING \
         fts5(ordinal UNINDEXED, owner UNINDEXED, claim, tokenize='trigram')"
    with
    | rc when Sqlite3.Rc.is_success rc -> Ok ()
    | _ -> Error (sqlite_error db "create memory search index")
  in
  populate db texts
;;

let rank_many_with ~queries ~texts ~max_results =
  let expressions = List.map (fun (owner, query) -> owner, match_expression query) queries in
  let empty_stats = { index_builds = 0; indexed_rows = 0; queries_executed = 0 } in
  match max_results, texts, List.exists (fun (_, expression) -> Option.is_some expression) expressions with
  | Some limit, _, _ when limit < 0 -> Error (Index_unavailable "negative result limit")
  | Some 0, _, _ | _, [], _ | _, _, false ->
    Ok (List.map (fun _ -> []) queries, empty_stats)
  | _, _ :: _, true ->
    (* Building and querying the table is one SQLite call per row, and a
       caller's fiber cannot yield inside it. The workspace curator ranks the
       whole workspace ledger: on domain 0 that held the server's HTTP answers
       and logs for tens of seconds (2026-10-07). *)
    Domain_pool_ref.submit_cpu_or_inline @@ fun () ->
    (try
       with_database (Sqlite3.db_open ":memory:") (fun db ->
         let* () = create_table db texts in
         let rec search_all results executed = function
           | [] -> Ok (List.rev results,
                       { index_builds = 1; indexed_rows = List.length texts;
                         queries_executed = executed })
           | (_, None) :: rest -> search_all ([] :: results) executed rest
           | (owner, Some expression) :: rest ->
             let* ranked = search db ~count:(List.length texts)
                 ~exclude_owner:owner ~max_results expression in
             search_all (ranked :: results) (executed + 1) rest
         in
         search_all [] 0 expressions)
     with
     | Sqlite3.Error detail -> Error (Index_unavailable detail))
;;

let rank_many ~queries texts =
  let queries = List.map (fun query -> None, query) queries in
  let texts = List.map (fun text -> "", text) texts in
  let* ranked, _ = rank_many_with ~queries ~texts ~max_results:None in
  Ok ranked
;;

let rank_many_excluding_owners ~queries ~texts ~max_results =
  rank_many_with ~queries:(List.map (fun (owner, query) -> Some owner, query) queries)
    ~texts ~max_results:(Some max_results)
;;

let close_table db =
  match Sqlite3.db_close db with
  | true -> ()
  | false -> log_cleanup "close" (Sqlite3.errmsg db)
  | exception Sqlite3.Error detail -> log_cleanup "close" detail
;;

(* The table is built on the first [rank] that has work and serves every
   later one. Each build and each [rank] is its own job on the domain pool
   when the caller is an Eio fiber, like [rank_many_with]; the jobs run one
   after another, so the database is never used by two at once. The caller
   runs [f] itself. *)
let with_excluding_owners ~texts ~max_results f =
  let opened = ref None in
  let stats = ref { index_builds = 0; indexed_rows = 0; queries_executed = 0 } in
  let table () =
    match !opened with
    | Some db -> Ok db
    | None ->
      let* db =
        Domain_pool_ref.submit_cpu_or_inline (fun () ->
          match Sqlite3.db_open ":memory:" with
          | exception Sqlite3.Error detail -> Error (Index_unavailable detail)
          | db ->
            (match create_table db texts with
             | Ok () -> Ok db
             | Error error -> close_table db; Error error
             | exception Sqlite3.Error detail -> close_table db; Error (Index_unavailable detail)))
      in
      opened := Some db;
      stats := { !stats with index_builds = !stats.index_builds + 1;
                             indexed_rows = !stats.indexed_rows + List.length texts };
      Ok db
  in
  let rank queries =
    let expressions = List.map (fun (owner, query) -> owner, match_expression query) queries in
    if max_results < 0 then Error (Index_unavailable "negative result limit")
    else if max_results = 0 || texts = [] || not (List.exists (fun (_, e) -> Option.is_some e) expressions)
    then Ok (List.map (fun _ -> []) queries)
    else
      let* db = table () in
      let* results, executed =
        Domain_pool_ref.submit_cpu_or_inline (fun () ->
          let rec search_all results executed = function
            | [] -> Ok (List.rev results, executed)
            | (_, None) :: rest -> search_all ([] :: results) executed rest
            | (owner, Some expression) :: rest ->
              let* ranked = search db ~count:(List.length texts)
                  ~exclude_owner:(Some owner) ~max_results:(Some max_results) expression in
              search_all (ranked :: results) (executed + 1) rest
          in
          try search_all [] 0 expressions with Sqlite3.Error detail -> Error (Index_unavailable detail))
      in
      stats := { !stats with queries_executed = !stats.queries_executed + executed };
      Ok results
  in
  let value =
    Fun.protect
      ~finally:(fun () -> Option.iter close_table !opened; opened := None)
      (fun () -> f ~rank)
  in
  value, !stats
;;

let rank ~query texts =
  let* results = rank_many ~queries:[query] texts in
  match results with
  | [result] -> Ok result
  | [] | _ :: _ :: _ -> Error (Index_unavailable "memory index returned an invalid query count")
;;
