module Turn_id = Ids.Turn_id
open Result.Syntax

type runtime_kind =
  | Agent_core_http
  | Acp_cli
  | Official_cli

let runtime_kind_to_string = function
  | Agent_core_http -> "agent_core_http"
  | Acp_cli -> "acp_cli"
  | Official_cli -> "official_cli"
;;

let runtime_kind_of_string = function
  | "agent_core_http" -> Ok Agent_core_http
  | "acp_cli" -> Ok Acp_cli
  | "official_cli" -> Ok Official_cli
  | other -> Error (Printf.sprintf "unknown canonical runtime_kind: %S" other)
;;

type canonical_turn =
  { turn_id : Turn_id.t
  ; parent_turn_id : Turn_id.t option
  ; runtime_kind : runtime_kind
  ; runtime_id : string
  ; user_input : string
  ; tool_calls_json : Yojson.Safe.t
  ; assistant_output : string
  ; usage_json : Yojson.Safe.t
  ; compaction_epoch_id : int option
  ; created_at : float
  }

type handoff_context =
  { anchor : Keeper_compaction.compaction_anchor option
  ; turns_after_anchor : canonical_turn list
  ; messages : Agent_core.Types.message list
  }

type store_error =
  | Sqlite_error of
      { operation : string
      ; detail : string
      }
  | Corrupt_record of
      { context : string
      ; detail : string
      }

let store_error_to_string = function
  | Sqlite_error { operation; detail } ->
    Printf.sprintf "canonical turn store sqlite error (%s): %s" operation detail
  | Corrupt_record { context; detail } ->
    Printf.sprintf "canonical turn store corrupt record (%s): %s" context detail
;;

let db_suffix = ".canonical-turns.db"
let max_retained_turns = 2000

let db_path ~keepers_dir ~keeper_id =
  Filename.concat keepers_dir (keeper_id ^ db_suffix)
;;

let delete_store ~keepers_dir ~keeper_id =
  let base = db_path ~keepers_dir ~keeper_id in
  let paths = [ base; base ^ "-wal"; base ^ "-shm"; base ^ "-journal" ] in
  Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
    let rec unlink_all = function
      | [] -> Ok ()
      | path :: rest ->
        (match Unix.unlink path with
         | () -> unlink_all rest
         | exception Unix.Unix_error (Unix.ENOENT, _, _) -> unlink_all rest
         | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
         | exception Unix.Unix_error (code, fn, arg) ->
           Error
             (Sqlite_error
                { operation = "delete_store"
                ; detail =
                    Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message code)
                })
         | exception Sys_error detail ->
           Error (Sqlite_error { operation = "delete_store"; detail }))
    in
    unlink_all paths)
;;

(* --- SQLite WAL helpers (off-domain via Domain_pool_ref) --- *)

let sqlite_err db operation rc =
  Sqlite_error
    { operation
    ; detail = Printf.sprintf "%s: %s" (Sqlite3.Rc.to_string rc) (Sqlite3.errmsg db)
    }
;;

let exec_sql db operation sql =
  match Sqlite3.exec db sql with
  | rc when Sqlite3.Rc.is_success rc -> Ok ()
  | rc -> Error (sqlite_err db operation rc)
  | exception (Sqlite3.Error detail | Sqlite3.SqliteError detail) ->
    Error (Sqlite_error { operation; detail })
;;

let with_stmt db operation sql f =
  match Sqlite3.prepare db sql with
  | exception (Sqlite3.Error detail | Sqlite3.SqliteError detail) ->
    Error (Sqlite_error { operation; detail })
  | stmt ->
    Fun.protect
      ~finally:(fun () ->
        try ignore (Sqlite3.finalize stmt : Sqlite3.Rc.t) with
        | Sqlite3.Error _ | Sqlite3.SqliteError _ -> ())
      (fun () ->
         try f stmt with
         | Sqlite3.Error detail | Sqlite3.SqliteError detail ->
           Error (Sqlite_error { operation; detail }))
;;

let bind_values db operation stmt values =
  let rec loop idx = function
    | [] -> Ok ()
    | v :: rest ->
      let rc = Sqlite3.bind stmt idx v in
      if Sqlite3.Rc.is_success rc
      then loop (idx + 1) rest
      else Error (sqlite_err db operation rc)
  in
  loop 1 values
;;

let table_exists db table_name =
  with_stmt
    db
    "check_table"
    "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1 LIMIT 1"
    (fun stmt ->
       let* () = bind_values db "bind_table_name" stmt [ Sqlite3.Data.TEXT table_name ] in
       let rc = Sqlite3.step stmt in
       if rc = Sqlite3.Rc.ROW
       then Ok true
       else if rc = Sqlite3.Rc.DONE
       then Ok false
       else Error (sqlite_err db "check_table" rc))
;;

let column_exists db ~table ~column =
  with_stmt
    db
    "check_column"
    (Printf.sprintf "PRAGMA table_info(%s)" table)
    (fun stmt ->
       let rec loop () =
         let rc = Sqlite3.step stmt in
         if rc = Sqlite3.Rc.ROW
         then
           if String.equal (Sqlite3.column_text stmt 1) column
           then Ok true
           else loop ()
         else if rc = Sqlite3.Rc.DONE
         then Ok false
         else Error (sqlite_err db "check_column" rc)
       in
       loop ())
;;

let init_schema db =
  let* () = exec_sql db "pragma_busy" "PRAGMA busy_timeout=5000;" in
  let* () = exec_sql db "pragma_fk" "PRAGMA foreign_keys=ON;" in
  let* () = exec_sql db "pragma_sync" "PRAGMA synchronous=NORMAL;" in
  let* ready = table_exists db "canonical_turns" in
  let* () =
    if ready
    then Ok ()
    else (
      (* Must be set before the first table is created so SQLite persists
         auto_vacuum=INCREMENTAL (2) in the database header. *)
      let* () = exec_sql db "pragma_auto_vacuum" "PRAGMA auto_vacuum=INCREMENTAL;" in
      let* () = exec_sql db "pragma_wal" "PRAGMA journal_mode=WAL;" in
      let* () =
        exec_sql
          db
          "create_canonical_turns"
          "CREATE TABLE IF NOT EXISTS canonical_turns (\
           seq INTEGER PRIMARY KEY AUTOINCREMENT, \
           turn_id TEXT NOT NULL UNIQUE, \
           parent_turn_id TEXT, \
           runtime_kind TEXT NOT NULL, \
           runtime_id TEXT NOT NULL, \
           user_input TEXT NOT NULL, \
           tool_calls_json TEXT NOT NULL, \
           assistant_output TEXT NOT NULL, \
           usage_json TEXT NOT NULL, \
           compaction_epoch_id INTEGER, \
           created_at REAL NOT NULL)"
      in
      exec_sql
        db
        "create_idx_canonical_turns_seq"
        "CREATE INDEX IF NOT EXISTS idx_canonical_turns_seq ON canonical_turns(seq)")
  in
  let* watermarks_ready = table_exists db "compaction_watermarks" in
  let* () =
    if watermarks_ready
    then (
      let* has_last_turn_id =
        column_exists db ~table:"compaction_watermarks" ~column:"last_turn_id"
      in
      if has_last_turn_id
      then Ok ()
      else
        exec_sql
          db
          "alter_compaction_watermarks_last_turn_id"
          "ALTER TABLE compaction_watermarks ADD COLUMN last_turn_id TEXT")
    else
      exec_sql
        db
        "create_compaction_watermarks"
        "CREATE TABLE IF NOT EXISTS compaction_watermarks (\
         epoch_id INTEGER PRIMARY KEY, \
         covers_through_turn TEXT NOT NULL, \
         cutoff_seq INTEGER NOT NULL, \
         recorded_at REAL NOT NULL, \
         last_turn_id TEXT)"
  in
  let* resets_ready = table_exists db "history_resets" in
  if resets_ready
  then Ok ()
  else
    exec_sql
      db
      "create_history_resets"
      "CREATE TABLE IF NOT EXISTS history_resets (\
       id INTEGER PRIMARY KEY CHECK (id = 1), \
       reset_after_seq INTEGER NOT NULL, \
       reset_after_anchor_epoch INTEGER NOT NULL, \
       recorded_at REAL NOT NULL)"
