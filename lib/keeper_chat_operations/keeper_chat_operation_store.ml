module Operation = Keeper_chat_operation
module Reducer = Keeper_chat_operation_reducer
module Id = Operation.Operation_id
module Semantic = Keeper_semantic_execution

let semantic_is_running = function
  | Semantic.Running | Semantic.Resuming_runtime_retry _ | Semantic.Resuming_gate _ -> true
  | Semantic.Preparing | Semantic.Ready | Semantic.Suspended _ | Semantic.Recovering _ | Semantic.Settled _ -> false

let scope_key id = Yojson.Safe.to_string (Keeper_execution_scope_id.to_json id)

type t =
  { db : Sqlite3.db
  ; path : string
  (* [close] used to test this and then set it. Two closers could both see
     [false] and both call [Sqlite3.db_close] on the same handle. As an
     [Atomic] the test and the set are one step, so exactly one caller
     reaches the close. *)
  ; closed : bool Atomic.t
  (* References the semantic writes of the open transaction stopped naming.
     The transaction checks them against every owning execution before it
     commits, and empties this either way. *)
  ; dropped : Keeper_checkpoint_ref.t list Atomic.t
  (* References committed transactions released, until
     [take_released_checkpoints] hands them to the caller that removes the
     files. *)
  ; released : Keeper_checkpoint_ref.t list Atomic.t
  }

type error =
  | Invalid_input of string
  | Unknown_operation of Id.t
  | Not_queued of Id.t
  | Not_running of Id.t
  | Idempotency_conflict of Id.t
  | Store_unavailable of string
  | Integrity_error of string
  | Native_call_unsettled

type admission =
  | Accepted of Operation.t
  | Existing of Operation.t

type inventory =
  { queued_count : int
  ; running_operation_id : Id.t option
  ; terminal_count : int
  ; interrupted_count : int
  }

let database_file = Common.chat_operation_store_basename

let path_for_keeper ~keepers_runtime_dir ~keeper_name =
  Filename.concat (Filename.concat keepers_runtime_dir keeper_name) database_file
;;

type input_history = Fresh_input_history | Prior_input_history_unavailable
(** A prior journal cannot prove that a missing trace row never had input.
    This durable global floor also covers omitted historical traces. *)
type input_checkpoint_observation =
  | Input_unobserved
  | Input_observed of Keeper_checkpoint_ref.t
  | Prior_input_unavailable

type outstanding_snapshot =
  | Missing_store
  | Stored_operations of { chat_operations : Operation.t list; semantic_executions : Semantic.t list; input_checkpoints : Keeper_checkpoint_ref.t list; input_history : input_history }

type durable_snapshot =
  | Missing_durable_store
  | Stored_durable_records of
      { chat_operations : Operation.t list
      ; batch_member_inputs : Yojson.Safe.t list
      ; semantic_executions : Semantic.t list
      ; input_checkpoints : Keeper_checkpoint_ref.t list
      ; input_history : input_history
      }
let database_schema = "masc.keeper_chat_operations.v3"
let database_application_id = 0x4d4b4f50L
let database_user_version = 3L

let metadata_table_sql =
  "CREATE TABLE metadata (singleton INTEGER PRIMARY KEY CHECK (singleton = 1), schema TEXT NOT NULL CHECK (schema = 'masc.keeper_chat_operations.v3'), next_sequence INTEGER NOT NULL CHECK (next_sequence >= 0)) STRICT"
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

let chat_schema_objects =
  [ "index", "operations_single_running", operations_single_running_index_sql
  ; "index", "operations_state_sequence", operations_state_sequence_index_sql
  ; "table", "metadata", metadata_table_sql
  ; "table", "operations", operations_table_sql
  ; "trigger", "operations_terminal_delete_immutable", terminal_delete_trigger_sql
  ; "trigger", "operations_terminal_update_immutable", terminal_update_trigger_sql
  ]
;;

let batch_table_sql =
  "CREATE TABLE operation_batch_members (operation_id TEXT PRIMARY KEY REFERENCES operations(operation_id), execution_id TEXT NOT NULL REFERENCES operations(operation_id), position INTEGER NOT NULL CHECK (position >= 0), admitted_digest TEXT NOT NULL CHECK (length(admitted_digest) = 64), admitted_input_json TEXT, UNIQUE(execution_id, position)) STRICT"
;;
let batch_schema_objects =
  [ "table", "operation_batch_members", batch_table_sql
  ; "trigger", "batch_members_update_immutable", "CREATE TRIGGER batch_members_update_immutable BEFORE UPDATE ON operation_batch_members WHEN NEW.operation_id <> OLD.operation_id OR NEW.execution_id <> OLD.execution_id OR NEW.position <> OLD.position OR NEW.admitted_digest <> OLD.admitted_digest OR OLD.admitted_input_json IS NULL OR NEW.admitted_input_json IS NOT NULL OR NOT EXISTS (SELECT 1 FROM operations WHERE operation_id = OLD.execution_id AND state IN ('succeeded', 'failed', 'cancelled')) BEGIN SELECT RAISE(ABORT, 'batch membership is immutable'); END"
  ; "trigger", "batch_members_delete_immutable", "CREATE TRIGGER batch_members_delete_immutable BEFORE DELETE ON operation_batch_members BEGIN SELECT RAISE(ABORT, 'batch membership is immutable'); END" ]
let input_checkpoint_table_sql =
  "CREATE TABLE input_checkpoints (trace_id TEXT PRIMARY KEY, turn_count INTEGER NOT NULL CHECK (turn_count >= 0), sha256 TEXT NOT NULL CHECK (length(sha256) = 64)) STRICT"
let input_history_table_sql =
  "CREATE TABLE input_history (singleton INTEGER PRIMARY KEY CHECK (singleton = 1), basis TEXT NOT NULL CHECK (basis IN ('fresh', 'prior_unavailable'))) STRICT"
let expected_schema_objects =
  List.sort compare (chat_schema_objects @ semantic_schema_objects @ batch_schema_objects
    @ ["table", "input_checkpoints", input_checkpoint_table_sql;
       "table", "input_history", input_history_table_sql])
let table_column_counts =
  [ "metadata", 3; "operations", 13; "semantic_executions", 4
  ; "operation_batch_members", 5; "input_checkpoints", 3; "input_history", 2 ]

type commit_fault =
  | Fail_before_commit
  | Fail_after_commit

let next_commit_fault : commit_fault option Atomic.t = Atomic.make None
let next_runtime_retry_read_fault = Atomic.make false

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
  | Native_call_unsettled ->
    "Keeper chat operation native call blocks this change: it is active without a terminal disposition or holds an unknown-effect receipt"
;;

let path store = store.path

