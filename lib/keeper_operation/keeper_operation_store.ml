type operation_state =
  | Queued
  | Running
  | Settled
  | Cancelled
  | Interrupted

type operation =
  { queue_seq : int64
  ; operation_id : Keeper_operation_id.Operation_id.t
  ; kind : Keeper_operation_request.kind
  ; source_ref : Keeper_operation_request.Canonical_json.t
  ; submitter_ref : Keeper_operation_request.Canonical_json.t
  ; state : operation_state
  ; request_digest : string
  ; input_ref : Keeper_operation_blob_store.Input_ref.t
  ; base_state_ref : Keeper_operation_blob_store.State_ref.t option
  ; outcome_ref : Keeper_operation_blob_store.Outcome_ref.t option
  ; next_state_ref : Keeper_operation_blob_store.State_ref.t option
  ; created_at : float
  ; started_at : float option
  ; finished_at : float option
  }

type error =
  | Invalid_input of string
  | Identity_conflict of Keeper_operation_id.Operation_id.t
  | State_conflict of
      { operation_id : Keeper_operation_id.Operation_id.t
      ; state : operation_state
      }
  | Store_error of string
  | Integrity_error of string

type t =
  { db : Sqlite3.db
  ; mutable closed : bool
  }

let ( let* ) = Result.bind

let state_to_string = function
  | Queued -> "queued"
  | Running -> "running"
  | Settled -> "settled"
  | Cancelled -> "cancelled"
  | Interrupted -> "interrupted"
;;

let state_of_string = function
  | "queued" -> Ok Queued
  | "running" -> Ok Running
  | "settled" -> Ok Settled
  | "cancelled" -> Ok Cancelled
  | "interrupted" -> Ok Interrupted
  | value -> Error (Integrity_error ("unknown operation state: " ^ value))
;;

let kind_of_string = function
  | "message" -> Ok Keeper_operation_request.Message
  | "stimulus" -> Ok Keeper_operation_request.Stimulus
  | "autonomous" -> Ok Keeper_operation_request.Autonomous
  | value -> Error (Integrity_error ("unknown operation kind: " ^ value))
;;

let error_to_string = function
  | Invalid_input detail -> "invalid Keeper operation input: " ^ detail
  | Identity_conflict operation_id ->
    "Keeper operation identity conflict: "
    ^ Keeper_operation_id.Operation_id.to_string operation_id
  | State_conflict { operation_id; state } ->
    Printf.sprintf
      "Keeper operation state conflict: operation_id=%s state=%s"
      (Keeper_operation_id.Operation_id.to_string operation_id)
      (state_to_string state)
  | Store_error detail -> "Keeper operation store failure: " ^ detail
  | Integrity_error detail -> "Keeper operation store integrity failure: " ^ detail
;;

let sqlite_error db operation rc =
  Printf.sprintf
    "%s: rc=%s detail=%s"
    operation
    (Sqlite3.Rc.to_string rc)
    (Sqlite3.errmsg db)
;;

let exec db ~operation sql =
  let rc = Sqlite3.exec db sql in
  if Sqlite3.Rc.is_success rc
  then Ok ()
  else Error (Store_error (sqlite_error db operation rc))
;;

let prepare db ~operation sql =
  try Ok (Sqlite3.prepare db sql) with
  | Sqlite3.Error detail -> Error (Store_error (operation ^ ": " ^ detail))
;;

let finalize db stmt result =
  let finalize_result =
    try
      let rc = Sqlite3.finalize stmt in
      if Sqlite3.Rc.is_success rc
      then Ok ()
      else Error (Store_error (sqlite_error db "finalize statement" rc))
    with
    | Sqlite3.Error detail -> Error (Store_error ("finalize statement: " ^ detail))
  in
  match result, finalize_result with
  | Ok value, Ok () -> Ok value
  | Error _ as error, Ok () -> error
  | Ok _, (Error _ as error) -> error
  | Error first, Error second ->
    Error (Store_error (error_to_string first ^ "; " ^ error_to_string second))
;;

let with_statement db ~operation sql f =
  let* stmt = prepare db ~operation sql in
  let result =
    try f stmt with
    | Sqlite3.Error detail -> Error (Store_error (operation ^ ": " ^ detail))
  in
  finalize db stmt result
;;

let bind db stmt ~operation index data =
  let rc = Sqlite3.bind stmt index data in
  if Sqlite3.Rc.is_success rc
  then Ok ()
  else Error (Store_error (sqlite_error db operation rc))
;;

let expect_done db stmt ~operation =
  let rc = Sqlite3.step stmt in
  if rc = Sqlite3.Rc.DONE
  then Ok ()
  else Error (Store_error (sqlite_error db operation rc))
;;

