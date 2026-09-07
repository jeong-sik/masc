module Operation = Keeper_chat_operation
module Reducer = Keeper_chat_operation_reducer
module Id = Operation.Operation_id
module Semantic = Keeper_semantic_execution

let scope_key id = Yojson.Safe.to_string (Keeper_execution_scope_id.to_json id)

type t =
  { db : Sqlite3.db
  ; path : string
  (* [close] used to test this and then set it. Two closers could both see
     [false] and both call [Sqlite3.db_close] on the same handle. As an
     [Atomic] the test and the set are one step, so exactly one caller
     reaches the close. *)
  ; closed : bool Atomic.t
  }

type error =
  | Invalid_input of string
  | Unknown_operation of Id.t
  | Not_queued of Id.t
  | Not_running of Id.t
  | Idempotency_conflict of Id.t
  | Store_unavailable of string
  | Integrity_error of string

type admission =
  | Accepted of Operation.t
  | Existing of Operation.t

type inventory =
  { queued_count : int
  ; running_operation_id : Id.t option
  ; terminal_count : int
  ; interrupted_count : int
  }

let database_file = "chat-operations.sqlite3"

let path_for_keeper ~keepers_runtime_dir ~keeper_name =
  Filename.concat (Filename.concat keepers_runtime_dir keeper_name) database_file
;;

type outstanding_snapshot =
  | Missing_store
  | Stored_operations of { chat_operations : Operation.t list; semantic_executions : Semantic.t list }
let database_schema = "masc.keeper_chat_operations.v2"
let database_application_id = 0x4d4b4f50L
let database_user_version = 2L

let legacy_metadata_table_sql =
  "CREATE TABLE metadata (singleton INTEGER PRIMARY KEY CHECK (singleton = 1), schema TEXT NOT NULL CHECK (schema = 'masc.keeper_chat_operations.v1'), next_sequence INTEGER NOT NULL CHECK (next_sequence >= 0)) STRICT"
;;

let metadata_table_sql =
  "CREATE TABLE metadata (singleton INTEGER PRIMARY KEY CHECK (singleton = 1), schema TEXT NOT NULL CHECK (schema = 'masc.keeper_chat_operations.v2'), next_sequence INTEGER NOT NULL CHECK (next_sequence >= 0)) STRICT"
;;

let semantic_table_sql =
  "CREATE TABLE semantic_executions (scope_key TEXT PRIMARY KEY, revision INTEGER NOT NULL CHECK (revision >= 0), phase TEXT NOT NULL CHECK (phase IN ('preparing', 'ready', 'running', 'suspended', 'recovering', 'settled')), record_json TEXT NOT NULL) STRICT"
;;
let semantic_running_index_sql =
  "CREATE UNIQUE INDEX semantic_single_running ON semantic_executions(phase) WHERE phase = 'running'"
;;
let semantic_terminal_update_sql =
  "CREATE TRIGGER semantic_terminal_update_immutable BEFORE UPDATE ON semantic_executions WHEN OLD.phase = 'settled' BEGIN SELECT RAISE(ABORT, 'terminal semantic execution is immutable'); END"
;;
let semantic_terminal_delete_sql =
  "CREATE TRIGGER semantic_terminal_delete_immutable BEFORE DELETE ON semantic_executions WHEN OLD.phase = 'settled' BEGIN SELECT RAISE(ABORT, 'terminal semantic execution is immutable'); END"
;;
let semantic_schema_objects =
  [ "index", "semantic_single_running", semantic_running_index_sql
  ; "table", "semantic_executions", semantic_table_sql
  ; "trigger", "semantic_terminal_delete_immutable", semantic_terminal_delete_sql
  ; "trigger", "semantic_terminal_update_immutable", semantic_terminal_update_sql ]
;;

let failure_kind_database_values =
  Operation.all_failure_kinds
  |> List.map (fun kind -> "'" ^ Operation.failure_kind_to_string kind ^ "'")
  |> String.concat ", "
;;

let operations_table_sql =
  Printf.sprintf
    "CREATE TABLE operations (operation_id TEXT PRIMARY KEY, admission_digest TEXT NOT NULL CHECK (length(admission_digest) = 64), execution_digest TEXT NOT NULL CHECK (length(execution_digest) = 64), sequence INTEGER NOT NULL UNIQUE CHECK (sequence >= 0), source_json TEXT NOT NULL, input_json TEXT, state TEXT NOT NULL CHECK (state IN ('queued', 'running', 'succeeded', 'failed', 'cancelled')), created_at REAL NOT NULL CHECK (created_at >= 0), started_at REAL, completed_at REAL, outcome_ref TEXT, failure_kind TEXT CHECK (failure_kind IS NULL OR failure_kind IN (%s)), failure_detail TEXT, CHECK ((state = 'queued' AND input_json IS NOT NULL AND started_at IS NULL AND completed_at IS NULL AND outcome_ref IS NULL AND failure_kind IS NULL AND failure_detail IS NULL) OR (state = 'running' AND input_json IS NOT NULL AND started_at IS NOT NULL AND completed_at IS NULL AND outcome_ref IS NULL AND failure_kind IS NULL AND failure_detail IS NULL) OR (state = 'succeeded' AND input_json IS NULL AND started_at IS NOT NULL AND completed_at IS NOT NULL AND outcome_ref IS NOT NULL AND failure_kind IS NULL AND failure_detail IS NULL) OR (state = 'failed' AND input_json IS NULL AND started_at IS NOT NULL AND completed_at IS NOT NULL AND failure_kind IS NOT NULL AND failure_detail IS NOT NULL) OR (state = 'cancelled' AND input_json IS NULL AND started_at IS NULL AND completed_at IS NOT NULL AND outcome_ref IS NULL AND failure_kind IS NULL AND failure_detail IS NULL))) STRICT"
    failure_kind_database_values
;;

let operations_state_sequence_index_sql =
  "CREATE INDEX operations_state_sequence ON operations(state, sequence)"
;;

let operations_single_running_index_sql =
  "CREATE UNIQUE INDEX operations_single_running ON operations(state) WHERE state = 'running'"
;;

let terminal_update_trigger_sql =
  "CREATE TRIGGER operations_terminal_update_immutable BEFORE UPDATE ON operations WHEN OLD.state IN ('succeeded', 'failed', 'cancelled') BEGIN SELECT RAISE(ABORT, 'terminal operation is immutable'); END"
;;

let terminal_delete_trigger_sql =
  "CREATE TRIGGER operations_terminal_delete_immutable BEFORE DELETE ON operations WHEN OLD.state IN ('succeeded', 'failed', 'cancelled') BEGIN SELECT RAISE(ABORT, 'terminal operation is immutable'); END"
;;

let legacy_schema_objects =
  [ "index", "operations_single_running", operations_single_running_index_sql
  ; "index", "operations_state_sequence", operations_state_sequence_index_sql
  ; "table", "metadata", legacy_metadata_table_sql
  ; "table", "operations", operations_table_sql
  ; "trigger", "operations_terminal_delete_immutable", terminal_delete_trigger_sql
  ; "trigger", "operations_terminal_update_immutable", terminal_update_trigger_sql
  ]
;;

let expected_schema_objects =
  (List.map (fun (kind, name, sql) ->
     kind, name, (if name = "metadata" then metadata_table_sql else sql)) legacy_schema_objects
   @ semantic_schema_objects)
  |> List.sort (fun (left_kind, left_name, _) (right_kind, right_name, _) ->
       compare (left_kind, left_name) (right_kind, right_name))
