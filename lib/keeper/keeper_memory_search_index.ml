(* Lexical ranking of memory texts.
   The SQLite plumbing follows [Keeper_capability_search]; see the interface
   for what the ranking is and is not. *)

type error = Index_unavailable of string
type batch_stats = { index_builds : int; indexed_rows : int; queries_executed : int }

let error_to_string (Index_unavailable detail) = detail
open Result.Syntax

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

(* Every term >= 3 UTF-8 code points becomes one FTS5 trigram string (a double
   quote inside it doubled), joined by OR; shorter terms (< 3 code points)
   cannot match FTS5 trigrams and fall back to escaped SQL LIKE substring scans
   on the same SQLite worker domain. *)
let utf8_char_count s =
  let count = ref 0 in
  String.iter
    (fun c -> if Char.code c land 0xc0 <> 0x80 then incr count)
    s;
  !count
;;

type compiled_query =
  { trigram_expr : string option
  ; short_terms : string list
  }

let escape_like term =
  let buffer = Buffer.create (String.length term + 4) in
  Buffer.add_char buffer '%';
  String.iter
    (fun c ->
       match c with
       | '\\' | '%' | '_' ->
         Buffer.add_char buffer '\\';
         Buffer.add_char buffer c
       | _ -> Buffer.add_char buffer c)
    term;
  Buffer.add_char buffer '%';
  Buffer.contents buffer
;;

let compile_query query =
  match String_util.query_tokens query with
  | [] -> None
  | terms ->
    let trigram_terms, short_terms =
      List.partition (fun term -> utf8_char_count term >= 3) terms
    in
    let trigram_expr =
      match trigram_terms with
      | [] -> None
      | _ :: _ ->
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
        Some (String.concat " OR " (List.map quote trigram_terms))
    in
    Some { trigram_expr; short_terms }
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

(* The rows one query may return. [Excluding] leaves out one owner's rows and
   keeps the best [limit] of the rest; the owner and the limit come together. *)
type row_filter =
  | All_rows
  | Excluding of { owner : string; limit : int }