let single_int64 db ~operation sql =
  with_statement db ~operation sql (fun stmt ->
    let rc = Sqlite3.step stmt in
    if rc = Sqlite3.Rc.ROW
    then (
      let value = Sqlite3.column_int64 stmt 0 in
      let terminal_rc = Sqlite3.step stmt in
      if terminal_rc = Sqlite3.Rc.DONE
      then Ok value
      else Error (Store_error (sqlite_error db operation terminal_rc)))
    else Error (Store_error (sqlite_error db operation rc)))
;;

let single_text db ~operation sql =
  with_statement db ~operation sql (fun stmt ->
    let rc = Sqlite3.step stmt in
    if rc = Sqlite3.Rc.ROW
    then (
      let value = Sqlite3.column_text stmt 0 in
      let terminal_rc = Sqlite3.step stmt in
      if terminal_rc = Sqlite3.Rc.DONE
      then Ok value
      else Error (Store_error (sqlite_error db operation terminal_rc)))
    else Error (Store_error (sqlite_error db operation rc)))
;;

let database_application_id = 0x4d4b4f50L
let database_user_version = 1L
let database_file = "operations.sqlite3"

let operations_table_sql =
  "CREATE TABLE operations (queue_seq INTEGER PRIMARY KEY, operation_id TEXT UNIQUE NOT NULL CHECK (length(operation_id) = 69 AND substr(operation_id, 1, 5) = 'kop1:' AND substr(operation_id, 6) NOT GLOB '*[^0-9a-f]*'), kind TEXT NOT NULL CHECK (kind IN ('message', 'stimulus', 'autonomous')), source_ref TEXT NOT NULL CHECK (length(source_ref) > 0), submitter_ref TEXT NOT NULL CHECK (length(submitter_ref) > 0), state TEXT NOT NULL CHECK (state IN ('queued', 'running', 'settled', 'cancelled', 'interrupted')), request_digest TEXT NOT NULL CHECK (length(request_digest) = 64 AND request_digest NOT GLOB '*[^0-9a-f]*'), input_ref TEXT NOT NULL CHECK (length(input_ref) = 71 AND substr(input_ref, 1, 7) = 'sha256:' AND substr(input_ref, 8) NOT GLOB '*[^0-9a-f]*'), base_state_ref TEXT, outcome_ref TEXT, next_state_ref TEXT, created_at REAL NOT NULL CHECK (created_at >= 0), started_at REAL, finished_at REAL, CHECK (base_state_ref IS NULL OR (length(base_state_ref) = 71 AND substr(base_state_ref, 1, 7) = 'sha256:' AND substr(base_state_ref, 8) NOT GLOB '*[^0-9a-f]*')), CHECK (outcome_ref IS NULL OR (length(outcome_ref) = 71 AND substr(outcome_ref, 1, 7) = 'sha256:' AND substr(outcome_ref, 8) NOT GLOB '*[^0-9a-f]*')), CHECK (next_state_ref IS NULL OR (length(next_state_ref) = 71 AND substr(next_state_ref, 1, 7) = 'sha256:' AND substr(next_state_ref, 8) NOT GLOB '*[^0-9a-f]*')), CHECK ((state = 'queued' AND started_at IS NULL AND finished_at IS NULL AND base_state_ref IS NULL AND outcome_ref IS NULL AND next_state_ref IS NULL) OR (state = 'running' AND started_at IS NOT NULL AND finished_at IS NULL AND outcome_ref IS NULL AND next_state_ref IS NULL) OR (state = 'settled' AND started_at IS NOT NULL AND finished_at IS NOT NULL AND outcome_ref IS NOT NULL) OR (state = 'cancelled' AND started_at IS NULL AND finished_at IS NOT NULL AND base_state_ref IS NULL AND outcome_ref IS NULL AND next_state_ref IS NULL) OR (state = 'interrupted' AND started_at IS NOT NULL AND finished_at IS NOT NULL AND outcome_ref IS NOT NULL AND next_state_ref IS NULL))) STRICT"
;;