;;

let prune_turns_through_seq_in_tx db ~max_seq =
  if max_seq <= 0L
  then Ok false
  else
    with_stmt
      db
      "prune_turns_through_seq"
      "DELETE FROM canonical_turns WHERE seq <= ?1"
      (fun stmt ->
         let* () = bind_values db "bind_prune_max_seq" stmt [ Sqlite3.Data.INT max_seq ] in
         let rc = Sqlite3.step stmt in
         if rc = Sqlite3.Rc.DONE
         then Ok (Sqlite3.changes db > 0)
         else Error (sqlite_err db "prune_turns_through_seq" rc))
;;

let prune_retention_cap_in_tx db ~retain =
  let keep = Int.max 1 retain in
  with_stmt
    db
    "prune_retention_cap"
    "DELETE FROM canonical_turns \
     WHERE seq NOT IN (SELECT seq FROM canonical_turns ORDER BY seq DESC LIMIT ?1)"
    (fun stmt ->
       let* () =
         bind_values db "bind_prune_retention_cap" stmt [ Sqlite3.Data.INT (Int64.of_int keep) ]
       in
       let rc = Sqlite3.step stmt in
       if rc = Sqlite3.Rc.DONE
       then Ok (Sqlite3.changes db > 0)
       else Error (sqlite_err db "prune_retention_cap" rc))
;;

let run_incremental_vacuum_if_pruned db ~keeper_id pruned =
  if not pruned
  then ()
  else (
    match exec_sql db "incremental_vacuum" "PRAGMA incremental_vacuum(64);" with
    | Ok () -> ()
    | Error err ->
      Log.Keeper.debug
        ~keeper_name:keeper_id
        "canonical turn store incremental_vacuum skipped: %s"
        (store_error_to_string err))
;;

let with_transaction db ~begin_sql f =
  let* () = exec_sql db "begin_tx" begin_sql in
  let rollback () =
    ignore (exec_sql db "rollback_tx" "ROLLBACK;" : (unit, store_error) result)
  in
  match f () with
  | Ok value ->
    (match exec_sql db "commit_tx" "COMMIT;" with
     | Ok () -> Ok value
     | Error _ as err ->
       rollback ();
       err)
  | Error _ as err ->
    rollback ();
    err
  | exception exn ->
    rollback ();
    raise exn
;;