(* [Rc.to_string] is the primary code and [errmsg] for IOERR is always
   "disk I/O error". The extended code names the failing syscall (IOERR_LOCK
   3850, IOERR_WRITE 778, IOERR_FSYNC 1034, IOERR_SHMOPEN 4618, ...), see
   https://sqlite.org/rescode.html. Without it an outage cannot be attributed. *)
let sqlite_error db operation rc =
  Printf.sprintf
    "%s: rc=%s extended_rc=%d detail=%s"
    operation
    (Sqlite3.Rc.to_string rc)
    (Sqlite3.extended_errcode_int db)
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
      ; batch_membership = None
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

let batch_execution_with_db db operation_id =
  with_statement db ~operation:"read batch membership"
    "SELECT execution_id, admitted_digest FROM operation_batch_members WHERE operation_id = ?" (fun stmt ->
      let* () = bind_text db stmt ~operation:"bind member id" 1 (Id.to_string operation_id) in
      let rc = Sqlite3.step stmt in
      if rc = Sqlite3.Rc.DONE then Ok None
      else if rc = Sqlite3.Rc.ROW then
          let* execution_id = Id.of_string (Sqlite3.column_text stmt 0)
            |> Result.map_error (fun detail -> Integrity_error detail) in
          let* input_digest = validate_digest "batch admitted digest" (Sqlite3.column_text stmt 1) in
          Ok (Some { Operation.execution_id; input_digest })
      else Error (Store_unavailable (sqlite_error db "read batch membership" rc)))
;;
let project_batch_with_db db (operation : Operation.t) =
  let* batch_membership = batch_execution_with_db db operation.operation_id in
  match batch_membership with
  | None -> Ok operation
  | Some { Operation.execution_id; _ } ->
    let* leader = get_with_db db execution_id in
    (match leader with
     | None -> Error (Integrity_error "batch execution owner is missing")
     | Some leader ->
       let* () = if Operation.is_terminal operation.state && operation.state <> leader.state
         then Error (Integrity_error "batch member terminal fact disagrees with execution") else Ok () in
       Ok { operation with batch_membership; state = leader.state;
         input = if Operation.is_terminal leader.state then None else operation.input })
;;
let get store operation_id =
  let* () = ensure_open store in
  let* operation = get_with_db store.db operation_id in
  match operation with None -> Ok None
  | Some operation -> project_batch_with_db store.db operation |> Result.map Option.some
;;

let list_restart_interrupted store =
  let* () = ensure_open store in
  with_statement store.db ~operation:"read durable restart interruptions"
    ("SELECT " ^ select_columns ^ " FROM operations WHERE state = 'failed' AND failure_kind = ? ORDER BY sequence")
    (fun stmt ->
      let* () = bind_text store.db stmt ~operation:"bind restart failure kind" 1
        (Operation.failure_kind_to_string Operation.Interrupted_by_restart) in
      let rec read acc =
        let rc = Sqlite3.step stmt in
        if rc = Sqlite3.Rc.DONE then Ok (List.rev acc)
        else if rc = Sqlite3.Rc.ROW then
          let* operation = decode_operation stmt in
          read (operation :: acc)
        else Error (Store_unavailable (sqlite_error store.db "read durable restart interruptions" rc)) in
      read [])
;;
let batch_operations store ~operation_id =
  let* () = ensure_open store in
  let* execution_id = batch_execution_with_db store.db operation_id in
  match execution_id with
  | None -> let* operation = get store operation_id in
      (match operation with Some operation -> Ok [operation] | None -> Error (Unknown_operation operation_id))
  | Some { Operation.execution_id; _ } ->
    let* ids = with_statement store.db ~operation:"read ordered batch"
      "SELECT operation_id, admitted_input_json, admitted_digest FROM operation_batch_members WHERE execution_id = ? ORDER BY position" (fun stmt ->
        let* () = bind_text store.db stmt ~operation:"bind execution id" 1 (Id.to_string execution_id) in
        let rec read acc =
          let rc = Sqlite3.step stmt in
          if rc = Sqlite3.Rc.DONE then Ok (List.rev acc)
          else if rc = Sqlite3.Rc.ROW then let* id = Id.of_string (Sqlite3.column_text stmt 0)
              |> Result.map_error (fun detail -> Integrity_error detail) in
              let* original_input = match text_option stmt 1 with None -> Ok None
                | Some json -> json_of_stored "batch original input" json |> Result.map Option.some in
              let* digest = validate_digest "batch admitted digest" (Sqlite3.column_text stmt 2) in
              let* () = match original_input with
                | None -> Ok ()
                | Some input -> let* actual = Operation.execution_digest input |> Result.map_error (fun detail -> Integrity_error detail) in
                  if actual = digest then Ok () else Error (Integrity_error "batch original input digest mismatch") in
              read ((id, original_input, digest) :: acc)
          else Error (Store_unavailable (sqlite_error store.db "read ordered batch" rc)) in read []) in
    List.fold_left (fun result (id, original_input, digest) -> let* acc = result in
      let* operation = get store id in match operation with
      | Some operation ->
        if Option.is_none original_input && not (Operation.is_terminal operation.state)
        then Error (Integrity_error "active batch lost original input")
        else Ok ({operation with input=original_input; execution_digest=digest} :: acc)
      | None -> Error (Integrity_error "batch member is missing")) (Ok []) ids |> Result.map List.rev
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
      "SELECT COUNT(*) FROM operations WHERE state = 'queued' AND NOT EXISTS (SELECT 1 FROM operation_batch_members b WHERE b.operation_id = operations.operation_id AND b.execution_id <> b.operation_id)"
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
  let* () = List.fold_left (fun result (_, name, sql) ->
    let* () = result in exec db ~operation:("create " ^ name) sql) (Ok ()) batch_schema_objects in
  let* () = exec db ~operation:"create input checkpoint ownership" input_checkpoint_table_sql in
  let* () = exec db ~operation:"create input history floor" input_history_table_sql in
  let* () = exec db ~operation:"initialize fresh input history"
    "INSERT INTO input_history(singleton, basis) VALUES (1, 'fresh')" in
  let* () =
    exec
      db
      ~operation:"initialize operation sequence"
      "INSERT INTO metadata(singleton, schema, next_sequence) VALUES (1, 'masc.keeper_chat_operations.v3', 0)"
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
let input_history_with_db db =
  let* basis = single_text db ~operation:"read input history floor"
    "SELECT basis FROM input_history WHERE singleton=1" in
  match basis with
  | "fresh" -> Ok Fresh_input_history
  | "prior_unavailable" -> Ok Prior_input_history_unavailable
  | _ -> Error (Integrity_error "input history floor is unknown")

let validate_schema db =
  let* () = validate_schema_with ~version:database_user_version ~schema_identity:database_schema
    ~objects:expected_schema_objects db in
  let* _history = input_history_with_db db in
  Ok ()
;;

let configure db =
  (* Boot opens several stores at once; a sibling writer holding the lock for
     a moment must be waited out. Without this, the first concurrent commit
     returns SQLITE_BUSY and the Owner fences chat for the rest of the
     process (install smoke, 2026-09-14). Same contract as
     keeper_tool_call_index and tool_metrics_store. *)
  let* () = exec db ~operation:"set busy timeout" "PRAGMA busy_timeout=5000" in
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
  else validate_schema db
;;

let open_or_create ~path =
  let db = Sqlite3.db_open path in
  let fail error =
    (* See open failure contract: preserve the typed store error; close is best-effort. *)
    ignore (close_db db : bool);
    Error error
  in
  let initialize_or_validate () =
    (* Reject unknown/corrupt contracts before changing journaling pragmas. *)
    let* () = validate_open_candidate db in
    let* () = configure db in
    let* () = exec db ~operation:"begin operation schema transaction" "BEGIN IMMEDIATE" in
    let body () =
      (* Recheck after acquiring the writer lock; another opener may already
         have initialized the candidate observed above. *)
      let* () = validate_open_candidate db in
      let* count = single_int64 db ~operation:"read locked schema" "SELECT COUNT(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'" in
      let* () = if count = 0L then initialize_schema db else validate_schema db in
      let* () = validate_schema db in
      commit db
    in
    match body () with
    | Ok () -> Ok ()
    | Error _ as error -> rollback db; error
  in
  match initialize_or_validate () with
  | Ok () -> Ok { db; path; closed = Atomic.make false; dropped = Atomic.make []; released = Atomic.make [] }
  | Error error -> fail error
;;

let open_existing ~path =
  match Sqlite3.db_open ~mode:`NO_CREATE path with
  | exception Sqlite3.Error detail -> Error (Store_unavailable detail)
  | db ->
    let result =
      let* () = validate_schema db in
      let* () = configure db in
      Ok { db; path; closed = Atomic.make false; dropped = Atomic.make []; released = Atomic.make [] }
    in
    (match result with
     | Ok _ -> result
     | Error error ->
       (* Failed candidates never become the Owner's active handle. *)
       (* See open failure contract: preserve the typed store error; close is best-effort. *)
       ignore (close_db db : bool);
       Error error)
;;

(* Whether this handle still names a live database. [close] is idempotent and
   every command is guarded by [ensure_open], so a closed handle cannot corrupt
   anything -- but a caller that holds one and knows why it was closed can say
   so instead of letting "database handle is closed" stand for the cause. *)
let is_open store = not (Atomic.get store.closed)

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

let read_semantic_rows db ~operation ~where ~keep =
  with_statement db ~operation
    ("SELECT scope_key, revision, phase, record_json FROM semantic_executions" ^ where
     ^ " ORDER BY scope_key")
    (fun stmt ->
      let rec loop acc =
        let rc = Sqlite3.step stmt in
        if rc = Sqlite3.Rc.DONE then Ok (List.rev acc)
        else if rc = Sqlite3.Rc.ROW then
            let* execution = decode_semantic stmt in
            loop (if keep execution then execution :: acc else acc)
        else Error (Store_unavailable (sqlite_error db operation rc))
      in loop [])
;;

let semantic_rows db ~active_only =
  (* The denormalized phase is not authority before validation: a damaged
     index must not hide an outstanding operation. *)
  read_semantic_rows db ~operation:"read semantic executions" ~where:""
    ~keep:(fun execution -> not (active_only && Semantic.is_terminal execution))
;;

let decode_input_checkpoint stmt =
  let* trace_id = Keeper_id.Trace_id.of_string (Sqlite3.column_text stmt 0)
    |> Result.map_error (fun detail -> Integrity_error ("input checkpoint trace: " ^ detail)) in
  let turn_count = Sqlite3.column_int64 stmt 1 in
  if turn_count < 0L || turn_count > Int64.of_int max_int then
    Error (Integrity_error "input checkpoint turn is outside the host integer range")
  else Keeper_checkpoint_ref.of_persisted ~trace_id ~turn_count:(Int64.to_int turn_count)
    ~sha256:(Sqlite3.column_text stmt 2)
    |> Result.map_error (function
      | Keeper_checkpoint_ref.Negative_turn_count turn ->
        Integrity_error (Printf.sprintf "input checkpoint trace %s has negative turn %d"
          (Keeper_id.Trace_id.to_string trace_id) turn)
      | Keeper_checkpoint_ref.Invalid_sha256 digest ->
        Integrity_error (Printf.sprintf "input checkpoint trace %s has invalid SHA-256 %S"
          (Keeper_id.Trace_id.to_string trace_id) digest))

let input_checkpoint_with_db db ~trace_id =
  with_statement db ~operation:"read current input checkpoint"
    "SELECT trace_id, turn_count, sha256 FROM input_checkpoints WHERE trace_id = ?" (fun stmt ->
      let* () = bind_text db stmt ~operation:"bind input checkpoint trace" 1
        (Keeper_id.Trace_id.to_string trace_id) in
      let rc = Sqlite3.step stmt in
      if rc = Sqlite3.Rc.DONE then Ok None
      else if rc = Sqlite3.Rc.ROW then
        let* reference = decode_input_checkpoint stmt in
        let* () = expect_done db stmt ~operation:"finish input checkpoint lookup" in
        Ok (Some reference)
      else Error (Store_unavailable (sqlite_error db "read input checkpoint" rc)))

let input_observation_with_db db ~trace_id =
  let* reference = input_checkpoint_with_db db ~trace_id in
  let* history = input_history_with_db db in
  match reference, history with
  | Some reference, (Fresh_input_history | Prior_input_history_unavailable) -> Ok (Input_observed reference)
  | None, Fresh_input_history -> Ok Input_unobserved
  | None, Prior_input_history_unavailable -> Ok Prior_input_unavailable

let input_predecessor_matches observed = function
  | Prior_input_unavailable -> false
  | Input_unobserved -> Option.is_none observed
  | Input_observed current -> Option.equal Keeper_checkpoint_ref.equal observed (Some current)

let input_checkpoint_rows db =
  with_statement db ~operation:"inspect input checkpoints"
    "SELECT trace_id, turn_count, sha256 FROM input_checkpoints ORDER BY trace_id" (fun stmt ->
      let rec read acc =
        let rc = Sqlite3.step stmt in
        if rc = Sqlite3.Rc.DONE then Ok (List.rev acc)
        else if rc = Sqlite3.Rc.ROW then
          let* reference = decode_input_checkpoint stmt in read (reference::acc)
        else Error (Store_unavailable (sqlite_error db "inspect input checkpoints" rc))
      in read [])

(* Executions whose checkpoint references keep retained files alive: every
   nonterminal execution, and a settled one that still holds a native-call
   receipt. The startup sweep's inspection and a native-call commit's release
   both select with this, so they treat the same files as live. *)
let owns_checkpoint_references (execution : Semantic.t) =
  not (Semantic.is_terminal execution) || match execution.native_call with
  | Keeper_native_call.No_native_call -> false
  | Keeper_native_call.Active _ | Keeper_native_call.Terminal_unacknowledged _ -> true
;;

(* The executions that own checkpoint references, for a commit's release.
   Settled rows are never deleted, so this does not decode them all: SQL skips
   a row whose stored record is settled and has no native call, which names no
   checkpoint. It reads the record itself, not the denormalized phase column,
   and [owns_checkpoint_references] stays the authority on what is decoded. *)
let owning_semantic_rows db =
  read_semantic_rows db ~operation:"read semantic executions owning checkpoints"
    ~where:" WHERE json_extract(record_json, '$.phase.kind') IS NOT 'settled' \
            OR json_extract(record_json, '$.native_call') IS NOT NULL"
    ~keep:owns_checkpoint_references
;;

(* [update_semantic] records the references one write stopped naming. *)
let record_dropped store ~before ~after =
  let named = List.map (fun (reference : Keeper_checkpoint_ref.t) -> reference.sha256)
      (Semantic.checkpoint_references after) in
  match List.filter (fun (reference : Keeper_checkpoint_ref.t) ->
      not (List.mem reference.sha256 named)) (Semantic.checkpoint_references before) with
  | [] -> ()
  | dropped -> Atomic.set store.dropped (Atomic.get store.dropped @ dropped)
;;

(* The files the open transaction releases: each dropped reference whose
   sha256 no execution owning references still names after all its writes,
   once per file. A retained file is named by its sha256, and the startup
   sweep keys liveness the same way over the same selection. The sweep reads
   every keeper's store and this reads one: the hashed bytes carry the
   checkpoint's session id, which is the keeper's trace id, so another
   keeper's executions cannot name the same sha256. The agent name in the
   bytes does not separate keepers; it names the runtime. *)
let released_by_transaction store =
  let* history = input_history_with_db store.db in
  let dropped = Atomic.exchange store.dropped [] in
  match history, dropped with
  | Prior_input_history_unavailable, _ -> Ok []
  | Fresh_input_history, [] -> Ok []
  | Fresh_input_history, dropped ->
    let* rows = owning_semantic_rows store.db in
    let* input_checkpoints = input_checkpoint_rows store.db in
    let live = input_checkpoints @ List.concat_map Semantic.checkpoint_references rows
      |> List.map (fun (reference : Keeper_checkpoint_ref.t) -> reference.sha256) in
    let same_file (left : Keeper_checkpoint_ref.t) (right : Keeper_checkpoint_ref.t) =
      String.equal left.sha256 right.sha256 in
    Ok (List.fold_left (fun released (retained : Keeper_checkpoint_ref.t) ->
        if List.mem retained.sha256 live || List.exists (same_file retained) released
        then released else retained :: released) [] dropped |> List.rev)
;;

(* Run [f] as one transaction. Only a COMMIT that returned success publishes
   what the transaction released; a failed or uncertain commit releases
   nothing, and the startup sweep removes what it left. *)
let in_transaction store ~begin_operation ~store_error f =
  let* () = exec store.db ~operation:begin_operation "BEGIN IMMEDIATE" |> Result.map_error store_error in
  Atomic.set store.dropped [];
  let committed = match f () with
    | Error _ as error -> error
    | Ok value ->
      let* released = released_by_transaction store |> Result.map_error store_error in
      let* () = commit store.db |> Result.map_error store_error in
      Ok (value, released) in
  Atomic.set store.dropped [];
  match committed with
  | Ok (value, released) ->
    Atomic.set store.released (Atomic.get store.released @ released);
    Ok value
  | Error _ as error -> rollback store.db; error
;;

let with_transaction store f =
  let* () = ensure_open store in
  in_transaction store ~begin_operation:"begin operation transaction" ~store_error:Fun.id f
;;

type input_checkpoint_update =
  | Input_checkpoint_updated
  | Input_checkpoint_source_changed of input_checkpoint_observation

let input_checkpoint store ~trace_id =
  let* () = ensure_open store in
  input_observation_with_db store.db ~trace_id

let install_input_checkpoint_with_db store ~previous checkpoint =
  let* () = with_statement store.db ~operation:"install input checkpoint"
    "INSERT INTO input_checkpoints(trace_id, turn_count, sha256) VALUES (?, ?, ?) ON CONFLICT(trace_id) DO UPDATE SET turn_count=excluded.turn_count, sha256=excluded.sha256" (fun stmt ->
      let* () = bind_text store.db stmt ~operation:"bind input trace" 1
        (Keeper_id.Trace_id.to_string checkpoint.Keeper_checkpoint_ref.trace_id) in
      let* () = bind_int64 store.db stmt ~operation:"bind input turn" 2
        (Int64.of_int checkpoint.turn_count) in
      let* () = bind_text store.db stmt ~operation:"bind input digest" 3 checkpoint.sha256 in
      expect_done store.db stmt ~operation:"install input checkpoint") in
  match previous with
  | None -> Ok ()
  | Some reference when Keeper_checkpoint_ref.equal reference checkpoint -> Ok ()
  | Some reference ->
    (* This non-yielding append belongs to the serialized write transaction,
       like [record_dropped]. Atomic storage does not grant concurrent writers. *)
    Atomic.set store.dropped (Atomic.get store.dropped @ [reference]);
    Ok ()

let check_input_predecessor ~observed ~checkpoint =
  match observed with
  | Some previous when not (Keeper_id.Trace_id.equal previous.Keeper_checkpoint_ref.trace_id
        checkpoint.Keeper_checkpoint_ref.trace_id) ->
    Error (Invalid_input "input checkpoint predecessor belongs to another trace")
  | Some previous when checkpoint.Keeper_checkpoint_ref.turn_count < previous.Keeper_checkpoint_ref.turn_count ->
    Error (Invalid_input "input checkpoint turn regressed")
  | Some _ | None -> Ok ()

let update_input_checkpoint store ~observed ~checkpoint =
  let* () = ensure_open store in
  let* () = check_input_predecessor ~observed ~checkpoint in
  with_transaction store (fun () ->
    let* previous = input_observation_with_db store.db ~trace_id:checkpoint.Keeper_checkpoint_ref.trace_id in
    if not (input_predecessor_matches observed previous) then
      Ok (Input_checkpoint_source_changed previous)
    else
      let previous = match previous with Input_observed ref -> Some ref
        | Input_unobserved | Prior_input_unavailable -> None in
      let* () = install_input_checkpoint_with_db store ~previous checkpoint in
      Ok Input_checkpoint_updated)

(* A terminal semantic phase alone cannot settle a native effect. Read every
   original record so unknown-effect calls on terminal rows are not hidden. *)
let require_history_clear_quiescence store =
  let* inventory = inventory store in
  let* rows = semantic_rows store.db ~active_only:false in
  let unsettled execution =
    not (Semantic.is_terminal execution) ||
    match execution.Semantic.native_call with
    | Keeper_native_call.No_native_call -> false
    | Active _ | Terminal_unacknowledged _ -> true in
  if Option.is_some inventory.running_operation_id || List.exists unsettled rows then
    Error (Invalid_input "history clear requires settled semantic and native execution; reconcile outstanding effects first")
  else Ok ()

let history_clear_input_checkpoint store ~trace_id =
  with_transaction store (fun () ->
    let* () = require_history_clear_quiescence store in
    let* observed = input_observation_with_db store.db ~trace_id in
    match observed with
    | Input_observed reference -> Ok (Some reference)
    | Input_unobserved -> Ok None
    | Prior_input_unavailable -> Error (Invalid_input
        "prior input history is unavailable; reconcile before clearing history"))

let commit_history_clear_input_checkpoint store ~trace_id ~observed ~checkpoint =
  let* () = match checkpoint,observed with
    | None,Some _ -> Error (Invalid_input "history clear cannot forget an observed input")
    | None,None -> Ok ()
    | Some checkpoint,(Some _ | None) ->
      if not (Keeper_id.Trace_id.equal trace_id checkpoint.Keeper_checkpoint_ref.trace_id)
      then Error (Invalid_input "history clear checkpoint belongs to another trace")
      else check_input_predecessor ~observed ~checkpoint in
  with_transaction store (fun () ->
    let* () = require_history_clear_quiescence store in
    let* previous = input_observation_with_db store.db ~trace_id in
    if not (input_predecessor_matches observed previous) then
      Ok (Input_checkpoint_source_changed previous)
    else match checkpoint with
    | None -> Ok Input_checkpoint_updated
    | Some checkpoint ->
      let* () = install_input_checkpoint_with_db store ~previous:observed checkpoint in
      Ok Input_checkpoint_updated)

let register_created_input_checkpoint store ~checkpoint =
  let* () = ensure_open store in
  with_transaction store (fun () ->
    let* previous = input_observation_with_db store.db ~trace_id:checkpoint.Keeper_checkpoint_ref.trace_id in
    match previous with
    | Input_observed reference when not (Keeper_checkpoint_ref.equal reference checkpoint) ->
      Ok (Input_checkpoint_source_changed previous)
    | Input_observed _ -> Ok Input_checkpoint_updated
    | Input_unobserved | Prior_input_unavailable ->
      let* () = install_input_checkpoint_with_db store ~previous:None checkpoint in
      Ok Input_checkpoint_updated)

type released_checkpoint = Keeper_checkpoint_ref.t
let take_released_checkpoints store = Atomic.exchange store.released []
let released_reference (released : released_checkpoint) = released
let released_session_dir ~session_root (released : released_checkpoint) =
  Filename.concat session_root (Keeper_id.Trace_id.to_string released.trace_id)

type inspection_scope =
  | Outstanding_integrity_audit
  | Pending_inputs
  | All_durable_records

let read_batch_member_inputs db =
  with_statement db ~operation:"inspect durable batch member inputs"
    "SELECT admitted_input_json, admitted_digest FROM operation_batch_members WHERE admitted_input_json IS NOT NULL ORDER BY execution_id, position"
    (fun stmt ->
      let rec read acc =
        let rc = Sqlite3.step stmt in
        if rc = Sqlite3.Rc.DONE then Ok (List.rev acc)
        else if rc = Sqlite3.Rc.ROW then
          let* input = json_of_stored "batch original input" (Sqlite3.column_text stmt 0) in
          let* digest = validate_digest "batch admitted digest" (Sqlite3.column_text stmt 1) in
          let* actual = Operation.execution_digest input |> Result.map_error (fun detail -> Integrity_error detail) in
          if actual = digest then read (input :: acc)
          else Error (Integrity_error "batch original input digest mismatch")
        else Error (Store_unavailable (sqlite_error db "inspect durable batch member inputs" rc))
      in read [])
;;

let inspect_store_with ~scope ~path =
  let inspect db =
    let* () = exec db ~operation:"begin read-only inspection" "BEGIN" in
    let* () = validate_schema db in
    let* () = match scope with
      | Pending_inputs -> Ok ()
      | Outstanding_integrity_audit | All_durable_records ->
        let* integrity = single_text db ~operation:"check operation store integrity" "PRAGMA quick_check" in
        if String.equal integrity "ok" then Ok () else Error (Integrity_error integrity) in
    let* chat_operations =
      with_statement db ~operation:"inspect durable operations"
        ("SELECT " ^ select_columns ^ " FROM operations"
         ^ (match scope with Pending_inputs -> " WHERE state IN ('queued', 'running')"
            | Outstanding_integrity_audit | All_durable_records -> "") ^ " ORDER BY sequence")
        (fun stmt ->
          let rec read acc =
            let rc = Sqlite3.step stmt in
            if rc = Sqlite3.Rc.DONE then Ok (List.rev acc)
            else if rc = Sqlite3.Rc.ROW then
              let* operation = decode_operation stmt in
              let* operation = project_batch_with_db db operation in
              let keep = match scope with
                | All_durable_records -> true
                | Outstanding_integrity_audit | Pending_inputs -> not (Operation.is_terminal operation.state) in
              read (if keep then operation :: acc else acc)
            else Error (Store_unavailable (sqlite_error db "inspect durable operations" rc))
          in read [])
    in
    let* batch_member_inputs =
      match scope with
      | All_durable_records -> read_batch_member_inputs db
      | Outstanding_integrity_audit | Pending_inputs -> Ok []
    in
    let* semantic_executions = match scope with
      | Pending_inputs -> Ok []
      | All_durable_records -> semantic_rows db ~active_only:false
      | Outstanding_integrity_audit -> let* rows = semantic_rows db ~active_only:false in
        Ok (List.filter owns_checkpoint_references rows) in
    let* input_history = input_history_with_db db in
    let* input_checkpoints = match scope with
      | Pending_inputs -> Ok []
      | All_durable_records | Outstanding_integrity_audit -> input_checkpoint_rows db in
    let* () = exec db ~operation:"end read-only inspection" "COMMIT" in
    Ok (Some (chat_operations, batch_member_inputs, semantic_executions, input_checkpoints, input_history))
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
      | [] -> Ok None
      | suffix :: rest ->
        (match Unix.lstat (path ^ suffix) with
         | _ -> Error (Integrity_error "operation journal exists without its database")
         | exception Unix.Unix_error (Unix.ENOENT, _, _) -> absent_companions rest
         | exception Unix.Unix_error (error, _, _) -> Error (Store_unavailable (Unix.error_message error)))
    in absent_companions [ "-journal"; "-wal"; "-shm" ]
  | exception Unix.Unix_error (error, _, _) -> Error (Store_unavailable (Unix.error_message error))
;;

let inspect_outstanding ~path =
  inspect_store_with ~scope:Outstanding_integrity_audit ~path |> Result.map (function
    | None -> Missing_store
    | Some (chat_operations, _batch_member_inputs, semantic_executions, input_checkpoints, input_history) ->
      Stored_operations { chat_operations; semantic_executions; input_checkpoints; input_history })
;;

let inspect_durable_records ~path =
  inspect_store_with ~scope:All_durable_records ~path |> Result.map (function
    | None -> Missing_durable_store
    | Some (chat_operations, batch_member_inputs, semantic_executions, input_checkpoints, input_history) ->
      Stored_durable_records { chat_operations; batch_member_inputs; semantic_executions; input_checkpoints; input_history })
;;

let inspect_pending_inputs ~path =
  inspect_store_with ~scope:Pending_inputs ~path |> Result.map (function
    | None -> None
    | Some (chat_operations, _, _, _, _) -> Some chat_operations)
;;


module Offline = struct
  type prepared_copy =
    { operation_count : int; semantic_count : int; batch_member_count : int
    ; next_sequence : int64 }

  (* Legacy shape is accepted only at this explicit copy boundary. Runtime
     open/inspection retain the mandatory current generation and history floor. *)
  let v2_metadata_sql =
    "CREATE TABLE metadata (singleton INTEGER PRIMARY KEY CHECK (singleton = 1), schema TEXT NOT NULL CHECK (schema = 'masc.keeper_chat_operations.v2'), next_sequence INTEGER NOT NULL CHECK (next_sequence >= 0)) STRICT"
  let v2_objects =
    List.sort compare
      (List.map (function
         | "table", "metadata", _ -> "table", "metadata", v2_metadata_sql
         | other -> other) chat_schema_objects @ semantic_schema_objects @ batch_schema_objects)

  let raw_rows db table order =
    with_statement db ~operation:("snapshot offline " ^ table)
      ("SELECT * FROM " ^ table ^ " ORDER BY " ^ order) (fun stmt ->
        let rec read acc =
          let rc = Sqlite3.step stmt in
          if rc=Sqlite3.Rc.DONE then Ok (List.rev acc)
          else if rc=Sqlite3.Rc.ROW then
            let row = List.init (Sqlite3.column_count stmt) (Sqlite3.column stmt) in
            read (row::acc)
          else Error (Store_unavailable (sqlite_error db "snapshot offline rows" rc)) in
        read [])

  let raw_snapshot db =
    let* operations = raw_rows db "operations" "sequence" in
    let* semantics = raw_rows db "semantic_executions" "scope_key" in
    let* batches = raw_rows db "operation_batch_members" "operation_id" in
    let* sequence = single_int64 db ~operation:"snapshot offline sequence"
      "SELECT next_sequence FROM metadata WHERE singleton=1" in
    Ok (operations, semantics, batches, sequence)

  let validate_payloads db =
    let* integrity = single_text db ~operation:"check offline integrity" "PRAGMA quick_check" in
    let* () = if integrity = "ok" then Ok () else Error (Integrity_error integrity) in
    let* () = with_statement db ~operation:"check offline foreign keys" "PRAGMA foreign_key_check"
      (fun stmt -> let rc = Sqlite3.step stmt in
       if rc=Sqlite3.Rc.DONE then Ok ()
       else if rc=Sqlite3.Rc.ROW then Error (Integrity_error "offline journal has foreign key violations")
       else Error (Store_unavailable (sqlite_error db "check offline foreign keys" rc))) in
    let* () = with_statement db ~operation:"validate offline operation payloads"
      ("SELECT " ^ select_columns ^ " FROM operations ORDER BY sequence") (fun stmt ->
        let rec read () = let rc = Sqlite3.step stmt in
          if rc=Sqlite3.Rc.DONE then Ok ()
          else if rc=Sqlite3.Rc.ROW then let* operation = decode_operation stmt in
            let* _ = project_batch_with_db db operation in read ()
          else Error (Store_unavailable (sqlite_error db "validate offline operations" rc)) in
        read ()) in
    let* _ = read_batch_member_inputs db in
    let* _ = semantic_rows db ~active_only:false in
    let* next_sequence = single_int64 db ~operation:"validate offline next sequence"
      "SELECT next_sequence FROM metadata WHERE singleton=1" in
    let* last_sequence = single_int64 db ~operation:"validate offline existing sequences"
      "SELECT COALESCE(MAX(sequence), -1) FROM operations" in
    if Int64.compare next_sequence last_sequence > 0 then Ok ()
    else Error (Integrity_error "offline next operation sequence overlaps existing evidence")

  let backup ~source ~destination =
    let backup = Sqlite3.Backup.init ~dst:destination ~dst_name:"main" ~src:source ~src_name:"main" in
    let finished = ref Sqlite3.Rc.OK in
    let result = Fun.protect
      ~finally:(fun () -> finished := Sqlite3.Backup.finish backup)
      (fun () -> let rc = Sqlite3.Backup.step backup (-1) in
        if rc=Sqlite3.Rc.DONE then Ok ()
        else Error (Store_unavailable (sqlite_error destination "copy offline journal" rc))) in
    let* () = result in
    if !finished = Sqlite3.Rc.OK then Ok ()
    else Error (Store_unavailable (sqlite_error destination "finish offline journal copy" !finished))

  let prepare_v2_copy ~source ~destination =
    let prepare () =
      let* objects = read_schema_objects destination in
      let* application = single_int64 destination ~operation:"check empty copy application" "PRAGMA application_id" in
      let* version = single_int64 destination ~operation:"check empty copy generation" "PRAGMA user_version" in
      let* () = if source != destination && objects=[] && application=0L && version=0L then Ok ()
        else Error (Invalid_input "offline destination must be a distinct reserved empty database") in
      let* () = exec source ~operation:"begin offline source snapshot" "BEGIN" in
      Fun.protect ~finally:(fun () -> rollback source) (fun () ->
        let* () = validate_schema_with ~version:2L ~schema_identity:"masc.keeper_chat_operations.v2"
          ~objects:v2_objects source in
        let* () = validate_payloads source in
        let* before = raw_snapshot source in
        let* () = backup ~source ~destination in
        let* () = configure destination in
        let* () = exec destination ~operation:"begin offline copy transformation" "BEGIN IMMEDIATE" in
        Fun.protect ~finally:(fun () -> rollback destination) (fun () ->
          let* operations, semantics, batches, next_sequence = raw_snapshot destination in
          let* () = if before=(operations,semantics,batches,next_sequence) then Ok ()
            else Error (Integrity_error "offline backup changed journal evidence") in
          let* () = exec destination ~operation:"replace offline metadata" "DROP TABLE metadata" in
          let* () = exec destination ~operation:"create current offline metadata" metadata_table_sql in
          let* () = with_statement destination ~operation:"preserve offline sequence"
            "INSERT INTO metadata(singleton, schema, next_sequence) VALUES (1, 'masc.keeper_chat_operations.v3', ?)"
            (fun stmt -> let* () = bind_int64 destination stmt ~operation:"bind offline sequence" 1 next_sequence in
              expect_done destination stmt ~operation:"preserve offline sequence") in
          let* () = exec destination ~operation:"create offline input ownership" input_checkpoint_table_sql in
          let* () = exec destination ~operation:"create unavailable prior input history" input_history_table_sql in
          let* () = exec destination ~operation:"preserve prior input uncertainty"
            "INSERT INTO input_history(singleton, basis) VALUES (1, 'prior_unavailable')" in
          let* () = exec destination ~operation:"set prepared journal generation" "PRAGMA user_version=3" in
          let* () = validate_schema destination in
          let* () = validate_payloads destination in
          let* after = raw_snapshot destination in
          let* () = if before=after then Ok () else Error (Integrity_error "offline preparation changed original evidence") in
          let* () = commit destination in
          Ok {operation_count=List.length operations;semantic_count=List.length semantics;
            batch_member_count=List.length batches;next_sequence}))
    in
    try prepare () with
    | Sqlite3.Error detail | Sqlite3.SqliteError detail -> Error (Store_unavailable detail)

  let verify_v2_copy ~source ~destination =
    let verify () =
      let* () = if source != destination then Ok ()
        else Error (Invalid_input "offline verification requires distinct source and copy") in
      let* () = exec source ~operation:"begin original journal verification" "BEGIN" in
      Fun.protect ~finally:(fun () -> rollback source) (fun () ->
        let* () = validate_schema_with ~version:2L ~schema_identity:"masc.keeper_chat_operations.v2"
          ~objects:v2_objects source in
        let* () = validate_payloads source in
        let* before = raw_snapshot source in
        let* () = exec destination ~operation:"begin prepared journal verification" "BEGIN" in
        Fun.protect ~finally:(fun () -> rollback destination) (fun () ->
          let* () = validate_schema destination in
          let* () = validate_payloads destination in
          let* history = input_history_with_db destination in
          let* inputs = input_checkpoint_rows destination in
          let* () = match history, inputs with
            | Prior_input_history_unavailable, [] -> Ok ()
            | Fresh_input_history, (_::_ | [])
            | Prior_input_history_unavailable, _::_ ->
              Error (Integrity_error "prepared journal must preserve unavailable input without imported rows") in
          let* (operations, semantics, batches, next_sequence) as after = raw_snapshot destination in
          if before=after then
            Ok {operation_count=List.length operations;semantic_count=List.length semantics;
              batch_member_count=List.length batches;next_sequence}
          else Error (Integrity_error "prepared journal changed original evidence"))) in
    try verify () with
    | Sqlite3.Error detail | Sqlite3.SqliteError detail -> Error (Store_unavailable detail)

  type prior_input_adoption = Operator_adopts_checkpoint of Keeper_checkpoint_ref.t
  type input_adoption_copy =
    { original_records : prepared_copy
    ; adopted_checkpoints : Keeper_checkpoint_ref.t list
    }

  let selected_inputs adoptions =
    let references = List.map (fun (Operator_adopts_checkpoint reference) -> reference) adoptions
      |> List.sort (fun (left : Keeper_checkpoint_ref.t) right ->
        String.compare (Keeper_id.Trace_id.to_string left.trace_id)
          (Keeper_id.Trace_id.to_string right.trace_id)) in
    let rec unique = function
      | first::(second::_ as rest) ->
        if Keeper_id.Trace_id.equal first.Keeper_checkpoint_ref.trace_id second.Keeper_checkpoint_ref.trace_id
        then Error (Invalid_input "prior input adoption selects a trace more than once")
        else unique rest
      | [_] | [] -> Ok () in
    match references with
    | [] -> Error (Invalid_input "prior input adoption requires an explicit nonempty selection")
    | _::_ -> let* () = unique references in Ok references

  let validate_adoption_inputs db expected =
    let* () = validate_schema db in
    let* () = validate_payloads db in
    let* history = input_history_with_db db in
    let* inputs = input_checkpoint_rows db in
    match history with
    | Fresh_input_history -> Error (Invalid_input "input adoption requires unavailable prior history")
    | Prior_input_history_unavailable ->
      if List.equal Keeper_checkpoint_ref.equal inputs expected then Ok ()
      else Error (Integrity_error "input adoption rows differ from the exact selection")

  let adoption_summary (operations, semantics, batches, next_sequence) adopted_checkpoints =
    { original_records = {operation_count=List.length operations;semantic_count=List.length semantics;
        batch_member_count=List.length batches;next_sequence}
    ; adopted_checkpoints }

  let insert_adopted_input db (reference : Keeper_checkpoint_ref.t) =
    with_statement db ~operation:"record explicitly adopted input checkpoint"
      "INSERT INTO input_checkpoints(trace_id, turn_count, sha256) VALUES (?, ?, ?)" (fun stmt ->
        let* () = bind_text db stmt ~operation:"bind adopted input trace" 1
          (Keeper_id.Trace_id.to_string reference.trace_id) in
        let* () = bind_int64 db stmt ~operation:"bind adopted input turn" 2
          (Int64.of_int reference.turn_count) in
        let* () = bind_text db stmt ~operation:"bind adopted input digest" 3 reference.sha256 in
        expect_done db stmt ~operation:"record explicitly adopted input checkpoint")

  let prepare_input_adoption_copy ~source ~destination ~adoptions =
    let prepare () =
      let* selected = selected_inputs adoptions in
      let* objects = read_schema_objects destination in
      let* application = single_int64 destination ~operation:"check adoption destination application" "PRAGMA application_id" in
      let* version = single_int64 destination ~operation:"check adoption destination generation" "PRAGMA user_version" in
      let* () = if source != destination && objects=[] && application=0L && version=0L then Ok ()
        else Error (Invalid_input "input adoption requires a distinct reserved empty destination") in
      let* () = exec source ~operation:"begin input adoption source snapshot" "BEGIN" in
      Fun.protect ~finally:(fun () -> rollback source) (fun () ->
        let* () = validate_adoption_inputs source [] in
        let* before = raw_snapshot source in
        let* () = backup ~source ~destination in
        let* () = configure destination in
        let* () = exec destination ~operation:"begin private input adoption" "BEGIN IMMEDIATE" in
        Fun.protect ~finally:(fun () -> rollback destination) (fun () ->
          let* () = validate_adoption_inputs destination [] in
          let rec insert = function
            | [] -> Ok ()
            | reference::rest -> let* () = insert_adopted_input destination reference in insert rest in
          let* () = insert selected in
          let* () = validate_adoption_inputs destination selected in
          let* after = raw_snapshot destination in
          let* () = if before=after then Ok ()
            else Error (Integrity_error "input adoption changed original execution evidence") in
          let* () = commit destination in
          Ok (adoption_summary before selected))) in
    try prepare () with
    | Sqlite3.Error detail | Sqlite3.SqliteError detail -> Error (Store_unavailable detail)

  let verify_input_adoption_copy ~source ~destination ~adoptions =
    let verify () =
      let* selected = selected_inputs adoptions in
      let* () = if source != destination then Ok ()
        else Error (Invalid_input "input adoption verification requires distinct handles") in
      let* () = exec source ~operation:"begin original input adoption verification" "BEGIN" in
      Fun.protect ~finally:(fun () -> rollback source) (fun () ->
        let* () = validate_adoption_inputs source [] in
        let* before = raw_snapshot source in
        let* () = exec destination ~operation:"begin derivative input adoption verification" "BEGIN" in
        Fun.protect ~finally:(fun () -> rollback destination) (fun () ->
          let* () = validate_adoption_inputs destination selected in
          let* after = raw_snapshot destination in
          if before=after then Ok (adoption_summary before selected)
          else Error (Integrity_error "input adoption derivative changed original execution evidence"))) in
    try verify () with
    | Sqlite3.Error detail | Sqlite3.SqliteError detail -> Error (Store_unavailable detail)
end

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

type batch_plan = { members : Id.t list; input : Yojson.Safe.t }
type batch_selector = Operation.t -> Operation.t list -> (batch_plan option, string) result

let prioritize_admission db select (incoming : Operation.t) =
  let* executions = semantic_rows db ~active_only:false in
  let* queued = with_statement db ~operation:"read admission queue"
    ("SELECT " ^ select_columns ^ " FROM operations WHERE state = 'queued' AND NOT EXISTS (SELECT 1 FROM operation_batch_members b WHERE b.operation_id = operations.operation_id AND b.execution_id <> b.operation_id) ORDER BY sequence")
    (fun stmt ->
      let rec read rows =
        let rc = Sqlite3.step stmt in
        if rc = Sqlite3.Rc.DONE then Ok (List.rev rows)
        else if rc = Sqlite3.Rc.ROW then let* row = decode_operation stmt in read (row :: rows)
        else Error (Store_unavailable (sqlite_error db "read admission queue" rc)) in
      read []) in
  let rec fresh rows = function
    | [] -> Ok (List.rev rows)
    | (row : Operation.t) :: rest ->
      let* binding = batch_execution_with_db db row.operation_id in
      let scoped = List.exists (fun (execution : Semantic.t) ->
        Keeper_execution_scope_id.equal execution.id
          (Keeper_execution_scope_id.direct_operation row.operation_id)) executions in
      fresh (if Option.is_some binding || scoped then rows else row :: rows) rest in
  let* candidates = fresh [] queued in
  let* plan = select incoming candidates |> Result.map_error (fun detail -> Invalid_input detail) in
  let members = match plan with None -> [incoming.operation_id] | Some plan -> plan.members in
  let selected = List.filter (fun (row : Operation.t) -> List.exists (Id.equal row.operation_id) members) candidates in
  let* () = if List.exists (Id.equal incoming.operation_id) members
      && List.map (fun (row : Operation.t) -> row.operation_id) selected = members
    then Ok () else Error (Invalid_input "interactive cohort must include the new request in existing queue order") in
  (* Keep the compatible cohort's accepted order, moving outsiders behind it.
     Insertion and every queue position commit together; a replay does neither. *)
  let rec move = function
    | [] -> Ok ()
    | (row : Operation.t) :: rest when List.exists (Id.equal row.operation_id) members -> move rest
    | row :: rest ->
      let* sequence = next_sequence db in
      let* () = with_statement db ~operation:"prioritize admitted cohort"
        "UPDATE operations SET sequence = ? WHERE operation_id = ? AND state = 'queued'"
        (fun stmt ->
          let* () = bind_int64 db stmt ~operation:"bind sequence" 1 sequence in
          let* () = bind_text db stmt ~operation:"bind operation" 2 (Id.to_string row.operation_id) in
          let* () = expect_done db stmt ~operation:"prioritize admitted cohort" in
          if Sqlite3.changes db = 1 then Ok () else Error (Not_queued row.operation_id)) in
      move rest in
  move queued

let submit ?priority store ~now ~operation_id ~source ~input =
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
        let* operation = project_batch_with_db store.db operation in
        Ok (Existing operation)
      | Some _ -> Error (Idempotency_conflict operation_id)
      | None ->
        let* sequence = next_sequence store.db in
        let operation =
          { Operation.operation_id
          ; batch_membership = None
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
        let* () = match priority with None -> Ok () | Some select -> prioritize_admission store.db select operation in
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
       | Integrity_error _
       | Native_call_unsettled ) -> Error commit_error)
;;

let reducer_error operation_id = function
  | Reducer.Not_queued -> Not_queued operation_id
  | Reducer.Not_running -> Not_running operation_id
  | Reducer.Invalid_input detail -> Invalid_input detail
;;

let operation_or_unknown db operation_id =
  let* operation = get_with_db db operation_id in
  match operation with
  | Some operation ->
    let* batch_membership = batch_execution_with_db db operation_id in
    Ok { operation with batch_membership }
  | None -> Error (Unknown_operation operation_id)
;;

let readback_exact store expected original_error =
  match get store expected.Operation.operation_id with
  | Ok (Some observed) when observed = expected -> Ok observed
  | Ok _ | Error _ -> Error original_error
;;

let persist_and_readback store expected persist =
  match with_transaction store persist with
  | Ok () ->
    (match get store expected.Operation.operation_id with
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
       | Integrity_error _
       | Native_call_unsettled ) -> Error error)
;;

let input_wait_state = function
  | Some {Semantic.phase=Semantic.Recovering {origin=Semantic.Input_wait waiting;_};_} -> Some waiting
  | Some {Semantic.phase=(Semantic.Preparing | Semantic.Ready | Semantic.Running
      | Semantic.Resuming_runtime_retry _ | Semantic.Resuming_gate _ | Semantic.Suspended _ | Semantic.Settled _
      | Semantic.Recovering {origin=(Semantic.Unconfirmed_sources | Semantic.Confirmed_undispatched
          | Semantic.Checkpointed _ | Semantic.Official_checkpointed _ | Semantic.Interrupted_execution
          | Semantic.Runtime_retry _ | Semantic.Gate_wait _ | Semantic.Gate_binding _);_});_}
  | None -> None

let gate_state = function
  | Some {Semantic.phase=Semantic.Recovering {origin=Semantic.Gate_wait state; _}; _} -> Some state
  | Some {Semantic.phase=(Semantic.Preparing | Semantic.Ready | Semantic.Running
      | Semantic.Resuming_runtime_retry _ | Semantic.Resuming_gate _ | Semantic.Suspended _ | Semantic.Settled _
      | Semantic.Recovering {origin=(Semantic.Runtime_retry _ | Semantic.Checkpointed _ | Semantic.Official_checkpointed _
          | Semantic.Unconfirmed_sources | Semantic.Confirmed_undispatched | Semantic.Interrupted_execution | Semantic.Gate_binding _ | Semantic.Input_wait _); _}); _}
  | None -> None

let blocked_queued_scopes db ~now =
  let* executions = semantic_rows db ~active_only:true in
  let blocked = List.filter_map (fun (execution : Semantic.t) ->
    match gate_state (Some execution) with
    | Some {resolution=None; _} -> Some execution.id
    | Some {resolution=Some _; _} -> None
    | None -> (match execution.phase with
        | Semantic.Recovering {origin=(Semantic.Gate_binding _ | Semantic.Input_wait _); _} -> Some execution.id
        (* A deferred runtime retry whose provider-throttle backoff is still
           running is not claimable: claiming it would re-issue the very call
           the provider just rejected, in a tight loop. The owner re-offers it once [not_before] passes or an exact
           live dependency witness commits a replacement wait. *)
        | Semantic.Recovering {origin=Semantic.Runtime_retry {Semantic.not_before=Some not_before; _}; _}
          when not_before > now -> Some execution.id
        | Semantic.Preparing | Semantic.Ready | Semantic.Running | Semantic.Resuming_runtime_retry _
        | Semantic.Resuming_gate _ | Semantic.Suspended _ | Semantic.Settled _
        | Semantic.Recovering {origin=(Semantic.Runtime_retry _ | Semantic.Gate_wait _ | Semantic.Checkpointed _ | Semantic.Official_checkpointed _
            | Semantic.Unconfirmed_sources | Semantic.Confirmed_undispatched | Semantic.Interrupted_execution); _} -> None)) executions in
  Ok blocked
;;

let claimable_queued_with_db db ~now =
  let* blocked = blocked_queued_scopes db ~now in
  with_statement db ~operation:"read claimable original operations"
    ("SELECT " ^ select_columns ^ " FROM operations WHERE state = 'queued' AND NOT EXISTS (SELECT 1 FROM operation_batch_members b WHERE b.operation_id = operations.operation_id AND b.execution_id <> b.operation_id) ORDER BY sequence")
    (fun statement ->
      let rec read () =
        let rc = Sqlite3.step statement in
        if rc = Sqlite3.Rc.DONE then Ok None
        else if rc = Sqlite3.Rc.ROW then
          let* operation = decode_operation statement in
          if List.exists (Keeper_execution_scope_id.equal
              (Keeper_execution_scope_id.direct_operation operation.operation_id)) blocked
          then read () else Ok (Some operation)
        else Error (Store_unavailable (sqlite_error db "read claimable original operations" rc)) in
      read ())

let has_claimable_queued store ~now =
  let* () = ensure_open store in
  claimable_queued_with_db store.db ~now |> Result.map Option.is_some

(* A direct turn may hand its slot to a later person's original input, but a
   yielded continuation must not make the next turn yield back to it. The
   operations table does not delete rows or VACUUM, so its insertion rowid
   keeps admission order even when queue priority or a checkpoint changes
   sequence. Wall-clock created_at can repeat or move backwards. A queued
   operation with a semantic execution has already been claimed and is a
   continuation, regardless of its current queue position. *)
let has_newer_original_queued store ~operation_id =
  let* () = ensure_open store in
  let* running = operation_or_unknown store.db operation_id in
  match running.Operation.state with
  | Operation.Queued | Operation.Succeeded _ | Operation.Failed _
  | Operation.Cancelled _ -> Error (Not_running operation_id)
  | Operation.Running _ ->
    with_statement store.db ~operation:"read newer original chat operations"
      ("SELECT " ^ select_columns ^ " FROM operations WHERE state = 'queued' "
       ^ "AND rowid > (SELECT rowid FROM operations WHERE operation_id = ?) "
       ^ "AND NOT EXISTS (SELECT 1 FROM operation_batch_members b "
       ^ "WHERE b.operation_id = operations.operation_id AND b.execution_id <> b.operation_id) "
       ^ "ORDER BY sequence")
      (fun statement ->
        let* () = bind_text store.db statement ~operation:"bind running admission identity"
          1 (Id.to_string operation_id) in
        let rec read () =
          let rc = Sqlite3.step statement in
          if rc = Sqlite3.Rc.DONE then Ok false
          else if rc = Sqlite3.Rc.ROW then
            let* candidate = decode_operation statement in
            let* execution = semantic_get_with_db store.db
              (Keeper_execution_scope_id.direct_operation candidate.operation_id) in
            (match execution with Some _ -> read () | None -> Ok true)
          else Error (Store_unavailable
            (sqlite_error store.db "read newer original chat operations" rc))
        in
        read ())
;;

(* The wake scheduled at defer time rides the process's pool switch and dies
   with it, and the Owner never polls: after a restart, a persisted future
   [not_before] would sit until an unrelated mailbox event unless the owner
   re-arms a wake for it. Several retries can be cooling at once (a cooling op
   is Queued, so another op can claim, defer, and cool behind it); the owner
   re-arms the earliest after start and after every drain wake, so each wake
   chains to the next. *)
let next_runtime_retry_wake store ~now =
  let* () = ensure_open store in
  semantic_rows store.db ~active_only:true
  |> Result.map (fun executions ->
    List.fold_left
      (fun earliest (execution : Semantic.t) ->
        match execution.phase with
        | Semantic.Recovering { origin; _ } ->
          (match origin with
           | Semantic.Runtime_retry retry ->
             (match retry.Semantic.not_before with
              | Some not_before when not_before > now ->
                (match earliest with
                 | Some current when current <= not_before -> earliest
                 | Some _ | None -> Some not_before)
              | Some _ | None -> earliest)
           | Semantic.Unconfirmed_sources | Semantic.Confirmed_undispatched
           | Semantic.Checkpointed _ | Semantic.Official_checkpointed _ | Semantic.Interrupted_execution
           | Semantic.Gate_wait _ | Semantic.Gate_binding _ | Semantic.Input_wait _ -> earliest)
        | Semantic.Preparing | Semantic.Ready | Semantic.Running
        | Semantic.Resuming_runtime_retry _ | Semantic.Resuming_gate _
        | Semantic.Suspended _ | Semantic.Settled _ -> earliest)
      None
      executions)


let freeze_batch_with_db db ~select (head : Operation.t) =
  let* executions = semantic_rows db ~active_only:false in
  let scoped operation = List.exists (fun (execution : Semantic.t) ->
    Keeper_execution_scope_id.equal execution.id
      (Keeper_execution_scope_id.direct_operation operation.Operation.operation_id)) executions in
  let* existing = batch_execution_with_db db head.operation_id in
  if Option.is_some existing || scoped head then Ok { head with batch_membership = existing }
  else
    let* queued = with_statement db ~operation:"read batch candidates"
      ("SELECT " ^ select_columns ^ " FROM operations WHERE state = 'queued' AND NOT EXISTS (SELECT 1 FROM operation_batch_members b WHERE b.operation_id = operations.operation_id AND b.execution_id <> b.operation_id) ORDER BY sequence")
      (fun stmt ->
        let rec read acc =
          let rc = Sqlite3.step stmt in
          if rc = Sqlite3.Rc.DONE then Ok (List.rev acc)
          else if rc = Sqlite3.Rc.ROW then let* operation = decode_operation stmt in
              read (operation :: acc)
          else Error (Store_unavailable (sqlite_error db "read batch candidates" rc)) in read []) in
    (* A continuation remains a queued turn in FIFO order even though it
       cannot join a fresh batch. Filtering it out before selection would let
       a later fresh message cross that turn and join the head's execution. *)
    let rec from_head = function
      | [] -> Ok []
      | (operation : Operation.t) :: rest as queued ->
        if Id.equal operation.operation_id head.operation_id
        then fresh_prefix [] queued
        else from_head rest
    and fresh_prefix acc = function
      | [] -> Ok (List.rev acc)
      | operation :: _ when scoped operation -> Ok (List.rev acc)
      | operation :: rest ->
        let* binding = batch_execution_with_db db operation.operation_id in
        if Option.is_some binding then Ok (List.rev acc)
        else fresh_prefix (operation :: acc) rest
    in
    let* candidates = from_head queued in
    let* plan = select head candidates |> Result.map_error (fun detail -> Invalid_input detail) in
    match plan with
    | None -> Ok head
    | Some plan ->
      let selected = List.filter (fun (operation : Operation.t) ->
        List.exists (Id.equal operation.operation_id) plan.members) candidates in
      let rec is_prefix members candidates =
        match members, candidates with
        | [], _ -> true
        | member :: members, (candidate : Operation.t) :: candidates
          when Id.equal member candidate.operation_id ->
          is_prefix members candidates
        | _ :: _, [] | _ :: _, _ :: _ -> false
      in
      let* () = match selected with
        | first :: _ :: _ when Id.equal first.operation_id head.operation_id
            && List.map (fun (operation : Operation.t) -> operation.operation_id) selected = plan.members
            && is_prefix plan.members candidates -> Ok ()
        | _ -> Error (Invalid_input "batch must contain its head and contiguous fresh members in queue order") in
      let* input_json = canonical_json "batch input" plan.input in
      let* input = json_of_stored "batch input" input_json in
      let* execution_digest = Operation.execution_digest input |> Result.map_error (fun detail -> Invalid_input detail) in
      let* () = List.fold_left (fun result (position, (operation : Operation.t)) ->
        let* () = result in
        with_statement db ~operation:"freeze batch member"
          "INSERT INTO operation_batch_members(operation_id, execution_id, position, admitted_digest, admitted_input_json) VALUES (?, ?, ?, ?, ?)" (fun stmt ->
            let* () = bind_text db stmt ~operation:"bind member" 1 (Id.to_string operation.operation_id) in
            let* () = bind_text db stmt ~operation:"bind batch owner" 2 (Id.to_string head.operation_id) in
            let* () = bind_int64 db stmt ~operation:"bind position" 3 (Int64.of_int position) in
            let* () = bind_text db stmt ~operation:"bind frozen digest" 4 operation.execution_digest in
            let* input = required_option "batch member input" operation.input in
            let* original = canonical_json "batch member input" input in
            let* () = bind_text db stmt ~operation:"bind frozen original" 5 original in
            expect_done db stmt ~operation:"freeze batch member")) (Ok ()) (List.mapi (fun i operation -> i, operation) selected) in
      let* () = with_statement db ~operation:"freeze batch input"
        "UPDATE operations SET input_json = ?, execution_digest = ? WHERE operation_id = ? AND state = 'queued'" (fun stmt ->
          let* () = bind_text db stmt ~operation:"bind batch input" 1 input_json in
          let* () = bind_text db stmt ~operation:"bind batch digest" 2 execution_digest in
          let* () = bind_text db stmt ~operation:"bind batch owner" 3 (Id.to_string head.operation_id) in
          expect_done db stmt ~operation:"freeze batch input") in
      Ok { head with input = Some input; execution_digest; batch_membership = Some { Operation.execution_id = head.operation_id; input_digest = head.execution_digest } }
;;

let claim_next ?batch store ~now =
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
        let* current = claimable_queued_with_db store.db ~now in
        match current with
        | None -> Ok ()
        | Some current ->
               let* current = match batch with
                 | None -> operation_or_unknown store.db current.operation_id
                 | Some select -> freeze_batch_with_db store.db ~select current in
               let* expected =
                 Reducer.apply current (Start { started_at = now })
                 |> Result.map_error (reducer_error current.operation_id)
               in
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
               Ok ())
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
       | Integrity_error _
       | Native_call_unsettled ),
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
          "SELECT %s FROM operations WHERE state = 'queued' AND NOT EXISTS (SELECT 1 FROM operation_batch_members b WHERE b.operation_id = operations.operation_id AND b.execution_id <> b.operation_id) ORDER BY sequence LIMIT %d"
          select_columns
          limit
      | Some _ ->
        Printf.sprintf
          "SELECT %s FROM operations WHERE state = 'queued' AND NOT EXISTS (SELECT 1 FROM operation_batch_members b WHERE b.operation_id = operations.operation_id AND b.execution_id <> b.operation_id) AND sequence > ? ORDER BY sequence LIMIT %d"
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
          let* operation = project_batch_with_db store.db operation in
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
    |> Result.map_error (reducer_error operation_id)
  in
  ignore current;
  persist_and_readback store expected (fun () ->
    let* executions = semantic_rows store.db ~active_only:true in
    if List.exists (fun (execution : Semantic.t) ->
        Keeper_execution_scope_id.equal execution.id (Keeper_execution_scope_id.direct_operation operation_id)) executions
    then Error (Invalid_input "direct continuation input is already admitted")
    else with_statement
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
        let* moved =
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
        expected := Some moved;
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
       | Integrity_error _
       | Native_call_unsettled ),
       _ -> Error error)
;;

let move_queued_to_front store ~now ~operation_id =
  let* () = ensure_open store in
  let* () = with_transaction store (fun () ->
    let* target = operation_or_unknown store.db operation_id in
    let* target = match target.batch_membership with
      | Some member when not (Id.equal member.execution_id operation_id) -> operation_or_unknown store.db member.execution_id
      | Some _ | None -> Ok target in
    let operation_id = target.Operation.operation_id in
    let* () = match target.state with
      | Operation.Queued -> Ok ()
      | Operation.Running _ | Operation.Succeeded _ | Operation.Failed _
      | Operation.Cancelled _ -> Error (Not_queued operation_id) in
    let* blocked = blocked_queued_scopes store.db ~now in
    let* () = if List.exists (Keeper_execution_scope_id.equal
        (Keeper_execution_scope_id.direct_operation operation_id)) blocked then
      Error (Invalid_input "message is waiting for input, approval, reconciliation, or provider retry; priority cannot make it runnable")
      else Ok () in
    let* queued = with_statement store.db ~operation:"read queue order"
      ("SELECT " ^ select_columns ^ " FROM operations WHERE state = 'queued' AND NOT EXISTS (SELECT 1 FROM operation_batch_members b WHERE b.operation_id = operations.operation_id AND b.execution_id <> b.operation_id) ORDER BY sequence")
      (fun stmt ->
        let rec read rows =
          let rc = Sqlite3.step stmt in
          if rc = Sqlite3.Rc.DONE then Ok (List.rev rows)
          else if rc = Sqlite3.Rc.ROW then
            let* row = decode_operation stmt in read (row :: rows)
          else Error (Store_unavailable (sqlite_error store.db "read queue order" rc)) in
        read []) in
    match queued with
    | first :: _ when Id.equal first.operation_id operation_id -> Ok ()
    | _ ->
      (* Sequences remain non-negative and unique. Moving every other queued
         row to fresh positions preserves their order without touching running
         work, input, ownership, or operation identities. *)
      let rec move = function
        | [] -> Ok ()
        | (row : Operation.t) :: rest when Id.equal row.operation_id operation_id -> move rest
        | row :: rest ->
          let* sequence = next_sequence store.db in
          let* () = with_statement store.db ~operation:"prioritize queued operation"
            "UPDATE operations SET sequence = ? WHERE operation_id = ? AND state = 'queued'"
            (fun stmt ->
              let* () = bind_int64 store.db stmt ~operation:"bind sequence" 1 sequence in
              let* () = bind_text store.db stmt ~operation:"bind operation" 2 (Id.to_string row.operation_id) in
              let* () = expect_done store.db stmt ~operation:"move queue position" in
              if Sqlite3.changes store.db = 1 then Ok () else Error (Not_queued row.operation_id)) in
          move rest in
      move queued) in
  let* operation = operation_or_unknown store.db operation_id in
  project_batch_with_db store.db operation
;;

let move_queued_priority_cohort_to_front store ~now ~operation_id ~predecessors =
  let* () = ensure_open store in
  let* () = with_transaction store (fun () ->
    let* target = operation_or_unknown store.db operation_id in
    let* target = match target.batch_membership with
      | Some member when not (Id.equal member.execution_id operation_id) ->
        operation_or_unknown store.db member.execution_id
      | Some _ | None -> Ok target in
    let operation_id = target.Operation.operation_id in
    let* () = match target.state with
      | Operation.Queued -> Ok ()
      | Operation.Running _ | Operation.Succeeded _ | Operation.Failed _
      | Operation.Cancelled _ -> Error (Not_queued operation_id) in
    let* blocked = blocked_queued_scopes store.db ~now in
    let* () =
      if List.exists
           (Keeper_execution_scope_id.equal
              (Keeper_execution_scope_id.direct_operation operation_id))
           blocked
      then Error (Invalid_input
        "message is waiting for input, approval, reconciliation, or provider retry; priority cannot make it runnable")
      else Ok () in
    let* () =
      if List.exists (Id.equal operation_id) predecessors
      then Error (Invalid_input "priority predecessors include the target operation")
      else Ok () in
    let* queued = with_statement store.db ~operation:"read queue order"
      ("SELECT " ^ select_columns ^ " FROM operations WHERE state = 'queued' AND NOT EXISTS (SELECT 1 FROM operation_batch_members b WHERE b.operation_id = operations.operation_id AND b.execution_id <> b.operation_id) ORDER BY sequence")
      (fun stmt ->
        let rec read rows =
          let rc = Sqlite3.step stmt in
          if rc = Sqlite3.Rc.DONE then Ok (List.rev rows)
          else if rc = Sqlite3.Rc.ROW then
            let* row = decode_operation stmt in read (row :: rows)
          else Error (Store_unavailable (sqlite_error store.db "read queue order" rc)) in
        read []) in
    let* () =
      if List.exists (fun (row : Operation.t) ->
           Id.equal row.operation_id operation_id) queued
      then Ok ()
      else Error (Integrity_error "queued priority target is absent from queue order") in
    let rec cohort reversed = function
      | [] -> Ok (List.rev (target :: reversed))
      | predecessor :: rest ->
        (match List.find_opt (fun (row : Operation.t) ->
           Id.equal row.operation_id predecessor) queued with
         | None -> cohort reversed rest
         | Some row when row.source <> target.source ->
           Error (Invalid_input "priority predecessor has a different source")
         | Some row when List.exists
             (Keeper_execution_scope_id.equal
                (Keeper_execution_scope_id.direct_operation row.operation_id))
             blocked -> cohort reversed rest
         | Some row when List.exists (fun (held : Operation.t) ->
             Id.equal held.operation_id row.operation_id) reversed ->
           Error (Invalid_input "priority predecessor appears twice")
         | Some row -> cohort (row :: reversed) rest) in
    let* cohort = cohort [] predecessors in
    let desired = cohort @ List.filter (fun (row : Operation.t) ->
      not (List.exists (fun (member : Operation.t) ->
        Id.equal member.operation_id row.operation_id) cohort)) queued in
    let same_order = List.for_all2 (fun (left : Operation.t) (right : Operation.t) ->
      Id.equal left.operation_id right.operation_id) queued desired in
    if same_order then Ok () else
    let rec move = function
      | [] -> Ok ()
      | (row : Operation.t) :: rest ->
        let* sequence = next_sequence store.db in
        let* () = with_statement store.db ~operation:"prioritize queued cohort"
          "UPDATE operations SET sequence = ? WHERE operation_id = ? AND state = 'queued'"
          (fun stmt ->
            let* () = bind_int64 store.db stmt ~operation:"bind sequence" 1 sequence in
            let* () = bind_text store.db stmt ~operation:"bind operation" 2
              (Id.to_string row.operation_id) in
            let* () = expect_done store.db stmt ~operation:"move queue position" in
            if Sqlite3.changes store.db = 1 then Ok ()
            else Error (Not_queued row.operation_id)) in
        move rest in
    move desired) in
  let* operation = operation_or_unknown store.db operation_id in
  project_batch_with_db store.db operation
;;

type semantic_error =
  | Semantic_store_error of error
  | Admission_conflict of Keeper_execution_scope_id.t
  | Sources_owned of Keeper_execution_scope_id.t list
  | Invalid_execution of Semantic.error

type semantic_admission = Semantic_created of Semantic.t | Semantic_existing of Semantic.t

let semantic_error_to_string = function
  | Semantic_store_error error -> error_to_string error
  | Admission_conflict id -> "semantic admission conflict: " ^ scope_key id
  | Sources_owned ids -> "selected sources already belong to: " ^ String.concat ", " (List.map scope_key ids)
  | Invalid_execution error -> Semantic.error_to_string error
;;
let semantic_store_result result = Result.map_error (fun error -> Semantic_store_error error) result

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
  in_transaction store ~begin_operation:"begin semantic operation transaction"
    ~store_error:(fun error -> Semantic_store_error error) f
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
(* Every semantic write that can stop naming a reference is this CAS: an
   insert names only new references, and no row is deleted. *)
let update_semantic store ~expected next =
  let db = store.db in
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
      if Sqlite3.changes db = 1 then (record_dropped store ~before:expected ~after:next; Ok ())
      else Error (Integrity_error "semantic CAS did not update its exact record"))
;;
let same_source (left : Semantic.source_member) (right : Semantic.source_member) =
  left.post_id = right.post_id && left.admitted_revision = right.admitted_revision
  && left.source_sha256 = right.source_sha256
;;
let semantic_prepare store ~id ~input ~sources ~now =
  let* candidate = Semantic.create ~id ~input ~sources ~now |> Result.map_error (fun error -> Invalid_execution error) in
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

let direct_execution_with_db db (operation : Operation.t) =
  let* execution = semantic_get_with_db db (Keeper_execution_scope_id.direct_operation operation.operation_id) in
  match execution with
  | None -> Ok None
  | Some execution ->
    let* () = match operation.input, execution.Semantic.input with
      | Some input, Some saved when String.equal execution.input_sha256 operation.execution_digest ->
        let* input = canonical_json "operation continuation input" input in
        let* saved = canonical_json "semantic continuation input" saved in
        if String.equal input saved then Ok ()
        else Error (Integrity_error "direct continuation input differs from operation")
      | None, None when Operation.is_terminal operation.state && Semantic.is_terminal execution -> Ok ()
      | _ -> Error (Integrity_error "direct continuation input binding is not current") in
    Ok (Some execution)
;;

let pending_retry = function
  | Some { Semantic.phase = Semantic.Recovering { origin = Semantic.Runtime_retry continuation; _ }; _ } -> Some continuation
  | Some { Semantic.phase = (Semantic.Preparing | Semantic.Ready | Semantic.Running | Semantic.Resuming_runtime_retry _ | Semantic.Resuming_gate _
      | Semantic.Suspended _ | Semantic.Settled _
      | Semantic.Recovering {origin = (Semantic.Checkpointed _ | Semantic.Official_checkpointed _ | Semantic.Unconfirmed_sources
          | Semantic.Confirmed_undispatched | Semantic.Interrupted_execution | Semantic.Gate_wait _ | Semantic.Gate_binding _ | Semantic.Input_wait _); _}); _ }
  | None -> None
;;

let pending_checkpoint = function
  | Some { Semantic.phase = Semantic.Suspended checkpoint; _ }
  | Some { Semantic.phase = Semantic.Recovering { origin = Semantic.Checkpointed checkpoint; _ }; _ } -> Some (Semantic.Agent_core checkpoint)
  | Some { Semantic.phase = Semantic.Recovering { origin = Semantic.Official_checkpointed checkpoint; _ }; _ } -> Some (Semantic.Official_client checkpoint)
  | Some { Semantic.phase = (Semantic.Preparing | Semantic.Ready | Semantic.Running
      | Semantic.Resuming_runtime_retry _ | Semantic.Resuming_gate _ | Semantic.Settled _
      | Semantic.Recovering {origin = (Semantic.Unconfirmed_sources | Semantic.Confirmed_undispatched
          | Semantic.Interrupted_execution | Semantic.Runtime_retry _ | Semantic.Gate_wait _ | Semantic.Gate_binding _ | Semantic.Input_wait _); _}); _ }
  | None -> None
;;
let direct_checkpoint store ~operation_id =
  let* () = ensure_open store in
  let* operation = operation_or_unknown store.db operation_id in
  let* execution = direct_execution_with_db store.db operation in
  Ok (pending_checkpoint execution)
;;

let direct_runtime_retry store ~operation_id =
  let* () = if Atomic.exchange next_runtime_retry_read_fault false
    then Error (Store_unavailable "injected direct runtime retry read failure") else Ok () in
  let* () = ensure_open store in
  let* operation = operation_or_unknown store.db operation_id in
  let* execution = direct_execution_with_db store.db operation in
  Ok (pending_retry execution)
;;

let requeue_continuation_with_db db operation =
  let* requeued = Reducer.apply operation Reducer.Requeue_continuation
    |> Result.map_error (reducer_error operation.Operation.operation_id) in
  let* () = with_statement db ~operation:"requeue checkpointed direct operation"
    "UPDATE operations SET state = 'queued', started_at = NULL WHERE operation_id = ? AND state = 'running'"
    (fun statement ->
      let* () = bind_text db statement ~operation:"bind continuation operation" 1 (Id.to_string operation.operation_id) in
      let* () = expect_done db statement ~operation:"requeue checkpointed direct operation" in
      if Sqlite3.changes db = 1 then Ok () else Error (Not_running operation.operation_id)) in
  Ok requeued
;;

let semantic_error_to_store_error = function
  | Semantic.Native_call_unsettled -> Native_call_unsettled
  | (Semantic.Invalid_record _ | Semantic.Invalid_transition _ | Semantic.Revision_exhausted) as error ->
    Integrity_error (Semantic.error_to_string error)
;;

let semantic_transition ~now action execution =
  Semantic.apply ~now action execution |> Result.map_error semantic_error_to_store_error
;;

let direct_input_wait store ~operation_id =
  let* () = ensure_open store in
  let* operation = operation_or_unknown store.db operation_id in
  let* execution = direct_execution_with_db store.db operation in
  Ok (input_wait_state execution)

let defer_direct_input_wait store ~now ~operation_id ~execution_digest ~(waiting:Semantic.input_wait) =
  let* () = ensure_open store in
  let exact_owner execution =
    match Option.bind execution (fun (execution:Semantic.t) -> execution.input_branch) with
    | Some branch when Keeper_checkpoint_ref.equal branch.checkpoint waiting.checkpoint -> Ok ()
    | Some _ -> Error (Invalid_input "input wait no longer names its original operation branch")
    | None ->
    let* input = input_observation_with_db store.db ~trace_id:waiting.checkpoint.trace_id in
    match input with
    | Input_observed reference when Keeper_checkpoint_ref.equal reference waiting.checkpoint -> Ok ()
    | Input_observed _ | Input_unobserved | Prior_input_unavailable ->
      Error (Invalid_input "input wait no longer names the exact current input owner") in
  let read_existing () =
    let* operation = operation_or_unknown store.db operation_id in
    let* execution = direct_execution_with_db store.db operation in
    match operation.state,input_wait_state execution with
    | Operation.Queued,Some expected when operation.execution_digest=execution_digest
        && Semantic.equal_input_wait expected waiting -> Ok operation
    | (Operation.Queued | Operation.Running _ | Operation.Succeeded _ | Operation.Failed _ | Operation.Cancelled _),(Some _ | None) ->
      Error (Invalid_input "input wait does not match the original queued continuation") in
  (* A readback cannot turn an uncertain commit into confirmed acceptance. *)
  let* _ = with_transaction store (fun () ->
    let* operation = operation_or_unknown store.db operation_id in
    if operation.execution_digest<>execution_digest then Error (Invalid_input "input wait execution digest changed")
    else
    let* current = direct_execution_with_db store.db operation in
    let* () = exact_owner current in
    match operation.state with
    | Operation.Queued -> read_existing ()
    | Operation.Succeeded _ | Operation.Failed _ | Operation.Cancelled _ -> Error (Not_running operation_id)
    | Operation.Running _ ->
      let* expected = match current with
        | Some execution -> Ok execution
        | None -> Error (Invalid_input "input wait has no original native execution") in
      let* () = match expected.native_call with
        | Keeper_native_call.Terminal_unacknowledged (call,{Agent_core.Agent.recovery=Agent_core.Agent.Retire;_})
            when Keeper_checkpoint_ref.equal call.checkpoint waiting.checkpoint -> Ok ()
        | Keeper_native_call.Terminal_unacknowledged (_, {Agent_core.Agent.recovery=Agent_core.Agent.Retire;_}) ->
          Error (Invalid_input "input wait differs from the retired native checkpoint")
        | Keeper_native_call.No_native_call | Keeper_native_call.Active _
        | Keeper_native_call.Terminal_unacknowledged (_, {Agent_core.Agent.recovery=Agent_core.Agent.Operator_repair_required _;_}) ->
          Error Native_call_unsettled in
      let* suspended = semantic_transition ~now (Semantic.Suspend_input waiting) expected in
      let* () = update_semantic store ~expected suspended in
      requeue_continuation_with_db store.db operation) in
  read_existing ()
;;

let direct_input_response_intent store ~operation_id =
  let* () = ensure_open store in
  let* operation = operation_or_unknown store.db operation_id in
  let* execution = direct_execution_with_db store.db operation in
  Ok (Option.bind execution (fun (execution : Semantic.t) -> execution.input_response_intent))

let direct_input_branch store ~operation_id =
  let* () = ensure_open store in
  let* operation = operation_or_unknown store.db operation_id in
  let* execution = direct_execution_with_db store.db operation in
  Ok (Option.bind execution (fun (execution : Semantic.t) -> execution.input_branch))

let validate_response_input_with_db store (execution:Semantic.t) (waiting:Semantic.input_wait) destination =
  let* input = input_observation_with_db store.db ~trace_id:waiting.checkpoint.trace_id in
  match destination,input,execution.input_branch with
  | Semantic.Canonical_input,Input_observed reference,None
      when Keeper_checkpoint_ref.equal reference waiting.checkpoint -> Ok ()
  | Operation_input,Input_observed _,None -> Ok ()
  | Operation_input,Input_observed _,Some branch
      when Keeper_checkpoint_ref.equal branch.checkpoint waiting.checkpoint -> Ok ()
  | (Canonical_input | Operation_input),(Input_observed _ | Input_unobserved | Prior_input_unavailable),(Some _ | None) ->
    Error (Invalid_input "input response destination lost its original input predecessor")

let prepare_direct_input_response store ~now ~operation_id ~execution_digest ~(intent:Semantic.input_response_intent) =
  let* () = ensure_open store in
  with_transaction store (fun () ->
    let* operation = operation_or_unknown store.db operation_id in
    if operation.execution_digest <> execution_digest then Error (Invalid_input "input response intent execution digest changed")
    else match operation.state with
    | Operation.Running _ | Operation.Succeeded _ | Operation.Failed _ | Operation.Cancelled _ ->
      Error (Not_queued operation_id)
    | Operation.Queued ->
      let* current = direct_execution_with_db store.db operation in
      let* expected = match current,input_wait_state current with
        | Some execution,Some waiting when Semantic.equal_input_wait waiting intent.waiting -> Ok execution
        | (Some _ | None),(Some _ | None) -> Error (Invalid_input "input response intent lost its original wait") in
      let* () = match expected.native_call with
        | Keeper_native_call.No_native_call -> Ok ()
        | Active _ | Terminal_unacknowledged _ -> Error Native_call_unsettled in
      let* () = match expected.input_response_intent with
        | Some current when not (Semantic.continues_input_response_intent ~previous:current ~next:intent) ->
          Error (Invalid_input "original input response intent cannot be replaced")
        | Some _ | None -> Ok () in
      let* () = validate_response_input_with_db store expected intent.waiting intent.destination in
      let* next = semantic_transition ~now (Semantic.Prepare_input_response intent) expected in
      update_semantic store ~expected next)
;;

let resolve_direct_input_wait store ~now ~operation_id ~execution_digest ~observed ~checkpoint =
  let* () = ensure_open store in
  with_transaction store (fun () ->
    let* operation = operation_or_unknown store.db operation_id in
    if operation.execution_digest <> execution_digest then Error (Invalid_input "input response execution digest changed")
    else match operation.state with
    | Operation.Running _ | Operation.Succeeded _ | Operation.Failed _ | Operation.Cancelled _ ->
      Error (Not_queued operation_id)
    | Operation.Queued ->
      let* current = direct_execution_with_db store.db operation in
      let* expected = match current,input_wait_state current with
        | Some execution,Some waiting when Semantic.equal_input_wait waiting observed -> Ok execution
        | (Some _ | None),(Some _ | None) -> Error (Invalid_input "input response no longer owns its original wait") in
      let* () = match expected.native_call with
        | Keeper_native_call.No_native_call -> Ok ()
        | Active _ | Terminal_unacknowledged _ -> Error Native_call_unsettled in
      let destination = match expected.input_response_intent with
        | None -> Semantic.Canonical_input | Some intent -> intent.destination in
      let* () = validate_response_input_with_db store expected observed destination in
      let action = match destination with
        | Semantic.Canonical_input -> Semantic.Resolve_input {observed;checkpoint}
        | Operation_input -> Semantic.Resolve_input_branch {observed;checkpoint} in
      let* next = semantic_transition ~now action expected in
      let* () = match destination with
        | Semantic.Canonical_input -> install_input_checkpoint_with_db store ~previous:(Some observed.checkpoint) checkpoint
        | Operation_input -> Ok () in
      update_semantic store ~expected next)
;;

let defer_direct_runtime_retry store ~now ~operation_id ~execution_digest ~continuation =
  let* () = ensure_open store in
  let read_existing () =
    let* operation = operation_or_unknown store.db operation_id in
    let* execution = direct_execution_with_db store.db operation in
    match operation.state, pending_retry execution with
    | Operation.Queued, Some existing when String.equal operation.execution_digest execution_digest
        && Semantic.equal_runtime_retry existing continuation -> Ok operation
    | (Operation.Queued | Operation.Running _ | Operation.Succeeded _
       | Operation.Failed _ | Operation.Cancelled _), (Some _ | None) ->
      Error (Integrity_error "direct continuation commit is not confirmed") in
  let result = with_transaction store (fun () ->
    let* operation = operation_or_unknown store.db operation_id in
    if not (String.equal operation.execution_digest execution_digest)
    then Error (Invalid_input "direct continuation execution digest changed")
    else match operation.state with
    | Operation.Queued -> read_existing ()
    | Operation.Succeeded _ | Operation.Failed _ | Operation.Cancelled _ -> Error (Not_running operation_id)
    | Operation.Running _ ->
      let* current = direct_execution_with_db store.db operation in
      let* execution = match current with
        | Some execution -> Ok execution
        | None ->
          (match operation.input with
           | None -> Error (Integrity_error "running direct operation has no input")
           | Some input ->
             let* created = Semantic.create ~id:(Keeper_execution_scope_id.direct_operation operation_id)
                 ~input ~sources:[] ~now
               |> Result.map_error (fun error -> Invalid_input (Semantic.error_to_string error)) in
             let* ready = semantic_transition ~now Semantic.Confirm_sources created in
             semantic_transition ~now Semantic.Begin_execution ready) in
      let* suspended = semantic_transition ~now (Semantic.Suspend_runtime_retry continuation) execution in
      let* () = match current with
        | None -> insert_semantic store.db suspended
        | Some current -> update_semantic store ~expected:current suspended in
      requeue_continuation_with_db store.db operation) in
  match result with
  | Ok _ -> read_existing ()
  | Error (Store_unavailable _ as error) ->
    (match read_existing () with Ok operation -> Ok operation | Error _ -> Error error)
  | Error (Invalid_input _ | Unknown_operation _ | Not_queued _ | Not_running _
      | Idempotency_conflict _ | Integrity_error _ | Native_call_unsettled) as error -> error
;;

let update_direct_runtime_retry_wait store ~now ~operation_id ~observed ~replacement =
  let* () = ensure_open store in
  with_transaction store (fun () ->
    let* operation = operation_or_unknown store.db operation_id in
    match operation.state with
    | Operation.Running _ | Operation.Succeeded _ | Operation.Failed _ | Operation.Cancelled _ -> Ok false
    | Operation.Queued ->
      let* execution = direct_execution_with_db store.db operation in
      match execution, pending_retry execution with
      | Some expected, Some retry when retry = observed ->
        let* next = semantic_transition ~now
          (Semantic.Update_runtime_retry_wait {observed; replacement}) expected in
        let* () = update_semantic store ~expected next in
        Ok true
      | Some _, Some _ | Some _, None | None, Some _ | None, None -> Ok false)
;;

let resume_direct_runtime_retry store ~now ~operation_id ~observed =
  let* () = ensure_open store in
  let expected_next = ref None in
  let result = with_transaction store (fun () ->
    let* operation = operation_or_unknown store.db operation_id in
    match operation.state with
    | Operation.Queued | Operation.Succeeded _ | Operation.Failed _ | Operation.Cancelled _ -> Error (Not_running operation_id)
    | Operation.Running _ ->
      let* execution = direct_execution_with_db store.db operation in
      match execution with
      | None -> Error (Integrity_error "direct operation has no durable continuation")
      | Some expected ->
        let* next = semantic_transition ~now (Semantic.Resume_runtime_retry observed) expected in
        let* outstanding = semantic_rows store.db ~active_only:true in
        if List.exists (fun (entry : Semantic.t) -> semantic_is_running entry.phase
            && not (Keeper_execution_scope_id.equal entry.id expected.id)) outstanding
        then Error (Integrity_error "another semantic execution owns the running slot")
        else (expected_next := Some next; update_semantic store ~expected next)) in
  match result with
  | Ok () -> Ok ()
  | Error (Store_unavailable _ as error) ->
    (match !expected_next with
     | None -> Error error
     | Some expected ->
       (match semantic_get_with_db store.db expected.id with
        | Ok (Some observed) when Semantic.to_json observed = Semantic.to_json expected -> Ok ()
        | Ok _ | Error _ -> Error error))
  | Error (Invalid_input _ | Unknown_operation _ | Not_queued _ | Not_running _
      | Idempotency_conflict _ | Integrity_error _ | Native_call_unsettled) as error -> error
;;

let defer_direct_checkpoint store ~now ~operation_id ~execution_digest ~checkpoint =
  let* () = ensure_open store in
  let read_existing () =
    let* operation = operation_or_unknown store.db operation_id in
    let* execution = direct_execution_with_db store.db operation in
    match operation.state, pending_checkpoint execution with
    | Operation.Queued, Some existing when String.equal operation.execution_digest execution_digest
        && Semantic.equal_gate_checkpoint existing checkpoint -> Ok operation
    | (Operation.Queued | Operation.Running _ | Operation.Succeeded _
       | Operation.Failed _ | Operation.Cancelled _), (Some _ | None) ->
      Error (Integrity_error "direct continuation commit is not confirmed") in
  let result = with_transaction store (fun () ->
    let* operation = operation_or_unknown store.db operation_id in
    if not (String.equal operation.execution_digest execution_digest)
    then Error (Invalid_input "direct continuation execution digest changed")
    else match operation.state with
    | Operation.Queued -> read_existing ()
    | Operation.Succeeded _ | Operation.Failed _ | Operation.Cancelled _ -> Error (Not_running operation_id)
    | Operation.Running _ ->
      let* current = direct_execution_with_db store.db operation in
      let* execution = match current with
        | Some execution -> Ok execution
        | None ->
          (match operation.input with
           | None -> Error (Integrity_error "running direct operation has no input")
           | Some input ->
             let* created = Semantic.create ~id:(Keeper_execution_scope_id.direct_operation operation_id)
                 ~input ~sources:[] ~now
               |> Result.map_error (fun error -> Invalid_input (Semantic.error_to_string error)) in
             let* ready = semantic_transition ~now Semantic.Confirm_sources created in
             semantic_transition ~now Semantic.Begin_execution ready) in
      let action = match checkpoint with
        | Semantic.Agent_core checkpoint -> Semantic.Suspend checkpoint
        | Semantic.Official_client checkpoint -> Semantic.Suspend_official_checkpoint checkpoint in
      let* suspended = semantic_transition ~now action execution in
      let* () = match current with
        | None -> insert_semantic store.db suspended
        | Some current -> update_semantic store ~expected:current suspended in
      let* requeued = requeue_continuation_with_db store.db operation in
      (* A cooperative yield hands the slot to already submitted input. Keep
         the operation identity/input frozen, but let newer steering run first. *)
      let* sequence = next_sequence store.db in
      let* () = with_statement store.db ~operation:"yield checkpoint queue position"
        "UPDATE operations SET sequence = ? WHERE operation_id = ? AND state = 'queued'" (fun stmt ->
          let* () = bind_int64 store.db stmt ~operation:"bind checkpoint sequence" 1 sequence in
          let* () = bind_text store.db stmt ~operation:"bind checkpoint operation" 2 (Id.to_string operation_id) in
          expect_done store.db stmt ~operation:"yield checkpoint queue position") in
      Ok { requeued with sequence }) in
  match result with
  | Ok _ -> read_existing ()
  | Error (Store_unavailable _ as error) ->
    (match read_existing () with Ok operation -> Ok operation | Error _ -> Error error)
  | Error (Invalid_input _ | Unknown_operation _ | Not_queued _ | Not_running _
      | Idempotency_conflict _ | Integrity_error _ | Native_call_unsettled) as error -> error
;;

let resume_direct_checkpoint store ~now ~operation_id ~observed =
  let* () = ensure_open store in
  let expected_next = ref None in
  let result = with_transaction store (fun () ->
    let* operation = operation_or_unknown store.db operation_id in
    match operation.state with
    | Operation.Queued | Operation.Succeeded _ | Operation.Failed _ | Operation.Cancelled _ -> Error (Not_running operation_id)
    | Operation.Running _ ->
      let* execution = direct_execution_with_db store.db operation in
      match execution with
      | None -> Error (Integrity_error "direct operation has no durable continuation")
      | Some expected ->
        let action = match observed with
          | Semantic.Agent_core checkpoint -> Semantic.Resume_checkpoint checkpoint
          | Semantic.Official_client checkpoint -> Semantic.Resume_official_checkpoint checkpoint in
        let* next = semantic_transition ~now action expected in
        let* outstanding = semantic_rows store.db ~active_only:true in
        if List.exists (fun (entry : Semantic.t) -> semantic_is_running entry.phase
            && not (Keeper_execution_scope_id.equal entry.id expected.id)) outstanding
        then Error (Integrity_error "another semantic execution owns the running slot")
        else (expected_next := Some next; update_semantic store ~expected next)) in
  match result with
  | Ok () -> Ok ()
  | Error (Store_unavailable _ as error) ->
    (match !expected_next with
     | None -> Error error
     | Some expected ->
       (match semantic_get_with_db store.db expected.id with
        | Ok (Some observed) when Semantic.to_json observed = Semantic.to_json expected -> Ok ()
        | Ok _ | Error _ -> Error error))
  | Error (Invalid_input _ | Unknown_operation _ | Not_queued _ | Not_running _
      | Idempotency_conflict _ | Integrity_error _ | Native_call_unsettled) as error -> error
;;

let direct_gate_state store ~operation_id =
  let* () = ensure_open store in
  let* operation = operation_or_unknown store.db operation_id in
  let* execution = direct_execution_with_db store.db operation in
  Ok (gate_state execution)

let direct_gate_waits store =
  let* () = ensure_open store in
  let* executions = semantic_rows store.db ~active_only:true in
  List.fold_left (fun result (execution : Semantic.t) ->
    let* rows = result in
    match Keeper_execution_scope_id.direct_operation_id execution.id, gate_state (Some execution) with
    | Some operation_id, Some waiting ->
      let* operation = operation_or_unknown store.db operation_id in
      let* _ = direct_execution_with_db store.db operation in
      Ok ((operation_id, waiting) :: rows)
    | None, _ | Some _, None -> Ok rows) (Ok []) executions |> Result.map List.rev

let direct_gate_bindings store =
  let* () = ensure_open store in
  let* executions = semantic_rows store.db ~active_only:true in
  List.fold_left (fun result (execution : Semantic.t) ->
    let* rows = result in
    match Keeper_execution_scope_id.direct_operation_id execution.id with
    | None -> Ok rows
    | Some operation_id ->
      match execution.phase with
      | Semantic.Recovering {origin=Semantic.Gate_binding binding; _} ->
        let* operation = operation_or_unknown store.db operation_id in
        let* _ = direct_execution_with_db store.db operation in
        Ok ((operation_id, binding) :: rows)
      | Semantic.Recovering {origin=(Semantic.Unconfirmed_sources | Semantic.Confirmed_undispatched
          | Semantic.Checkpointed _ | Semantic.Official_checkpointed _ | Semantic.Interrupted_execution | Semantic.Runtime_retry _ | Semantic.Gate_wait _ | Semantic.Input_wait _); _}
      | Semantic.Preparing | Semantic.Ready | Semantic.Running | Semantic.Resuming_runtime_retry _
      | Semantic.Resuming_gate _ | Semantic.Suspended _ | Semantic.Settled _ -> Ok rows) (Ok []) executions |> Result.map List.rev

let direct_gate_obligations store ~operation_id =
  let* () = ensure_open store in
  let* operation = operation_or_unknown store.db operation_id in
  let* execution = direct_execution_with_db store.db operation in
  Ok (Option.fold ~none:[] ~some:(fun (execution : Semantic.t) -> execution.gate_obligations) execution)

let direct_gate_binding store ~operation_id =
  let* () = ensure_open store in
  let* operation = operation_or_unknown store.db operation_id in
  let* execution = direct_execution_with_db store.db operation in
  match execution with
  | Some {Semantic.phase=Semantic.Recovering {origin=Semantic.Gate_binding binding; _}; _} -> Ok (Some binding)
  | Some {Semantic.phase=(Semantic.Preparing | Semantic.Ready | Semantic.Running | Semantic.Resuming_runtime_retry _
      | Semantic.Resuming_gate _ | Semantic.Suspended _ | Semantic.Settled _
      | Semantic.Recovering {origin=(Semantic.Runtime_retry _ | Semantic.Gate_wait _ | Semantic.Checkpointed _ | Semantic.Official_checkpointed _
          | Semantic.Unconfirmed_sources | Semantic.Confirmed_undispatched | Semantic.Interrupted_execution | Semantic.Input_wait _); _}); _}
  | None -> Ok None

let defer_direct_gate store ~now ~operation_id ~execution_digest ~waiting =
  let* () = ensure_open store in
  let readback () =
    let* operation = operation_or_unknown store.db operation_id in
    let* state = direct_gate_state store ~operation_id in
    match operation.state, state with
    | Operation.Queued, Some state when Semantic.equal_gate_wait state.waiting waiting
        && operation.execution_digest = execution_digest -> Ok operation
    | (Operation.Queued | Operation.Running _ | Operation.Succeeded _ | Operation.Failed _ | Operation.Cancelled _), _ ->
      Error (Integrity_error "Gate wait commit is not confirmed") in
  let result = with_transaction store (fun () ->
    let* operation = operation_or_unknown store.db operation_id in
    if operation.execution_digest <> execution_digest then Error (Invalid_input "Gate wait input digest changed")
    else match operation.state with
    | Operation.Queued -> readback ()
    | Operation.Succeeded _ | Operation.Failed _ | Operation.Cancelled _ -> Error (Not_running operation_id)
    | Operation.Running _ ->
      let* current = direct_execution_with_db store.db operation in
      let* execution = match current with
        | Some execution -> Ok execution
        | None ->
          (match operation.input with
           | None -> Error (Integrity_error "Gate wait has no original input")
           | Some input ->
             let* created = Semantic.create ~id:(Keeper_execution_scope_id.direct_operation operation_id)
                 ~input ~sources:[] ~now |> Result.map_error (fun e -> Invalid_input (Semantic.error_to_string e)) in
             let* ready = semantic_transition ~now Semantic.Confirm_sources created in
             semantic_transition ~now Semantic.Begin_execution ready) in
      let* suspended = semantic_transition ~now (Semantic.Suspend_gate waiting) execution in
      let* () = match current with None -> insert_semantic store.db suspended
        | Some current -> update_semantic store ~expected:current suspended in
      requeue_continuation_with_db store.db operation) in
  match result with
  | Ok _ -> readback ()
  | Error (Store_unavailable _ as error) -> (match readback () with Ok operation -> Ok operation | Error _ -> Error error)
  | Error (Invalid_input _ | Unknown_operation _ | Not_queued _ | Not_running _
      | Idempotency_conflict _ | Integrity_error _ | Native_call_unsettled) as error -> error

let defer_direct_gate_reconciliation store ~now ~operation_id ~execution_digest ~binding ~diagnostic =
  let* () = ensure_open store in
  let readback () =
    let* operation = operation_or_unknown store.db operation_id in
    let* observed_binding = direct_gate_binding store ~operation_id in
    match operation.state, observed_binding with
    | Operation.Queued, Some observed
        when observed = binding && operation.execution_digest = execution_digest -> Ok operation
    | (Operation.Queued | Operation.Running _ | Operation.Succeeded _ | Operation.Failed _ | Operation.Cancelled _), _ ->
      Error (Integrity_error "Gate wait commit is not confirmed") in
  let result = with_transaction store (fun () ->
    let* operation = operation_or_unknown store.db operation_id in
    if operation.execution_digest <> execution_digest then Error (Invalid_input "Gate wait input digest changed")
    else match operation.state with
    | Operation.Queued -> readback ()
    | Operation.Succeeded _ | Operation.Failed _ | Operation.Cancelled _ -> Error (Not_running operation_id)
    | Operation.Running _ ->
      let* current = direct_execution_with_db store.db operation in
      let* execution = match current with
        | Some execution -> Ok execution
        | None ->
          (match operation.input with
           | None -> Error (Integrity_error "Gate wait has no original input")
           | Some input ->
             let* created = Semantic.create ~id:(Keeper_execution_scope_id.direct_operation operation_id)
                 ~input ~sources:[] ~now |> Result.map_error (fun e -> Invalid_input (Semantic.error_to_string e)) in
             let* ready = semantic_transition ~now Semantic.Confirm_sources created in
             semantic_transition ~now Semantic.Begin_execution ready) in
      (* This is admission of a caller-supplied binding. Refusing its scope,
         obligations, or diagnostic does not mean the stored execution is corrupt. *)
      let* suspended = Semantic.apply ~now
          (Semantic.Suspend_gate_reconciliation (binding, diagnostic)) execution
        |> Result.map_error (function
          | Semantic.Invalid_transition _ as error -> Invalid_input (Semantic.error_to_string error)
          | Semantic.Native_call_unsettled -> Native_call_unsettled
          | (Semantic.Invalid_record _ | Semantic.Revision_exhausted) as error ->
            Integrity_error (Semantic.error_to_string error)) in
      let* () = match current with None -> insert_semantic store.db suspended
        | Some current -> update_semantic store ~expected:current suspended in
      requeue_continuation_with_db store.db operation) in
  match result with
  | Ok _ -> readback ()
  | Error (Store_unavailable _ as error) -> (match readback () with Ok operation -> Ok operation | Error _ -> Error error)
  | Error (Invalid_input _ | Unknown_operation _ | Not_queued _ | Not_running _
      | Idempotency_conflict _ | Integrity_error _ | Native_call_unsettled) as error -> error

let confirm_semantic_transition store expected result =
  match result with
  | Ok _ -> result
  | Error (Store_unavailable _ as error) ->
    (match !expected with
     | None -> Error error
     | Some (next, value) ->
       match semantic_get_with_db store.db next.Semantic.id with
       | Ok (Some observed) when Semantic.to_json observed = Semantic.to_json next -> Ok value
       | Ok (Some _) | Ok None | Error _ -> Error error)
  | Error (Invalid_input _ | Unknown_operation _ | Not_queued _ | Not_running _
      | Idempotency_conflict _ | Integrity_error _ | Native_call_unsettled) -> result

let direct_native_call store ~operation_id =
  let* () = ensure_open store in
  let* operation = operation_or_unknown store.db operation_id in
  let* execution = direct_execution_with_db store.db operation in
  Ok (match execution with None -> Keeper_native_call.No_native_call | Some execution -> execution.native_call)

let apply_direct_native_call_with_db store ~now ~operation_id ~execution_digest change =
    let* operation = operation_or_unknown store.db operation_id in
    let* () = if operation.execution_digest = execution_digest then Ok ()
      else Error (Invalid_input "native call operation digest changed") in
    match operation.state with
    | Operation.Queued | Operation.Succeeded _ | Operation.Failed _ | Operation.Cancelled _ -> Error (Not_running operation_id)
    | Operation.Running _ ->
      let* current = direct_execution_with_db store.db operation in
      let* execution = match current, change with
        | Some execution, _ -> Ok execution
        | None, Keeper_native_call.Bind _ ->
          let* input = required_option "native operation input" operation.input in
          let* created = Semantic.create ~id:(Keeper_execution_scope_id.direct_operation operation_id)
              ~input ~sources:[] ~now
            |> Result.map_error (fun error -> Invalid_input (Semantic.error_to_string error)) in
          let* ready = semantic_transition ~now Semantic.Confirm_sources created in
          semantic_transition ~now Semantic.Begin_execution ready
        | None, (Keeper_native_call.Checkpoint _ | Keeper_native_call.Terminal _) ->
          Error (Invalid_input "native call has no owning execution") in
      (* A stale callback rejects that request; it does not establish that the
         authoritative row is damaged. Owner fences only storage failures. *)
      let* replacement = Keeper_native_call.transition execution.native_call change
        |> Result.map_error (fun detail -> Invalid_input detail) in
      let* next = Semantic.update_native_call ~now ~expected:execution.native_call ~replacement execution
        |> Result.map_error (function
          | Semantic.Invalid_transition detail -> Invalid_input detail
          | Semantic.Native_call_unsettled -> Native_call_unsettled
          | (Semantic.Invalid_record _ | Semantic.Revision_exhausted) as error ->
            Integrity_error (Semantic.error_to_string error)) in
      (* The pure native and branch transitions are one persisted record. A
         reader can never observe a new native checkpoint with an older branch
         head, including the seed of the first resumed native invocation. *)
      let* next = match execution.input_branch, replacement with
        | Some branch, Keeper_native_call.Active call ->
          semantic_transition ~now
            (Semantic.Advance_input_branch {observed=branch.checkpoint;checkpoint=call.checkpoint}) next
        | (Some _ | None),(Keeper_native_call.No_native_call | Terminal_unacknowledged _)
        | None,Keeper_native_call.Active _ -> Ok next in
      let* () = match current with
        | None -> insert_semantic store.db next
        | Some expected when Semantic.to_json expected = Semantic.to_json next -> Ok ()
        | Some expected -> update_semantic store ~expected next in
      Ok next

let update_direct_native_call store ~now ~operation_id ~execution_digest change =
  let* () = ensure_open store in
  let expected_commit = ref None in
  let branch_publication = ref false in
  let result = with_transaction store (fun () ->
    let* next = apply_direct_native_call_with_db store ~now ~operation_id ~execution_digest change in
    branch_publication := Option.is_some next.input_branch;
    expected_commit := Some (next, ()); Ok ()) in
  if !branch_publication then result
  else confirm_semantic_transition store expected_commit result

let update_direct_branch_checkpoint store ~now ~operation_id ~execution_digest
    ~call_id ~observed ~observed_branch ~checkpoint =
  let* () = ensure_open store in
  with_transaction store (fun () ->
    let* operation = operation_or_unknown store.db operation_id in
    let* execution = direct_execution_with_db store.db operation in
    let* () = match Option.bind execution (fun (execution:Semantic.t) -> execution.input_branch) with
      | Some branch when Keeper_checkpoint_ref.equal branch.checkpoint observed_branch -> Ok ()
      | Some _ | None -> Error (Invalid_input "original operation branch predecessor changed") in
    let* _ = apply_direct_native_call_with_db store ~now ~operation_id ~execution_digest
      (Keeper_native_call.Checkpoint {call_id;observed;checkpoint}) in
    Ok ())

let require_global_direct_input_with_db store operation_id =
  let* operation = operation_or_unknown store.db operation_id in
  let* execution = direct_execution_with_db store.db operation in
  match Option.bind execution (fun (execution:Semantic.t) -> execution.input_branch) with
  | None -> Ok ()
  | Some _ -> Error (Invalid_input "operation input branch cannot publish global input")

let update_direct_input_checkpoint store ~now ~operation_id ~execution_digest
    ~call_id ~observed ~observed_input ~checkpoint =
  let* () = ensure_open store in
  (* Unlike the legacy native-only update, an uncertain commit stays Error.
     Semantic readback alone cannot certify the input-owner relation. The
     caller must reread both authorities before reconciling; its old input CAS
     cannot replay an installed transition, and no files are released. *)
  let* () = check_input_predecessor ~observed:observed_input ~checkpoint in
  with_transaction store (fun () ->
    let* () = require_global_direct_input_with_db store operation_id in
    let* previous = input_observation_with_db store.db ~trace_id:checkpoint.Keeper_checkpoint_ref.trace_id in
    if not (input_predecessor_matches observed_input previous) then
      Ok (Input_checkpoint_source_changed previous)
    else
      let* _next = apply_direct_native_call_with_db store ~now ~operation_id ~execution_digest
        (Keeper_native_call.Checkpoint {call_id; observed; checkpoint}) in
      let previous = match previous with Input_observed ref -> Some ref
        | Input_unobserved | Prior_input_unavailable -> None in
      let* () = install_input_checkpoint_with_db store ~previous checkpoint in
      Ok Input_checkpoint_updated)

let bind_direct_input_checkpoint store ~now ~operation_id ~execution_digest
    ~observed ~call ~observed_input ~checkpoint =
  let* () = ensure_open store in
  let* () = check_input_predecessor ~observed:observed_input ~checkpoint in
  with_transaction store (fun () ->
    let* () = require_global_direct_input_with_db store operation_id in
    let* previous = input_observation_with_db store.db ~trace_id:checkpoint.Keeper_checkpoint_ref.trace_id in
    if not (input_predecessor_matches observed_input previous) then
      Ok (Input_checkpoint_source_changed previous)
    else
      let* _next = apply_direct_native_call_with_db store ~now ~operation_id ~execution_digest
        (Keeper_native_call.Bind {observed;call}) in
      let previous = match previous with Input_observed reference -> Some reference
        | Input_unobserved | Prior_input_unavailable -> None in
      let* () = install_input_checkpoint_with_db store ~previous checkpoint in
      Ok Input_checkpoint_updated)

let resolve_direct_gate store ~now ~operation_id ~resolution =
  let* () = ensure_open store in
  let expected_commit = ref None in
  let result = with_transaction store (fun () ->
    let* operation = operation_or_unknown store.db operation_id in
    match operation.state with
    | Operation.Queued ->
      let* execution = direct_execution_with_db store.db operation in
      (match execution with
       | None -> Error (Integrity_error "Gate resolution has no waiting operation")
       | Some expected ->
         let* next = semantic_transition ~now (Semantic.Resolve_gate resolution) expected in
         expected_commit := Some (next, operation);
         let* () = if next == expected then Ok () else update_semantic store ~expected next in
         Ok operation)
    | Operation.Running _ | Operation.Succeeded _ | Operation.Failed _ | Operation.Cancelled _ -> Error (Not_queued operation_id)) in
  confirm_semantic_transition store expected_commit result

let resume_direct_gate store ~now ~operation_id ~waiting ~resolution =
  let* () = ensure_open store in
  let expected_commit = ref None in
  let result = with_transaction store (fun () ->
    let* operation = operation_or_unknown store.db operation_id in
    match operation.state with
    | Operation.Running _ ->
      let* execution = direct_execution_with_db store.db operation in
      (match execution with
       | None -> Error (Integrity_error "Gate resume has no waiting operation")
       | Some expected ->
         let* next = semantic_transition ~now (Semantic.Resume_gate (waiting, resolution)) expected in
         let* outstanding = semantic_rows store.db ~active_only:true in
         if List.exists (fun (entry : Semantic.t) -> semantic_is_running entry.phase
             && not (Keeper_execution_scope_id.equal entry.id expected.id)) outstanding
         then Error (Integrity_error "another execution owns the running slot")
         else (expected_commit := Some (next, ()); update_semantic store ~expected next))
    | Operation.Queued | Operation.Succeeded _ | Operation.Failed _ | Operation.Cancelled _ -> Error (Not_running operation_id)) in
  confirm_semantic_transition store expected_commit result

let discharge_direct_gate store ~now ~operation_id ~obligation =
  let* () = ensure_open store in
  let expected_commit = ref None in
  let result = with_transaction store (fun () ->
    let* operation = operation_or_unknown store.db operation_id in
    match operation.state with
    | Operation.Running _ ->
      let* execution = direct_execution_with_db store.db operation in
      (match execution with
       | None -> Error (Integrity_error "Gate evidence has no original operation")
       | Some expected ->
         let* next = semantic_transition ~now (Semantic.Discharge_gate obligation) expected in
         expected_commit := Some (next, ());
         update_semantic store ~expected next)
    | Operation.Queued | Operation.Succeeded _ | Operation.Failed _ | Operation.Cancelled _ -> Error (Not_running operation_id)) in
  confirm_semantic_transition store expected_commit result

let reconcile_direct_gate_binding store ~now ~operation_id ~binding ~waiting =
  let* () = ensure_open store in
  let expected_commit = ref None in
  let result = with_transaction store (fun () ->
    let* operation = operation_or_unknown store.db operation_id in
    match operation.state with
    | Operation.Queued ->
      let* execution = direct_execution_with_db store.db operation in
      (match execution with
       | None -> Error (Integrity_error "Gate reconciliation lost its original execution")
       | Some expected ->
         let* next = semantic_transition ~now (Semantic.Reconcile_gate_binding (binding, waiting)) expected in
         expected_commit := Some (next, ());
         update_semantic store ~expected next)
    | Operation.Running _ | Operation.Succeeded _ | Operation.Failed _ | Operation.Cancelled _ ->
      Error (Not_queued operation_id)) in
  confirm_semantic_transition store expected_commit result

let settle_direct_semantic store current command =
  let* execution = direct_execution_with_db store.db current in
  match execution with
  | None -> Ok ()
  | Some {Semantic.phase = (Semantic.Preparing | Semantic.Ready | Semantic.Settled _
      | Semantic.Recovering {origin = (Semantic.Unconfirmed_sources
          | Semantic.Confirmed_undispatched | Semantic.Interrupted_execution); _}); _} -> Ok ()
  | Some ({Semantic.phase = (Semantic.Running | Semantic.Suspended _ | Semantic.Resuming_runtime_retry _ | Semantic.Resuming_gate _
      | Semantic.Recovering {origin = (Semantic.Checkpointed _ | Semantic.Official_checkpointed _ | Semantic.Runtime_retry _ | Semantic.Gate_wait _ | Semantic.Gate_binding _ | Semantic.Input_wait _); _}); _} as expected) ->
    let* now, terminal = match command with
      | Reducer.Cancel_queued {completed_at} -> Ok (completed_at, Semantic.Cancelled)
      | Reducer.Succeed_running {completed_at; _} -> Ok (completed_at, Semantic.Completed)
      | Reducer.Fail_running {completed_at; failure} -> Ok (completed_at, Semantic.Failed failure.detail)
      | Reducer.Start _ | Reducer.Requeue_continuation | Reducer.Edit_queued _ | Reducer.Move_queued _ ->
        Error (Integrity_error "nonterminal command cannot settle direct continuation") in
    (* Retire is acknowledged by the operation's actual terminal transaction,
       never by the Core callback alone. Unknown outcomes keep their receipt. *)
    let* acknowledged = match expected.native_call with
      | Keeper_native_call.Terminal_unacknowledged (_, {Agent_core.Agent.recovery=Agent_core.Agent.Retire; _}) ->
        Semantic.update_native_call ~now ~expected:expected.native_call
          ~replacement:Keeper_native_call.No_native_call expected
        |> Result.map_error (fun error -> Integrity_error (Semantic.error_to_string error))
      | Keeper_native_call.No_native_call | Keeper_native_call.Active _
      | Keeper_native_call.Terminal_unacknowledged (_, {Agent_core.Agent.recovery=Agent_core.Agent.Operator_repair_required _; _}) -> Ok expected in
    let* next = semantic_transition ~now (Semantic.Settle terminal) acknowledged in
    update_semantic store ~expected next
;;

let settle_batch_members_with_db db ~execution_id =
  let* () = with_statement db ~operation:"settle shared execution members"
    "UPDATE operations SET state = leader.state, input_json = NULL, started_at = leader.started_at, completed_at = leader.completed_at, outcome_ref = leader.outcome_ref, failure_kind = leader.failure_kind, failure_detail = leader.failure_detail FROM operations AS leader WHERE leader.operation_id = ? AND leader.state IN ('succeeded', 'failed', 'cancelled') AND operations.state = 'queued' AND operations.operation_id IN (SELECT operation_id FROM operation_batch_members WHERE execution_id = leader.operation_id AND operation_id <> execution_id)" (fun stmt ->
      let* () = bind_text db stmt ~operation:"bind settled batch" 1 (Id.to_string execution_id) in
      expect_done db stmt ~operation:"settle shared execution members") in
  with_statement db ~operation:"release settled batch input"
    "UPDATE operation_batch_members SET admitted_input_json = NULL WHERE execution_id = ? AND admitted_input_json IS NOT NULL AND EXISTS (SELECT 1 FROM operations WHERE operation_id = execution_id AND state IN ('succeeded', 'failed', 'cancelled'))" (fun stmt ->
      let* () = bind_text db stmt ~operation:"bind settled batch input" 1 (Id.to_string execution_id) in
      expect_done db stmt ~operation:"release settled batch input")
;;

let persist_terminal store current command sql bind_terminal =
  let operation_id = current.Operation.operation_id in
  let* expected =
    Reducer.apply current command |> Result.map_error (reducer_error operation_id)
  in
  persist_and_readback store expected (fun () ->
    let* () = settle_direct_semantic store current command in
    let* () = with_statement store.db ~operation:"terminalize operation" sql (fun stmt ->
      let* () = bind_terminal stmt in
      let* () = expect_done store.db stmt ~operation:"terminalize operation" in
      if Sqlite3.changes store.db = 1
      then Ok ()
      else
        match current.state with
        | Queued -> Error (Not_queued operation_id)
        | Running _ -> Error (Not_running operation_id)
        | Succeeded _ | Failed _ | Cancelled _ ->
          Error (Integrity_error "terminal operation changed")) in
    settle_batch_members_with_db store.db ~execution_id:operation_id)
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

let reconcile_semantic_running store ~now =
  let* executions = semantic_rows store.db ~active_only:true in
  List.fold_left (fun result (execution : Semantic.t) ->
    let* count = result in
    match execution.native_call, execution.phase with
    | Keeper_native_call.Active _, _ -> Ok count
    | (Keeper_native_call.No_native_call | Keeper_native_call.Terminal_unacknowledged _),
      (Semantic.Running | Semantic.Resuming_runtime_retry _ | Semantic.Resuming_gate _) ->
        let* next = Semantic.apply ~now
          (Semantic.Require_reconciliation "process restarted during semantic execution") execution
          |> Result.map_error (fun error -> Integrity_error (Semantic.error_to_string error)) in
        let* () = update_semantic store ~expected:execution next in
        Ok (count + 1)
    | (Keeper_native_call.No_native_call | Keeper_native_call.Terminal_unacknowledged _),
      (Semantic.Preparing | Semantic.Ready | Semantic.Suspended _
      | Semantic.Recovering _ | Semantic.Settled _) -> Ok count) (Ok 0) executions
;;

let settle_running_after_restart store ~now =
  let* () = ensure_open store in
  let* () =
    Operation.validate_timestamp ~field:"completed_at" now
    |> Result.map_error (fun detail -> Invalid_input detail)
  in
  with_transaction store (fun () ->
    let* running = with_statement store.db ~operation:"read interrupted direct operations"
      ("SELECT " ^ select_columns ^ " FROM operations WHERE state = 'running'")
      (fun statement ->
        let rec read acc =
          let rc = Sqlite3.step statement in
          if rc = Sqlite3.Rc.DONE then Ok (List.rev acc)
          else if rc = Sqlite3.Rc.ROW then
            let* operation = decode_operation statement in read (operation :: acc)
          else Error (Store_unavailable (sqlite_error store.db "read interrupted direct operations" rc)) in
        read []) in
    (* A running operation with a durable continuation goes back to Queued and
       resumes; one without is the request the restart cut off, and only
       those are failed below. *)
    let* interrupted = List.fold_left (fun result operation ->
      let* interrupted = result in
      let* execution = direct_execution_with_db store.db operation in
      match Option.map (fun (execution : Semantic.t) -> execution.native_call) execution with
      | Some (Keeper_native_call.Active _) ->
        requeue_continuation_with_db store.db operation |> Result.map (fun _ -> interrupted)
      | Some (Keeper_native_call.Terminal_unacknowledged _) ->
        (* A committed Core terminal is not an Owner response receipt. Keep
           its identity, report interruption, and never resume its journal. *)
        let* () = match execution with
          | None -> Error (Integrity_error "native terminal lost its execution")
          | Some expected ->
            let* next = semantic_transition ~now
              (Semantic.Settle (Semantic.Failed "process restarted before Owner receipt acknowledgement")) expected in
            update_semantic store ~expected next in
        Ok (operation :: interrupted)
      | None | Some Keeper_native_call.No_native_call ->
        (match pending_checkpoint execution, pending_retry execution, gate_state execution with
         | None, None, None -> Ok (operation :: interrupted)
         | Some _, _, _ | None, Some _, _ | None, None, Some _ ->
           requeue_continuation_with_db store.db operation |> Result.map (fun _ -> interrupted))) (Ok []) running in
    let interrupted = List.rev interrupted in
    let* _reconciled = reconcile_semantic_running store ~now in
    let* count = with_statement
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
         Ok (Sqlite3.changes store.db)) in
    let* () = List.fold_left (fun result (operation : Operation.t) -> let* () = result in
      settle_batch_members_with_db store.db ~execution_id:operation.operation_id) (Ok ()) running in
    let* () =
      if count = List.length interrupted then Ok ()
      else Error (Integrity_error (Printf.sprintf
        "restart settlement failed %d row(s) for %d interrupted operation(s)" count (List.length interrupted))) in
    (* The failed rows as they were read, still [Running]: the caller needs
       their identity and source to leave an operator-visible failure row,
       which the store cannot write itself. *)
    Ok interrupted)
;;

module For_testing = struct
  type nonrec commit_fault = commit_fault =
    | Fail_before_commit
    | Fail_after_commit

  let fail_next_commit fault = Atomic.set next_commit_fault (Some fault)
  let clear_commit_fault () = Atomic.set next_commit_fault None
  let fail_next_runtime_retry_read () = Atomic.set next_runtime_retry_read_fault true
  let clear_runtime_retry_read_fault () = Atomic.set next_runtime_retry_read_fault false
  let database_file = database_file
  let database_application_id = database_application_id
  let owning_semantic_executions store =
    let* () = ensure_open store in
    owning_semantic_rows store.db
  let table_column_counts = table_column_counts
end