;;
let table_column_counts = [ "metadata", 3; "operations", 13; "semantic_executions", 4 ]

type commit_fault =
  | Fail_before_commit
  | Fail_after_commit

let next_commit_fault : commit_fault option Atomic.t = Atomic.make None

let error_to_string = function
  | Invalid_input detail -> "invalid Keeper chat operation: " ^ detail
  | Unknown_operation operation_id ->
    "unknown Keeper chat operation: " ^ Id.to_string operation_id
  | Not_queued operation_id ->
    "Keeper chat operation is not queued: " ^ Id.to_string operation_id
  | Not_running operation_id ->
    "Keeper chat operation is not running: " ^ Id.to_string operation_id
  | Idempotency_conflict operation_id ->
    "Keeper chat operation idempotency conflict: " ^ Id.to_string operation_id
  | Store_unavailable detail -> "Keeper chat operation store unavailable: " ^ detail
  | Integrity_error detail -> "Keeper chat operation store integrity error: " ^ detail
;;

let path store = store.path

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
  else Error (Store_unavailable (sqlite_error db operation rc))
;;

let close_db db =
  let closed = Sqlite3.db_close db in
  (* [caml_sqlite3_close] has the same runtime-release/null-after-return
     lifetime window as statement finalization. *)
  ignore (Sys.opaque_identity db);
  closed
;;

let prepare db ~operation sql =
  try Ok (Sqlite3.prepare db sql) with
  | Sqlite3.Error detail -> Error (Store_unavailable (operation ^ ": " ^ detail))
;;

let finalize db stmt result =
  let cleanup =
    try
      let rc = Sqlite3.finalize stmt in
      if Sqlite3.Rc.is_success rc
      then Ok ()
      else Error (Store_unavailable (sqlite_error db "finalize statement" rc))
    with
    | Sqlite3.Error detail ->
      Error (Store_unavailable ("finalize statement: " ^ detail))
  in
  (* sqlite3-ocaml 5.4.1 releases the OCaml runtime while
     [sqlite3_finalize] runs, then clears the statement pointer only after it
     reacquires the runtime.  Without a use after [Sqlite3.finalize], another
     domain can collect the wrapper in that window and its GC finalizer calls
     [sqlite3_finalize] on the same pointer.  Keep the wrapper reachable until
     the explicit finalize has fully returned. *)
  ignore (Sys.opaque_identity stmt);
  match result, cleanup with
  | Ok value, Ok () -> Ok value
  | Error _ as error, Ok () -> error
  | Ok _, (Error _ as error) -> error
  | Error first, Error second ->
    Error (Store_unavailable (error_to_string first ^ "; " ^ error_to_string second))
;;

let with_statement db ~operation sql f =
  match prepare db ~operation sql with
  | Error _ as error -> error
  | Ok stmt ->
    let result =
      try f stmt with
      | Sqlite3.Error detail -> Error (Store_unavailable (operation ^ ": " ^ detail))
    in
    finalize db stmt result
;;

let bind db stmt ~operation index data =
  let rc = Sqlite3.bind stmt index data in
  if Sqlite3.Rc.is_success rc
  then Ok ()
  else Error (Store_unavailable (sqlite_error db operation rc))
;;

let expect_done db stmt ~operation =
  let rc = Sqlite3.step stmt in
  if rc = Sqlite3.Rc.DONE
  then Ok ()
  else Error (Store_unavailable (sqlite_error db operation rc))
;;

let ( let* ) = Result.bind

let bind_text db stmt ~operation index value =
  bind db stmt ~operation index (Sqlite3.Data.TEXT value)
;;

let bind_int64 db stmt ~operation index value =
  bind db stmt ~operation index (Sqlite3.Data.INT value)
;;

let bind_float db stmt ~operation index value =
  bind db stmt ~operation index (Sqlite3.Data.FLOAT value)
;;

let bind_optional_text db stmt ~operation index = function
  | None -> bind db stmt ~operation index Sqlite3.Data.NULL
  | Some value -> bind_text db stmt ~operation index value
;;

let single_int64 db ~operation sql =
  with_statement db ~operation sql (fun stmt ->
    let rc = Sqlite3.step stmt in
    if rc <> Sqlite3.Rc.ROW
    then Error (Store_unavailable (sqlite_error db operation rc))
    else
      let value = Sqlite3.column_int64 stmt 0 in
      let rc = Sqlite3.step stmt in
      if rc = Sqlite3.Rc.DONE
      then Ok value
      else Error (Store_unavailable (sqlite_error db (operation ^ " completion") rc)))
;;

let single_text db ~operation sql =
  with_statement db ~operation sql (fun stmt ->
    let rc = Sqlite3.step stmt in
    if rc <> Sqlite3.Rc.ROW
    then Error (Store_unavailable (sqlite_error db operation rc))
    else
      let value = Sqlite3.column_text stmt 0 in
      let rc = Sqlite3.step stmt in
      if rc = Sqlite3.Rc.DONE
      then Ok value
      else Error (Store_unavailable (sqlite_error db (operation ^ " completion") rc)))
;;

let ensure_open store =
  if Atomic.get store.closed
  then Error (Store_unavailable "database handle is closed")
  else Ok ()
;;

let rollback db = ignore (Sqlite3.exec db "ROLLBACK" : Sqlite3.Rc.t)

let commit db =
  match Atomic.exchange next_commit_fault None with
  | None -> exec db ~operation:"commit operation transaction" "COMMIT"
  | Some Fail_before_commit ->
    Error (Store_unavailable "injected failure before operation commit")
  | Some Fail_after_commit ->
    let* () = exec db ~operation:"commit operation transaction" "COMMIT" in
    Error (Store_unavailable "injected uncertain operation commit")
;;

let with_transaction store f =
  let* () = ensure_open store in
  let* () = exec store.db ~operation:"begin operation transaction" "BEGIN IMMEDIATE" in
  match f () with
  | Error _ as error -> rollback store.db; error
  | Ok value ->
    (match commit store.db with
     | Ok () -> Ok value
     | Error _ as error -> rollback store.db; error)
;;

let canonical_json field value =
  Operation.canonical_json_string value
  |> Result.map_error (fun detail -> Invalid_input (field ^ ": " ^ detail))
;;

let validate_digest field value =
  let rec lowercase_hex index =
    if index = String.length value
    then true
    else
      match value.[index] with
      | '0' .. '9' | 'a' .. 'f' -> lowercase_hex (index + 1)
      | _ -> false
  in
  if String.length value = 64 && lowercase_hex 0
  then Ok value
  else Error (Integrity_error (field ^ " is not lowercase SHA-256 hex"))
;;

let json_of_stored field stored =
  try
    let parsed = Yojson.Safe.from_string stored in
    match Operation.canonical_json_string parsed with
    | Error detail -> Error (Integrity_error (field ^ ": " ^ detail))
    | Ok canonical when String.equal canonical stored -> Ok parsed
    | Ok _ -> Error (Integrity_error (field ^ " is not canonical JSON"))
  with
  | Yojson.Json_error detail -> Error (Integrity_error (field ^ ": " ^ detail))
;;

let text_option stmt index =
  match Sqlite3.column stmt index with
  | Sqlite3.Data.NULL -> None
  | Sqlite3.Data.TEXT value -> Some value
  | NONE | INT _ | FLOAT _ | BLOB _ -> None
;;

let float_option stmt index =
  match Sqlite3.column stmt index with
  | Sqlite3.Data.NULL -> None
  | Sqlite3.Data.FLOAT value -> Some value
  | Sqlite3.Data.INT value -> Some (Int64.to_float value)
  | NONE | TEXT _ | BLOB _ -> None