let with_db ~create ~keepers_dir ~keeper_id f =
  let path = db_path ~keepers_dir ~keeper_id in
  Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
    if (not create) && not (Sys.file_exists path)
    then Ok None
    else (
      if create then Fs_compat.mkdir_p keepers_dir;
      match
        if create
        then Sqlite3.db_open path
        else Sqlite3.db_open ~mode:`READONLY path
      with
      | exception (Sqlite3.Error detail | Sqlite3.SqliteError detail) ->
        Error (Sqlite_error { operation = "db_open"; detail })
      | db ->
        Fun.protect
          ~finally:(fun () ->
            try ignore (Sqlite3.db_close db : bool) with
            | Sqlite3.Error _ | Sqlite3.SqliteError _ -> ())
          (fun () ->
             let* () =
               if create
               then init_schema db
               else exec_sql db "pragma_busy_ro" "PRAGMA busy_timeout=5000;"
             in
             f db)))
;;

let decode_json_column ~context raw =
  match Yojson.Safe.from_string raw with
  | json -> Ok json
  | exception Yojson.Json_error detail -> Error (Corrupt_record { context; detail })
;;

let decode_int64_column ~context stmt col =
  match Sqlite3.column stmt col with
  | Sqlite3.Data.INT i -> Ok i
  | Sqlite3.Data.NONE
  | Sqlite3.Data.NULL
  | Sqlite3.Data.FLOAT _
  | Sqlite3.Data.TEXT _
  | Sqlite3.Data.BLOB _ ->
    Error (Corrupt_record { context; detail = "expected INTEGER column" })
;;

let decode_opt_int64_column ~context stmt col =
  match Sqlite3.column stmt col with
  | Sqlite3.Data.NULL -> Ok None
  | Sqlite3.Data.INT i -> Ok (Some i)
  | Sqlite3.Data.NONE
  | Sqlite3.Data.FLOAT _
  | Sqlite3.Data.TEXT _
  | Sqlite3.Data.BLOB _ ->
    Error (Corrupt_record { context; detail = "expected INTEGER or NULL column" })
;;

let decode_row stmt =
  let* turn_id =
    match Sqlite3.column stmt 0 with
    | Sqlite3.Data.TEXT s when not (String.equal (String.trim s) "") ->
      Ok (Turn_id.of_string s)
    | Sqlite3.Data.NONE
    | Sqlite3.Data.NULL
    | Sqlite3.Data.INT _
    | Sqlite3.Data.FLOAT _
    | Sqlite3.Data.TEXT _
    | Sqlite3.Data.BLOB _ ->
      Error
        (Corrupt_record
           { context = "turn_id"
           ; detail = "expected non-blank TEXT for turn_id"
           })
  in
  let* parent_turn_id =
    match Sqlite3.column stmt 1 with
    | Sqlite3.Data.NULL -> Ok None
    | Sqlite3.Data.TEXT s when not (String.equal (String.trim s) "") ->
      Ok (Some (Turn_id.of_string s))
    | Sqlite3.Data.NONE
    | Sqlite3.Data.INT _
    | Sqlite3.Data.FLOAT _
    | Sqlite3.Data.TEXT _
    | Sqlite3.Data.BLOB _ ->
      Error
        (Corrupt_record
           { context = "parent_turn_id"
           ; detail = "expected NULL or non-blank TEXT for parent_turn_id"
           })
  in
  let* runtime_kind =
    runtime_kind_of_string (Sqlite3.column_text stmt 2)
    |> Result.map_error (fun detail -> Corrupt_record { context = "runtime_kind"; detail })
  in
  let runtime_id = Sqlite3.column_text stmt 3 in
  let user_input = Sqlite3.column_text stmt 4 in
  let* tool_calls_json =
    decode_json_column ~context:"tool_calls_json" (Sqlite3.column_text stmt 5)
  in
  let assistant_output = Sqlite3.column_text stmt 6 in
  let* usage_json =
    decode_json_column ~context:"usage_json" (Sqlite3.column_text stmt 7)
  in
  let* compaction_epoch_id =
    match Sqlite3.column stmt 8 with
    | Sqlite3.Data.NULL -> Ok None
    | Sqlite3.Data.INT i -> Ok (Some (Int64.to_int i))
    | Sqlite3.Data.NONE
    | Sqlite3.Data.FLOAT _
    | Sqlite3.Data.TEXT _
    | Sqlite3.Data.BLOB _ ->
      Error
        (Corrupt_record
           { context = "compaction_epoch_id"
           ; detail = "expected INTEGER or NULL for compaction_epoch_id"
           })
  in
  let created_at = Sqlite3.column_double stmt 9 in
  Ok
    { turn_id
    ; parent_turn_id
    ; runtime_kind
    ; runtime_id
    ; user_input
    ; tool_calls_json
    ; assistant_output
    ; usage_json
    ; compaction_epoch_id
    ; created_at
    }
;;

let select_columns =
  "turn_id, parent_turn_id, runtime_kind, runtime_id, user_input, \
   tool_calls_json, assistant_output, usage_json, compaction_epoch_id, created_at"
;;

let lookup_history_reset_in_tx db =
  let* ready = table_exists db "history_resets" in
  if not ready
  then Ok (0L, 0)
  else
    with_stmt
      db
      "select_history_reset"
      "SELECT reset_after_seq, reset_after_anchor_epoch FROM history_resets WHERE id = 1 LIMIT 1"
      (fun stmt ->
         let rc = Sqlite3.step stmt in
         if rc = Sqlite3.Rc.ROW
         then (
           let* reset_after_seq =
             decode_int64_column ~context:"history_resets.reset_after_seq" stmt 0
           in
           let* reset_after_anchor_epoch =
             decode_int64_column ~context:"history_resets.reset_after_anchor_epoch" stmt 1
           in
           Ok (reset_after_seq, Int64.to_int reset_after_anchor_epoch))
         else if rc = Sqlite3.Rc.DONE
         then Ok (0L, 0)
         else Error (sqlite_err db "select_history_reset" rc))
;;

let lookup_watermark_cutoff_seq_in_tx db ~epoch_id =
  let* ready = table_exists db "compaction_watermarks" in
  if not ready
  then Ok None
  else
    with_stmt
      db
      "select_compaction_watermark"
      "SELECT cutoff_seq FROM compaction_watermarks WHERE epoch_id = ?1 LIMIT 1"
      (fun stmt ->
         let* () =
           bind_values
             db
             "bind_watermark_epoch_id"
             stmt
             [ Sqlite3.Data.INT (Int64.of_int epoch_id) ]
         in
         let rc = Sqlite3.step stmt in
         if rc = Sqlite3.Rc.ROW
         then (
           let* cutoff =
             decode_int64_column ~context:"compaction_watermarks.cutoff_seq" stmt 0
           in
           Ok (Some cutoff))
         else if rc = Sqlite3.Rc.DONE
         then Ok None
         else Error (sqlite_err db "select_compaction_watermark" rc))
;;

let lookup_prior_watermark_cutoff_seq_in_tx db ~before_epoch_id =
  let* ready = table_exists db "compaction_watermarks" in
  if not ready
  then Ok None
  else
    with_stmt
      db
      "select_prior_compaction_watermark"
      "SELECT MAX(cutoff_seq) FROM compaction_watermarks WHERE epoch_id < ?1"
      (fun stmt ->
         let* () =
           bind_values
             db
             "bind_prior_watermark_epoch_id"
             stmt
             [ Sqlite3.Data.INT (Int64.of_int before_epoch_id) ]
         in
         let rc = Sqlite3.step stmt in
         if rc = Sqlite3.Rc.ROW
         then
           decode_opt_int64_column
             ~context:"compaction_watermarks.prior_max_cutoff_seq"
             stmt
             0
         else if rc = Sqlite3.Rc.DONE
         then Ok None
         else Error (sqlite_err db "select_prior_compaction_watermark" rc))
;;

let latest_turn_id_in_tx db ~excluding_turn_id =
  let* reset_after_seq, reset_after_anchor_epoch = lookup_history_reset_in_tx db in
  let excluding_str = Turn_id.to_string excluding_turn_id in
  let* from_live =
    with_stmt
      db
      "select_parent_turn"
      "SELECT turn_id FROM canonical_turns WHERE turn_id <> ?1 AND seq > ?2 ORDER BY seq DESC LIMIT 1"
      (fun stmt ->
         let* () =
           bind_values
             db
             "bind_excluding_turn_id"
             stmt
             [ Sqlite3.Data.TEXT excluding_str; Sqlite3.Data.INT reset_after_seq ]
         in
         let rc = Sqlite3.step stmt in
         if rc = Sqlite3.Rc.ROW
         then Ok (Some (Turn_id.of_string (Sqlite3.column_text stmt 0)))
         else if rc = Sqlite3.Rc.DONE
         then Ok None
         else Error (sqlite_err db "select_parent_turn" rc))
  in
  match from_live with
  | Some _ as hit -> Ok hit
  | None ->
    (* When compaction pruned all post-reset turns, preserve parent_turn_id
       continuity across the compaction boundary using the latest post-reset
       watermark's last canonical turn id (never crossing a history reset). *)
    let* watermarks_ready = table_exists db "compaction_watermarks" in
    if not watermarks_ready
    then Ok None
    else
      with_stmt
        db
        "select_parent_turn_from_watermark"
        "SELECT last_turn_id FROM compaction_watermarks \
         WHERE epoch_id > ?1 AND cutoff_seq > ?2 \
           AND last_turn_id IS NOT NULL AND last_turn_id <> ?3 \
         ORDER BY epoch_id DESC LIMIT 1"
        (fun stmt ->
           let* () =
             bind_values
               db
               "bind_parent_watermark"
               stmt
               [ Sqlite3.Data.INT (Int64.of_int reset_after_anchor_epoch)
               ; Sqlite3.Data.INT reset_after_seq
               ; Sqlite3.Data.TEXT excluding_str
               ]
           in
           let rc = Sqlite3.step stmt in
           if rc = Sqlite3.Rc.ROW
           then (
             match Sqlite3.column stmt 0 with
             | Sqlite3.Data.TEXT s when not (String.equal (String.trim s) "") ->
               Ok (Some (Turn_id.of_string s))
             | Sqlite3.Data.NULL -> Ok None
             | Sqlite3.Data.NONE
             | Sqlite3.Data.INT _
             | Sqlite3.Data.FLOAT _
             | Sqlite3.Data.TEXT _
             | Sqlite3.Data.BLOB _ ->
               Error
                 (Corrupt_record
                    { context = "compaction_watermarks.last_turn_id"
                    ; detail = "expected NULL or non-blank TEXT for last_turn_id"
                    }))
           else if rc = Sqlite3.Rc.DONE
           then Ok None
           else Error (sqlite_err db "select_parent_turn_from_watermark" rc))
;;

let existing_parent_in_tx db turn_id =
  with_stmt
    db
    "select_existing_parent_turn"
    "SELECT parent_turn_id FROM canonical_turns WHERE turn_id = ?1 LIMIT 1"
    (fun stmt ->
       let* () =
         bind_values
           db
           "bind_existing_turn_id"
           stmt
           [ Sqlite3.Data.TEXT (Turn_id.to_string turn_id) ]
       in
       let rc = Sqlite3.step stmt in
       if rc = Sqlite3.Rc.ROW
       then (
         match Sqlite3.column stmt 0 with
         | Sqlite3.Data.NULL -> Ok (`Exists None)
         | Sqlite3.Data.TEXT s when not (String.equal (String.trim s) "") ->
           Ok (`Exists (Some (Turn_id.of_string s)))
         | Sqlite3.Data.NONE
         | Sqlite3.Data.INT _
         | Sqlite3.Data.FLOAT _
         | Sqlite3.Data.TEXT _
         | Sqlite3.Data.BLOB _ ->
           Error
             (Corrupt_record
                { context = "existing_parent_turn_id"
                ; detail = "expected NULL or non-blank TEXT for parent_turn_id"
                }))
       else if rc = Sqlite3.Rc.DONE
       then Ok `Absent
       else Error (sqlite_err db "select_existing_parent_turn" rc))
;;