let deliveries_table_sql =
  "CREATE TABLE deliveries (delivery_seq INTEGER PRIMARY KEY, delivery_id TEXT UNIQUE NOT NULL CHECK (length(delivery_id) = 70 AND substr(delivery_id, 1, 6) = 'kdel1:' AND substr(delivery_id, 7) NOT GLOB '*[^0-9a-f]*'), operation_id TEXT NOT NULL REFERENCES operations(operation_id), destination_ref TEXT NOT NULL CHECK (length(destination_ref) > 0), state TEXT NOT NULL CHECK (state IN ('pending', 'attempting', 'delivered', 'failed', 'ambiguous')), payload_ref TEXT NOT NULL CHECK (length(payload_ref) = 71 AND substr(payload_ref, 1, 7) = 'sha256:' AND substr(payload_ref, 8) NOT GLOB '*[^0-9a-f]*'), connector_message_id TEXT, evidence_ref TEXT, created_at REAL NOT NULL CHECK (created_at >= 0), started_at REAL, finished_at REAL, CHECK (evidence_ref IS NULL OR (length(evidence_ref) = 71 AND substr(evidence_ref, 1, 7) = 'sha256:' AND substr(evidence_ref, 8) NOT GLOB '*[^0-9a-f]*')), CHECK ((state = 'pending' AND started_at IS NULL AND finished_at IS NULL AND connector_message_id IS NULL AND evidence_ref IS NULL) OR (state = 'attempting' AND started_at IS NOT NULL AND finished_at IS NULL AND connector_message_id IS NULL AND evidence_ref IS NULL) OR (state IN ('delivered', 'failed', 'ambiguous') AND started_at IS NOT NULL AND finished_at IS NOT NULL AND evidence_ref IS NOT NULL))) STRICT"
;;

let keeper_control_table_sql =
  "CREATE TABLE keeper_control (singleton INTEGER PRIMARY KEY CHECK (singleton = 1), paused INTEGER NOT NULL CHECK (paused IN (0, 1))) STRICT"
;;

let queued_index_sql =
  "CREATE INDEX operations_queued_fifo ON operations(queue_seq) WHERE state = 'queued'"
;;

let running_index_sql =
  "CREATE UNIQUE INDEX operations_single_running ON operations(state) WHERE state = 'running'"
;;

let pending_delivery_index_sql =
  "CREATE INDEX deliveries_pending_fifo ON deliveries(delivery_seq) WHERE state = 'pending'"
;;

let operations_terminal_update_trigger_sql =
  "CREATE TRIGGER operations_terminal_update_immutable BEFORE UPDATE ON operations WHEN OLD.state IN ('settled', 'cancelled', 'interrupted') BEGIN SELECT RAISE(ABORT, 'terminal operation is immutable'); END"
;;

let operations_terminal_delete_trigger_sql =
  "CREATE TRIGGER operations_terminal_delete_immutable BEFORE DELETE ON operations WHEN OLD.state IN ('settled', 'cancelled', 'interrupted') BEGIN SELECT RAISE(ABORT, 'terminal operation is immutable'); END"
;;

let deliveries_terminal_update_trigger_sql =
  "CREATE TRIGGER deliveries_terminal_update_immutable BEFORE UPDATE ON deliveries WHEN OLD.state IN ('delivered', 'failed', 'ambiguous') BEGIN SELECT RAISE(ABORT, 'terminal delivery is immutable'); END"
;;

let deliveries_terminal_delete_trigger_sql =
  "CREATE TRIGGER deliveries_terminal_delete_immutable BEFORE DELETE ON deliveries WHEN OLD.state IN ('delivered', 'failed', 'ambiguous') BEGIN SELECT RAISE(ABORT, 'terminal delivery is immutable'); END"
;;

let expected_schema_objects =
  [ "index", "deliveries_pending_fifo", pending_delivery_index_sql
  ; "index", "operations_queued_fifo", queued_index_sql
  ; "index", "operations_single_running", running_index_sql
  ; "table", "deliveries", deliveries_table_sql
  ; "table", "keeper_control", keeper_control_table_sql
  ; "table", "operations", operations_table_sql
  ; ( "trigger"
    , "deliveries_terminal_delete_immutable"
    , deliveries_terminal_delete_trigger_sql )
  ; ( "trigger"
    , "deliveries_terminal_update_immutable"
    , deliveries_terminal_update_trigger_sql )
  ; ( "trigger"
    , "operations_terminal_delete_immutable"
    , operations_terminal_delete_trigger_sql )
  ; ( "trigger"
    , "operations_terminal_update_immutable"
    , operations_terminal_update_trigger_sql )
  ]
;;

let validate_time field value =
  if Float.is_finite value && value >= 0.
  then Ok ()
  else Error (Invalid_input (field ^ " must be a finite non-negative timestamp"))
;;

let configure_connection db =
  let* mode =
    single_text db ~operation:"set DELETE journal mode" "PRAGMA journal_mode=DELETE"
  in
  let* () =
    if String.equal mode "delete"
    then Ok ()
    else Error (Store_error ("SQLite refused DELETE journal mode: " ^ mode))
  in
  let* () = exec db ~operation:"set FULL synchronous" "PRAGMA synchronous=FULL" in
  let* () = exec db ~operation:"enable foreign keys" "PRAGMA foreign_keys=ON" in
  let* synchronous =
    single_int64 db ~operation:"read synchronous mode" "PRAGMA synchronous"
  in
  let* foreign_keys =
    single_int64 db ~operation:"read foreign key mode" "PRAGMA foreign_keys"
  in
  if not (Int64.equal synchronous 2L)
  then Error (Store_error "SQLite synchronous mode is not FULL")
  else if not (Int64.equal foreign_keys 1L)
  then Error (Store_error "SQLite foreign key enforcement is disabled")
  else Ok ()