;;

let required_option field = function
  | Some value -> Ok value
  | None -> Error (Integrity_error (field ^ " is missing"))
;;

let decode_operation stmt =
  let* operation_id =
    Id.of_string (Sqlite3.column_text stmt 0)
    |> Result.map_error (fun detail -> Integrity_error detail)
  in
  let* admission_digest =
    validate_digest "admission_digest" (Sqlite3.column_text stmt 1)
  in
  let* execution_digest =
    validate_digest "execution_digest" (Sqlite3.column_text stmt 2)
  in
  let sequence = Sqlite3.column_int64 stmt 3 in
  if Int64.compare sequence 0L < 0
  then Error (Integrity_error "sequence is negative")
  else
    let* source = json_of_stored "source_json" (Sqlite3.column_text stmt 4) in
    let* input =
      match text_option stmt 5 with
      | None -> Ok None
      | Some stored -> json_of_stored "input_json" stored |> Result.map Option.some
    in
    let* () = match input with
      | None -> Ok ()
      | Some input ->
          let* actual = Operation.execution_digest input
            |> Result.map_error (fun detail -> Integrity_error detail) in
          if String.equal actual execution_digest then Ok ()
          else Error (Integrity_error "input_json does not match execution_digest")
    in
    let state_name = Sqlite3.column_text stmt 6 in
    let created_at = Sqlite3.column_double stmt 7 in
    let started_at = float_option stmt 8 in
    let completed_at = float_option stmt 9 in
    let outcome_ref = text_option stmt 10 in
    let failure_kind = text_option stmt 11 in
    let failure_detail = text_option stmt 12 in
    let* () =
      Operation.validate_timestamp ~field:"created_at" created_at
      |> Result.map_error (fun detail -> Integrity_error detail)
    in
    let* () = List.fold_left (fun result (field, value) ->
      let* () = result in
      match value with
      | None -> Ok ()
      | Some value -> Operation.validate_timestamp ~field value
          |> Result.map_error (fun detail -> Integrity_error detail))
      (Ok ()) ["started_at", started_at; "completed_at", completed_at] in
    let* state =
      match state_name with
      | "queued" -> Ok Operation.Queued
      | "running" ->
        let* started_at = required_option "started_at" started_at in
        Ok (Operation.Running { started_at })
      | "succeeded" ->
        let* completed_at = required_option "completed_at" completed_at in
        let* outcome_ref = required_option "outcome_ref" outcome_ref in
        Ok (Operation.Succeeded { completed_at; outcome_ref })
      | "failed" ->
        let* completed_at = required_option "completed_at" completed_at in
        let* kind = required_option "failure_kind" failure_kind in
        let* kind =
          Operation.failure_kind_of_string kind
          |> Result.map_error (fun detail -> Integrity_error detail)
        in
        let* detail = required_option "failure_detail" failure_detail in
        Ok
          (Operation.Failed
             { completed_at
             ; failure = { kind; detail; outcome_ref }
             })
      | "cancelled" ->
        let* completed_at = required_option "completed_at" completed_at in
        Ok (Operation.Cancelled { completed_at })
      | value -> Error (Integrity_error (Printf.sprintf "unknown state %S" value))
    in
    Ok
      { Operation.operation_id
      ; admission_digest
      ; execution_digest
      ; sequence
      ; source
      ; input
      ; state
      ; created_at
      }
;;

let select_columns =
  "operation_id, admission_digest, execution_digest, sequence, source_json, input_json, state, created_at, started_at, completed_at, outcome_ref, failure_kind, failure_detail"
;;

let get_with_db db operation_id =
  with_statement
    db
    ~operation:"lookup operation"
    ("SELECT " ^ select_columns ^ " FROM operations WHERE operation_id = ?")
    (fun stmt ->
       let* () = bind_text db stmt ~operation:"bind operation id" 1 (Id.to_string operation_id) in
       let rc = Sqlite3.step stmt in
       if rc = Sqlite3.Rc.DONE
       then Ok None
       else if rc = Sqlite3.Rc.ROW
       then
         let* operation = decode_operation stmt in
         let rc = Sqlite3.step stmt in
         if rc = Sqlite3.Rc.DONE
         then Ok (Some operation)
         else Error (Store_unavailable (sqlite_error db "complete operation lookup" rc))
       else Error (Store_unavailable (sqlite_error db "lookup operation" rc)))
;;

let get store operation_id =
  let* () = ensure_open store in
  get_with_db store.db operation_id
;;

let optional_text db ~operation sql =
  with_statement db ~operation sql (fun stmt ->
    let rc = Sqlite3.step stmt in
    if rc = Sqlite3.Rc.DONE
    then Ok None
    else if rc = Sqlite3.Rc.ROW
    then
      let value = Sqlite3.column_text stmt 0 in
      let rc = Sqlite3.step stmt in
      if rc = Sqlite3.Rc.DONE
      then Ok (Some value)
      else Error (Store_unavailable (sqlite_error db (operation ^ " completion") rc))
    else Error (Store_unavailable (sqlite_error db operation rc)))
;;

let inventory store =
  let* () = ensure_open store in
  let* queued =
    single_int64
      store.db
      ~operation:"count queued operations"
      "SELECT COUNT(*) FROM operations WHERE state = 'queued'"
  in
  let* running_operation_id =
    optional_text
      store.db
      ~operation:"read running operation"
      "SELECT operation_id FROM operations WHERE state = 'running'"
  in
  let* running_operation_id =
    match running_operation_id with
    | None -> Ok None
    | Some value ->
      Id.of_string value
      |> Result.map Option.some
      |> Result.map_error (fun detail -> Integrity_error detail)
  in
  let* terminal =
    single_int64
      store.db
      ~operation:"count terminal operations"
      "SELECT COUNT(*) FROM operations WHERE state IN ('succeeded', 'failed', 'cancelled')"
  in
  let* interrupted =
    single_int64
      store.db
      ~operation:"count interrupted operations"
      "SELECT COUNT(*) FROM operations WHERE state = 'failed' AND failure_kind = 'Interrupted_by_restart'"
  in
  if Int64.compare queued (Int64.of_int max_int) > 0
     || Int64.compare terminal (Int64.of_int max_int) > 0
     || Int64.compare interrupted (Int64.of_int max_int) > 0
  then Error (Integrity_error "operation inventory count exceeds OCaml int")
  else
    Ok
      { queued_count = Int64.to_int queued
      ; running_operation_id
      ; terminal_count = Int64.to_int terminal
      ; interrupted_count = Int64.to_int interrupted
      }
;;

let read_schema_objects db =
  with_statement
    db
    ~operation:"read operation schema"
    "SELECT type, name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name"
    (fun stmt ->
       let rec loop objects =
         let rc = Sqlite3.step stmt in
         if rc = Sqlite3.Rc.DONE
         then Ok (List.rev objects)
         else if rc = Sqlite3.Rc.ROW
         then
           loop
             (( Sqlite3.column_text stmt 0
              , Sqlite3.column_text stmt 1
              , Sqlite3.column_text stmt 2 )
              :: objects)
         else Error (Store_unavailable (sqlite_error db "read operation schema" rc))
       in
       loop [])
;;

let initialize_semantic_schema db =
  List.fold_left (fun result (_, name, sql) ->
    let* () = result in exec db ~operation:("create " ^ name) sql)
    (Ok ())
    [ "table", "semantic_executions", semantic_table_sql
    ; "index", "semantic_single_running", semantic_running_index_sql
    ; "trigger", "semantic_terminal_update_immutable", semantic_terminal_update_sql
    ; "trigger", "semantic_terminal_delete_immutable", semantic_terminal_delete_sql ]