let commit_turn
      ~keepers_dir
      ~keeper_id
      ?parent_turn_id
      ~turn_id
      ~runtime_kind
      ~runtime_id
      ~user_input
      ~tool_calls_json
      ~assistant_output
      ~usage_json
      ?compaction_epoch_id
      ?(max_retained_turns = max_retained_turns)
      ~created_at
      ()
  =
  let turn_id_str = Turn_id.to_string turn_id in
  if String.equal (String.trim turn_id_str) ""
  then
    Error
      (Corrupt_record
         { context = "commit_turn.turn_id"; detail = "turn_id must be non-blank" })
  else (
    let parent_valid =
      match parent_turn_id with
      | None -> Ok ()
      | Some pid ->
        let pid_str = Turn_id.to_string pid in
        if String.equal (String.trim pid_str) ""
        then
          Error
            (Corrupt_record
               { context = "commit_turn.parent_turn_id"
               ; detail = "parent_turn_id must be non-blank"
               })
        else if String.equal pid_str turn_id_str
        then
          Error
            (Corrupt_record
               { context = "commit_turn.parent_turn_id"
               ; detail = "parent_turn_id cannot reference turn_id itself"
               })
        else Ok ()
    in
    let* () = parent_valid in
    let* committed =
      with_db ~create:true ~keepers_dir ~keeper_id (fun db ->
        let* turn, pruned =
          with_transaction db ~begin_sql:"BEGIN IMMEDIATE;" (fun () ->
            let* existing = existing_parent_in_tx db turn_id in
            let* resolved_parent =
              match parent_turn_id, existing with
              | Some _ as explicit, (`Exists _ | `Absent) -> Ok explicit
              | None, `Exists preserved_parent ->
                (* Preserve original parent_turn_id on idempotent re-commit so
                   re-writing an older turn never points forward in time. *)
                Ok preserved_parent
              | None, `Absent -> latest_turn_id_in_tx db ~excluding_turn_id:turn_id
            in
            let turn =
              { turn_id
              ; parent_turn_id = resolved_parent
              ; runtime_kind
              ; runtime_id
              ; user_input
              ; tool_calls_json
              ; assistant_output
              ; usage_json
              ; compaction_epoch_id
              ; created_at
              }
            in
            let parent_data =
              match resolved_parent with
              | None -> Sqlite3.Data.NULL
              | Some pid -> Sqlite3.Data.TEXT (Turn_id.to_string pid)
            in
            let epoch_data =
              match compaction_epoch_id with
              | None -> Sqlite3.Data.NULL
              | Some ep -> Sqlite3.Data.INT (Int64.of_int ep)
            in
            let* () =
              with_stmt
                db
                "upsert_canonical_turn"
                "INSERT INTO canonical_turns \
                 (turn_id, parent_turn_id, runtime_kind, runtime_id, user_input, \
                  tool_calls_json, assistant_output, usage_json, compaction_epoch_id, created_at) \
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10) \
                 ON CONFLICT(turn_id) DO UPDATE SET \
                   parent_turn_id = excluded.parent_turn_id, \
                   runtime_kind = excluded.runtime_kind, \
                   runtime_id = excluded.runtime_id, \
                   user_input = excluded.user_input, \
                   tool_calls_json = excluded.tool_calls_json, \
                   assistant_output = excluded.assistant_output, \
                   usage_json = excluded.usage_json, \
                   compaction_epoch_id = excluded.compaction_epoch_id, \
                   created_at = excluded.created_at"
                (fun stmt ->
                   let* () =
                     bind_values
                       db
                       "bind_canonical_turn"
                       stmt
                       [ Sqlite3.Data.TEXT turn_id_str
                       ; parent_data
                       ; Sqlite3.Data.TEXT (runtime_kind_to_string runtime_kind)
                       ; Sqlite3.Data.TEXT runtime_id
                       ; Sqlite3.Data.TEXT user_input
                       ; Sqlite3.Data.TEXT (Yojson.Safe.to_string tool_calls_json)
                       ; Sqlite3.Data.TEXT assistant_output
                       ; Sqlite3.Data.TEXT (Yojson.Safe.to_string usage_json)
                       ; epoch_data
                       ; Sqlite3.Data.FLOAT created_at
                       ]
                   in
                   let rc = Sqlite3.step stmt in
                   if rc = Sqlite3.Rc.DONE
                   then Ok ()
                   else Error (sqlite_err db "upsert_canonical_turn" rc))
            in
            let* pruned = prune_retention_cap_in_tx db ~retain:max_retained_turns in
            Ok (turn, pruned))
        in
        run_incremental_vacuum_if_pruned db ~keeper_id pruned;
        Ok (Some turn))
    in
    match committed with
    | Some turn -> Ok turn
    | None ->
      Error
        (Sqlite_error
           { operation = "commit_turn"
           ; detail = "write connection unexpectedly returned no committed turn"
           }))
;;

let step_all_turns db operation stmt =
  let rec loop acc =
    let rc = Sqlite3.step stmt in
    if rc = Sqlite3.Rc.ROW
    then (
      let* row = decode_row stmt in
      loop (row :: acc))
    else if rc = Sqlite3.Rc.DONE
    then Ok (List.rev acc)
    else Error (sqlite_err db operation rc)
  in
  loop []
;;

let latest_turn ~keepers_dir ~keeper_id =
  with_db ~create:false ~keepers_dir ~keeper_id (fun db ->
    with_transaction db ~begin_sql:"BEGIN DEFERRED;" (fun () ->
      let* ready = table_exists db "canonical_turns" in
      if not ready
      then Ok None
      else
        with_stmt
          db
          "select_latest_turn"
          ("SELECT " ^ select_columns ^ " FROM canonical_turns ORDER BY seq DESC LIMIT 1")
          (fun stmt ->
             let rc = Sqlite3.step stmt in
             if rc = Sqlite3.Rc.ROW
             then (
               let* turn = decode_row stmt in
               Ok (Some turn))
             else if rc = Sqlite3.Rc.DONE
             then Ok None
             else Error (sqlite_err db "select_latest_turn" rc))))
;;

let list_turns ~keepers_dir ~keeper_id =
  let* res =
    with_db ~create:false ~keepers_dir ~keeper_id (fun db ->
      with_transaction db ~begin_sql:"BEGIN DEFERRED;" (fun () ->
        let* ready = table_exists db "canonical_turns" in
        if not ready
        then Ok (Some [])
        else
          with_stmt
            db
            "list_turns"
            ("SELECT " ^ select_columns ^ " FROM canonical_turns ORDER BY seq ASC")
            (fun stmt ->
               let* rows = step_all_turns db "list_turns" stmt in
               Ok (Some rows))))
  in
  Ok (Option.value ~default:[] res)
;;

let load_turns_after ~keepers_dir ~keeper_id ~after_turn_id =
  let* res =
    with_db ~create:false ~keepers_dir ~keeper_id (fun db ->
      with_transaction db ~begin_sql:"BEGIN DEFERRED;" (fun () ->
        let* ready = table_exists db "canonical_turns" in
        if not ready
        then Ok (Some [])
        else
          let* cutoff_seq =
            with_stmt
              db
              "find_cutoff_seq"
              "SELECT seq FROM canonical_turns WHERE turn_id = ?1 LIMIT 1"
              (fun stmt ->
                 let* () =
                   bind_values
                     db
                     "bind_after_turn_id"
                     stmt
                     [ Sqlite3.Data.TEXT (Turn_id.to_string after_turn_id) ]
                 in
                 let rc = Sqlite3.step stmt in
                 if rc = Sqlite3.Rc.ROW
                 then (
                   let* seq = decode_int64_column ~context:"canonical_turns.seq" stmt 0 in
                   Ok (Some seq))
                 else if rc = Sqlite3.Rc.DONE
                 then Ok None
                 else Error (sqlite_err db "find_cutoff_seq" rc))
          in
          match cutoff_seq with
          | None ->
            with_stmt
              db
              "list_all_turns_after_missing_anchor"
              ("SELECT " ^ select_columns ^ " FROM canonical_turns ORDER BY seq ASC")
              (fun stmt ->
                 let* rows = step_all_turns db "list_all_turns_after_missing_anchor" stmt in
                 Ok (Some rows))
          | Some seq ->
            with_stmt
              db
              "load_turns_after_seq"
              ("SELECT "
               ^ select_columns
               ^ " FROM canonical_turns WHERE seq > ?1 ORDER BY seq ASC")
              (fun stmt ->
                 let* () = bind_values db "bind_cutoff_seq" stmt [ Sqlite3.Data.INT seq ] in
                 let* rows = step_all_turns db "load_turns_after_seq" stmt in
                 Ok (Some rows))))
  in
  Ok (Option.value ~default:[] res)
