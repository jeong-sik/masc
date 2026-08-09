type source =
  | Dashboard of { thread_id : string }
  | Discord of
      { channel_id : string
      ; user_id : string
      }
  | Slack of
      { channel_id : string
      ; user_id : string
      ; user_name : string
      ; team_id : string option
      ; thread_ts : string option
      }

type input =
  { content : string
  ; user_blocks : Keeper_multimodal_input.user_input_block list
  ; attachments : Keeper_chat_store.attachment list
  ; submitted_at : float
  ; source : source
  ; user_row_origin : Keeper_chat_store.user_row_origin
  }

type edit_input =
  { content : string
  ; user_blocks : Keeper_multimodal_input.user_input_block list
  ; attachments : Keeper_chat_store.attachment list
  }

type failure_kind =
  | Interrupted_by_restart
  | Shutdown_interrupted
  | Turn_failed
  | No_visible_reply
  | Transcript_persist_failed
  | Connector_unavailable
  | Delivery_failed
  | Terminal_effect_failed
  | Internal_error

type state =
  | Queued
  | Running of { started_at : float }
  | Succeeded of
      { completed_at : float
      ; outcome_ref : string
      }
  | Failed of
      { completed_at : float
      ; kind : failure_kind
      ; detail : string
      ; outcome_ref : string option
      }
  | Cancelled of { completed_at : float }

type operation =
  { operation_id : string
  ; admission_digest : string
  ; execution_digest : string
  ; sequence : int64
  ; input : input option
  ; state : state
  }

type error =
  | Unknown_operation of string
  | Not_queued of
      { operation_id : string
      ; state : state
      }
  | Idempotency_conflict of string
  | Invalid_input of string
  | Store_unavailable of string

type submit_result =
  | Accepted of operation
  | Existing of operation

type t =
  { db : Sqlite3.db
  ; path : string
  ; ownership_root : string
  ; mutable closed : bool
  }

let ( let* ) = Result.bind

let database_schema = "masc.keeper_chat_operations.v1"
let database_user_version = 1L
let database_application_id = 0x4d434f50L
let database_file = "chat-operations.sqlite3"

type commit_fault =
  | Before_commit
  | After_commit

let commit_fault_for_testing : commit_fault option Atomic.t = Atomic.make None

let failure_kind_to_string = function
  | Interrupted_by_restart -> "interrupted_by_restart"
  | Shutdown_interrupted -> "shutdown_interrupted"
  | Turn_failed -> "turn_failed"
  | No_visible_reply -> "no_visible_reply"
  | Transcript_persist_failed -> "transcript_persist_failed"
  | Connector_unavailable -> "connector_unavailable"
  | Delivery_failed -> "delivery_failed"
  | Terminal_effect_failed -> "terminal_effect_failed"
  | Internal_error -> "internal_error"
;;

let failure_kind_of_string = function
  | "interrupted_by_restart" -> Ok Interrupted_by_restart
  | "shutdown_interrupted" -> Ok Shutdown_interrupted
  | "turn_failed" -> Ok Turn_failed
  | "no_visible_reply" -> Ok No_visible_reply
  | "transcript_persist_failed" -> Ok Transcript_persist_failed
  | "connector_unavailable" -> Ok Connector_unavailable
  | "delivery_failed" -> Ok Delivery_failed
  | "terminal_effect_failed" -> Ok Terminal_effect_failed
  | "internal_error" -> Ok Internal_error
  | value -> Error ("unknown operation failure kind: " ^ value)
;;

let error_to_string = function
  | Unknown_operation operation_id -> "unknown operation: " ^ operation_id
  | Not_queued { operation_id; _ } -> "operation is not queued: " ^ operation_id
  | Idempotency_conflict operation_id ->
    "operation id was already submitted with different input: " ^ operation_id
  | Invalid_input detail -> "invalid operation input: " ^ detail
  | Store_unavailable detail -> "chat operation store unavailable: " ^ detail
;;

let store_error detail = Error (Store_unavailable detail)

let valid_nonempty value =
  let value = String.trim value in
  value <> "" && String.is_valid_utf_8 value && not (String.contains value '\000')
;;

let validate_optional label = function
  | None -> Ok ()
  | Some value when valid_nonempty value -> Ok ()
  | Some _ -> Error (Invalid_input (label ^ " must be non-empty UTF-8 when present"))
;;

let validate_source = function
  | Dashboard { thread_id } ->
    if valid_nonempty thread_id
    then Ok ()
    else Error (Invalid_input "dashboard thread_id must be non-empty UTF-8")
  | Discord { channel_id; user_id } ->
    if not (valid_nonempty channel_id)
    then Error (Invalid_input "discord channel_id must be non-empty UTF-8")
    else if not (valid_nonempty user_id)
    then Error (Invalid_input "discord user_id must be non-empty UTF-8")
    else Ok ()
  | Slack { channel_id; user_id; user_name; team_id; thread_ts } ->
    if not (valid_nonempty channel_id)
    then Error (Invalid_input "slack channel_id must be non-empty UTF-8")
    else if not (valid_nonempty user_id)
    then Error (Invalid_input "slack user_id must be non-empty UTF-8")
    else if not (valid_nonempty user_name)
    then Error (Invalid_input "slack user_name must be non-empty UTF-8")
    else
      let* () = validate_optional "slack team_id" team_id in
      validate_optional "slack thread_ts" thread_ts
;;

let validate_body ~content ~user_blocks ~attachments =
  if not (String.is_valid_utf_8 content) || String.contains content '\000'
  then Error (Invalid_input "content must be UTF-8 without NUL")
  else if String.trim content = "" && user_blocks = [] && attachments = []
  then Error (Invalid_input "operation input has no content or media")
  else Ok ()
;;

let validate_input (input : input) =
  if not (Float.is_finite input.submitted_at)
  then Error (Invalid_input "submitted_at must be finite")
  else
    let* () = validate_source input.source in
    validate_body
      ~content:input.content
      ~user_blocks:input.user_blocks
      ~attachments:input.attachments
;;

let validate_edit input =
  validate_body
    ~content:input.content
    ~user_blocks:input.user_blocks
    ~attachments:input.attachments
;;

let validate_operation_id operation_id =
  if not (valid_nonempty operation_id)
  then Error (Invalid_input "operation_id must be non-empty UTF-8")
  else if String.length operation_id > 256
  then Error (Invalid_input "operation_id exceeds 256 bytes")
  else Ok ()
;;

let validate_timestamp label value =
  if Float.is_finite value
  then Ok ()
  else Error (Invalid_input (label ^ " must be finite"))