;;

let initialize_schema db =
  let* () = exec db ~operation:"create operation metadata" metadata_table_sql in
  let* () = exec db ~operation:"create operations" operations_table_sql in
  let* () = exec db ~operation:"create state sequence index" operations_state_sequence_index_sql in
  let* () = exec db ~operation:"create single running index" operations_single_running_index_sql in
  let* () = exec db ~operation:"create terminal update trigger" terminal_update_trigger_sql in
  let* () = exec db ~operation:"create terminal delete trigger" terminal_delete_trigger_sql in
  let* () = initialize_semantic_schema db in
  let* () =
    exec
      db
      ~operation:"initialize operation sequence"
      "INSERT INTO metadata(singleton, schema, next_sequence) VALUES (1, 'masc.keeper_chat_operations.v2', 0)"
  in
  let* () =
    exec
      db
      ~operation:"set operation application id"
      (Printf.sprintf "PRAGMA application_id=%Ld" database_application_id)
  in
  exec
    db
    ~operation:"set operation user version"
    (Printf.sprintf "PRAGMA user_version=%Ld" database_user_version)
;;

let validate_schema_with ~version ~schema_identity ~objects db =
  let* application_id = single_int64 db ~operation:"read application id" "PRAGMA application_id" in
  let* user_version = single_int64 db ~operation:"read user version" "PRAGMA user_version" in
  if application_id <> database_application_id || user_version <> version then
    Error (Integrity_error "operation store application_id or user_version mismatch")
  else
    let* schema = single_text db ~operation:"read schema identity" "SELECT schema FROM metadata WHERE singleton = 1" in
    if schema <> schema_identity then Error (Integrity_error "operation store schema identity mismatch")
    else
      let* observed = read_schema_objects db in
      if observed = objects then Ok ()
      else Error (Integrity_error "operation store schema objects do not exactly match")
;;
let validate_schema db =
  validate_schema_with ~version:database_user_version ~schema_identity:database_schema
    ~objects:expected_schema_objects db
;;

let upgrade_validated_v1_unlocked db =
    let* () = validate_schema_with ~version:1L
      ~schema_identity:"masc.keeper_chat_operations.v1" ~objects:legacy_schema_objects db in
    let* integrity = single_text db ~operation:"validate v1 integrity" "PRAGMA quick_check" in
    let* () = if integrity = "ok" then Ok () else Error (Integrity_error integrity) in
    let* () = with_statement db ~operation:"validate every v1 operation"
      ("SELECT " ^ select_columns ^ " FROM operations") (fun stmt ->
        let rec loop () =
          let rc = Sqlite3.step stmt in
          if rc = Sqlite3.Rc.DONE then Ok ()
          else if rc = Sqlite3.Rc.ROW then let* _ = decode_operation stmt in loop ()
          else Error (Store_unavailable (sqlite_error db "validate v1 operation" rc))
        in loop ()) in
    let* next_sequence = single_int64 db ~operation:"preserve v1 sequence" "SELECT next_sequence FROM metadata WHERE singleton = 1" in
    let* max_sequence = single_int64 db ~operation:"validate v1 sequence" "SELECT COALESCE(MAX(sequence), -1) FROM operations" in
    let* () = if next_sequence > max_sequence then Ok () else Error (Integrity_error "v1 next_sequence does not follow stored operations") in
    let* () = exec db ~operation:"replace validated metadata contract" "DROP TABLE metadata" in
    let* () = exec db ~operation:"create v2 metadata contract" metadata_table_sql in
    let* () = with_statement db ~operation:"preserve operation sequence"
      "INSERT INTO metadata(singleton, schema, next_sequence) VALUES (1, 'masc.keeper_chat_operations.v2', ?)"
      (fun stmt -> let* () = bind_int64 db stmt ~operation:"bind preserved sequence" 1 next_sequence in
        expect_done db stmt ~operation:"write preserved sequence") in
    let* () = initialize_semantic_schema db in
    let* () = exec db ~operation:"advance operation schema version" "PRAGMA user_version=2" in
    validate_schema db
;;

let ensure_current_schema db =
  let* version = single_int64 db ~operation:"read schema upgrade version" "PRAGMA user_version" in
  if version = 1L then upgrade_validated_v1_unlocked db else validate_schema db
;;