;;

let canonical_turn_id_metadata_key = "canonical_turn_id"

let tool_context_summary_of_json = function
  | `List [] | `Null -> None
  | (`List (_ :: _) | `Assoc _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _) as json ->
    Some (Printf.sprintf "[canonical tool calls] %s" (Yojson.Safe.to_string json))
;;

let messages_of_canonical_turn (turn : canonical_turn) =
  let turn_meta = [ canonical_turn_id_metadata_key, `String (Turn_id.to_string turn.turn_id) ] in
  let user_msgs =
    if String.equal (String.trim turn.user_input) ""
    then []
    else
      [ { (Agent_core.Types.make_message
             ~role:Agent_core.Types.User
             [ Agent_core.Types.Text turn.user_input ]) with
          metadata = turn_meta
        }
      ]
  in
  let assistant_parts =
    Option.to_list
      (Option.map
         (fun summary -> Agent_core.Types.Text summary)
         (tool_context_summary_of_json turn.tool_calls_json))
    @
    if String.equal (String.trim turn.assistant_output) ""
    then []
    else [ Agent_core.Types.Text turn.assistant_output ]
  in
  let assistant_msgs =
    match assistant_parts with
    | [] -> []
    | blocks ->
      [ { (Agent_core.Types.make_message ~role:Agent_core.Types.Assistant blocks) with
          metadata = turn_meta
        }
      ]
  in
  user_msgs @ assistant_msgs
;;

let bridged_turn_ref_metadata_key = "masc.bridged_turn_ref"

let joined_text_of_message (msg : Agent_core.Types.message) =
  let parts =
    msg.content
    |> List.filter_map (function
      | Agent_core.Types.Text s -> Some s
      | Agent_core.Types.Thinking _
      | Agent_core.Types.ReasoningDetails _
      | Agent_core.Types.RedactedThinking _
      | Agent_core.Types.ToolUse _
      | Agent_core.Types.ToolResult _
      | Agent_core.Types.ToolReference _
      | Agent_core.Types.Image _
      | Agent_core.Types.Document _
      | Agent_core.Types.Audio _ -> None)
  in
  let joined = String.trim (String.concat "\n" parts) in
  let singles =
    parts
    |> List.filter_map (fun s ->
      let trimmed = String.trim s in
      if String.equal trimmed "" then None else Some trimmed)
  in
  if String.equal joined ""
  then singles
  else if List.exists (String.equal joined) singles
  then singles
  else joined :: singles
;;

let canonical_turn_id_of_message (msg : Agent_core.Types.message) =
  let lookup key =
    match List.assoc_opt key msg.metadata with
    | Some (`String s) when not (String.equal (String.trim s) "") -> Some s
    | Some _ | None -> None
  in
  match lookup canonical_turn_id_metadata_key with
  | Some _ as hit -> hit
  | None -> lookup bridged_turn_ref_metadata_key
;;

type indexed_msg =
  { msg_role : Agent_core.Types.role
  ; msg_turn_id : string option
  ; msg_texts : string list
  }

let index_messages (messages : Agent_core.Types.message list) : indexed_msg array =
  Array.of_list
    (List.map
       (fun (msg : Agent_core.Types.message) ->
          { msg_role = msg.role
          ; msg_turn_id = canonical_turn_id_of_message msg
          ; msg_texts = joined_text_of_message msg
          })
       messages)
;;

(* Order-aware matching starting at [cursor]:
   1. Structural [canonical_turn_id] / [masc.bridged_turn_ref] match always wins,
      advancing past the last message carrying that turn_id.
   2. Legacy fallback ONLY matches untagged messages (never crossing or matching
      a message tagged with a different structural turn_id, and never re-matching
      messages already consumed by earlier turns). Joined per-message text
      matches [Llm_provider.Types.text_of_content], and tool-result User frames
      (empty [msg_texts]) do not prematurely terminate a multi-round turn. *)
let match_turn_from (msgs : indexed_msg array) ~cursor (turn : canonical_turn) =
  let n = Array.length msgs in
  let tid = Turn_id.to_string turn.turn_id in
  let rec find_structural i last_hit =
    if i >= n
    then last_hit
    else
      match msgs.(i).msg_turn_id with
      | Some m_tid when String.equal m_tid tid -> find_structural (i + 1) (Some (i + 1))
      | Some _ | None -> find_structural (i + 1) last_hit
  in
  match find_structural cursor None with
  | Some _ as next_cursor -> next_cursor
  | None ->
    let u = String.trim turn.user_input in
    let a = String.trim turn.assistant_output in
    let has_u = not (String.equal u "") in
    let has_a = not (String.equal a "") in
    let matches_untagged role needle m =
      m.msg_role = role
      && Option.is_none m.msg_turn_id
      && List.exists (String.equal needle) m.msg_texts
    in
    let rec find_next role needle i =
      if i >= n
      then None
      else if matches_untagged role needle msgs.(i)
      then Some i
      else find_next role needle (i + 1)
    in
    (match has_u, has_a with
     | true, true ->
       let rec find_reply i =
         if i >= n
         then None
         else if msgs.(i).msg_role = Agent_core.Types.User
                 && (msgs.(i).msg_texts <> [] || Option.is_some msgs.(i).msg_turn_id)
         then None
         else if matches_untagged Agent_core.Types.Assistant a msgs.(i)
         then Some (i + 1)
         else find_reply (i + 1)
       in
       let rec find_pair i =
         match find_next Agent_core.Types.User u i with
         | None -> None
         | Some u_idx ->
           (match find_reply (u_idx + 1) with
            | Some _ as hit -> hit
            | None -> find_pair (u_idx + 1))
       in
       find_pair cursor
     | true, false ->
       Option.map (fun u_idx -> u_idx + 1) (find_next Agent_core.Types.User u cursor)
     | false, true ->
       Option.map (fun a_idx -> a_idx + 1) (find_next Agent_core.Types.Assistant a cursor)
     | false, false -> None)
;;

