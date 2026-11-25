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

let count_short_term_hits claim short_terms =
  List.fold_left
    (fun acc term -> if String_util.contains_query_term_ci claim term then acc + 1 else acc)
    0
    short_terms
;;

let compare_hit (oa, sa) (ob, sb) =
  match Float.compare sa sb with
  | 0 -> Int.compare oa ob
  | c -> c
;;

let take_prefix limit items =
  let rec loop acc left = function
    | [] -> List.rev acc
    | _ when left <= 0 -> List.rev acc
    | x :: rest -> loop (x :: acc) (left - 1) rest
  in
  loop [] limit items
;;

let column_opt_double statement col =
  match Sqlite3.column statement col with
  | Sqlite3.Data.NULL -> Ok None
  | Sqlite3.Data.FLOAT value -> Ok (Some value)
  | Sqlite3.Data.INT value -> Ok (Some (Int64.to_float value))
  | Sqlite3.Data.NONE | Sqlite3.Data.TEXT _ | Sqlite3.Data.BLOB _ ->
    Error (Index_unavailable "memory index returned non-numeric BM25 score")
;;

let search db ~claims ~filter compiled =
  let count = Array.length claims in
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
      let where_like = "(" ^ String.concat " OR " like_terms ^ ")" in
      Ok
        (match filter with
         | All_rows ->
           Printf.sprintf "SELECT ordinal FROM memory_search WHERE %s" where_like
         | Excluding _ ->
           Printf.sprintf
             "SELECT ordinal FROM memory_search WHERE %s AND owner != ?%d"
             where_like
             (like_count + 1))
    | Some _, _ :: _ ->
      let like_terms =
        List.init like_count (fun i -> Printf.sprintf "(m.claim LIKE ?%d ESCAPE '\\')" (i + 1))
      in
      let where_like = String.concat " OR " like_terms in
      let match_param = like_count + 1 in
      Ok
        (match filter with
         | All_rows ->
           Printf.sprintf
             "SELECT m.ordinal, f.score FROM memory_search AS m \
              LEFT JOIN (SELECT rowid, bm25(memory_search) AS score FROM memory_search WHERE memory_search MATCH ?%d) AS f \
              ON m.rowid = f.rowid \
              WHERE (f.rowid IS NOT NULL OR %s)"
             match_param
             where_like
         | Excluding _ ->
           Printf.sprintf
             "SELECT m.ordinal, f.score FROM memory_search AS m \
              LEFT JOIN (SELECT rowid, bm25(memory_search) AS score FROM memory_search WHERE memory_search MATCH ?%d) AS f \
              ON m.rowid = f.rowid \
              WHERE (f.rowid IS NOT NULL OR %s) AND m.owner != ?%d"
             match_param
             where_like
             (match_param + 1))
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
         match filter, compiled.short_terms with
         | All_rows, _ -> Ok ()
         | Excluding { owner; limit }, [] ->
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
         | Excluding { owner; limit = (_ : int) }, _ :: _ ->
           check
             db
             "bind excluded memory owner"
             (Sqlite3.bind statement next_param (Sqlite3.Data.TEXT owner))
       in
       let rec rows hits =
         match Sqlite3.step statement with
         | exception Sqlite3.Error detail -> Error (Index_unavailable ("search memory: " ^ detail))
         | Sqlite3.Rc.ROW ->
           let ordinal = Sqlite3.column_int statement 0 in
           if ordinal < 0 || ordinal >= count
           then Error (Index_unavailable "memory index returned an ordinal outside its input")
           else (
             match compiled.trigram_expr, compiled.short_terms with
             | _, [] -> rows ((ordinal, Sqlite3.column_double statement 1) :: hits)
             | None, short_terms ->
               let short_hits = count_short_term_hits claims.(ordinal) short_terms in
               if short_hits > 0
               then rows ((ordinal, -. float_of_int short_hits) :: hits)
               else rows hits
             | Some _, short_terms ->
               let* trigram_score = column_opt_double statement 1 in
               let short_hits = count_short_term_hits claims.(ordinal) short_terms in
               if Option.is_some trigram_score || short_hits > 0
               then
                 let score = Option.value trigram_score ~default:0.0 -. float_of_int short_hits in
                 rows ((ordinal, score) :: hits)
               else rows hits)
         | Sqlite3.Rc.DONE ->
           (match compiled.short_terms, filter with
            | [], (All_rows | Excluding _) -> Ok (List.rev hits)
            | _ :: _, All_rows -> Ok (List.sort compare_hit hits)
            | _ :: _, Excluding { owner = (_ : string); limit } ->
              Ok (take_prefix limit (List.sort compare_hit hits)))
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
    let claims = Array.of_list (List.map snd texts) in
    Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ @@ fun () ->
    (try
       with_database (Sqlite3.db_open ":memory:") (fun db ->
         let* () = create_table db texts in
         let rec search_all results executed = function
           | [] ->
             Ok
               ( List.rev results
               , { index_builds = 1; indexed_rows = Array.length claims; queries_executed = executed }
               )
           | (_, None) :: rest -> search_all ([] :: results) executed rest
           | (filter, Some plan) :: rest ->
             let* ranked = search db ~claims ~filter plan in
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
  let claims = Array.of_list (List.map snd texts) in
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
                             indexed_rows = !stats.indexed_rows + Array.length claims };
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
                  ~claims
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

(* --- Persistent Per-Keeper SQLite WAL FTS5 Index --- *)

type persistent_hit =
  { memory_id : string
  ; claim : string
  ; category : string
  ; score : float
  }

let db_suffix = ".memory_fts.db"

let db_path ~keepers_dir ~keeper_id =
  Filename.concat keepers_dir (keeper_id ^ db_suffix)
;;

let exec_ok db op sql =
  let rc = Sqlite3.exec db sql in
  if Sqlite3.Rc.is_success rc then Ok () else Error (sqlite_error db op)
;;

let step_done db op stmt =
  let rc = Sqlite3.step stmt in
  if rc = Sqlite3.Rc.DONE then Ok () else Error (sqlite_error db op)
;;

let persistent_schema_initialized db =
  with_statement db
    "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'keeper_memory_fts' LIMIT 1"
    (fun stmt ->
       let rc = Sqlite3.step stmt in
       if rc = Sqlite3.Rc.ROW
       then Ok true
       else if rc = Sqlite3.Rc.DONE
       then Ok false
       else Error (sqlite_error db "check persistent fts schema"))
;;

let init_persistent_schema db =
  let* () = exec_ok db "pragma busy_timeout" "PRAGMA busy_timeout=5000;" in
  let* () = exec_ok db "pragma synchronous" "PRAGMA synchronous=NORMAL;" in
  let* ready = persistent_schema_initialized db in
  if ready
  then Ok ()
  else (
    let* () = exec_ok db "pragma journal_mode" "PRAGMA journal_mode=WAL;" in
    let* () =
      exec_ok db "create fts_meta"
        "CREATE TABLE IF NOT EXISTS fts_meta (\
           id INTEGER PRIMARY KEY CHECK (id = 1),\
           revision INTEGER NOT NULL,\
           content_sha256 TEXT NOT NULL\
         );"
    in
    exec_ok db "create persistent fts5"
      "CREATE VIRTUAL TABLE IF NOT EXISTS keeper_memory_fts USING \
       fts5(ordinal UNINDEXED, memory_id UNINDEXED, category UNINDEXED, claim, tokenize='trigram');")
;;

let facts_content_sha256 (facts : Keeper_memory_os_types.fact list) =
  let ctx = Agent_core_sha256.init () in
  let ctx =
    List.fold_left
      (fun ctx (fact : Keeper_memory_os_types.fact) ->
         let line =
           Printf.sprintf "%s|%s|%s\n"
             (Keeper_memory_os_types.memory_id fact)
             (Keeper_memory_os_types.category_to_string fact.category)
             fact.claim
         in
         Agent_core_sha256.feed_string ctx line)
      ctx
      facts
  in
  Agent_core_sha256.get ctx |> Agent_core_sha256.to_hex
;;

let read_stored_meta db =
  with_statement db "SELECT revision, content_sha256 FROM fts_meta WHERE id = 1" (fun stmt ->
    let rc = Sqlite3.step stmt in
    if rc = Sqlite3.Rc.ROW
    then Ok (Some (Sqlite3.column_int stmt 0, Sqlite3.column_text stmt 1))
    else if rc = Sqlite3.Rc.DONE
    then Ok None
    else Error (sqlite_error db "read fts_meta"))
;;

let sync_facts_on_db db ?revision (facts : Keeper_memory_os_types.fact list) =
  let expected_sha = facts_content_sha256 facts in
  let* stored = read_stored_meta db in
  match stored with
  | Some (_, sha) when String.equal sha expected_sha -> Ok (List.length facts)
  | (Some _ | None) as prior ->
    let stored_revision =
      match revision, prior with
      | Some rev, _ -> rev
      | None, Some (existing_rev, _) -> existing_rev
      | None, None -> 0
    in
    let* () = exec_ok db "begin immediate" "BEGIN IMMEDIATE;" in
    let body () =
      let* () = exec_ok db "clear fts" "DELETE FROM keeper_memory_fts;" in
      let* count =
        with_statement db
          "INSERT INTO keeper_memory_fts(ordinal, memory_id, category, claim) VALUES (?1, ?2, ?3, ?4)"
          (fun stmt ->
             let rec loop idx = function
               | [] -> Ok idx
               | (fact : Keeper_memory_os_types.fact) :: rest ->
                 let* () =
                   check db "bind ordinal"
                     (Sqlite3.bind stmt 1 (Sqlite3.Data.INT (Int64.of_int idx)))
                 in
                 let* () =
                   check db "bind memory_id"
                     (Sqlite3.bind stmt 2 (Sqlite3.Data.TEXT (Keeper_memory_os_types.memory_id fact)))
                 in
                 let* () =
                   check db "bind category"
                     (Sqlite3.bind stmt 3
                        (Sqlite3.Data.TEXT (Keeper_memory_os_types.category_to_string fact.category)))
                 in
                 let* () = check db "bind claim" (Sqlite3.bind stmt 4 (Sqlite3.Data.TEXT fact.claim)) in
                 let* () = step_done db "insert fts row" stmt in
                 let* () = check db "reset fts insert" (Sqlite3.reset stmt) in
                 loop (idx + 1) rest
             in
             loop 0 facts)
      in
      let* () =
        with_statement db
          "INSERT INTO fts_meta(id, revision, content_sha256) VALUES (1, ?1, ?2) \
           ON CONFLICT(id) DO UPDATE SET revision = excluded.revision, content_sha256 = excluded.content_sha256"
          (fun stmt ->
             let* () =
               check db "bind rev" (Sqlite3.bind stmt 1 (Sqlite3.Data.INT (Int64.of_int stored_revision)))
             in
             let* () = check db "bind sha" (Sqlite3.bind stmt 2 (Sqlite3.Data.TEXT expected_sha)) in
             step_done db "upsert fts_meta" stmt)
      in
      let* () = exec_ok db "commit" "COMMIT;" in
      Ok count
    in
    (match body () with
     | Ok count -> Ok count
     | Error err ->
       ignore (Sqlite3.exec db "ROLLBACK;" : Sqlite3.Rc.t);
       Error err)
;;

let open_persistent_db ~keepers_dir ~keeper_id f =
  let path = db_path ~keepers_dir ~keeper_id in
  let dir = Filename.dirname path in
  match Fs_compat.mkdir_p dir with
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn -> Error (Index_unavailable (Printexc.to_string exn))
  | () ->
    (match Sqlite3.db_open path with
     | exception Sqlite3.Error detail -> Error (Index_unavailable detail)
     | db ->
       with_database db (fun db ->
         let* () = init_persistent_schema db in
         f db))
;;

let sync_snapshot ~keepers_dir ~keeper_id (snapshot : Keeper_memory_os_current_types.t) =
  (* The persistent index has no account or conversation scope, so personal
     facts never enter it. Indexing the ordinary projection also keeps the
     stored content hash equal to the one [rank_persistent_for_facts] computes
     from ordinary reads, so its read-only fast path stays valid. *)
  let facts = List.filter Keeper_memory_os_types.is_ordinary snapshot.facts in
  Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
    open_persistent_db ~keepers_dir ~keeper_id (fun db ->
      sync_facts_on_db db ~revision:snapshot.revision facts))