;;

let source_to_yojson = function
  | Dashboard { thread_id } ->
    `Assoc [ "kind", `String "dashboard"; "thread_id", `String thread_id ]
  | Discord { channel_id; user_id } ->
    `Assoc
      [ "kind", `String "discord"
      ; "channel_id", `String channel_id
      ; "user_id", `String user_id
      ]
  | Slack { channel_id; user_id; user_name; team_id; thread_ts } ->
    `Assoc
      [ "kind", `String "slack"
      ; "channel_id", `String channel_id
      ; "user_id", `String user_id
      ; "user_name", `String user_name
      ; ("team_id", Option.fold ~none:`Null ~some:(fun value -> `String value) team_id)
      ; ( "thread_ts"
        , Option.fold ~none:`Null ~some:(fun value -> `String value) thread_ts )
      ]
;;

let user_row_origin_to_yojson = function
  | Keeper_chat_store.Needs_append -> `Assoc [ "kind", `String "needs_append" ]
  | Keeper_chat_store.Already_persisted { row_id } ->
    `Assoc [ "kind", `String "already_persisted"; "row_id", `String row_id ]
  | Keeper_chat_store.Already_persisted_upstream ->
    `Assoc [ "kind", `String "already_persisted_upstream" ]
;;

let input_body_to_yojson (input : input) =
  `Assoc
    [ "content", `String input.content
    ; "user_blocks", Keeper_multimodal_input.user_blocks_to_yojson input.user_blocks
    ; "attachments", Keeper_multimodal_input.attachments_to_yojson input.attachments
    ; "submitted_at", `Float input.submitted_at
    ; "user_row_origin", user_row_origin_to_yojson input.user_row_origin
    ]
;;

let canonical_input (input : input) =
  `Assoc
    [ "source", source_to_yojson input.source
    ; "input", input_body_to_yojson input
    ]
  |> Yojson.Safe.to_string
;;

let input_digest (input : input) =
  Digestif.SHA256.(canonical_input input |> digest_string |> to_hex)
;;

let exact_object_keys ~context expected = function
  | `Assoc fields ->
    let actual = List.map fst fields |> List.sort_uniq String.compare in
    let expected = List.sort String.compare expected in
    if actual = expected
    then Ok fields
    else
      Error
        (Printf.sprintf
           "%s JSON keys differ: expected=[%s] actual=[%s]"
           context
           (String.concat "," expected)
           (String.concat "," actual))
  | _ -> Error (context ^ " must be a JSON object")
;;

let member fields key =
  match List.assoc_opt key fields with
  | Some value -> Ok value
  | None -> Error ("missing JSON field: " ^ key)
;;

let string_member fields key =
  match member fields key with
  | Ok (`String value) -> Ok value
  | Ok _ -> Error ("JSON field must be string: " ^ key)
  | Error _ as error -> error
;;

let optional_string_member fields key =
  match member fields key with
  | Ok `Null -> Ok None
  | Ok (`String value) -> Ok (Some value)
  | Ok _ -> Error ("JSON field must be string or null: " ^ key)
  | Error _ as error -> error
;;

let source_of_yojson json =
  let* outer =
    match json with
    | `Assoc fields -> Ok fields
    | _ -> Error "operation source must be a JSON object"
  in
  match List.assoc_opt "kind" outer with
  | Some (`String "dashboard") ->
    let* fields =
      exact_object_keys ~context:"dashboard operation source" [ "kind"; "thread_id" ] json
    in
    let* thread_id = string_member fields "thread_id" in
    let source = Dashboard { thread_id } in
    let* () = validate_source source |> Result.map_error error_to_string in
    Ok source
  | Some (`String "discord") ->
    let* fields =
      exact_object_keys
        ~context:"discord operation source"
        [ "channel_id"; "kind"; "user_id" ]
        json
    in
    let* channel_id = string_member fields "channel_id" in
    let* user_id = string_member fields "user_id" in
    let source = Discord { channel_id; user_id } in
    let* () = validate_source source |> Result.map_error error_to_string in
    Ok source
  | Some (`String "slack") ->
    let* fields =
      exact_object_keys
        ~context:"slack operation source"
        [ "channel_id"; "kind"; "team_id"; "thread_ts"; "user_id"; "user_name" ]
        json
    in
    let* channel_id = string_member fields "channel_id" in
    let* user_id = string_member fields "user_id" in
    let* user_name = string_member fields "user_name" in
    let* team_id = optional_string_member fields "team_id" in
    let* thread_ts = optional_string_member fields "thread_ts" in
    let source = Slack { channel_id; user_id; user_name; team_id; thread_ts } in
    let* () = validate_source source |> Result.map_error error_to_string in
    Ok source
  | Some (`String kind) -> Error ("unknown operation source kind: " ^ kind)
  | Some _ -> Error "operation source kind must be a string"
  | None -> Error "operation source kind is missing"
;;

let attachment_of_yojson json =
  let* fields =
    exact_object_keys
      ~context:"operation attachment"
      [ "data"; "id"; "mime_type"; "name"; "size"; "type" ]
      json
  in
  let* id = string_member fields "id" in
  let* att_type = string_member fields "type" in
  let* name = string_member fields "name" in
  let* mime_type = string_member fields "mime_type" in
  let* data = string_member fields "data" in
  let* size =
    match member fields "size" with
    | Ok (`Int value) when value >= 0 -> Ok value
    | Ok _ -> Error "operation attachment size must be a non-negative integer"
    | Error _ as error -> error
  in
  if not (valid_nonempty id) || data = ""
  then Error "operation attachment requires non-empty id and data"
  else Ok { Keeper_chat_store.id; att_type; name; size; mime_type; data }
;;

let attachments_of_yojson = function
  | `List values ->
    List.fold_left
      (fun result json ->
         let* acc = result in
         let* attachment = attachment_of_yojson json in
         Ok (attachment :: acc))
      (Ok [])
      values
    |> Result.map List.rev
  | _ -> Error "operation attachments must be an array"
;;

let user_row_origin_of_yojson json =
  match json with
  | `Assoc [ "kind", `String "needs_append" ] -> Ok Keeper_chat_store.Needs_append
  | `Assoc [ "kind", `String "already_persisted_upstream" ] ->
    Ok Keeper_chat_store.Already_persisted_upstream
  | _ ->
    let* fields =
      exact_object_keys
        ~context:"operation user_row_origin"
        [ "kind"; "row_id" ]
        json
    in
    let* kind = string_member fields "kind" in
    if not (String.equal kind "already_persisted")
    then Error ("unknown operation user_row_origin kind: " ^ kind)
    else
      let* row_id = string_member fields "row_id" in
      if valid_nonempty row_id
      then Ok (Keeper_chat_store.Already_persisted { row_id })
      else Error "operation persisted row id must be non-empty UTF-8"
;;

let input_body_of_yojson ~source json =
  let* fields =
    exact_object_keys
      ~context:"operation input"
      [ "attachments"; "content"; "submitted_at"; "user_blocks"; "user_row_origin" ]
      json
  in
  let* content = string_member fields "content" in
  let* submitted_at =
    match member fields "submitted_at" with
    | Ok (`Float value) when Float.is_finite value -> Ok value
    | Ok (`Int value) -> Ok (Float.of_int value)
    | Ok _ -> Error "operation submitted_at must be finite numeric JSON"
    | Error _ as error -> error
  in
  let* attachments_json = member fields "attachments" in
  let* attachments = attachments_of_yojson attachments_json in
  let* user_row_origin_json = member fields "user_row_origin" in
  let* user_row_origin = user_row_origin_of_yojson user_row_origin_json in
  let* user_blocks =
    match Keeper_multimodal_input.parse_user_blocks json with
    | Ok blocks -> Ok blocks
    | Error detail -> Error detail
  in
  let input = { content; user_blocks; attachments; submitted_at; source; user_row_origin } in
  let* () = validate_input input |> Result.map_error error_to_string in
  Ok input
;;

let metadata_table_sql =
  "CREATE TABLE metadata (singleton INTEGER PRIMARY KEY CHECK (singleton = 1), schema TEXT NOT NULL, next_sequence INTEGER NOT NULL CHECK (next_sequence >= 0)) STRICT"
;;

let operations_table_sql =
  "CREATE TABLE operations (operation_id TEXT PRIMARY KEY NOT NULL, admission_digest TEXT NOT NULL CHECK (length(admission_digest) = 64), execution_digest TEXT NOT NULL CHECK (length(execution_digest) = 64), fifo_sequence INTEGER NOT NULL UNIQUE CHECK (fifo_sequence >= 0), source_json TEXT, input_json TEXT, state_kind TEXT NOT NULL CHECK (state_kind IN ('queued', 'running', 'succeeded', 'failed', 'cancelled')), submitted_at REAL NOT NULL, started_at REAL, completed_at REAL, outcome_ref TEXT, failure_kind TEXT, failure_detail TEXT, CHECK ((state_kind = 'queued' AND source_json IS NOT NULL AND input_json IS NOT NULL AND started_at IS NULL AND completed_at IS NULL AND outcome_ref IS NULL AND failure_kind IS NULL AND failure_detail IS NULL) OR (state_kind = 'running' AND source_json IS NOT NULL AND input_json IS NOT NULL AND started_at IS NOT NULL AND completed_at IS NULL AND outcome_ref IS NULL AND failure_kind IS NULL AND failure_detail IS NULL) OR (state_kind = 'succeeded' AND source_json IS NULL AND input_json IS NULL AND started_at IS NOT NULL AND completed_at IS NOT NULL AND outcome_ref IS NOT NULL AND length(outcome_ref) > 0 AND failure_kind IS NULL AND failure_detail IS NULL) OR (state_kind = 'failed' AND source_json IS NULL AND input_json IS NULL AND started_at IS NOT NULL AND completed_at IS NOT NULL AND failure_kind IS NOT NULL AND failure_detail IS NOT NULL) OR (state_kind = 'cancelled' AND source_json IS NULL AND input_json IS NULL AND started_at IS NULL AND completed_at IS NOT NULL AND outcome_ref IS NULL AND failure_kind IS NULL AND failure_detail IS NULL))) STRICT, WITHOUT ROWID"
;;

let state_sequence_index_sql =
  "CREATE INDEX operations_state_sequence ON operations (state_kind, fifo_sequence)"
;;

let single_running_index_sql =
  "CREATE UNIQUE INDEX operations_single_running ON operations ((CASE WHEN state_kind = 'running' THEN 1 END))"
;;

let expected_schema_objects =
  [ "index", "operations_single_running", single_running_index_sql
  ; "index", "operations_state_sequence", state_sequence_index_sql
  ; "index", "sqlite_autoindex_operations_2", ""
  ; "table", "metadata", metadata_table_sql
  ; "table", "operations", operations_table_sql
  ]
;;

let exec db ~operation sql =
  Keeper_chat_queue_storage.exec db ~operation sql
  |> Result.map_error (fun detail -> Store_unavailable detail)
;;

let with_statement db sql body =
  match
    try Ok (Sqlite3.prepare db sql) with
    | exn -> store_error ("SQLite statement prepare failed: " ^ Printexc.to_string exn)
  with
  | Error _ as error -> error
  | Ok stmt ->
    let body_result =
      try body stmt with
      | Eio.Cancel.Cancelled _ as exn ->
        (match Keeper_chat_queue_storage.finalize db stmt with
         | Ok () -> ()
         | Error detail ->
           Log.Keeper.error
             "chat operation statement finalize failed during cancellation: %s"
             detail);
        raise exn
      | exn ->
        store_error ("SQLite statement body raised: " ^ Printexc.to_string exn)
    in
    let cleanup =
      Keeper_chat_queue_storage.finalize db stmt
      |> Result.map_error (fun detail -> Store_unavailable detail)
    in
    (match body_result, cleanup with
     | Ok value, Ok () -> Ok value
     | Error error, Ok () | Ok _, Error error -> Error error
     | Error first, Error second ->
       store_error (error_to_string first ^ "; " ^ error_to_string second))
;;

let configure_connection db =
  let* mode =
    Keeper_chat_queue_storage.single_text
      db
      ~operation:"set chat operation DELETE journal mode"
      "PRAGMA journal_mode=DELETE"
    |> Result.map_error (fun detail -> Store_unavailable detail)
  in
  if not (String.equal mode "delete")
  then store_error ("SQLite refused DELETE journal mode: " ^ mode)
  else
    let* () = exec db ~operation:"set chat operation FULL synchronous" "PRAGMA synchronous=FULL" in
    let* () = exec db ~operation:"enable chat operation foreign keys" "PRAGMA foreign_keys=ON" in
    let* synchronous =
      Keeper_chat_queue_storage.single_int64
        db
        ~operation:"read chat operation synchronous mode"
        "PRAGMA synchronous"
      |> Result.map_error (fun detail -> Store_unavailable detail)
    in
    let* foreign_keys =
      Keeper_chat_queue_storage.single_int64
        db
        ~operation:"read chat operation foreign key mode"
        "PRAGMA foreign_keys"
      |> Result.map_error (fun detail -> Store_unavailable detail)
    in
    if not (Int64.equal synchronous 2L)
    then store_error (Printf.sprintf "SQLite synchronous mode is %Ld, expected FULL(2)" synchronous)
    else if not (Int64.equal foreign_keys 1L)
    then store_error "SQLite foreign key enforcement could not be enabled"
    else Ok ()
;;

let rollback db primary =
  match exec db ~operation:"rollback chat operation transaction" "ROLLBACK" with
  | Ok () -> Error primary
  | Error rollback_error ->
    store_error (error_to_string primary ^ "; rollback failed: " ^ error_to_string rollback_error)
;;

let initialize_database db path =
  let* () = exec db ~operation:"begin chat operation schema transaction" "BEGIN EXCLUSIVE" in
  let body =
    let* () = exec db ~operation:"create chat operation metadata" metadata_table_sql in
    let* () = exec db ~operation:"create chat operations" operations_table_sql in
    let* () =
      exec db ~operation:"create chat operation single-running index" single_running_index_sql
    in
    let* () = exec db ~operation:"create chat operation state index" state_sequence_index_sql in
    let* () =
      with_statement
        db
        "INSERT INTO metadata(singleton, schema, next_sequence) VALUES (1, ?, 0)"
        (fun stmt ->
           let* () =
             Keeper_chat_queue_storage.bind_text
               db
               stmt
               ~operation:"bind chat operation schema"
               1
               database_schema
             |> Result.map_error (fun detail -> Store_unavailable detail)
           in
           Keeper_chat_queue_storage.expect_done
             db
             stmt
             ~operation:"insert chat operation metadata"
           |> Result.map_error (fun detail -> Store_unavailable detail))
    in
    let* () =
      exec
        db
        ~operation:"set chat operation application id"
        (Printf.sprintf "PRAGMA application_id=%Ld" database_application_id)
    in
    let* () =
      exec
        db
        ~operation:"set chat operation user version"
        (Printf.sprintf "PRAGMA user_version=%Ld" database_user_version)
    in
    exec db ~operation:"commit chat operation schema transaction" "COMMIT"
  in
  match body with
  | Error error -> rollback db error
  | Ok () ->
    (try
       Keeper_fs_durable_directory.fsync_directory (Filename.dirname path);
       Ok ()
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       store_error
         ("failed to durably publish chat operation database: " ^ Printexc.to_string exn))
;;

let read_schema_objects db =
  with_statement
    db
    "SELECT type, name, COALESCE(sql, '') FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%' OR name = 'sqlite_autoindex_operations_2' ORDER BY type, name"
    (fun stmt ->
       let rec loop acc =
         match Sqlite3.step stmt with
         | Sqlite3.Rc.DONE -> Ok (List.rev acc)
         | Sqlite3.Rc.ROW ->
           loop
             (( Sqlite3.column_text stmt 0
              , Sqlite3.column_text stmt 1
              , Sqlite3.column_text stmt 2 )
              :: acc)
         | rc ->
           store_error
             (Keeper_chat_queue_storage.error
                ~operation:"read chat operation schema objects"
                db
                rc)
       in
       loop [])
;;

let validate_database db =
  let* application_id =
    Keeper_chat_queue_storage.single_int64
      db
      ~operation:"read chat operation application id"
      "PRAGMA application_id"
    |> Result.map_error (fun detail -> Store_unavailable detail)
  in
  let* user_version =
    Keeper_chat_queue_storage.single_int64
      db
      ~operation:"read chat operation user version"
      "PRAGMA user_version"
    |> Result.map_error (fun detail -> Store_unavailable detail)
  in
  let* schema =
    Keeper_chat_queue_storage.single_text
      db
      ~operation:"read chat operation schema"
      "SELECT schema FROM metadata WHERE singleton = 1"
    |> Result.map_error (fun detail -> Store_unavailable detail)
  in
  let* metadata_count =
    Keeper_chat_queue_storage.single_int64
      db
      ~operation:"count chat operation metadata"
      "SELECT COUNT(*) FROM metadata"
    |> Result.map_error (fun detail -> Store_unavailable detail)
  in
  if not (Int64.equal application_id database_application_id)
  then store_error (Printf.sprintf "unsupported operation application_id=%Ld" application_id)
  else if not (Int64.equal user_version database_user_version)
  then store_error (Printf.sprintf "unsupported operation user_version=%Ld" user_version)
  else if not (String.equal schema database_schema)
  then store_error ("unsupported operation schema: " ^ schema)
  else if not (Int64.equal metadata_count 1L)
  then store_error "operation database must contain exactly one metadata row"
  else
    let* objects = read_schema_objects db in
    if objects = expected_schema_objects
    then Ok ()
    else store_error "operation database schema does not exactly match masc.keeper_chat_operations.v1"
;;

let database_path ~base_path ~keeper_name =
  match Config_dir_resolver.canonical_base_path base_path with
  | Error error ->
    Error
      (Invalid_input
         (Config_dir_resolver.canonical_base_path_error_to_string error))
  | Ok base_path ->
    if not (Safe_identifier.is_portable_name keeper_name)
    then Error (Invalid_input ("invalid Keeper name: " ^ keeper_name))
    else
      Ok
        (Filename.concat
           (Filename.concat (Common.keepers_runtime_dir_of_base ~base_path) keeper_name)
           database_file)
;;

let close_db db =
  try
    if Sqlite3.db_close db
    then Ok ()
    else store_error "SQLite operation database close reported a busy handle"
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> store_error ("SQLite operation database close failed: " ^ Printexc.to_string exn)
;;

let open_ ~base_path ~keeper_name =
  let* path = database_path ~base_path ~keeper_name in
  let* ownership_root =
    match Config_dir_resolver.canonical_base_path base_path with
    | Ok value -> Ok value
    | Error error ->
      Error
        (Invalid_input
           (Config_dir_resolver.canonical_base_path_error_to_string error))
  in
  let* () =
    Keeper_chat_queue_storage.prepare_database_parent
      ~ownership_root
      ~path
      ~create_if_missing:true
    |> Result.map_error (fun detail -> Store_unavailable detail)
  in
  let* observed =
    Keeper_chat_queue_storage.validate_database_paths ~ownership_root path
    |> Result.map_error (fun detail -> Store_unavailable detail)
  in
  let missing = observed = Keeper_chat_queue_storage.Path_absent in
  let db =
    try
      Ok
        (if missing
         then Sqlite3.db_open ~mutex:`FULL path
         else Sqlite3.db_open ~mode:`NO_CREATE ~mutex:`FULL path)
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn -> store_error ("SQLite operation database open failed: " ^ Printexc.to_string exn)
  in
  let* db = db in
  let prepared =
    let* () = configure_connection db in
    if missing then initialize_database db path else validate_database db
  in
  (match prepared with
   | Ok () -> Ok { db; path; ownership_root; closed = false }
   | Error error ->
     let close_result = close_db db in
     (match close_result with
      | Ok () -> Error error
      | Error close_error ->
        store_error (error_to_string error ^ "; " ^ error_to_string close_error)))
;;

let ensure_open t =
  if t.closed then Error (Store_unavailable "operation store is closed") else Ok ()
;;

let close t =
  if t.closed
  then Ok ()
  else (
    t.closed <- true;
    let result = close_db t.db in
    ignore (Sys.opaque_identity t.db);
    let identity =
      Keeper_chat_queue_storage.validate_owned_parent
        ~ownership_root:t.ownership_root
        t.path
      |> Result.map_error (fun detail -> Store_unavailable detail)
    in
    match result, identity with
    | Ok (), Ok () -> Ok ()
    | Error error, Ok () | Ok (), Error error -> Error error
    | Error first, Error second ->
      store_error (error_to_string first ^ "; " ^ error_to_string second))
;;

let state_of_columns stmt =
  let kind = Sqlite3.column_text stmt 5 in
  let nullable_text column =
    if Sqlite3.column_is_null stmt column then None else Some (Sqlite3.column_text stmt column)
  in
  let nullable_float column =
    if Sqlite3.column_is_null stmt column then None else Some (Sqlite3.column_double stmt column)
  in
  match kind with
  | "queued" -> Ok Queued
  | "running" ->
    (match nullable_float 7 with
     | Some started_at when Float.is_finite started_at -> Ok (Running { started_at })
     | Some _ | None -> store_error "running operation has invalid started_at")
  | "succeeded" ->
    (match nullable_float 8, nullable_text 9 with
     | Some completed_at, Some outcome_ref
       when Float.is_finite completed_at && valid_nonempty outcome_ref ->
       Ok (Succeeded { completed_at; outcome_ref })
     | _ -> store_error "succeeded operation has invalid terminal columns")
  | "failed" ->
    (match nullable_float 8, nullable_text 10, nullable_text 11 with
     | Some completed_at, Some kind, Some detail when Float.is_finite completed_at ->
       let* kind = failure_kind_of_string kind |> Result.map_error (fun detail -> Store_unavailable detail) in
       Ok (Failed { completed_at; kind; detail; outcome_ref = nullable_text 9 })
     | _ -> store_error "failed operation has invalid terminal columns")
  | "cancelled" ->
    (match nullable_float 8 with
     | Some completed_at when Float.is_finite completed_at -> Ok (Cancelled { completed_at })
     | Some _ | None -> store_error "cancelled operation has invalid completed_at")
  | value -> store_error ("unknown persisted operation state: " ^ value)
;;

let operation_of_row stmt =
  let operation_id = Sqlite3.column_text stmt 0 in
  let admission_digest = Sqlite3.column_text stmt 1 in
  let execution_digest = Sqlite3.column_text stmt 2 in
  let sequence = Sqlite3.column_int64 stmt 3 in
  let source_json =
    if Sqlite3.column_is_null stmt 4 then None else Some (Sqlite3.column_text stmt 4)
  in
  let input_json =
    if Sqlite3.column_is_null stmt 6 then None else Some (Sqlite3.column_text stmt 6)
  in
  let* state = state_of_columns stmt in
  let* input =
    match state, source_json, input_json with
    | (Queued | Running _), Some source_json, Some input_json ->
      (match Yojson.Safe.from_string source_json, Yojson.Safe.from_string input_json with
       | source_json, input_json ->
         let* source = source_of_yojson source_json |> Result.map_error (fun detail -> Store_unavailable detail) in
         input_body_of_yojson ~source input_json
         |> Result.map_error (fun detail -> Store_unavailable detail)
       | exception exn ->
         store_error ("operation input JSON parse failed: " ^ Printexc.to_string exn))
      |> Result.map Option.some
    | (Succeeded _ | Failed _ | Cancelled _), None, None -> Ok None
    | _ -> store_error "operation input retention invariant is violated"
  in
  Ok { operation_id; admission_digest; execution_digest; sequence; input; state }
;;

let select_columns =
  "operation_id, admission_digest, execution_digest, fifo_sequence, source_json, state_kind, input_json, started_at, completed_at, outcome_ref, failure_kind, failure_detail"
;;

let lookup_optional t ~operation_id =
  let* () = ensure_open t in
  with_statement
    t.db
    ("SELECT " ^ select_columns ^ " FROM operations WHERE operation_id = ?")
    (fun stmt ->
       let* () =
         Keeper_chat_queue_storage.bind_text
           t.db stmt ~operation:"bind operation lookup id" 1 operation_id
         |> Result.map_error (fun detail -> Store_unavailable detail)
       in
       match Sqlite3.step stmt with
       | Sqlite3.Rc.DONE -> Ok None
       | Sqlite3.Rc.ROW ->
         let* operation = operation_of_row stmt in
         (match Sqlite3.step stmt with
          | Sqlite3.Rc.DONE -> Ok (Some operation)
          | rc ->
            store_error
              (Keeper_chat_queue_storage.error
                 ~operation:"finish operation lookup"
                 t.db
                 rc))
       | rc ->
         store_error
           (Keeper_chat_queue_storage.error ~operation:"lookup operation" t.db rc))
;;

let lookup t ~operation_id =
  let* () = validate_operation_id operation_id in
  let* operation = lookup_optional t ~operation_id in
  match operation with
  | Some operation -> Ok operation
  | None -> Error (Unknown_operation operation_id)
;;

let operation_equal left right = left = right

let durable_readback t ~operation_id =
  let* db =
    try Ok (Sqlite3.db_open ~mode:`READONLY ~mutex:`FULL t.path) with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn ->
      store_error
        ("SQLite durable read-back open failed: " ^ Printexc.to_string exn)
  in
  let readback =
    let reader = { t with db; closed = false } in
    lookup_optional reader ~operation_id
  in
  let closed = close_db db in
  match readback, closed with
  | Ok value, Ok () -> Ok value
  | Error error, Ok () | Ok _, Error error -> Error error
  | Error first, Error second ->
    store_error (error_to_string first ^ "; " ^ error_to_string second)
;;

let rollback_after_uncertain_commit t =
  match exec t.db ~operation:"rollback uncertain chat operation commit" "ROLLBACK" with
  | Ok () | Error _ -> ()
;;

let commit_transaction t ~operation =
  match Atomic.exchange commit_fault_for_testing None with
  | None -> exec t.db ~operation "COMMIT"
  | Some Before_commit ->
    store_error "injected chat operation failure before COMMIT"
  | Some After_commit ->
    (match exec t.db ~operation "COMMIT" with
     | Error _ as error -> error
     | Ok () -> store_error "injected uncertain chat operation COMMIT result")
;;

let commit_operation t expected =
  match commit_transaction t ~operation:"commit chat operation transaction" with
  | Ok () -> Ok expected
  | Error commit_error ->
    (match durable_readback t ~operation_id:expected.operation_id with
     | Ok (Some observed) when operation_equal observed expected -> Ok observed
     | Ok _ | Error _ ->
       rollback_after_uncertain_commit t;
       store_error
         ("chat operation commit could not be confirmed: " ^ error_to_string commit_error))
;;

let read_next_sequence t =
  Keeper_chat_queue_storage.single_int64
    t.db
    ~operation:"read next chat operation sequence"
    "SELECT next_sequence FROM metadata WHERE singleton = 1"
  |> Result.map_error (fun detail -> Store_unavailable detail)
;;

let allocate_sequence t =
  let* sequence = read_next_sequence t in
  if Int64.equal sequence Int64.max_int
  then Error (Invalid_input "chat operation sequence exhausted")
  else
    let* () =
      with_statement
        t.db
        "UPDATE metadata SET next_sequence = ? WHERE singleton = 1"
        (fun stmt ->
           let* () =
             Keeper_chat_queue_storage.bind_int64
               t.db
               stmt
               ~operation:"bind next chat operation sequence"
               1
               (Int64.succ sequence)
             |> Result.map_error (fun detail -> Store_unavailable detail)
           in
           Keeper_chat_queue_storage.expect_done
             t.db
             stmt
             ~operation:"advance chat operation sequence"
           |> Result.map_error (fun detail -> Store_unavailable detail))
    in
    Ok sequence
;;

let submit t ~operation_id input =
  let* () = ensure_open t in
  let* () = validate_operation_id operation_id in
  let* () = validate_input input in
  let digest = input_digest input in
  let* existing = lookup_optional t ~operation_id in
  match existing with
  | Some operation when String.equal operation.admission_digest digest ->
    Ok (Existing operation)
  | Some _ -> Error (Idempotency_conflict operation_id)
  | None ->
    let* () = exec t.db ~operation:"begin chat operation submit" "BEGIN IMMEDIATE" in
    let body =
      let* sequence = allocate_sequence t in
      let source_json = source_to_yojson input.source |> Yojson.Safe.to_string in
      let input_json = input_body_to_yojson input |> Yojson.Safe.to_string in
      let* () =
        with_statement
          t.db
          "INSERT INTO operations(operation_id, admission_digest, execution_digest, fifo_sequence, source_json, input_json, state_kind, submitted_at) VALUES (?, ?, ?, ?, ?, ?, 'queued', ?)"
          (fun stmt ->
             let bind_text index value operation =
               Keeper_chat_queue_storage.bind_text t.db stmt ~operation index value
               |> Result.map_error (fun detail -> Store_unavailable detail)
             in
             let* () = bind_text 1 operation_id "bind submitted operation id" in
             let* () = bind_text 2 digest "bind submitted admission digest" in
             let* () = bind_text 3 digest "bind submitted execution digest" in
             let* () =
               Keeper_chat_queue_storage.bind_int64
                 t.db stmt ~operation:"bind submitted operation sequence" 4 sequence
               |> Result.map_error (fun detail -> Store_unavailable detail)
             in
             let* () = bind_text 5 source_json "bind submitted operation source" in
             let* () = bind_text 6 input_json "bind submitted operation input" in
             let* () =
               Keeper_chat_queue_storage.bind
                 t.db stmt ~operation:"bind submitted operation timestamp" 7
                 (Sqlite3.Data.FLOAT input.submitted_at)
               |> Result.map_error (fun detail -> Store_unavailable detail)
             in
             Keeper_chat_queue_storage.expect_done
               t.db stmt ~operation:"insert submitted chat operation"
             |> Result.map_error (fun detail -> Store_unavailable detail))
      in
      Ok
        { operation_id
        ; admission_digest = digest
        ; execution_digest = digest
        ; sequence
        ; input = Some input
        ; state = Queued
        }
    in
    (match body with
     | Error error -> rollback t.db error
     | Ok operation -> commit_operation t operation |> Result.map (fun value -> Accepted value))
;;

let list_queued t ~after_sequence ~limit =
  let* () = ensure_open t in
  if limit <= 0 || limit > 1000
  then Error (Invalid_input "queued operation limit must be between 1 and 1000")
  else
    let after_sequence = Option.value ~default:(-1L) after_sequence in
    if Int64.compare after_sequence (-1L) < 0
    then Error (Invalid_input "after_sequence must be non-negative when present")
    else
      with_statement
        t.db
        ("SELECT " ^ select_columns
         ^ " FROM operations WHERE state_kind = 'queued' AND fifo_sequence > ? ORDER BY fifo_sequence LIMIT ?")
        (fun stmt ->
           let* () =
             Keeper_chat_queue_storage.bind_int64
               t.db stmt ~operation:"bind queued after sequence" 1 after_sequence
             |> Result.map_error (fun detail -> Store_unavailable detail)
           in
           let* () =
             Keeper_chat_queue_storage.bind_int64
               t.db stmt ~operation:"bind queued operation limit" 2 (Int64.of_int limit)
             |> Result.map_error (fun detail -> Store_unavailable detail)
           in
           let rec loop acc =
             match Sqlite3.step stmt with
             | Sqlite3.Rc.DONE -> Ok (List.rev acc)
             | Sqlite3.Rc.ROW ->
               let* operation = operation_of_row stmt in
               loop (operation :: acc)
             | rc ->
               store_error
                 (Keeper_chat_queue_storage.error
                    ~operation:"list queued chat operations"
                    t.db
                    rc)
           in
           loop [])
;;

let update_and_read t ~operation_id ~sql ~bind =
  let* () = exec t.db ~operation:"begin chat operation mutation" "BEGIN IMMEDIATE" in
  let body =
    let* () =
      with_statement t.db sql (fun stmt ->
          let* () = bind stmt in
          Keeper_chat_queue_storage.expect_done
            t.db stmt ~operation:"mutate chat operation"
          |> Result.map_error (fun detail -> Store_unavailable detail))
    in
    if Sqlite3.changes t.db <> 1
    then store_error "chat operation mutation changed an unexpected row count"
    else
      let* operation = lookup_optional t ~operation_id in
      match operation with
      | Some operation -> Ok operation
      | None -> Error (Unknown_operation operation_id)
  in
  match body with
  | Error error -> rollback t.db error
  | Ok operation -> commit_operation t operation
;;

let start_next t ~started_at =
  let* () = ensure_open t in
  let* () = validate_timestamp "started_at" started_at in
  let* () = exec t.db ~operation:"begin start next chat operation" "BEGIN IMMEDIATE" in
  let body =
    let* head =
      with_statement
        t.db
        "SELECT operation_id FROM operations WHERE state_kind = 'queued' ORDER BY fifo_sequence LIMIT 1"
        (fun stmt ->
           match Sqlite3.step stmt with
           | Sqlite3.Rc.DONE -> Ok None
           | Sqlite3.Rc.ROW -> Ok (Some (Sqlite3.column_text stmt 0))
           | rc ->
             store_error
               (Keeper_chat_queue_storage.error
                  ~operation:"select queued chat operation head"
                  t.db
                  rc))
    in
    match head with
    | None -> Ok None
    | Some operation_id ->
      let* () =
        with_statement
          t.db
          "UPDATE operations SET state_kind = 'running', started_at = ? WHERE operation_id = ? AND state_kind = 'queued'"
          (fun stmt ->
             let* () =
               Keeper_chat_queue_storage.bind
                 t.db stmt ~operation:"bind operation started_at" 1
                 (Sqlite3.Data.FLOAT started_at)
               |> Result.map_error (fun detail -> Store_unavailable detail)
             in
             let* () =
               Keeper_chat_queue_storage.bind_text
                 t.db stmt ~operation:"bind operation start id" 2 operation_id
               |> Result.map_error (fun detail -> Store_unavailable detail)
             in
             Keeper_chat_queue_storage.expect_done
               t.db stmt ~operation:"start queued chat operation"
             |> Result.map_error (fun detail -> Store_unavailable detail))
      in
      if Sqlite3.changes t.db <> 1
      then store_error "queued operation head changed before start"
      else
        let* operation = lookup_optional t ~operation_id in
        (match operation with
         | Some operation -> Ok (Some operation)
         | None -> store_error "started operation disappeared")
  in
  match body with
  | Error error -> rollback t.db error
  | Ok None ->
    let* () = exec t.db ~operation:"commit empty chat operation start" "COMMIT" in
    Ok None
  | Ok (Some operation) -> commit_operation t operation |> Result.map Option.some
;;

let require_queued t operation_id =
  let* operation = lookup t ~operation_id in
  match operation.state with
  | Queued -> Ok operation
  | state -> Error (Not_queued { operation_id; state })
;;

let edit t ~operation_id edit =
  let* () = ensure_open t in
  let* () = validate_operation_id operation_id in
  let* () = validate_edit edit in
  let* current = require_queued t operation_id in
  match current.input with
  | None -> store_error "queued operation has no retained input"
  | Some current_input ->
    let input =
      { current_input with
        content = edit.content
      ; user_blocks = edit.user_blocks
      ; attachments = edit.attachments
      }
    in
    let digest = input_digest input in
    let input_json = input_body_to_yojson input |> Yojson.Safe.to_string in
    update_and_read
      t
      ~operation_id
      ~sql:
        "UPDATE operations SET execution_digest = ?, input_json = ? WHERE operation_id = ? AND state_kind = 'queued'"
      ~bind:(fun stmt ->
        let bind index value operation =
          Keeper_chat_queue_storage.bind_text t.db stmt ~operation index value
          |> Result.map_error (fun detail -> Store_unavailable detail)
        in
        let* () = bind 1 digest "bind edited operation digest" in
        let* () = bind 2 input_json "bind edited operation input" in
        bind 3 operation_id "bind edited operation id")
;;

let move_to_end t ~operation_id =
  let* () = ensure_open t in
  let* () = validate_operation_id operation_id in
  let* _ = require_queued t operation_id in
  let* () = exec t.db ~operation:"begin move chat operation" "BEGIN IMMEDIATE" in
  let body =
    let* sequence = allocate_sequence t in
    let* () =
      with_statement
        t.db
        "UPDATE operations SET fifo_sequence = ? WHERE operation_id = ? AND state_kind = 'queued'"
        (fun stmt ->
           let* () =
             Keeper_chat_queue_storage.bind_int64
               t.db stmt ~operation:"bind moved operation sequence" 1 sequence
             |> Result.map_error (fun detail -> Store_unavailable detail)
           in
           let* () =
             Keeper_chat_queue_storage.bind_text
               t.db stmt ~operation:"bind moved operation id" 2 operation_id
             |> Result.map_error (fun detail -> Store_unavailable detail)
           in
           Keeper_chat_queue_storage.expect_done
             t.db stmt ~operation:"move queued chat operation"
           |> Result.map_error (fun detail -> Store_unavailable detail))
    in
    if Sqlite3.changes t.db <> 1
    then store_error "queued operation changed before move-to-end"
    else
      let* operation = lookup_optional t ~operation_id in
      match operation with
      | Some operation -> Ok operation
      | None -> store_error "moved operation disappeared"
  in
  match body with
  | Error error -> rollback t.db error
  | Ok operation -> commit_operation t operation
;;

let bind_terminal_common t ~operation_id ~completed_at stmt =
  let* () =
    Keeper_chat_queue_storage.bind
      t.db stmt ~operation:"bind operation completed_at" 1
      (Sqlite3.Data.FLOAT completed_at)
    |> Result.map_error (fun detail -> Store_unavailable detail)
  in
  Keeper_chat_queue_storage.bind_text
    t.db stmt ~operation:"bind terminal operation id" 2 operation_id
  |> Result.map_error (fun detail -> Store_unavailable detail)
;;

let cancel t ~operation_id ~completed_at =
  let* () = ensure_open t in
  let* () = validate_operation_id operation_id in
  let* () = validate_timestamp "completed_at" completed_at in
  let* _ = require_queued t operation_id in
  update_and_read
    t
    ~operation_id
    ~sql:
      "UPDATE operations SET state_kind = 'cancelled', source_json = NULL, input_json = NULL, completed_at = ? WHERE operation_id = ? AND state_kind = 'queued'"
    ~bind:(bind_terminal_common t ~operation_id ~completed_at)
;;

let require_running t operation_id =
  let* operation = lookup t ~operation_id in
  match operation.state with
  | Running _ -> Ok operation
  | state -> Error (Not_queued { operation_id; state })
;;

let succeed t ~operation_id ~completed_at ~outcome_ref =
  let* () = ensure_open t in
  let* () = validate_operation_id operation_id in
  let* () = validate_timestamp "completed_at" completed_at in
  if not (valid_nonempty outcome_ref)
  then Error (Invalid_input "outcome_ref must be non-empty UTF-8")
  else
    let* _ = require_running t operation_id in
    update_and_read
      t
      ~operation_id
      ~sql:
        "UPDATE operations SET state_kind = 'succeeded', source_json = NULL, input_json = NULL, completed_at = ?, outcome_ref = ? WHERE operation_id = ? AND state_kind = 'running'"
      ~bind:(fun stmt ->
        let* () =
          Keeper_chat_queue_storage.bind
            t.db stmt ~operation:"bind successful operation completed_at" 1
            (Sqlite3.Data.FLOAT completed_at)
          |> Result.map_error (fun detail -> Store_unavailable detail)
        in
        let* () =
          Keeper_chat_queue_storage.bind_text
            t.db stmt ~operation:"bind successful operation outcome" 2 outcome_ref
          |> Result.map_error (fun detail -> Store_unavailable detail)
        in
        Keeper_chat_queue_storage.bind_text
          t.db stmt ~operation:"bind successful operation id" 3 operation_id
        |> Result.map_error (fun detail -> Store_unavailable detail))
;;

let fail t ~operation_id ~completed_at ~kind ~detail ~outcome_ref =
  let* () = ensure_open t in
  let* () = validate_operation_id operation_id in
  let* () = validate_timestamp "completed_at" completed_at in
  if not (String.is_valid_utf_8 detail) || String.contains detail '\000'
  then Error (Invalid_input "failure detail must be UTF-8 without NUL")
  else
    let* () = validate_optional "failure outcome_ref" outcome_ref in
    let* _ = require_running t operation_id in
    update_and_read
      t
      ~operation_id
      ~sql:
        "UPDATE operations SET state_kind = 'failed', source_json = NULL, input_json = NULL, completed_at = ?, failure_kind = ?, failure_detail = ?, outcome_ref = ? WHERE operation_id = ? AND state_kind = 'running'"
      ~bind:(fun stmt ->
        let* () =
          Keeper_chat_queue_storage.bind
            t.db stmt ~operation:"bind failed operation completed_at" 1
            (Sqlite3.Data.FLOAT completed_at)
          |> Result.map_error (fun detail -> Store_unavailable detail)
        in
        let bind_text index value operation =
          Keeper_chat_queue_storage.bind_text t.db stmt ~operation index value
          |> Result.map_error (fun detail -> Store_unavailable detail)
        in
        let* () = bind_text 2 (failure_kind_to_string kind) "bind operation failure kind" in
        let* () = bind_text 3 detail "bind operation failure detail" in
        let* () =
          Keeper_chat_queue_storage.bind
            t.db stmt ~operation:"bind failed operation outcome" 4
            (Option.fold
               ~none:Sqlite3.Data.NULL
               ~some:(fun value -> Sqlite3.Data.TEXT value)
               outcome_ref)
          |> Result.map_error (fun detail -> Store_unavailable detail)
        in
        bind_text 5 operation_id "bind failed operation id")
;;

let settle_interrupted t ~completed_at =
  let* () = ensure_open t in
  let* () = validate_timestamp "completed_at" completed_at in
  let* () = exec t.db ~operation:"begin interrupted operation settlement" "BEGIN IMMEDIATE" in
  let body =
    let* running_ids =
      with_statement
        t.db
        "SELECT operation_id FROM operations WHERE state_kind = 'running' ORDER BY fifo_sequence"
        (fun stmt ->
           let rec loop acc =
             match Sqlite3.step stmt with
             | Sqlite3.Rc.DONE -> Ok (List.rev acc)
             | Sqlite3.Rc.ROW -> loop (Sqlite3.column_text stmt 0 :: acc)
             | rc ->
               store_error
                 (Keeper_chat_queue_storage.error
                    ~operation:"list running operations for restart settlement"
                    t.db
                    rc)
           in
           loop [])
    in
    let* () =
      with_statement
        t.db
        "UPDATE operations SET state_kind = 'failed', source_json = NULL, input_json = NULL, completed_at = ?, failure_kind = 'interrupted_by_restart', failure_detail = 'operation interrupted by process restart' WHERE state_kind = 'running'"
        (fun stmt ->
           let* () =
             Keeper_chat_queue_storage.bind
               t.db stmt ~operation:"bind interrupted settlement timestamp" 1
               (Sqlite3.Data.FLOAT completed_at)
             |> Result.map_error (fun detail -> Store_unavailable detail)
           in
           Keeper_chat_queue_storage.expect_done
             t.db stmt ~operation:"settle interrupted chat operations"
           |> Result.map_error (fun detail -> Store_unavailable detail))
    in
    Ok running_ids
  in
  match body with
  | Error error -> rollback t.db error
  | Ok running_ids ->
    (match
       commit_transaction t ~operation:"commit interrupted operation settlement"
     with
     | Ok () -> Ok (List.length running_ids)
     | Error error ->
       if running_ids = []
       then (
         rollback_after_uncertain_commit t;
         Ok 0)
       else
       let durable =
         List.for_all
           (fun operation_id ->
              match durable_readback t ~operation_id with
              | Ok
                  (Some
                    { state =
                        Failed
                          { completed_at = observed_at
                          ; kind = Interrupted_by_restart
                          ; _
                          }
                    ; _
                    }) ->
                Float.equal observed_at completed_at
              | Ok (Some _ | None) | Error _ -> false)
           running_ids
       in
         if durable
         then Ok (List.length running_ids)
         else (
           rollback_after_uncertain_commit t;
           store_error
             ("interrupted operation settlement commit was uncertain: "
              ^ error_to_string error)))
;;

module For_testing = struct
  type nonrec commit_fault = commit_fault =
    | Before_commit
    | After_commit

  let database_path = database_path
  let fail_next_commit fault = Atomic.set commit_fault_for_testing (Some fault)
end