let list_turns_with_seq_in_tx db =
  let* ready = table_exists db "canonical_turns" in
  if not ready
  then Ok []
  else
    with_stmt
      db
      "list_turns_with_seq"
      ("SELECT seq, " ^ select_columns ^ " FROM canonical_turns ORDER BY seq ASC")
      (fun stmt ->
         let rec loop acc =
           let rc = Sqlite3.step stmt in
           if rc = Sqlite3.Rc.ROW
           then (
             let* seq = decode_int64_column ~context:"canonical_turns.seq" stmt 0 in
             let* turn_id =
               match Sqlite3.column stmt 1 with
               | Sqlite3.Data.TEXT s when not (String.equal (String.trim s) "") ->
                 Ok (Turn_id.of_string s)
               | Sqlite3.Data.NONE
               | Sqlite3.Data.NULL
               | Sqlite3.Data.INT _
               | Sqlite3.Data.FLOAT _
               | Sqlite3.Data.TEXT _
               | Sqlite3.Data.BLOB _ ->
                 Error
                   (Corrupt_record
                      { context = "turn_id"; detail = "expected non-blank TEXT for turn_id" })
             in
             let* parent_turn_id =
               match Sqlite3.column stmt 2 with
               | Sqlite3.Data.NULL -> Ok None
               | Sqlite3.Data.TEXT s when not (String.equal (String.trim s) "") ->
                 Ok (Some (Turn_id.of_string s))
               | Sqlite3.Data.NONE
               | Sqlite3.Data.INT _
               | Sqlite3.Data.FLOAT _
               | Sqlite3.Data.TEXT _
               | Sqlite3.Data.BLOB _ ->
                 Error
                   (Corrupt_record
                      { context = "parent_turn_id"
                      ; detail = "expected NULL or non-blank TEXT for parent_turn_id"
                      })
             in
             let* runtime_kind =
               runtime_kind_of_string (Sqlite3.column_text stmt 3)
               |> Result.map_error (fun detail ->
                 Corrupt_record { context = "runtime_kind"; detail })
             in
             let runtime_id = Sqlite3.column_text stmt 4 in
             let user_input = Sqlite3.column_text stmt 5 in
             let* tool_calls_json =
               decode_json_column ~context:"tool_calls_json" (Sqlite3.column_text stmt 6)
             in
             let assistant_output = Sqlite3.column_text stmt 7 in
             let* usage_json =
               decode_json_column ~context:"usage_json" (Sqlite3.column_text stmt 8)
             in
             let* compaction_epoch_id =
               match Sqlite3.column stmt 9 with
               | Sqlite3.Data.NULL -> Ok None
               | Sqlite3.Data.INT i -> Ok (Some (Int64.to_int i))
               | Sqlite3.Data.NONE
               | Sqlite3.Data.FLOAT _
               | Sqlite3.Data.TEXT _
               | Sqlite3.Data.BLOB _ ->
                 Error
                   (Corrupt_record
                      { context = "compaction_epoch_id"
                      ; detail = "expected INTEGER or NULL for compaction_epoch_id"
                      })
             in
             let created_at = Sqlite3.column_double stmt 10 in
             let row =
               { turn_id
               ; parent_turn_id
               ; runtime_kind
               ; runtime_id
               ; user_input
               ; tool_calls_json
               ; assistant_output
               ; usage_json
               ; compaction_epoch_id
               ; created_at
               }
             in
             loop ((seq, row) :: acc))
           else if rc = Sqlite3.Rc.DONE
           then Ok (List.rev acc)
           else Error (sqlite_err db "list_turns_with_seq" rc)
         in
         loop [])
;;

let find_cutoff_seq_for_evicted_turns
      ~(covers_through_turn : Turn_id.t)
      ~(evicted_turns : Keeper_compaction.canonical_turn list)
      (rows : (int64 * canonical_turn) list)
  =
  let target_id = Turn_id.to_string covers_through_turn in
  (* 1. Exact canonical turn_id match against covers_through_turn or evicted turn ids. *)
  let exact_ids =
    target_id
    :: List.map
         (fun (t : Keeper_compaction.canonical_turn) -> Turn_id.to_string t.turn_id)
         evicted_turns
  in
  let exact_match =
    List.fold_left
      (fun best (seq, row) ->
         if List.exists (String.equal (Turn_id.to_string row.turn_id)) exact_ids
         then Some seq
         else best)
      None
      rows
  in
  match exact_match with
  | Some _ as hit -> hit
  | None ->
    (* 2. Order-aware sequential matching of evicted messages against canonical
       turns so repeated autonomous prompts/replies never over-advance cutoff_seq. *)
    let evicted_messages =
      List.concat_map (fun (t : Keeper_compaction.canonical_turn) -> t.messages) evicted_turns
    in
    let indexed = index_messages evicted_messages in
    let _, best_seq =
      List.fold_left
        (fun (cursor, best) (seq, row) ->
           match match_turn_from indexed ~cursor row with
           | Some next_cursor -> next_cursor, Some seq
           | None -> cursor, best)
        (0, None)
        rows
    in
    best_seq
;;

let record_compaction_watermark
      ~keepers_dir
      ~keeper_id
      ~(anchor : Keeper_compaction.compaction_anchor)
      ~(evicted_turns : Keeper_compaction.canonical_turn list)
  =
  let path = db_path ~keepers_dir ~keeper_id in
  Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
    if not (Sys.file_exists path)
    then Ok None
    else (
      match Sqlite3.db_open path with
      | exception (Sqlite3.Error detail | Sqlite3.SqliteError detail) ->
        Error (Sqlite_error { operation = "record_compaction_watermark.db_open"; detail })
      | db ->
        Fun.protect
          ~finally:(fun () ->
            try ignore (Sqlite3.db_close db : bool) with
            | Sqlite3.Error _ | Sqlite3.SqliteError _ -> ())
          (fun () ->
             let* () = init_schema db in
             let* cutoff_opt, pruned =
               with_transaction db ~begin_sql:"BEGIN IMMEDIATE;" (fun () ->
                 let* reset_after_seq, (_ : int) = lookup_history_reset_in_tx db in
                 let* prior_cutoff =
                   lookup_prior_watermark_cutoff_seq_in_tx
                     db
                     ~before_epoch_id:anchor.epoch_id
                 in
                 let floor_seq =
                   Int64.max reset_after_seq (Option.value ~default:0L prior_cutoff)
                 in
                 let* all_rows = list_turns_with_seq_in_tx db in
                 let rows = List.filter (fun (seq, _) -> seq > floor_seq) all_rows in
                 match
                   find_cutoff_seq_for_evicted_turns
                     ~covers_through_turn:anchor.covers_through_turn
                     ~evicted_turns
                     rows
                 with
                 | None -> Ok (None, false)
                 | Some raw_cutoff_seq ->
                   let cutoff_seq = Int64.max floor_seq raw_cutoff_seq in
                   let last_turn_id_data =
                     match
                       List.find_opt (fun (seq, _) -> Int64.equal seq cutoff_seq) rows
                     with
                     | Some (_, row) -> Sqlite3.Data.TEXT (Turn_id.to_string row.turn_id)
                     | None -> Sqlite3.Data.NULL
                   in
                   let* () =
                     with_stmt
                       db
                       "upsert_compaction_watermark"
                       "INSERT INTO compaction_watermarks \
                        (epoch_id, covers_through_turn, cutoff_seq, recorded_at, last_turn_id) \
                        VALUES (?1, ?2, ?3, ?4, ?5) \
                        ON CONFLICT(epoch_id) DO UPDATE SET \
                          covers_through_turn = excluded.covers_through_turn, \
                          cutoff_seq = MAX(compaction_watermarks.cutoff_seq, excluded.cutoff_seq), \
                          recorded_at = excluded.recorded_at, \
                          last_turn_id = COALESCE(excluded.last_turn_id, compaction_watermarks.last_turn_id)"
                       (fun stmt ->
                          let* () =
                            bind_values
                              db
                              "bind_compaction_watermark"
                              stmt
                              [ Sqlite3.Data.INT (Int64.of_int anchor.epoch_id)
                              ; Sqlite3.Data.TEXT (Turn_id.to_string anchor.covers_through_turn)
                              ; Sqlite3.Data.INT cutoff_seq
                              ; Sqlite3.Data.FLOAT (Time_compat.now ())
                              ; last_turn_id_data
                              ]
                          in
                          let rc = Sqlite3.step stmt in
                          if rc = Sqlite3.Rc.DONE
                          then Ok ()
                          else Error (sqlite_err db "upsert_compaction_watermark" rc))
                   in
                   let* pruned = prune_turns_through_seq_in_tx db ~max_seq:cutoff_seq in
                   Ok (Some cutoff_seq, pruned))
             in
             run_incremental_vacuum_if_pruned db ~keeper_id pruned;
             Ok cutoff_opt)))