;;

let fsync_directory path =
  let fd = Unix.openfile path [ Unix.O_RDONLY ] 0 in
  match Unix.fsync fd with
  | () -> Unix.close fd
  | exception exn ->
    let backtrace = Printexc.get_raw_backtrace () in
    (try Unix.close fd with _ -> ());
    Printexc.raise_with_backtrace exn backtrace
;;

let initialize_database db path =
  let* () = exec db ~operation:"begin schema transaction" "BEGIN EXCLUSIVE" in
  let body =
    let* () = exec db ~operation:"create operations" operations_table_sql in
    let* () = exec db ~operation:"create deliveries" deliveries_table_sql in
    let* () = exec db ~operation:"create keeper control" keeper_control_table_sql in
    let* () = exec db ~operation:"create queued index" queued_index_sql in
    let* () = exec db ~operation:"create running index" running_index_sql in
    let* () =
      exec db ~operation:"create pending delivery index" pending_delivery_index_sql
    in
    let* () =
      exec
        db
        ~operation:"create terminal operation update trigger"
        operations_terminal_update_trigger_sql
    in
    let* () =
      exec
        db
        ~operation:"create terminal operation delete trigger"
        operations_terminal_delete_trigger_sql
    in
    let* () =
      exec
        db
        ~operation:"create terminal delivery update trigger"
        deliveries_terminal_update_trigger_sql
    in
    let* () =
      exec
        db
        ~operation:"create terminal delivery delete trigger"
        deliveries_terminal_delete_trigger_sql
    in
    let* () =
      exec
        db
        ~operation:"initialize keeper control"
        "INSERT INTO keeper_control(singleton, paused) VALUES (1, 0)"
    in
    let* () =
      exec
        db
        ~operation:"set application id"
        (Printf.sprintf "PRAGMA application_id=%Ld" database_application_id)
    in
    let* () =
      exec
        db
        ~operation:"set user version"
        (Printf.sprintf "PRAGMA user_version=%Ld" database_user_version)
    in
    exec db ~operation:"commit schema transaction" "COMMIT"
  in
  match body with
  | Error error ->
    ignore (exec db ~operation:"rollback schema transaction" "ROLLBACK");
    Error error
  | Ok () ->
    (try
       fsync_directory (Filename.dirname path);
       Ok ()
     with
     | Sys_error detail -> Error (Store_error detail)
     | Unix.Unix_error (code, operation, argument) ->
       Error
         (Store_error
            (Printf.sprintf
               "%s(%s): %s"
               operation
               argument
               (Unix.error_message code))))
;;

let read_schema_objects db =
  with_statement
    db
    ~operation:"read schema objects"
    "SELECT type, name, sql FROM sqlite_schema WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%' ORDER BY type, name"
    (fun stmt ->
       let rec loop acc =
         let rc = Sqlite3.step stmt in
         if rc = Sqlite3.Rc.DONE
         then Ok (List.rev acc)
         else if rc = Sqlite3.Rc.ROW
         then
           loop
             (( Sqlite3.column_text stmt 0
              , Sqlite3.column_text stmt 1
              , Sqlite3.column_text stmt 2 )
              :: acc)
         else Error (Store_error (sqlite_error db "read schema objects" rc))
       in
       loop [])
;;

let validate_database db =
  let* application_id =
    single_int64 db ~operation:"read application id" "PRAGMA application_id"
  in
  let* user_version =
    single_int64 db ~operation:"read user version" "PRAGMA user_version"
  in
  if not (Int64.equal application_id database_application_id)
  then
    Error
      (Integrity_error
         (Printf.sprintf "unsupported application_id=%Ld" application_id))
  else if not (Int64.equal user_version database_user_version)
  then
    Error
      (Integrity_error
         (Printf.sprintf "unsupported user_version=%Ld" user_version))
  else
    let* objects = read_schema_objects db in
    if objects <> expected_schema_objects
    then Error (Integrity_error "database schema does not exactly match v1")
    else
      let* control_rows =
        single_int64
          db
          ~operation:"count keeper control rows"
          "SELECT COUNT(*) FROM keeper_control"
      in
      if not (Int64.equal control_rows 1L)
      then Error (Integrity_error "keeper_control must contain exactly one row")
      else
        let* integrity =
        single_text db ~operation:"run integrity check" "PRAGMA integrity_check"
        in
        if String.equal integrity "ok"
        then Ok ()
        else Error (Integrity_error ("SQLite integrity_check: " ^ integrity))