;;

let query_persistent_db db ~query ~limit =
  match compile_query query with
  | None -> Ok []
  | Some compiled when limit <= 0 ->
    let (_ : compiled_query) = compiled in
    Ok []
  | Some compiled ->
    let like_count = List.length compiled.short_terms in
    let* sql =
      match compiled.trigram_expr, compiled.short_terms with
      | None, [] -> Error (Index_unavailable "empty search query")
      | Some _, [] ->
        Ok
          "SELECT ordinal, memory_id, category, claim, bm25(keeper_memory_fts) \
           FROM keeper_memory_fts WHERE keeper_memory_fts MATCH ?1 \
           ORDER BY bm25(keeper_memory_fts), ordinal LIMIT ?2"
      | None, _ :: _ ->
        let like_terms =
          List.init like_count (fun i -> Printf.sprintf "claim LIKE ?%d ESCAPE '\\'" (i + 1))
        in
        Ok
          (Printf.sprintf
             "SELECT ordinal, memory_id, category, claim, NULL \
              FROM keeper_memory_fts WHERE (%s) ORDER BY ordinal"
             (String.concat " OR " like_terms))
      | Some _, _ :: _ ->
        let like_terms =
          List.init like_count (fun i -> Printf.sprintf "(m.claim LIKE ?%d ESCAPE '\\')" (i + 1))
        in
        let match_param = like_count + 1 in
        Ok
          (Printf.sprintf
             "SELECT m.ordinal, m.memory_id, m.category, m.claim, f.score \
              FROM keeper_memory_fts AS m \
              LEFT JOIN (SELECT rowid, bm25(keeper_memory_fts) AS score \
                         FROM keeper_memory_fts WHERE keeper_memory_fts MATCH ?%d) AS f \
              ON m.rowid = f.rowid \
              WHERE (f.rowid IS NOT NULL OR %s)"
             match_param
             (String.concat " OR " like_terms))
    in
    with_statement db sql (fun stmt ->
      let* () =
        match compiled.trigram_expr, compiled.short_terms with
        | Some expr, [] ->
          let* () = check db "bind match" (Sqlite3.bind stmt 1 (Sqlite3.Data.TEXT expr)) in
          check db "bind limit" (Sqlite3.bind stmt 2 (Sqlite3.Data.INT (Int64.of_int limit)))
        | trigram_opt, short_terms ->
          let rec bind_short idx = function
            | [] -> Ok idx
            | term :: rest ->
              let* () =
                check db "bind short" (Sqlite3.bind stmt idx (Sqlite3.Data.TEXT (escape_like term)))
              in
              bind_short (idx + 1) rest
          in
          let* idx = bind_short 1 short_terms in
          (match trigram_opt with
           | None -> Ok ()
           | Some expr -> check db "bind match" (Sqlite3.bind stmt idx (Sqlite3.Data.TEXT expr)))
      in
      let rec collect acc =
        let rc = Sqlite3.step stmt in
        if rc = Sqlite3.Rc.ROW
        then (
          let ordinal = Sqlite3.column_int stmt 0 in
          let memory_id = Sqlite3.column_text stmt 1 in
          let category = Sqlite3.column_text stmt 2 in
          let claim = Sqlite3.column_text stmt 3 in
          match compiled.trigram_expr, compiled.short_terms with
          | _, [] ->
            let score = Sqlite3.column_double stmt 4 in
            collect ((ordinal, { memory_id; claim; category; score }) :: acc)
          | None, short_terms ->
            let short_hits = count_short_term_hits claim short_terms in
            if short_hits > 0
            then
              collect
                ((ordinal, { memory_id; claim; category; score = -.float_of_int short_hits }) :: acc)
            else collect acc
          | Some _, short_terms ->
            let* trigram_score = column_opt_double stmt 4 in
            let short_hits = count_short_term_hits claim short_terms in
            if Option.is_some trigram_score || short_hits > 0
            then (
              let score = Option.value trigram_score ~default:0.0 -. float_of_int short_hits in
              collect ((ordinal, { memory_id; claim; category; score }) :: acc))
            else collect acc)
        else if rc = Sqlite3.Rc.DONE
        then (
          match compiled.short_terms with
          | [] -> Ok (List.rev acc)
          | _ :: _ ->
            let sorted =
              List.sort
                (fun (oa, ha) (ob, hb) ->
                   match Float.compare ha.score hb.score with
                   | 0 -> Int.compare oa ob
                   | c -> c)
                acc
            in
            Ok (take_prefix limit sorted))
        else Error (sqlite_error db "search persistent memory")
      in
      collect [])