;;

let map_compaction_error = function
  | Keeper_compaction.Sqlite_error { operation; detail } ->
    Sqlite_error { operation = "compaction." ^ operation; detail }
  | Keeper_compaction.Corrupt_record { context; detail } ->
    Corrupt_record { context = "compaction." ^ context; detail }
  | Keeper_compaction.Capacity_exceeded _ as err ->
    Corrupt_record
      { context = "compaction.latest_anchor"
      ; detail = Keeper_compaction.store_error_to_string err
      }
;;

let record_history_reset ~keepers_dir ~keeper_id =
  let* latest_anchor =
    Keeper_compaction.latest_anchor ~keepers_dir ~keeper_id
    |> Result.map_error map_compaction_error
  in
  let latest_epoch =
    match latest_anchor with
    | Some a -> a.Keeper_compaction.epoch_id
    | None -> 0
  in
  let path = db_path ~keepers_dir ~keeper_id in
  if (not (Sys.file_exists path)) && latest_epoch = 0
  then Ok ()
  else
    let* _ =
      with_db ~create:true ~keepers_dir ~keeper_id (fun db ->
        let* pruned =
          with_transaction db ~begin_sql:"BEGIN IMMEDIATE;" (fun () ->
            let* max_seq =
              with_stmt
                db
                "select_max_seq_for_reset"
                "SELECT COALESCE(MAX(seq), 0) FROM canonical_turns"
                (fun stmt ->
                   let rc = Sqlite3.step stmt in
                   if rc = Sqlite3.Rc.ROW
                   then decode_int64_column ~context:"canonical_turns.max_seq" stmt 0
                   else if rc = Sqlite3.Rc.DONE
                   then Ok 0L
                   else Error (sqlite_err db "select_max_seq_for_reset" rc))
            in
            let* () =
              with_stmt
                db
                "upsert_history_reset"
                "INSERT INTO history_resets \
                 (id, reset_after_seq, reset_after_anchor_epoch, recorded_at) \
                 VALUES (1, ?1, ?2, ?3) \
                 ON CONFLICT(id) DO UPDATE SET \
                   reset_after_seq = MAX(history_resets.reset_after_seq, excluded.reset_after_seq), \
                   reset_after_anchor_epoch = MAX(history_resets.reset_after_anchor_epoch, excluded.reset_after_anchor_epoch), \
                   recorded_at = excluded.recorded_at"
                (fun stmt ->
                   let* () =
                     bind_values
                       db
                       "bind_history_reset"
                       stmt
                       [ Sqlite3.Data.INT max_seq
                       ; Sqlite3.Data.INT (Int64.of_int latest_epoch)
                       ; Sqlite3.Data.FLOAT (Time_compat.now ())
                       ]
                   in
                   let rc = Sqlite3.step stmt in
                   if rc = Sqlite3.Rc.DONE
                   then Ok ()
                   else Error (sqlite_err db "upsert_history_reset" rc))
            in
            prune_turns_through_seq_in_tx db ~max_seq)
        in
        run_incremental_vacuum_if_pruned db ~keeper_id pruned;
        Ok (Some ()))
    in
    Ok ()
;;

let bind_turn_ref
      ~keepers_dir
      ~keeper_id
      ~from_turn_id
      ~to_turn_id
      ~suppress_assistant_output
      ()
  =
  let from_str = Turn_id.to_string from_turn_id in
  let to_str = Turn_id.to_string to_turn_id in
  if String.equal (String.trim from_str) "" || String.equal (String.trim to_str) ""
  then
    Error
      (Corrupt_record
         { context = "bind_turn_ref"; detail = "from_turn_id and to_turn_id must be non-blank" })
  else (
    let path = db_path ~keepers_dir ~keeper_id in
    Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
      if not (Sys.file_exists path)
      then Ok ()
      else (
        match Sqlite3.db_open path with
        | exception (Sqlite3.Error detail | Sqlite3.SqliteError detail) ->
          Error (Sqlite_error { operation = "bind_turn_ref.db_open"; detail })
        | db ->
          Fun.protect
            ~finally:(fun () ->
              try ignore (Sqlite3.db_close db : bool) with
              | Sqlite3.Error _ | Sqlite3.SqliteError _ -> ())
            (fun () ->
               let* () = init_schema db in
               with_transaction db ~begin_sql:"BEGIN IMMEDIATE;" (fun () ->
                 let row_exists tid_str =
                   with_stmt
                     db
                     "check_turn_exists"
                     "SELECT 1 FROM canonical_turns WHERE turn_id = ?1 LIMIT 1"
                     (fun stmt ->
                        let* () =
                          bind_values db "bind_check_turn" stmt [ Sqlite3.Data.TEXT tid_str ]
                        in
                        let rc = Sqlite3.step stmt in
                        if rc = Sqlite3.Rc.ROW
                        then Ok true
                        else if rc = Sqlite3.Rc.DONE
                        then Ok false
                        else Error (sqlite_err db "check_turn_exists" rc))
                 in
                 let* from_present = row_exists from_str in
                 if not from_present
                 then Ok ()
                 else (
                   let suppress_flag = if suppress_assistant_output then 1L else 0L in
                   if String.equal from_str to_str
                   then
                     if not suppress_assistant_output
                     then Ok ()
                     else
                       with_stmt
                         db
                         "suppress_same_turn_output"
                         "UPDATE canonical_turns SET assistant_output = '' WHERE turn_id = ?1"
                         (fun stmt ->
                            let* () =
                              bind_values db "bind_suppress" stmt [ Sqlite3.Data.TEXT to_str ]
                            in
                            let rc = Sqlite3.step stmt in
                            if rc = Sqlite3.Rc.DONE
                            then Ok ()
                            else Error (sqlite_err db "suppress_same_turn_output" rc))
                   else (
                     let* to_present = row_exists to_str in
                     if to_present
                     then Ok ()
                     else (
                       let* () =
                         with_stmt
                           db
                           "rebind_turn_id"
                           "UPDATE canonical_turns \
                            SET turn_id = ?1, \
                                assistant_output = CASE WHEN ?2 = 1 THEN '' ELSE assistant_output END \
                            WHERE turn_id = ?3"
                           (fun stmt ->
                              let* () =
                                bind_values
                                  db
                                  "bind_rebind_turn_id"
                                  stmt
                                  [ Sqlite3.Data.TEXT to_str
                                  ; Sqlite3.Data.INT suppress_flag
                                  ; Sqlite3.Data.TEXT from_str
                                  ]
                              in
                              let rc = Sqlite3.step stmt in
                              if rc = Sqlite3.Rc.DONE
                              then Ok ()
                              else Error (sqlite_err db "rebind_turn_id" rc))
                       in
                       with_stmt
                         db
                         "rebind_child_parent_turn_id"
                         "UPDATE canonical_turns SET parent_turn_id = ?1 WHERE parent_turn_id = ?2"
                         (fun stmt ->
                            let* () =
                              bind_values
                                db
                                "bind_rebind_child"
                                stmt
                                [ Sqlite3.Data.TEXT to_str; Sqlite3.Data.TEXT from_str ]
                            in
                            let rc = Sqlite3.step stmt in
                            if rc = Sqlite3.Rc.DONE
                            then Ok ()
                            else Error (sqlite_err db "rebind_child_parent_turn_id" rc))))))))))
;;

let () =
  Keeper_compaction.set_on_canonical_epoch_committed
    (Some
       (fun ~keepers_dir ~keeper_id ~anchor ~evicted_turns ->
          match record_compaction_watermark ~keepers_dir ~keeper_id ~anchor ~evicted_turns with
          | Ok _ -> ()
          | Error err ->
            Log.Keeper.warn
              ~keeper_name:keeper_id
              "canonical turn compaction watermark update skipped: %s"
              (store_error_to_string err)))