let search db ~count ~filter compiled =
  let like_count = List.length compiled.short_terms in
  let* sql =
    match compiled.trigram_expr, compiled.short_terms with
    | None, [] -> Error (Index_unavailable "empty search query")
    | Some _, [] ->
      Ok
        (match filter with
         | All_rows ->
           "SELECT ordinal, bm25(memory_search) FROM memory_search WHERE memory_search MATCH ?1 \
            ORDER BY bm25(memory_search), ordinal"
         | Excluding _ ->
           "SELECT ordinal, bm25(memory_search) FROM memory_search WHERE memory_search MATCH ?1 \
            AND owner != ?2 ORDER BY bm25(memory_search), ordinal LIMIT ?3")
    | None, _ :: _ ->
      let like_terms =
        List.init like_count (fun i -> Printf.sprintf "claim LIKE ?%d ESCAPE '\\'" (i + 1))
      in
      let score_expr = "-(" ^ String.concat " + " like_terms ^ ")" in
      let where_like = "(" ^ String.concat " OR " like_terms ^ ")" in
      Ok
        (match filter with
         | All_rows ->
           Printf.sprintf
             "SELECT ordinal, %s FROM memory_search WHERE %s ORDER BY 2, ordinal"
             score_expr
             where_like
         | Excluding _ ->
           Printf.sprintf
             "SELECT ordinal, %s FROM memory_search WHERE %s AND owner != ?%d ORDER BY 2, ordinal LIMIT ?%d"
             score_expr
             where_like
             (like_count + 1)
             (like_count + 2))
    | Some _, _ :: _ ->
      let like_terms =
        List.init like_count (fun i -> Printf.sprintf "(m.claim LIKE ?%d ESCAPE '\\')" (i + 1))
      in
      let score_expr = "COALESCE(f.score, 0.0) - (" ^ String.concat " + " like_terms ^ ")" in
      let where_like = String.concat " OR " like_terms in
      let match_param = like_count + 1 in
      Ok
        (match filter with
         | All_rows ->
           Printf.sprintf
             "SELECT m.ordinal, %s FROM memory_search AS m \
              LEFT JOIN (SELECT rowid, bm25(memory_search) AS score FROM memory_search WHERE memory_search MATCH ?%d) AS f \
              ON m.rowid = f.rowid \
              WHERE (f.rowid IS NOT NULL OR %s) \
              ORDER BY 2, m.ordinal"
             score_expr
             match_param
             where_like
         | Excluding _ ->
           Printf.sprintf
             "SELECT m.ordinal, %s FROM memory_search AS m \
              LEFT JOIN (SELECT rowid, bm25(memory_search) AS score FROM memory_search WHERE memory_search MATCH ?%d) AS f \
              ON m.rowid = f.rowid \
              WHERE (f.rowid IS NOT NULL OR %s) AND m.owner != ?%d \
              ORDER BY 2, m.ordinal LIMIT ?%d"
             score_expr
             match_param
             where_like
             (match_param + 1)
             (match_param + 2))
  in
  with_statement
    db
    sql
    (fun statement ->
       let* next_param =
         match compiled.trigram_expr, like_count with
         | Some expression, 0 ->
           let* () =
             check db "bind memory query" (Sqlite3.bind statement 1 (Sqlite3.Data.TEXT expression))
           in
           Ok 2
         | trigram_opt, _ ->
           let rec bind_short idx = function
             | [] -> Ok idx
             | term :: rest ->
               let* () =
                 check
                   db
                   "bind short memory query"
                   (Sqlite3.bind statement idx (Sqlite3.Data.TEXT (escape_like term)))
               in
               bind_short (idx + 1) rest
           in
           let* idx = bind_short 1 compiled.short_terms in
           (match trigram_opt with
            | None -> Ok idx
            | Some expression ->
              let* () =
                check
                  db
                  "bind memory query"
                  (Sqlite3.bind statement idx (Sqlite3.Data.TEXT expression))
              in
              Ok (idx + 1))
       in
       let* () =
         match filter with
         | Excluding { owner; limit } ->
           let* () =
             check
               db
               "bind excluded memory owner"
               (Sqlite3.bind statement next_param (Sqlite3.Data.TEXT owner))
           in
           check
             db
             "bind memory result limit"
             (Sqlite3.bind statement (next_param + 1) (Sqlite3.Data.INT (Int64.of_int limit)))
         | All_rows -> Ok ()
       in
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
         | Sqlite3.Rc.FORMAT | Sqlite3.Rc.RANGE | Sqlite3.Rc.NOTADB | Sqlite3.Rc.UNKNOWN _ ->
           Error (sqlite_error db "search memory")
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

let no_work = { index_builds = 0; indexed_rows = 0; queries_executed = 0 }

let rank_many_with ~queries ~texts =
  let compiled = List.map (fun (filter, query) -> filter, compile_query query) queries in
  match texts, List.exists (fun (_, plan) -> Option.is_some plan) compiled with
  | [], _ | _, false -> Ok (List.map (fun _ -> []) queries, no_work)
  | _ :: _, true ->
    (* Building and querying the table is one SQLite call per row, and a
       caller's fiber cannot yield inside it. The workspace curator ranks the
       whole workspace ledger: on domain 0 that held the server's HTTP answers
       and logs for tens of seconds (2026-10-07). *)
    Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ @@ fun () ->
    (try
       with_database (Sqlite3.db_open ":memory:") (fun db ->
         let* () = create_table db texts in
         let rec search_all results executed = function
           | [] ->
             Ok
               ( List.rev results
               , { index_builds = 1; indexed_rows = List.length texts; queries_executed = executed }
               )
           | (_, None) :: rest -> search_all ([] :: results) executed rest
           | (filter, Some plan) :: rest ->
             let* ranked = search db ~count:(List.length texts) ~filter plan in
             search_all (ranked :: results) (executed + 1) rest
         in
         search_all [] 0 compiled)
     with
     | Sqlite3.Error detail -> Error (Index_unavailable detail))
;;

let rank_many ~queries texts =
  let queries = List.map (fun query -> All_rows, query) queries in
  let texts = List.map (fun text -> "", text) texts in
  let* ranked, _ = rank_many_with ~queries ~texts in
  Ok ranked
;;

let rank_many_excluding_owners ~queries ~texts ~max_results =
  if max_results < 0 then Error (Index_unavailable "negative result limit")
  else if max_results = 0 then Ok (List.map (fun _ -> []) queries, no_work)
  else
    rank_many_with
      ~queries:(List.map (fun (owner, query) -> Excluding { owner; limit = max_results }, query) queries)
      ~texts
;;

let close_table db =
  match Sqlite3.db_close db with
  | true -> ()
  | false -> log_cleanup "close" (Sqlite3.errmsg db)
  | exception Sqlite3.Error detail -> log_cleanup "close" detail
;;

let close_db_in_pool db =
  let run () =
    Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ (fun () -> close_table db)
  in
  match Eio_guard.execution_context () with
  | Eio_guard.Non_eio -> run ()
  | Eio_guard.Eio_fiber -> Eio.Cancel.protect run
;;

(* The table is built on the first [rank] that has work and serves every
   later one. Each build, each [rank], and closing the database run on the
   domain pool when the caller is an Eio fiber, like [rank_many_with]; the jobs
   run one after another, so the database is never used by two at once and
   [Sqlite3.db_close] never runs on the caller's Eio scheduler domain. *)
let with_excluding_owners ~texts ~max_results f =
  let opened = ref None in
  let stats = ref no_work in
  let table () =
    match !opened with
    | Some db -> Ok db
    | None ->
      let* db =
        Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ (fun () ->
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
    let compiled = List.map (fun (owner, query) -> owner, compile_query query) queries in
    if max_results < 0 then Error (Index_unavailable "negative result limit")
    else if max_results = 0 || texts = [] || not (List.exists (fun (_, p) -> Option.is_some p) compiled)
    then Ok (List.map (fun _ -> []) queries)
    else
      let* db = table () in
      let* results, executed =
        Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ (fun () ->
          let rec search_all results executed = function
            | [] -> Ok (List.rev results, executed)
            | (_, None) :: rest -> search_all ([] :: results) executed rest
            | (owner, Some plan) :: rest ->
              let* ranked =
                search
                  db
                  ~count:(List.length texts)
                  ~filter:(Excluding { owner; limit = max_results })
                  plan
              in
              search_all (ranked :: results) (executed + 1) rest
          in
          try search_all [] 0 compiled with Sqlite3.Error detail -> Error (Index_unavailable detail))
      in
      stats := { !stats with queries_executed = !stats.queries_executed + executed };
      Ok results
  in
  let value =
    Fun.protect
      ~finally:(fun () -> Option.iter close_db_in_pool !opened; opened := None)
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