let configure db =
  let* journal_mode =
    single_text db ~operation:"set DELETE journal mode" "PRAGMA journal_mode=DELETE"
  in
  if not (String.equal (String.lowercase_ascii journal_mode) "delete")
  then Error (Store_unavailable "SQLite refused journal_mode=DELETE")
  else
    (* DELETE-mode commit unlinks its rollback journal. EXTRA also syncs that
       directory; FULL alone may lose the last commit after power loss.
       See https://www.sqlite.org/pragma.html#pragma_synchronous. *)
    let* () = exec db ~operation:"set EXTRA synchronous" "PRAGMA synchronous=EXTRA" in
    let* () = exec db ~operation:"enable foreign keys" "PRAGMA foreign_keys=ON" in
    let* synchronous = single_int64 db ~operation:"read synchronous mode" "PRAGMA synchronous" in
    if not (Int64.equal synchronous 3L)
    then Error (Store_unavailable "SQLite synchronous mode is not EXTRA")
    else
      let* foreign_keys = single_int64 db ~operation:"read foreign keys" "PRAGMA foreign_keys" in
      if Int64.equal foreign_keys 1L
      then Ok ()
      else Error (Store_unavailable "SQLite foreign_keys is not enabled")
;;

let validate_open_candidate db =
  let* count = single_int64 db ~operation:"inspect candidate schema" "SELECT COUNT(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'" in
  if count = 0L then
    let* application_id = single_int64 db ~operation:"inspect empty application id" "PRAGMA application_id" in
    let* version = single_int64 db ~operation:"inspect empty schema version" "PRAGMA user_version" in
    if application_id = 0L && version = 0L then Ok ()
    else Error (Integrity_error "empty database has a foreign or damaged identity")
  else
    let* version = single_int64 db ~operation:"inspect candidate version" "PRAGMA user_version" in
    if version = 1L then validate_schema_with ~version:1L
      ~schema_identity:"masc.keeper_chat_operations.v1" ~objects:legacy_schema_objects db
    else validate_schema db
;;

let open_or_create ~path =
  let db = Sqlite3.db_open path in
  let fail error =
    (* See open failure contract: preserve the typed store error; close is best-effort. *)
    ignore (close_db db : bool);
    Error error
  in
  let initialize_or_upgrade () =
    (* Reject unknown/corrupt contracts before changing journaling pragmas. *)
    let* () = validate_open_candidate db in
    let* () = configure db in
    let* () = exec db ~operation:"begin operation schema transaction" "BEGIN IMMEDIATE" in
    let body () =
      (* Recheck after acquiring the writer lock; another opener may already
         have initialized or migrated the candidate observed above. *)
      let* () = validate_open_candidate db in
      let* count = single_int64 db ~operation:"read locked schema" "SELECT COUNT(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'" in
      let* () = if count = 0L then initialize_schema db else ensure_current_schema db in
      let* () = validate_schema db in
      commit db
    in
    match body () with
    | Ok () -> Ok ()
    | Error _ as error -> rollback db; error
  in
  match initialize_or_upgrade () with
  | Ok () -> Ok { db; path; closed = Atomic.make false }
  | Error error -> fail error
;;

let close store =
  if Atomic.compare_and_set store.closed false true
  then
    if close_db store.db
    then Ok ()
    else Error (Store_unavailable "failed to close SQLite database")
  else Ok ()
;;

let decode_semantic stmt =
  let* json = json_of_stored "semantic execution" (Sqlite3.column_text stmt 3) in
  let* execution = Semantic.of_json json
    |> Result.map_error (fun error -> Integrity_error (Semantic.error_to_string error)) in
  if scope_key execution.id <> Sqlite3.column_text stmt 0
     || execution.revision <> Sqlite3.column_int64 stmt 1
     || Semantic.phase_name execution.phase <> Sqlite3.column_text stmt 2 then
    Error (Integrity_error "semantic execution index and record disagree")
  else Ok execution
;;
let semantic_rows db ~active_only =
  with_statement db ~operation:"read semantic executions"
    "SELECT scope_key, revision, phase, record_json FROM semantic_executions ORDER BY scope_key"
    (fun stmt ->
      let rec loop acc =
        let rc = Sqlite3.step stmt in
        if rc = Sqlite3.Rc.DONE then Ok (List.rev acc)
        else if rc = Sqlite3.Rc.ROW then
            let* execution = decode_semantic stmt in
            (* The denormalized phase is not authority before validation:
               a damaged index must not hide an outstanding operation. *)
            loop (if active_only && Semantic.is_terminal execution then acc else execution :: acc)
        else Error (Store_unavailable (sqlite_error db "read semantic executions" rc))
      in loop [])
;;

let inspect_outstanding ~path =
  let inspect db =
    let* () = exec db ~operation:"begin read-only inspection" "BEGIN" in
    let* version = single_int64 db ~operation:"read inspection schema version" "PRAGMA user_version" in
    let* chat_only =
      if version = 1L then
        let* () = validate_schema_with ~version:1L
          ~schema_identity:"masc.keeper_chat_operations.v1" ~objects:legacy_schema_objects db in
        Ok true
      else let* () = validate_schema db in Ok false
    in
    let* integrity = single_text db ~operation:"check operation store integrity" "PRAGMA quick_check" in
    let* () = if String.equal integrity "ok" then Ok () else Error (Integrity_error integrity) in
    let* outstanding =
      with_statement db ~operation:"inspect durable operations"
        ("SELECT " ^ select_columns ^ " FROM operations ORDER BY sequence")
        (fun stmt ->
          let rec read acc =
            let rc = Sqlite3.step stmt in
            if rc = Sqlite3.Rc.DONE then Ok (List.rev acc)
            else if rc = Sqlite3.Rc.ROW then
              let* operation = decode_operation stmt in
              read (if Operation.is_terminal operation.state then acc else operation :: acc)
            else Error (Store_unavailable (sqlite_error db "inspect durable operations" rc))
          in read [])
    in
    (* An exactly validated v1 schema cannot contain semantic records.
       Ownerless stores remain inspectable without a write or migration. *)
    let* semantic_executions =
      if chat_only then Ok [] else semantic_rows db ~active_only:true in
    let* () = exec db ~operation:"end read-only inspection" "COMMIT" in
    Ok (Stored_operations { chat_operations = outstanding; semantic_executions })
  in
  let inspect_existing () =
    match Sqlite3.db_open ~mode:`READONLY path with
    | exception Sqlite3.Error detail -> Error (Store_unavailable detail)
    | db ->
      let result =
        try inspect db with
        | Sqlite3.Error detail -> Error (Store_unavailable detail)
      in
      if close_db db then result
      else Error (Store_unavailable "failed to close read-only operation store")
  in
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_REG; _ } -> inspect_existing ()
  | { Unix.st_kind = (Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK); _ } ->
    Error (Integrity_error "operation store path is not a regular file")
  | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
    (* A journal without its database is damaged evidence, not an empty queue. *)
    let rec absent_companions = function
      | [] -> Ok Missing_store
      | suffix :: rest ->
        (match Unix.lstat (path ^ suffix) with
         | _ -> Error (Integrity_error "operation journal exists without its database")
         | exception Unix.Unix_error (Unix.ENOENT, _, _) -> absent_companions rest
         | exception Unix.Unix_error (error, _, _) -> Error (Store_unavailable (Unix.error_message error)))
    in absent_companions [ "-journal"; "-wal"; "-shm" ]
  | exception Unix.Unix_error (error, _, _) -> Error (Store_unavailable (Unix.error_message error))
;;

let next_sequence db =
  let* sequence =
    single_int64 db ~operation:"read next operation sequence" "SELECT next_sequence FROM metadata WHERE singleton = 1"
  in
  if Int64.equal sequence Int64.max_int
  then Error (Store_unavailable "operation sequence exhausted")
  else
    let next = Int64.succ sequence in
    let* () =
      with_statement
        db
        ~operation:"advance operation sequence"
        "UPDATE metadata SET next_sequence = ? WHERE singleton = 1 AND next_sequence = ?"
        (fun stmt ->
           let* () = bind_int64 db stmt ~operation:"bind next sequence" 1 next in
           let* () = bind_int64 db stmt ~operation:"bind current sequence" 2 sequence in
           let* () = expect_done db stmt ~operation:"advance operation sequence" in
           if Sqlite3.changes db = 1
           then Ok ()
           else Error (Integrity_error "operation sequence update lost sole-writer authority"))
    in
    Ok sequence
;;

let insert_queued db operation =
  let* source_json = canonical_json "source" operation.Operation.source in
  let* input = required_option "queued input" operation.input in
  let* input_json = canonical_json "input" input in
  with_statement
    db
    ~operation:"insert queued operation"
    "INSERT INTO operations(operation_id, admission_digest, execution_digest, sequence, source_json, input_json, state, created_at, started_at, completed_at, outcome_ref, failure_kind, failure_detail) VALUES (?, ?, ?, ?, ?, ?, 'queued', ?, NULL, NULL, NULL, NULL, NULL)"
    (fun stmt ->
       let* () = bind_text db stmt ~operation:"bind operation id" 1 (Id.to_string operation.operation_id) in
       let* () = bind_text db stmt ~operation:"bind admission digest" 2 operation.admission_digest in
       let* () = bind_text db stmt ~operation:"bind execution digest" 3 operation.execution_digest in
       let* () = bind_int64 db stmt ~operation:"bind operation sequence" 4 operation.sequence in
       let* () = bind_text db stmt ~operation:"bind operation source" 5 source_json in
       let* () = bind_text db stmt ~operation:"bind operation input" 6 input_json in
       let* () = bind_float db stmt ~operation:"bind operation creation" 7 operation.created_at in
       expect_done db stmt ~operation:"insert queued operation")
;;

let same_admission expected observed =
  Id.equal expected.Operation.operation_id observed.Operation.operation_id
  && String.equal expected.admission_digest observed.admission_digest
;;

let submit store ~now ~operation_id ~source ~input =
  let* () = ensure_open store in
  let* () =
    Operation.validate_timestamp ~field:"created_at" now
    |> Result.map_error (fun detail -> Invalid_input detail)
  in
  let* admission_digest =
    Operation.admission_digest ~source ~input
    |> Result.map_error (fun detail -> Invalid_input detail)
  in
  let* execution_digest =
    Operation.execution_digest input
    |> Result.map_error (fun detail -> Invalid_input detail)
  in
  let* source_json = canonical_json "source" source in
  let* source = json_of_stored "source" source_json in
  let* input_json = canonical_json "input" input in
  let* input = json_of_stored "input" input_json in
  let inserted = ref None in
  let transaction =
    with_transaction store (fun () ->
      let* existing = get_with_db store.db operation_id in
      match existing with
      | Some operation when String.equal operation.admission_digest admission_digest ->
        Ok (Existing operation)
      | Some _ -> Error (Idempotency_conflict operation_id)
      | None ->
        let* sequence = next_sequence store.db in
        let operation =
          { Operation.operation_id
          ; admission_digest
          ; execution_digest
          ; sequence
          ; source
          ; input = Some input
          ; state = Queued
          ; created_at = now
          }
        in
        let* () = insert_queued store.db operation in
        inserted := Some operation;
        Ok (Accepted operation))
  in
  match transaction with
  | Ok _ as result -> result
  | Error commit_error ->
    (match commit_error with
     | Store_unavailable _ ->
       (match !inserted with
        | None -> Error commit_error
        | Some expected ->
          (match get_with_db store.db operation_id with
           | Ok (Some observed) when same_admission expected observed ->
             Ok (Accepted observed)
           | Ok _ | Error _ -> Error commit_error))
     | ( Invalid_input _
       | Unknown_operation _
       | Not_queued _
       | Not_running _
       | Idempotency_conflict _
       | Integrity_error _ ) -> Error commit_error)
;;

let reducer_error operation_id = function
  | Reducer.Not_queued -> Not_queued operation_id
  | Reducer.Not_running -> Not_running operation_id
  | Reducer.Invalid_input detail -> Invalid_input detail
;;

let operation_or_unknown db operation_id =
  let* operation = get_with_db db operation_id in
  match operation with
  | Some operation -> Ok operation
  | None -> Error (Unknown_operation operation_id)
;;

let readback_exact store expected original_error =
  match get_with_db store.db expected.Operation.operation_id with
  | Ok (Some observed) when observed = expected -> Ok observed
  | Ok _ | Error _ -> Error original_error
;;

let persist_and_readback store expected persist =
  match with_transaction store persist with
  | Ok () ->
    (match get_with_db store.db expected.Operation.operation_id with
     | Ok (Some observed) when observed = expected -> Ok observed
     | Ok _ -> Error (Integrity_error "committed operation does not match reducer transition")
     | Error _ as error -> error)
  | Error error ->
    (match error with
     | Store_unavailable _ -> readback_exact store expected error
     | ( Invalid_input _
       | Unknown_operation _
       | Not_queued _
       | Not_running _
       | Idempotency_conflict _
       | Integrity_error _ ) -> Error error)
;;

let claim_next store ~now =
  let* () = ensure_open store in
  let* () =
    Operation.validate_timestamp ~field:"started_at" now
    |> Result.map_error (fun detail -> Invalid_input detail)
  in
  let result = ref None in
  let transaction =
    with_transaction store (fun () ->
      let* running =
        single_int64 store.db ~operation:"count running operation" "SELECT COUNT(*) FROM operations WHERE state = 'running'"
      in
      if Int64.compare running 0L > 0
      then Ok ()
      else
        with_statement
          store.db
          ~operation:"select queued FIFO head"
          ("SELECT " ^ select_columns ^ " FROM operations WHERE state = 'queued' ORDER BY sequence LIMIT 1")
          (fun stmt ->
             let rc = Sqlite3.step stmt in
             if rc = Sqlite3.Rc.DONE
             then Ok ()
             else if rc = Sqlite3.Rc.ROW
             then
               let* current = decode_operation stmt in
               let* transition =
                 Reducer.apply current (Start { started_at = now })
                 |> Result.map_error (reducer_error current.operation_id)
               in
               let expected = transition.operation in
               let* () =
                 with_statement
                   store.db
                   ~operation:"mark operation running"
                   "UPDATE operations SET state = 'running', started_at = ? WHERE operation_id = ? AND state = 'queued'"
                   (fun update ->
                      let* () = bind_float store.db update ~operation:"bind start time" 1 now in
                      let* () = bind_text store.db update ~operation:"bind claimed id" 2 (Id.to_string current.operation_id) in
                      let* () = expect_done store.db update ~operation:"mark operation running" in
                      if Sqlite3.changes store.db = 1
                      then Ok ()
                      else Error (Integrity_error "queued FIFO head changed under sole writer"))
               in
               result := Some expected;
               Ok ()
             else Error (Store_unavailable (sqlite_error store.db "select queued FIFO head" rc))))
  in
  match transaction with
  | Ok () ->
    (match !result with
     | None -> Ok None
     | Some expected ->
       let* observed = operation_or_unknown store.db expected.operation_id in
       if observed = expected
       then Ok (Some observed)
       else Error (Integrity_error "running operation read-back mismatch"))
  | Error error ->
    (match error, !result with
     | Store_unavailable _, Some expected ->
       (match readback_exact store expected error with
        | Ok operation -> Ok (Some operation)
        | Error _ as error -> error)
     | Store_unavailable _, None -> Error error
     | ( Invalid_input _
       | Unknown_operation _
       | Not_queued _
       | Not_running _
       | Idempotency_conflict _
       | Integrity_error _ ),
       _ -> Error error)
;;

let list_queued store ~after_sequence ~limit =
  let* () = ensure_open store in
  if limit < 1 || limit > 1_000
  then Error (Invalid_input "limit must be in 1..1000")
  else
    let* () =
      match after_sequence with
      | None -> Ok ()
      | Some value when Int64.compare value 0L >= 0 -> Ok ()
      | Some _ -> Error (Invalid_input "after_sequence must be non-negative")
    in
    let sql =
      match after_sequence with
      | None ->
        Printf.sprintf
          "SELECT %s FROM operations WHERE state = 'queued' ORDER BY sequence LIMIT %d"
          select_columns
          limit
      | Some _ ->
        Printf.sprintf
          "SELECT %s FROM operations WHERE state = 'queued' AND sequence > ? ORDER BY sequence LIMIT %d"
          select_columns
          limit
    in
    with_statement store.db ~operation:"list queued operations" sql (fun stmt ->
      let* () =
        match after_sequence with
        | None -> Ok ()
        | Some value -> bind_int64 store.db stmt ~operation:"bind queued cursor" 1 value
      in
      let rec loop operations =
        let rc = Sqlite3.step stmt in
        if rc = Sqlite3.Rc.DONE
        then Ok (List.rev operations)
        else if rc = Sqlite3.Rc.ROW
        then
          let* operation = decode_operation stmt in
          loop (operation :: operations)
        else Error (Store_unavailable (sqlite_error store.db "list queued operations" rc))
      in
      loop [])
;;

let edit_queued store ~operation_id ~input =
  let* () = ensure_open store in
  let* execution_digest =
    Operation.execution_digest input
    |> Result.map_error (fun detail -> Invalid_input detail)
  in
  let* input_json = canonical_json "input" input in
  let* input = json_of_stored "input" input_json in
  let current = ref None in
  let* expected =
    let* operation = operation_or_unknown store.db operation_id in
    current := Some operation;
    Reducer.apply operation (Edit_queued { input; execution_digest })
    |> Result.map (fun transition -> transition.Reducer.operation)
    |> Result.map_error (reducer_error operation_id)
  in
  ignore current;
  persist_and_readback store expected (fun () ->
    with_statement
      store.db
      ~operation:"edit queued operation"
      "UPDATE operations SET input_json = ?, execution_digest = ? WHERE operation_id = ? AND state = 'queued'"
      (fun stmt ->
         let* () = bind_text store.db stmt ~operation:"bind edited input" 1 input_json in
         let* () = bind_text store.db stmt ~operation:"bind edited digest" 2 execution_digest in
         let* () = bind_text store.db stmt ~operation:"bind edited operation" 3 (Id.to_string operation_id) in
         let* () = expect_done store.db stmt ~operation:"edit queued operation" in
         if Sqlite3.changes store.db = 1 then Ok () else Error (Not_queued operation_id)))
;;

let move_queued_to_end store ~operation_id =
  let* () = ensure_open store in
  let expected = ref None in
  let transaction =
    with_transaction store (fun () ->
      let* operation = operation_or_unknown store.db operation_id in
      let* () =
        match operation.state with
        | Operation.Queued -> Ok ()
        | Running _ | Succeeded _ | Failed _ | Cancelled _ ->
          Error (Not_queued operation_id)
      in
        let* sequence = next_sequence store.db in
        let* transition =
          Reducer.apply operation (Move_queued { sequence })
          |> Result.map_error (reducer_error operation_id)
        in
        let* () =
          with_statement
            store.db
            ~operation:"move queued operation"
            "UPDATE operations SET sequence = ? WHERE operation_id = ? AND state = 'queued'"
            (fun stmt ->
               let* () = bind_int64 store.db stmt ~operation:"bind moved sequence" 1 sequence in
               let* () = bind_text store.db stmt ~operation:"bind moved operation" 2 (Id.to_string operation_id) in
               let* () = expect_done store.db stmt ~operation:"move queued operation" in
               if Sqlite3.changes store.db = 1 then Ok () else Error (Not_queued operation_id))
        in
        expected := Some transition.operation;
        Ok ())
  in
  match transaction with
  | Ok () ->
    (match !expected with
     | Some expected ->
       readback_exact store expected (Integrity_error "move read-back failed")
     | None -> Error (Integrity_error "move committed without an expected operation"))
  | Error error ->
    (match error, !expected with
     | Store_unavailable _, Some expected -> readback_exact store expected error
     | Store_unavailable _, None -> Error error
     | ( Invalid_input _
       | Unknown_operation _
       | Not_queued _
       | Not_running _
       | Idempotency_conflict _
       | Integrity_error _ ),
       _ -> Error error)
;;

let persist_terminal store current command sql bind_terminal =
  let operation_id = current.Operation.operation_id in
  let* transition =
    Reducer.apply current command |> Result.map_error (reducer_error operation_id)
  in
  let expected = transition.operation in
  persist_and_readback store expected (fun () ->
    with_statement store.db ~operation:"terminalize operation" sql (fun stmt ->
      let* () = bind_terminal stmt in
      let* () = expect_done store.db stmt ~operation:"terminalize operation" in
      if Sqlite3.changes store.db = 1
      then Ok ()
      else
        match current.state with
        | Queued -> Error (Not_queued operation_id)
        | Running _ -> Error (Not_running operation_id)
        | Succeeded _ | Failed _ | Cancelled _ ->
          Error (Integrity_error "terminal operation changed")))
;;

let cancel_queued store ~now ~operation_id =
  let* () = ensure_open store in
  let* current = operation_or_unknown store.db operation_id in
  persist_terminal
    store
    current
    (Cancel_queued { completed_at = now })
    "UPDATE operations SET state = 'cancelled', input_json = NULL, completed_at = ? WHERE operation_id = ? AND state = 'queued'"
    (fun stmt ->
       let* () = bind_float store.db stmt ~operation:"bind cancellation time" 1 now in
       bind_text store.db stmt ~operation:"bind cancelled operation" 2 (Id.to_string operation_id))
;;

let succeed_running store ~now ~operation_id ~outcome_ref =
  let* () = ensure_open store in
  let* current = operation_or_unknown store.db operation_id in
  persist_terminal
    store
    current
    (Succeed_running { completed_at = now; outcome_ref })
    "UPDATE operations SET state = 'succeeded', input_json = NULL, completed_at = ?, outcome_ref = ? WHERE operation_id = ? AND state = 'running'"
    (fun stmt ->
       let* () = bind_float store.db stmt ~operation:"bind success time" 1 now in
       let* () = bind_text store.db stmt ~operation:"bind outcome reference" 2 outcome_ref in
       bind_text store.db stmt ~operation:"bind succeeded operation" 3 (Id.to_string operation_id))
;;

let fail_running store ~now ~operation_id ~kind ~detail ~outcome_ref =
  let* () = ensure_open store in
  let* current = operation_or_unknown store.db operation_id in
  let failure : Operation.failure = { kind; detail; outcome_ref } in
  persist_terminal
    store
    current
    (Fail_running { completed_at = now; failure })
    "UPDATE operations SET state = 'failed', input_json = NULL, completed_at = ?, outcome_ref = ?, failure_kind = ?, failure_detail = ? WHERE operation_id = ? AND state = 'running'"
    (fun stmt ->
       let* () = bind_float store.db stmt ~operation:"bind failure time" 1 now in
       let* () = bind_optional_text store.db stmt ~operation:"bind failure outcome" 2 outcome_ref in
       let* () =
         bind_text
           store.db
           stmt
           ~operation:"bind failure kind"
           3
           (Operation.failure_kind_to_string kind)
       in
       let* () = bind_text store.db stmt ~operation:"bind failure detail" 4 detail in
       bind_text store.db stmt ~operation:"bind failed operation" 5 (Id.to_string operation_id))
;;

type semantic_error =
  | Semantic_store_error of error
  | Unknown_execution of Keeper_execution_scope_id.t
  | Admission_conflict of Keeper_execution_scope_id.t
  | Execution_changed of Semantic.t
  | Sources_owned of Keeper_execution_scope_id.t list
  | Execution_slot_busy of Keeper_execution_scope_id.t
  | Invalid_execution of Semantic.error

type semantic_admission = Semantic_created of Semantic.t | Semantic_existing of Semantic.t

let semantic_error_to_string = function
  | Semantic_store_error error -> error_to_string error
  | Unknown_execution id -> "unknown semantic execution: " ^ scope_key id
  | Admission_conflict id -> "semantic admission conflict: " ^ scope_key id
  | Execution_changed current -> "semantic execution changed: " ^ scope_key current.id
  | Sources_owned ids -> "selected sources already belong to: " ^ String.concat ", " (List.map scope_key ids)
  | Execution_slot_busy id -> "semantic execution slot is held by: " ^ scope_key id
  | Invalid_execution error -> Semantic.error_to_string error
;;
let semantic_store_result result = Result.map_error (fun error -> Semantic_store_error error) result

let semantic_get_with_db db id =
  with_statement db ~operation:"lookup semantic execution"
    "SELECT scope_key, revision, phase, record_json FROM semantic_executions WHERE scope_key = ?"
    (fun stmt ->
      let* () = bind_text db stmt ~operation:"bind semantic identity" 1 (scope_key id) in
      let rc = Sqlite3.step stmt in
      if rc = Sqlite3.Rc.DONE then Ok None
      else if rc = Sqlite3.Rc.ROW then
          let* current = decode_semantic stmt in
          let* () = expect_done db stmt ~operation:"complete semantic lookup" in
          Ok (Some current)
      else Error (Store_unavailable (sqlite_error db "lookup semantic execution" rc)))
;;
let semantic_get store id =
  let* () = ensure_open store |> semantic_store_result in
  semantic_get_with_db store.db id |> semantic_store_result
;;
let semantic_outstanding store =
  let* () = ensure_open store |> semantic_store_result in
  semantic_rows store.db ~active_only:true |> semantic_store_result
;;
let with_semantic_transaction store f =
  let* () = ensure_open store |> semantic_store_result in
  let* () = exec store.db ~operation:"begin semantic operation transaction" "BEGIN IMMEDIATE" |> semantic_store_result in
  match f () with
  | Error _ as error -> rollback store.db; error
  | Ok value ->
      (match commit store.db |> semantic_store_result with
       | Ok () -> Ok value
       | Error _ as error -> rollback store.db; error)
;;
let semantic_canonical execution = canonical_json "semantic execution" (Semantic.to_json execution)

let insert_semantic db execution =
  let* bytes = semantic_canonical execution in
  with_statement db ~operation:"persist semantic admission"
    "INSERT INTO semantic_executions(scope_key, revision, phase, record_json) VALUES (?, ?, ?, ?)"
    (fun stmt ->
      let* () = bind_text db stmt ~operation:"bind execution identity" 1 (scope_key execution.id) in
      let* () = bind_int64 db stmt ~operation:"bind execution revision" 2 execution.revision in
      let* () = bind_text db stmt ~operation:"bind execution phase" 3 (Semantic.phase_name execution.phase) in
      let* () = bind_text db stmt ~operation:"bind initialized frame and membership" 4 bytes in
      expect_done db stmt ~operation:"persist semantic admission")
;;
let update_semantic db ~expected next =
  let* expected_bytes = semantic_canonical expected in
  let* bytes = semantic_canonical next in
  with_statement db ~operation:"CAS semantic execution"
    "UPDATE semantic_executions SET revision = ?, phase = ?, record_json = ? WHERE scope_key = ? AND revision = ? AND record_json = ?"
    (fun stmt ->
      let* () = bind_int64 db stmt ~operation:"bind next revision" 1 next.revision in
      let* () = bind_text db stmt ~operation:"bind next phase" 2 (Semantic.phase_name next.phase) in
      let* () = bind_text db stmt ~operation:"bind next execution record" 3 bytes in
      let* () = bind_text db stmt ~operation:"bind expected identity" 4 (scope_key expected.id) in
      let* () = bind_int64 db stmt ~operation:"bind expected revision" 5 expected.revision in
      let* () = bind_text db stmt ~operation:"bind expected exact record" 6 expected_bytes in
      let* () = expect_done db stmt ~operation:"CAS semantic execution" in
      if Sqlite3.changes db = 1 then Ok () else Error (Integrity_error "semantic CAS did not update its exact record"))
;;
let same_source (left : Semantic.source_member) (right : Semantic.source_member) =
  left.post_id = right.post_id && left.admitted_revision = right.admitted_revision
  && left.source_sha256 = right.source_sha256
;;
let semantic_prepare store ~id ~sources ~now =
  let* candidate = Semantic.create ~id ~sources ~now |> Result.map_error (fun error -> Invalid_execution error) in
  with_semantic_transaction store (fun () ->
    let* existing = semantic_get_with_db store.db id |> semantic_store_result in
    match existing with
    | Some current when Semantic.same_admission current candidate -> Ok (Semantic_existing current)
    | Some _ -> Error (Admission_conflict id)
    | None ->
        let* outstanding = semantic_rows store.db ~active_only:true |> semantic_store_result in
        let owners = List.filter (fun (execution : Semantic.t) ->
          List.exists (fun selected -> List.exists (same_source selected)
            (execution.sources @ execution.current_sources)) sources) outstanding in
        if owners <> [] then Error (Sources_owned (List.map (fun (execution : Semantic.t) -> execution.id) owners))
        else
          let* () = insert_semantic store.db candidate |> semantic_store_result in
          Ok (Semantic_created candidate))
;;
let semantic_apply store ~expected ~now action =
  with_semantic_transaction store (fun () ->
    let* current = semantic_get_with_db store.db expected.Semantic.id |> semantic_store_result in
    let* current = match current with None -> Error (Unknown_execution expected.id) | Some current -> Ok current in
    let* expected_bytes = semantic_canonical expected |> semantic_store_result in
    let* current_bytes = semantic_canonical current |> semantic_store_result in
    if expected_bytes <> current_bytes then Error (Execution_changed current)
    else
      let* next = Semantic.apply ~now action current |> Result.map_error (fun error -> Invalid_execution error) in
      let* () =
        if next.current_sources = current.current_sources then Ok ()
        else
          let* outstanding = semantic_rows store.db ~active_only:true |> semantic_store_result in
          let owners = List.filter (fun (execution : Semantic.t) ->
            not (Keeper_execution_scope_id.equal execution.id current.id)
            && List.exists (fun selected -> List.exists (same_source selected)
                 (execution.sources @ execution.current_sources)) next.current_sources) outstanding in
          if owners = [] then Ok ()
          else Error (Sources_owned (List.map (fun (execution : Semantic.t) -> execution.id) owners)) in
      let* () = match next.phase with
        | Semantic.Running ->
            if current.phase = Semantic.Running then Ok () else
            let* outstanding = semantic_rows store.db ~active_only:true |> semantic_store_result in
            (match List.find_opt (fun (execution : Semantic.t) -> execution.phase = Semantic.Running) outstanding with
             | Some running -> Error (Execution_slot_busy running.id)
             | None -> Ok ())
        | Semantic.Preparing | Semantic.Ready | Semantic.Suspended _ | Semantic.Recovering _ | Semantic.Settled _ -> Ok () in
      let* () =
        if next == current then Ok ()
        else update_semantic store.db ~expected:current next |> semantic_store_result in
      Ok next)
;;

let reconcile_semantic_running_with_db db ~now =
  let* executions = semantic_rows db ~active_only:true in
  List.fold_left (fun result (execution : Semantic.t) ->
    let* count = result in
    match execution.phase with
    | Semantic.Running ->
        let* next = Semantic.apply ~now
          (Semantic.Require_reconciliation "process restarted during semantic execution") execution
          |> Result.map_error (fun error -> Integrity_error (Semantic.error_to_string error)) in
        let* () = update_semantic db ~expected:execution next in
        Ok (count + 1)
    | Semantic.Preparing | Semantic.Ready | Semantic.Suspended _
    | Semantic.Recovering _ | Semantic.Settled _ -> Ok count) (Ok 0) executions
;;

let settle_running_after_restart store ~now =
  let* () = ensure_open store in
  let* () =
    Operation.validate_timestamp ~field:"completed_at" now
    |> Result.map_error (fun detail -> Invalid_input detail)
  in
  with_transaction store (fun () ->
    let* _reconciled = reconcile_semantic_running_with_db store.db ~now in
    with_statement
      store.db
      ~operation:"settle interrupted operations"
      "UPDATE operations SET state = 'failed', input_json = NULL, completed_at = ?, failure_kind = ?, failure_detail = 'process restarted before terminal operation commit' WHERE state = 'running'"
      (fun stmt ->
         let* () = bind_float store.db stmt ~operation:"bind restart settlement time" 1 now in
         let* () =
           bind_text
             store.db
             stmt
             ~operation:"bind restart failure kind"
             2
             (Operation.failure_kind_to_string Operation.Interrupted_by_restart)
         in
         let* () = expect_done store.db stmt ~operation:"settle interrupted operations" in
         Ok (Sqlite3.changes store.db)))
;;

module For_testing = struct
  type nonrec commit_fault = commit_fault =
    | Fail_before_commit
    | Fail_after_commit

  let fail_next_commit fault = Atomic.set next_commit_fault (Some fault)
  let clear_commit_fault () = Atomic.set next_commit_fault None
  let database_file = database_file
  let database_application_id = database_application_id
  let table_column_counts = table_column_counts
end