;;

let open_persistent_db_ro ~keepers_dir ~keeper_id f =
  let path = db_path ~keepers_dir ~keeper_id in
  if not (Sys.file_exists path)
  then Ok None
  else (
    match Sqlite3.db_open ~mode:`READONLY path with
    | exception Sqlite3.Error detail -> Error (Index_unavailable detail)
    | db ->
      with_database db (fun db ->
        let* () = exec_ok db "pragma busy_timeout_ro" "PRAGMA busy_timeout=5000;" in
        let* v = f db in
        Ok (Some v)))
;;

let search_persistent ~keepers_dir ~keeper_id ~query ~limit =
  Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
    let* rows_opt =
      open_persistent_db_ro ~keepers_dir ~keeper_id (fun db ->
        query_persistent_db db ~query ~limit)
    in
    match rows_opt with
    | None -> Ok []
    | Some rows -> Ok (List.map snd rows))
;;

let rank_persistent_for_facts ~keepers_dir ~keeper_id ~query (facts : Keeper_memory_os_types.fact list) =
  match compile_query query, facts with
  | None, _ | _, [] -> Ok []
  | Some _, _ :: _ ->
    let expected_sha = facts_content_sha256 facts in
    Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
      (* Fast path: pure read-only MVCC query when the persistent FTS5 index
         already matches [expected_sha] (zero write locks, zero rebuilds). *)
      let ro_attempt =
        open_persistent_db_ro ~keepers_dir ~keeper_id (fun db ->
          let* stored = read_stored_meta db in
          match stored with
          | Some (_, sha) when String.equal sha expected_sha ->
            let* rows = query_persistent_db db ~query ~limit:(List.length facts) in
            Ok (Some (List.map (fun (ordinal, hit) -> ordinal, hit.score) rows))
          | Some _ | None -> Ok None)
      in
      match ro_attempt with
      | Ok (Some (Some hits)) -> Ok hits
      | Ok (Some None) | Ok None | Error _ ->
        open_persistent_db ~keepers_dir ~keeper_id (fun db ->
          let* (_ : int) = sync_facts_on_db db facts in
          let* rows = query_persistent_db db ~query ~limit:(List.length facts) in
          Ok (List.map (fun (ordinal, hit) -> ordinal, hit.score) rows)))
;;