;;

let load_handoff_context ~keepers_dir ~keeper_id =
  let* raw_anchor =
    Keeper_compaction.latest_anchor ~keepers_dir ~keeper_id
    |> Result.map_error map_compaction_error
  in
  let* db_snapshot =
    with_db ~create:false ~keepers_dir ~keeper_id (fun db ->
      with_transaction db ~begin_sql:"BEGIN DEFERRED;" (fun () ->
        let* reset_after_seq, reset_after_anchor_epoch = lookup_history_reset_in_tx db in
        let effective_anchor =
          match raw_anchor with
          | Some a when a.Keeper_compaction.epoch_id > reset_after_anchor_epoch -> Some a
          | Some _ | None -> None
        in
        let* all_rows = list_turns_with_seq_in_tx db in
        let post_reset_rows = List.filter (fun (seq, _) -> seq > reset_after_seq) all_rows in
        match effective_anchor with
        | None -> Ok (Some (None, `Resolved (List.map snd post_reset_rows)))
        | Some a ->
          let* prior_cutoff =
            lookup_prior_watermark_cutoff_seq_in_tx db ~before_epoch_id:a.epoch_id
          in
          let floor_seq =
            Int64.max reset_after_seq (Option.value ~default:0L prior_cutoff)
          in
          let rows = List.filter (fun (seq, _) -> seq > floor_seq) post_reset_rows in
          (match rows with
           | [] -> Ok (Some (Some a, `Resolved []))
           | _ :: _ ->
             let target_id = Turn_id.to_string a.covers_through_turn in
             let direct_cutoff =
               List.fold_left
                 (fun acc (seq, row) ->
                    if String.equal (Turn_id.to_string row.turn_id) target_id
                    then Some seq
                    else acc)
                 None
                 post_reset_rows
             in
             let* cutoff_opt =
               match direct_cutoff with
               | Some _ as hit -> Ok hit
               | None -> lookup_watermark_cutoff_seq_in_tx db ~epoch_id:a.epoch_id
             in
             (match cutoff_opt with
              | Some cutoff_seq ->
                let min_seq = Int64.max floor_seq cutoff_seq in
                let remaining =
                  rows
                  |> List.filter_map (fun (seq, row) -> if seq > min_seq then Some row else None)
                in
                Ok (Some (Some a, `Resolved remaining))
              | None -> Ok (Some (Some a, `Needs_archive_fallback (a, floor_seq, rows)))))))
  in
  let anchor, turns_after_anchor =
    match db_snapshot with
    | None -> raw_anchor, []
    | Some (anchor, `Resolved turns) -> anchor, turns
    | Some (anchor, `Needs_archive_fallback (a, floor_seq, rows)) ->
      let archived =
        match
          Keeper_compaction.load_archived_turns_for_epoch
            ~keepers_dir
            ~keeper_id
            ~epoch_id:a.epoch_id
        with
        | Ok turns -> turns
        | Error _ -> []
      in
      let turns =
        match
          find_cutoff_seq_for_evicted_turns
            ~covers_through_turn:a.covers_through_turn
            ~evicted_turns:archived
            rows
        with
        | Some cutoff_seq ->
          let min_seq = Int64.max floor_seq cutoff_seq in
          rows
          |> List.filter_map (fun (seq, row) -> if seq > min_seq then Some row else None)
        | None -> List.map snd rows
      in
      anchor, turns
  in
  let anchor_messages =
    match anchor with
    | None -> []
    | Some a -> [ Keeper_compaction.anchor_to_message a ]
  in
  let turn_messages = List.concat_map messages_of_canonical_turn turns_after_anchor in
  Ok { anchor; turns_after_anchor; messages = anchor_messages @ turn_messages }
;;

let hydrate_missing_turns ~keepers_dir ~keeper_id ~existing_messages =
  let* handoff = load_handoff_context ~keepers_dir ~keeper_id in
  let has_conversation_messages =
    List.exists
      (fun (m : Agent_core.Types.message) -> m.role <> Agent_core.Types.System)
      existing_messages
  in
  if not has_conversation_messages
  then Ok handoff.messages
  else (
    match handoff.turns_after_anchor with
    | [] -> Ok []
    | turns ->
      let indexed_msgs = index_messages existing_messages in
      let indexed_turns = List.mapi (fun i t -> i, t) turns in
      let _, last_present_idx =
        List.fold_left
          (fun (cursor, last_present) (i, t) ->
             match match_turn_from indexed_msgs ~cursor t with
             | Some next_cursor -> next_cursor, Some i
             | None -> cursor, last_present)
          (0, None)
          indexed_turns
      in
      let missing_turns =
        match last_present_idx with
        | Some idx ->
          indexed_turns
          |> List.filter_map (fun (i, t) -> if i > idx then Some t else None)
        | None -> turns
      in
      Ok (List.concat_map messages_of_canonical_turn missing_turns))
;;

(* --- Tool_blob_maintenance sweep-root scanner --- *)

let sqlite_companions_absent path =
  let rec check = function
    | [] -> Ok true
    | suffix :: rest ->
      (match Unix.lstat (path ^ suffix) with
       | _ -> Ok false
       | exception Unix.Unix_error (Unix.ENOENT, _, _) -> check rest
       | exception Unix.Unix_error (code, fn, arg) ->
         Error (Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message code)))
  in
  check
    [ Common.sqlite_journal_suffix
    ; Common.sqlite_wal_suffix
    ; Common.sqlite_shm_suffix
    ]
;;

let decode_live_blob_references_json path =
  Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
    match Unix.lstat path with
    | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
    | exception Unix.Unix_error (code, fn, arg) ->
      Error (Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message code))
    | { Unix.st_size = 0; _ } ->
      (match sqlite_companions_absent path with
       | Ok true -> Ok None
       | Error reason -> Error reason
       | Ok false ->
         Error "empty canonical turns database with present sqlite companions")
    | _ ->
      (match Sqlite3.db_open ~mode:`READONLY path with
       | exception (Sqlite3.Error detail | Sqlite3.SqliteError detail) ->
         Error (Printf.sprintf "canonical turns sqlite db_open failed: %s" detail)
       | db ->
         Fun.protect
           ~finally:(fun () ->
             try ignore (Sqlite3.db_close db : bool) with
             | Sqlite3.Error _ | Sqlite3.SqliteError _ -> ())
           (fun () ->
              let res =
                let* () = exec_sql db "pragma_busy_ro" "PRAGMA busy_timeout=5000;" in
                with_transaction db ~begin_sql:"BEGIN DEFERRED;" (fun () ->
                  let* present = table_exists db "canonical_turns" in
                  if not present
                  then Ok None
                  else
                    with_stmt
                      db
                      "scan_canonical_turns_blobs"
                      "SELECT tool_calls_json, usage_json FROM canonical_turns ORDER BY seq ASC"
                      (fun stmt ->
                         let rec loop acc =
                           let rc = Sqlite3.step stmt in
                           if rc = Sqlite3.Rc.ROW
                           then (
                             let* tc =
                               decode_json_column
                                 ~context:"scan.tool_calls_json"
                                 (Sqlite3.column_text stmt 0)
                             in
                             let* usage =
                               decode_json_column
                                 ~context:"scan.usage_json"
                                 (Sqlite3.column_text stmt 1)
                             in
                             loop (usage :: tc :: acc))
                           else if rc = Sqlite3.Rc.DONE
                           then Ok (Some (`List (List.rev acc)))
                           else Error (sqlite_err db "scan_canonical_turns_blobs" rc)
                         in
                         loop []))
              in
              Result.map_error store_error_to_string res)))
;;