;;

let inspect_database_path path =
  try
    let stat = Unix.lstat path in
    if stat.Unix.st_kind = Unix.S_REG
    then Ok true
    else Error (Integrity_error "operation database path is not a regular file")
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok false
  | Unix.Unix_error (code, operation, argument) ->
    Error
      (Store_error
         (Printf.sprintf "%s(%s): %s" operation argument (Unix.error_message code)))
;;

let close_db db =
  try
    if Sqlite3.db_close db
    then Ok ()
    else Error (Store_error "SQLite close reported a busy handle")
  with
  | Sqlite3.Error detail -> Error (Store_error ("SQLite close: " ^ detail))
;;

let open_or_create ~base_path ~keeper_runtime_dir =
  let path = Filename.concat keeper_runtime_dir database_file in
  try
    Fs_compat.mkdir_p keeper_runtime_dir;
    let* ownership =
      Fs_compat.inspect_owned_directory_chain
        ~ownership_root:base_path
        keeper_runtime_dir
      |> Result.map_error (fun rejection ->
        Integrity_error
          (Fs_compat.owned_directory_chain_rejection_to_string rejection))
    in
    let* () =
      match ownership with
      | Fs_compat.Owned_directory _ -> Ok ()
      | Fs_compat.Owned_directory_missing ->
        Error (Store_error "Keeper runtime directory was not created")
    in
    let* existed = inspect_database_path path in
    let db = Sqlite3.db_open ~mutex:`FULL path in
    let opened =
      if existed
      then
        let* () = validate_database db in
        let* () = configure_connection db in
        validate_database db
      else
        let* () = configure_connection db in
        let* () = initialize_database db path in
        validate_database db
    in
    (match opened with
     | Ok () -> Ok { db; closed = false }
     | Error error ->
       ignore (close_db db);
       Error error)
  with
  | Sys_error detail -> Error (Store_error detail)
  | Sqlite3.Error detail -> Error (Store_error ("SQLite open: " ^ detail))
  | Unix.Unix_error (code, operation, argument) ->
    Error
      (Store_error
         (Printf.sprintf "%s(%s): %s" operation argument (Unix.error_message code)))
;;

let ensure_open t =
  if t.closed then Error (Store_error "operation store is closed") else Ok ()
;;

let close t =
  if t.closed
  then Ok ()
  else (
    t.closed <- true;
    close_db t.db)
;;

let nullable_text stmt index =
  if Sqlite3.column_is_null stmt index then None else Some (Sqlite3.column_text stmt index)
;;

let nullable_float stmt index =
  if Sqlite3.column_is_null stmt index then None else Some (Sqlite3.column_double stmt index)
;;

let parse_canonical field bytes =
  match Keeper_operation_request.Canonical_json.of_string bytes with
  | Ok value
    when String.equal bytes (Keeper_operation_request.Canonical_json.to_bytes value) ->
    Ok value
  | Ok _ -> Error (Integrity_error (field ^ " is not canonical JSON"))
  | Error error ->
    Error
      (Integrity_error
         (field
          ^ ": "
          ^ Keeper_operation_request.Canonical_json.error_to_string error))
;;

let parse_ref field decode = function
  | None -> Ok None
  | Some value ->
    decode value
    |> Result.map Option.some
    |> Result.map_error (fun detail -> Integrity_error (field ^ ": " ^ detail))
;;

let operation_of_row stmt =
  let* operation_id =
    Keeper_operation_id.Operation_id.of_string (Sqlite3.column_text stmt 1)
    |> Result.map_error (fun detail -> Integrity_error detail)
  in
  let* kind = kind_of_string (Sqlite3.column_text stmt 2) in
  let* source_ref = parse_canonical "source_ref" (Sqlite3.column_text stmt 3) in
  let* submitter_ref = parse_canonical "submitter_ref" (Sqlite3.column_text stmt 4) in
  let* state = state_of_string (Sqlite3.column_text stmt 5) in
  let* input_ref =
    Keeper_operation_blob_store.Input_ref.of_string (Sqlite3.column_text stmt 7)
    |> Result.map_error (fun detail -> Integrity_error ("input_ref: " ^ detail))
  in
  let* base_state_ref =
    parse_ref
      "base_state_ref"
      Keeper_operation_blob_store.State_ref.of_string
      (nullable_text stmt 8)
  in
  let* outcome_ref =
    parse_ref
      "outcome_ref"
      Keeper_operation_blob_store.Outcome_ref.of_string
      (nullable_text stmt 9)
  in
  let* next_state_ref =
    parse_ref
      "next_state_ref"
      Keeper_operation_blob_store.State_ref.of_string
      (nullable_text stmt 10)
  in
  Ok
    { queue_seq = Sqlite3.column_int64 stmt 0
    ; operation_id
    ; kind
    ; source_ref
    ; submitter_ref
    ; state
    ; request_digest = Sqlite3.column_text stmt 6
    ; input_ref
    ; base_state_ref
    ; outcome_ref
    ; next_state_ref
    ; created_at = Sqlite3.column_double stmt 11
    ; started_at = nullable_float stmt 12
    ; finished_at = nullable_float stmt 13
    }
;;

let select_columns =
  "queue_seq, operation_id, kind, source_ref, submitter_ref, state, request_digest, input_ref, base_state_ref, outcome_ref, next_state_ref, created_at, started_at, finished_at"
;;

let find t operation_id =
  let* () = ensure_open t in
  with_statement
    t.db
    ~operation:"find operation"
    ("SELECT " ^ select_columns ^ " FROM operations WHERE operation_id = ?")
    (fun stmt ->
       let* () =
         bind
           t.db
           stmt
           ~operation:"bind operation id"
           1
           (Sqlite3.Data.TEXT (Keeper_operation_id.Operation_id.to_string operation_id))
       in
       let rc = Sqlite3.step stmt in
       if rc = Sqlite3.Rc.DONE
       then Ok None
       else if rc = Sqlite3.Rc.ROW
       then
         let* operation = operation_of_row stmt in
         let terminal_rc = Sqlite3.step stmt in
         if terminal_rc = Sqlite3.Rc.DONE
         then Ok (Some operation)
         else Error (Store_error (sqlite_error t.db "find operation" terminal_rc))
       else Error (Store_error (sqlite_error t.db "find operation" rc)))
;;

let begin_immediate t = exec t.db ~operation:"begin operation transaction" "BEGIN IMMEDIATE"
let rollback t = exec t.db ~operation:"rollback operation transaction" "ROLLBACK"
let commit t = exec t.db ~operation:"commit operation transaction" "COMMIT"

type admission =
  | Accepted of operation
  | Replayed of operation

let exact_request_row request input_ref row =
  String.equal row.request_digest (Keeper_operation_request.request_digest request)
  && Keeper_operation_blob_store.Input_ref.equal row.input_ref input_ref
  && row.kind = Keeper_operation_request.kind request
;;

let insert_queued t ~now ~request ~input_ref =
  let* source_ref =
    Keeper_operation_request.Source_ref.to_canonical_json
      (Keeper_operation_request.source_ref request)
    |> Result.map_error (fun detail -> Invalid_input detail)
  in
  let* submitter_ref =
    Keeper_operation_request.Submitter_ref.to_canonical_json
      (Keeper_operation_request.submitter_ref request)
    |> Result.map_error (fun detail -> Invalid_input detail)
  in
  with_statement
    t.db
    ~operation:"insert queued operation"
    "INSERT INTO operations(operation_id, kind, source_ref, submitter_ref, state, request_digest, input_ref, created_at) VALUES (?, ?, ?, ?, 'queued', ?, ?, ?)"
    (fun stmt ->
       let values =
         [ Sqlite3.Data.TEXT
             (Keeper_operation_id.Operation_id.to_string
                (Keeper_operation_request.operation_id request))
         ; Sqlite3.Data.TEXT
             (Keeper_operation_request.kind_to_string
                (Keeper_operation_request.kind request))
         ; Sqlite3.Data.TEXT
             (Keeper_operation_request.Canonical_json.to_bytes source_ref)
         ; Sqlite3.Data.TEXT
             (Keeper_operation_request.Canonical_json.to_bytes submitter_ref)
         ; Sqlite3.Data.TEXT (Keeper_operation_request.request_digest request)
         ; Sqlite3.Data.TEXT (Keeper_operation_blob_store.Input_ref.to_string input_ref)
         ; Sqlite3.Data.FLOAT now
         ]
       in
       let rec bind_all index = function
         | [] -> expect_done t.db stmt ~operation:"insert queued operation"
         | value :: rest ->
           let* () = bind t.db stmt ~operation:"bind queued operation" index value in
           bind_all (index + 1) rest
       in
       bind_all 1 values)
;;

let admit t ~now ~request ~input_ref =
  let* () = ensure_open t in
  let* () = validate_time "created_at" now in
  let operation_id = Keeper_operation_request.operation_id request in
  let* () = begin_immediate t in
  match find t operation_id with
  | Error error ->
    ignore (rollback t);
    Error error
  | Ok (Some existing) ->
    ignore (rollback t);
    if exact_request_row request input_ref existing
    then Ok (Replayed existing)
    else Error (Identity_conflict operation_id)
  | Ok None ->
    (match insert_queued t ~now ~request ~input_ref with
     | Error error ->
       ignore (rollback t);
       Error error
     | Ok () ->
       (match commit t with
        | Error commit_error ->
          ignore (rollback t);
          (match find t operation_id with
           | Ok (Some row) when exact_request_row request input_ref row ->
             Ok (Accepted row)
           | Ok _ | Error _ -> Error commit_error)
        | Ok () ->
          (match find t operation_id with
           | Ok (Some row) -> Ok (Accepted row)
           | Ok None -> Error (Integrity_error "accepted operation disappeared")
           | Error _ as error -> error)))
;;

let running_count t =
  single_int64
    t.db
    ~operation:"count running operations"
    "SELECT COUNT(*) FROM operations WHERE state = 'running'"
;;

let first_queued_id t =
  with_statement
    t.db
    ~operation:"select FIFO queued operation"
    "SELECT operation_id FROM operations WHERE state = 'queued' ORDER BY queue_seq LIMIT 1"
    (fun stmt ->
       let rc = Sqlite3.step stmt in
       if rc = Sqlite3.Rc.DONE
       then Ok None
       else if rc = Sqlite3.Rc.ROW
       then
         let value = Sqlite3.column_text stmt 0 in
         let* operation_id =
           Keeper_operation_id.Operation_id.of_string value
           |> Result.map_error (fun detail -> Integrity_error detail)
         in
         let terminal_rc = Sqlite3.step stmt in
         if terminal_rc = Sqlite3.Rc.DONE
         then Ok (Some operation_id)
         else
           Error
             (Store_error
                (sqlite_error t.db "select queued operation" terminal_rc))
       else Error (Store_error (sqlite_error t.db "select queued operation" rc)))
;;

let start_next t ~now ~base_state_ref =
  let* () = ensure_open t in
  let* () = validate_time "started_at" now in
  let* () = begin_immediate t in
  let body =
    let* running = running_count t in
    if not (Int64.equal running 0L)
    then Ok None
    else
      let* next = first_queued_id t in
      match next with
      | None -> Ok None
      | Some operation_id ->
        with_statement
          t.db
          ~operation:"start queued operation"
          "UPDATE operations SET state = 'running', base_state_ref = ?, started_at = ? WHERE operation_id = ? AND state = 'queued'"
          (fun stmt ->
             let base =
               match base_state_ref with
               | None -> Sqlite3.Data.NULL
               | Some reference ->
                 Sqlite3.Data.TEXT
                   (Keeper_operation_blob_store.State_ref.to_string reference)
             in
             let* () = bind t.db stmt ~operation:"bind base state" 1 base in
             let* () =
               bind t.db stmt ~operation:"bind started_at" 2 (Sqlite3.Data.FLOAT now)
             in
             let* () =
               bind
                 t.db
                 stmt
                 ~operation:"bind operation id"
                 3
                 (Sqlite3.Data.TEXT
                    (Keeper_operation_id.Operation_id.to_string operation_id))
             in
             let* () = expect_done t.db stmt ~operation:"start queued operation" in
             if Sqlite3.changes t.db = 1
             then Ok (Some operation_id)
             else Error (Integrity_error "FIFO queued operation changed before start"))
  in
  match body with
  | Error error ->
    ignore (rollback t);
    Error error
  | Ok None ->
    let* () = commit t in
    Ok None
  | Ok (Some operation_id) ->
    let* () = commit t in
    find t operation_id
;;

let update_terminal t ~operation_id ~from_state ~to_state ~now ~outcome_ref ~next_state_ref =
  with_statement
    t.db
    ~operation:"update terminal operation"
    "UPDATE operations SET state = ?, outcome_ref = ?, next_state_ref = ?, finished_at = ? WHERE operation_id = ? AND state = ?"
    (fun stmt ->
       let* () =
         bind
           t.db
           stmt
           ~operation:"bind terminal state"
           1
           (Sqlite3.Data.TEXT (state_to_string to_state))
       in
       let* () =
         bind
           t.db
           stmt
           ~operation:"bind outcome ref"
           2
           (match outcome_ref with
            | None -> Sqlite3.Data.NULL
            | Some reference ->
              Sqlite3.Data.TEXT
                (Keeper_operation_blob_store.Outcome_ref.to_string reference))
       in
       let* () =
         bind
           t.db
           stmt
           ~operation:"bind next state ref"
           3
           (match next_state_ref with
            | None -> Sqlite3.Data.NULL
            | Some reference ->
              Sqlite3.Data.TEXT
                (Keeper_operation_blob_store.State_ref.to_string reference))
       in
       let* () =
         bind t.db stmt ~operation:"bind finished_at" 4 (Sqlite3.Data.FLOAT now)
       in
       let* () =
         bind
           t.db
           stmt
           ~operation:"bind operation id"
           5
           (Sqlite3.Data.TEXT
              (Keeper_operation_id.Operation_id.to_string operation_id))
       in
       let* () =
         bind
           t.db
           stmt
           ~operation:"bind prior state"
           6
           (Sqlite3.Data.TEXT (state_to_string from_state))
       in
       let* () = expect_done t.db stmt ~operation:"update terminal operation" in
       if Sqlite3.changes t.db = 1
       then Ok ()
       else Error (Integrity_error "terminal operation compare-and-update failed"))
;;

let cancel_queued t ~now operation_id =
  let* () = ensure_open t in
  let* () = validate_time "finished_at" now in
  let* existing = find t operation_id in
  match existing with
  | None -> Error (Invalid_input "operation does not exist")
  | Some ({ state = Cancelled; _ } as operation) -> Ok operation
  | Some { state = Queued; _ } ->
    let* () = begin_immediate t in
    (match
       update_terminal
         t
         ~operation_id
         ~from_state:Queued
         ~to_state:Cancelled
         ~now
         ~outcome_ref:None
         ~next_state_ref:None
     with
     | Error error ->
       ignore (rollback t);
       Error error
     | Ok () ->
       let* () = commit t in
       (match find t operation_id with
        | Ok (Some operation) -> Ok operation
        | Ok None -> Error (Integrity_error "cancelled operation disappeared")
        | Error _ as error -> error))
  | Some ({ state = (Running | Settled | Interrupted); _ } as operation) ->
    Error (State_conflict { operation_id; state = operation.state })
;;

let finish_running t ~now ~operation_id ~target_state ~outcome_ref ~next_state_ref =
  let* () = ensure_open t in
  let* () = validate_time "finished_at" now in
  let* existing = find t operation_id in
  match existing with
  | None -> Error (Invalid_input "operation does not exist")
  | Some operation ->
    if operation.state = target_state
    then
      let same_outcome =
        Option.exists
          (Keeper_operation_blob_store.Outcome_ref.equal outcome_ref)
          operation.outcome_ref
      in
      let same_next =
        match next_state_ref, operation.next_state_ref with
        | None, None -> true
        | Some left, Some right ->
          Keeper_operation_blob_store.State_ref.equal left right
        | None, Some _ | Some _, None -> false
      in
      if same_outcome && same_next
      then Ok operation
      else Error (State_conflict { operation_id; state = operation.state })
    else
      match operation.state with
      | Running ->
        let* () = begin_immediate t in
        (match
           update_terminal
             t
             ~operation_id
             ~from_state:Running
             ~to_state:target_state
             ~now
             ~outcome_ref:(Some outcome_ref)
             ~next_state_ref
         with
         | Error error ->
           ignore (rollback t);
           Error error
         | Ok () ->
           let* () = commit t in
           (match find t operation_id with
            | Ok (Some terminal) -> Ok terminal
            | Ok None -> Error (Integrity_error "terminal operation disappeared")
            | Error _ as error -> error))
      | Queued | Settled | Cancelled | Interrupted ->
        Error (State_conflict { operation_id; state = operation.state })
;;

let interrupt_running t ~now ~operation_id ~evidence_ref =
  finish_running
    t
    ~now
    ~operation_id
    ~target_state:Interrupted
    ~outcome_ref:evidence_ref
    ~next_state_ref:None
;;

let settle t ~now ~operation_id ~outcome_ref ~next_state_ref =
  finish_running
    t
    ~now
    ~operation_id
    ~target_state:Settled
    ~outcome_ref
    ~next_state_ref
;;

let set_paused t value =
  let* () = ensure_open t in
  let* () =
    with_statement
      t.db
      ~operation:"set paused"
      "UPDATE keeper_control SET paused = ? WHERE singleton = 1"
      (fun stmt ->
         let* () =
           bind
             t.db
             stmt
             ~operation:"bind paused"
             1
             (Sqlite3.Data.INT (if value then 1L else 0L))
         in
         expect_done t.db stmt ~operation:"set paused")
  in
  if Sqlite3.changes t.db = 1 || Sqlite3.changes t.db = 0
  then Ok ()
  else Error (Integrity_error "keeper_control contains an invalid row count")
;;

let paused t =
  let* () = ensure_open t in
  let* value =
    single_int64
      t.db
      ~operation:"read paused"
      "SELECT paused FROM keeper_control WHERE singleton = 1"
  in
  if Int64.equal value 0L
  then Ok false
  else if Int64.equal value 1L
  then Ok true
  else Error (Integrity_error "keeper_control.paused is outside its domain")
;;

let count_operations t =
  let* () = ensure_open t in
  single_int64 t.db ~operation:"count operations" "SELECT COUNT(*) FROM operations"
;;
