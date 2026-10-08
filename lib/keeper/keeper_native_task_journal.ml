module Task = Runtime_native_tasks
let ( let* ) = Result.bind

type source = Operation of Keeper_chat_operation.Operation_id.t | Autonomous_turn of Ids.Turn_ref.t
type error =
  | Invalid_scope of string | Invalid_observation of string | Missing_store
  | Corrupt of { line : int; detail : string } | Conflicting_uuid of string
  | Sequence_exhausted | Cursor_store_mismatch | Cursor_ahead | Io_failed of exn
  | Directory_prepare_failed of Keeper_fs_durable_directory.failure
  | Store_unavailable of { operation : string; detail : string }
  | Commit_unconfirmed of string
type cleanup_failure = { operation : string; detail : string }
type record = { seq : int; recorded_at : float; observation : Task.t }
type commit = Appended of record | Replayed of record
type 'a outcome = { result : ('a, error) result; cleanup_failure : cleanup_failure list }
type issue = { event_uuid : string; error : error option; cleanup_failure : cleanup_failure list }
type scope = { base_path : string; keeper_name : string; receiver_generation : string; session_id : string }
type reader = { scope : scope; path : string }
type t =
  { context : (string * string, error) result; source : source; redact_text : string -> string
  ; health_mutex : Mutex.t; mutable issues : issue list
  ; audit_mutex : Mutex.t; audited : (string, string) Hashtbl.t }
type publication = { reader : reader; observation : Task.t; collector : t }
type cursor = { store_id : string; after_sequence : int }
type validation = { store_id : string; through_sequence : int }
type snapshot = { validation : validation; records : record list }

let error_to_string = function
  | Invalid_scope s -> "invalid native task scope: " ^ s
  | Invalid_observation s -> "invalid bound native task: " ^ s
  | Missing_store -> "native task store is missing"
  | Corrupt {line;detail} -> Printf.sprintf "native task store row %d: %s" line detail
  | Conflicting_uuid s -> "native task UUID conflict: " ^ s
  | Sequence_exhausted -> "native task sequence exceeds JSON safe precision"
  | Cursor_store_mismatch -> "native task cursor belongs to a different store incarnation"
  | Cursor_ahead -> "native task cursor is beyond this snapshot"
  | Io_failed exn -> "native task I/O: " ^ Printexc.to_string exn
  | Directory_prepare_failed _ -> "native task directory preparation failed"
  | Store_unavailable {operation;detail} -> operation ^ ": " ^ detail
  | Commit_unconfirmed detail -> "native task commit outcome unconfirmed: " ^ detail
let cleanup_failure_to_string (failure : cleanup_failure) = failure.operation ^ ": " ^ failure.detail
let cursor ~store_id ~after_sequence =
  if String.trim store_id = "" then Error (Invalid_scope "empty cursor incarnation")
  else match Runtime_json_integer.of_json (`Int after_sequence) with
    | Ok n when n >= 0 -> Ok {store_id;after_sequence=n}
    | Ok _ | Error _ -> Error (Invalid_scope "invalid cursor sequence")
let next_cursor (snapshot : snapshot) =
  {store_id=snapshot.validation.store_id;after_sequence=snapshot.validation.through_sequence}

let context ~base_path ~keeper_name =
  if String.equal keeper_name "" then Error (Invalid_scope "empty Keeper name")
  else
    try Ok (Keeper_registry_types.canonical_base_path_exn base_path, keeper_name)
    with Invalid_argument detail -> Error (Invalid_scope detail)

let create ~base_path ~keeper_name ~source ~redact_text =
  { context = context ~base_path ~keeper_name; source; redact_text
  ; health_mutex = Mutex.create (); issues = []; audit_mutex = Mutex.create (); audited = Hashtbl.create 2 }

(* Whole-byte hexadecimal encoding, including punctuation, has one inverse.
   IDs are never trimmed, sanitized or interpreted as filesystem paths. *)
let component value =
  let encoded = Buffer.create (2 * String.length value) in
  String.iter (fun c -> Buffer.add_string encoded (Printf.sprintf "%02x" (Char.code c))) value;
  Buffer.contents encoded

let reader_for scope =
  let path = Filename.concat (Common.masc_dir_from_base_path ~base_path:scope.base_path) "native-task-journals/v2" in
  let path = Filename.concat path (component scope.keeper_name) in
  let path = Filename.concat path (component scope.receiver_generation) in
  let path = Filename.concat path (component scope.session_id ^ ".sqlite3") in
  {scope; path}

let open_reader ~base_path ~keeper_name ~receiver_generation ~session_id =
  let* base_path, keeper_name = context ~base_path ~keeper_name in
  if String.equal receiver_generation "" || String.equal session_id "" then
    Error (Invalid_scope "empty receiver generation or session")
  else Ok (reader_for {base_path; keeper_name; receiver_generation; session_id})

let path reader = reader.path
let reader_of_publication publication = publication.reader

let prepare t ~attempt (bound : Keeper_claude_task_binding.bound) =
  let* base_path, keeper_name = t.context in
  let ticket = bound.ticket and observed = bound.observation in
  let owner = observed.owner in
  let source = match t.source with
    | Operation operation_id -> Task.Operation
        {operation_id = Keeper_chat_operation.Operation_id.to_string operation_id}
    | Autonomous_turn turn_ref -> Task.Autonomous_turn {turn_ref = Ids.Turn_ref.to_string turn_ref} in
  let origin : Task.origin =
    { keeper_name; source; attempt
    ; invocation = {receiver_generation=ticket.receiver_generation;
        session_id=ticket.session_id; client_uuid=ticket.client_uuid}
    ; native_call = {session_id=owner.session_id; call_id=owner.call_id;
        call_envelope_uuid=owner.call_envelope_uuid; call_ordinal=owner.call_ordinal}
    ; task_id=owner.task_id; run_id=owner.run_id } in
  let* observation = Task.make ~origin ~uuid:observed.uuid ~event:observed.event
      ~boundary:observed.boundary |> Result.map_error (fun e -> Invalid_observation e) in
  let observation = Task.redact t.redact_text observation in
  let reader = reader_for {base_path; keeper_name;
    receiver_generation=ticket.receiver_generation; session_id=ticket.session_id} in
  Ok {reader; observation; collector=t}


let schema = "masc.native_task_journal.v2"
let application_id = 1296127042
let max_sequence = 9007199254740991L
let metadata_sql = "CREATE TABLE metadata(singleton INTEGER PRIMARY KEY CHECK(singleton=1), schema TEXT NOT NULL, store_id TEXT NOT NULL, base_path TEXT NOT NULL, keeper_name TEXT NOT NULL, receiver_generation TEXT NOT NULL, session_id TEXT NOT NULL, next_sequence INTEGER NOT NULL CHECK(next_sequence>0))"
let observations_sql = "CREATE TABLE observations(seq INTEGER PRIMARY KEY CHECK(seq>0), event_uuid TEXT NOT NULL UNIQUE, recorded_at REAL NOT NULL, payload TEXT NOT NULL)"
let immutable_rows_sql = "CREATE TRIGGER immutable_observations BEFORE UPDATE ON observations BEGIN SELECT RAISE(ABORT,'immutable observation'); END"
let no_delete_sql = "CREATE TRIGGER no_delete_observations BEFORE DELETE ON observations BEGIN SELECT RAISE(ABORT,'immutable observation'); END"
let immutable_scope_sql = "CREATE TRIGGER immutable_scope BEFORE UPDATE OF singleton,schema,store_id,base_path,keeper_name,receiver_generation,session_id ON metadata BEGIN SELECT RAISE(ABORT,'immutable scope'); END"
let objects = ["metadata",metadata_sql;"observations",observations_sql;
  "immutable_observations",immutable_rows_sql;"no_delete_observations",no_delete_sql;
  "immutable_scope",immutable_scope_sql] |> List.sort compare
let corrupt ?(line=0) detail = Error (Corrupt {line;detail})
let sqlite_failure db operation rc = Store_unavailable
  {operation;detail=Sqlite3.Rc.to_string rc ^ ": " ^ Sqlite3.errmsg db}
let exec db operation sql =
  match Sqlite3.exec db sql with
  | rc when Sqlite3.Rc.is_success rc -> Ok ()
  | rc -> Error (sqlite_failure db operation rc)
  | exception (Sqlite3.Error detail | Sqlite3.SqliteError detail) ->
      Error (Store_unavailable {operation;detail})
let statement db cleanup operation sql f =
  match Sqlite3.prepare db sql with
  | exception (Sqlite3.Error detail | Sqlite3.SqliteError detail) -> Error (Store_unavailable {operation;detail})
  | stmt ->
      Fun.protect ~finally:(fun () ->
        match Sqlite3.finalize stmt with
        | rc when Sqlite3.Rc.is_success rc -> ()
        | rc -> cleanup := {operation="finalize " ^ operation;
            detail=Sqlite3.Rc.to_string rc} :: !cleanup
        | exception (Sqlite3.Error detail | Sqlite3.SqliteError detail) ->
            cleanup := {operation="finalize " ^ operation;detail} :: !cleanup)
        (fun () -> try f stmt with (Sqlite3.Error detail | Sqlite3.SqliteError detail) -> Error (Store_unavailable {operation;detail}))
let bind db stmt values =
  let rec loop index = function
    | [] -> Ok ()
    | value :: rest ->
        let rc = Sqlite3.bind stmt index value in
        if Sqlite3.Rc.is_success rc then loop (index+1) rest
        else Error (sqlite_failure db "bind" rc) in
  loop 1 values
let done_ db stmt operation =
  match Sqlite3.step stmt with Sqlite3.Rc.DONE -> Ok () | rc -> Error (sqlite_failure db operation rc)
let scalar db cleanup sql = statement db cleanup "scalar" sql (fun stmt ->
  match Sqlite3.step stmt with
  | Sqlite3.Rc.ROW -> let value = Sqlite3.column stmt 0 in let* () = done_ db stmt "scalar end" in Ok value
  | rc -> Error (sqlite_failure db "scalar" rc))
let integer = function Sqlite3.Data.INT value -> Ok value | _ -> corrupt "expected integer"
let text = function Sqlite3.Data.TEXT value -> Ok value | _ -> corrupt "expected text"
let schema_objects db cleanup = statement db cleanup "schema"
    "SELECT name,sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY name" (fun stmt ->
  let rec loop acc = match Sqlite3.step stmt with
    | Sqlite3.Rc.DONE -> Ok (List.rev acc)
    | Sqlite3.Rc.ROW ->
        let* name = text (Sqlite3.column stmt 0) in
        let* sql = text (Sqlite3.column stmt 1) in loop ((name,sql)::acc)
    | rc -> Error (sqlite_failure db "schema" rc) in loop [])
let validate_schema db cleanup =
  let* id = scalar db cleanup "PRAGMA application_id" |> fun result -> Result.bind result integer in
  let* version = scalar db cleanup "PRAGMA user_version" |> fun result -> Result.bind result integer in
  let* observed = schema_objects db cleanup in
  if id=Int64.of_int application_id && version=2L && observed=objects then Ok ()
  else corrupt "unknown or damaged native task store schema"
let validate_candidate db cleanup =
  let* observed = schema_objects db cleanup in
  if observed<>[] then let* () = validate_schema db cleanup in Ok false
  else
    let* id = scalar db cleanup "PRAGMA application_id" |> fun result -> Result.bind result integer in
    let* version = scalar db cleanup "PRAGMA user_version" |> fun result -> Result.bind result integer in
    if id=0L && version=0L then Ok true else corrupt "empty store has foreign identity"
let configure db cleanup =
  let* () = exec db "immediate busy refusal" "PRAGMA busy_timeout=0" in
  let* mode = scalar db cleanup "PRAGMA journal_mode=DELETE" |> fun result -> Result.bind result text in
  let* () = if String.lowercase_ascii mode="delete" then Ok () else corrupt "DELETE journaling unavailable" in
  let* () = exec db "durable synchronous mode" "PRAGMA synchronous=EXTRA" in
  let* mode = scalar db cleanup "PRAGMA synchronous" |> fun result -> Result.bind result integer in
  if mode=3L then Ok () else corrupt "EXTRA durability unavailable"
let initialize db cleanup scope =
  let* () = List.fold_left (fun result (_,sql) -> let* () = result in exec db "initialize schema" sql)
      (Ok ()) ["metadata",metadata_sql;"observations",observations_sql;
        "immutable_observations",immutable_rows_sql;"no_delete_observations",no_delete_sql;
        "immutable_scope",immutable_scope_sql] in
  let* () = exec db "identify store" (Printf.sprintf "PRAGMA application_id=%d" application_id) in
  let* () = exec db "version store" "PRAGMA user_version=2" in
  statement db cleanup "initialize scope"
    "INSERT INTO metadata VALUES(1,?,?,?,?,?,?,1)" (fun stmt ->
      let* () = bind db stmt (List.map (fun s -> Sqlite3.Data.TEXT s)
        [schema;Random_id.uuid_v7 ();scope.base_path;scope.keeper_name;
         scope.receiver_generation;scope.session_id]) in
      done_ db stmt "initialize scope")
let metadata db cleanup expected = statement db cleanup "scope"
    "SELECT singleton,schema,store_id,base_path,keeper_name,receiver_generation,session_id,next_sequence FROM metadata" (fun stmt ->
  match Sqlite3.step stmt with
  | Sqlite3.Rc.ROW ->
      let* singleton = integer (Sqlite3.column stmt 0) in
      let* identity = text (Sqlite3.column stmt 1) in
      let* store_id = text (Sqlite3.column stmt 2) in
      let* base_path = text (Sqlite3.column stmt 3) in
      let* keeper_name = text (Sqlite3.column stmt 4) in
      let* receiver_generation = text (Sqlite3.column stmt 5) in
      let* session_id = text (Sqlite3.column stmt 6) in
      let* next = integer (Sqlite3.column stmt 7) in
      let* () = done_ db stmt "scope singleton" in
      if singleton<>1L || identity<>schema || String.trim store_id=""
         || {base_path;keeper_name;receiver_generation;session_id}<>expected then
        corrupt "store belongs to another receiver scope or has invalid identity"
      else if next<1L || next>Int64.succ max_sequence then corrupt "invalid next sequence"
      else Ok (store_id,next)
  | Sqlite3.Rc.DONE -> corrupt "missing store metadata"
  | rc -> Error (sqlite_failure db "scope" rc))
let decode_row scope stmt =
  let* seq64 = integer (Sqlite3.column stmt 0) in
  let* seq = Runtime_json_integer.of_json (`Intlit (Int64.to_string seq64))
      |> Result.map_error (fun detail -> Corrupt {line=0;detail}) in
  let* event_uuid = text (Sqlite3.column stmt 1) in
  let* recorded_at = match Sqlite3.column stmt 2 with
    | Sqlite3.Data.FLOAT f when Float.is_finite f -> Ok f
    | _ -> corrupt ~line:seq "invalid timestamp" in
  let* payload = text (Sqlite3.column stmt 3) in
  let* observation =
    try Task.of_json (Yojson.Safe.from_string payload)
        |> Result.map_error (fun detail -> Corrupt {line=seq;detail})
    with Yojson.Json_error detail -> corrupt ~line:seq detail in
  let origin = observation.origin in
  if seq<=0 || observation.uuid<>event_uuid || origin.keeper_name<>scope.keeper_name
     || origin.invocation.receiver_generation<>scope.receiver_generation
     || origin.invocation.session_id<>scope.session_id then
    corrupt ~line:seq "observation contradicts row key or receiver scope"
  else Ok {seq;recorded_at;observation}
let full_audit db cleanup scope next =
  let* integrity = scalar db cleanup "PRAGMA quick_check" |> fun result -> Result.bind result text in
  let* () = if integrity="ok" then Ok () else corrupt integrity in
  statement db cleanup "audit history"
    "SELECT seq,event_uuid,recorded_at,payload FROM observations ORDER BY seq" (fun stmt ->
      let uuids = Hashtbl.create 16 in
      let rec loop expected acc = match Sqlite3.step stmt with
        | Sqlite3.Rc.DONE ->
            if expected=next then Ok (List.rev acc) else corrupt "metadata does not follow history"
        | Sqlite3.Rc.ROW ->
            let* row = decode_row scope stmt in
            if Int64.of_int row.seq<>expected || Hashtbl.mem uuids row.observation.uuid then
              corrupt ~line:row.seq "noncontiguous sequence or duplicate UUID"
            else (Hashtbl.add uuids row.observation.uuid (); loop (Int64.succ expected) (row::acc))
        | rc -> Error (sqlite_failure db "audit history" rc) in loop 1L [])
let tail_boundary db cleanup next =
  let* highest = scalar db cleanup "SELECT COALESCE(MAX(seq),0) FROM observations" |> fun result -> Result.bind result integer in
  if Int64.succ highest=next then Ok () else corrupt "metadata does not follow last row"
let rollback db cleanup =
  match exec db "rollback" "ROLLBACK" with
  | Ok () -> ()
  | Error error -> cleanup := {operation="rollback";detail=error_to_string error} :: !cleanup
type sqlite_io = { commit : Sqlite3.db -> Sqlite3.Rc.t; close : Sqlite3.db -> bool }
let sqlite_io = {commit=(fun db -> Sqlite3.exec db "COMMIT");close=Sqlite3.db_close}
let commit_transaction io db =
  match io.commit db with
  | rc when Sqlite3.Rc.is_success rc -> Ok ()
  | rc -> Error (Commit_unconfirmed (error_to_string (sqlite_failure db "commit" rc)))
  | exception (Sqlite3.Error detail | Sqlite3.SqliteError detail) -> Error (Commit_unconfirmed detail)
let protect_io f =
  try f () with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | (Sqlite3.Error detail | Sqlite3.SqliteError detail) -> {result=Error (Store_unavailable {operation="SQLite";detail});cleanup_failure=[]}
  | (Unix.Unix_error _ | Sys_error _) as exn -> {result=Error (Io_failed exn);cleanup_failure=[]}
let regular_file ~create path =
  match Unix.lstat path with
  | {Unix.st_kind=Unix.S_REG;_} -> Ok ()
  | _ -> corrupt "store path is not a regular file"
  | exception Unix.Unix_error (Unix.ENOENT,_,_) -> if create then Ok () else Error Missing_store
let with_database ?(io=sqlite_io) ~create reader f = protect_io (fun () ->
  Eio_guard.run_in_systhread ~label:"native-task-sqlite" (fun () ->
    let cleanup = ref [] in
    let result =
      let* () = regular_file ~create reader.path in
      let db = if create then Sqlite3.db_open reader.path
        else Sqlite3.db_open ~mode:`READONLY reader.path in
      Fun.protect ~finally:(fun () ->
        (match io.close db with
         | true -> ()
         | false -> cleanup := {operation="close";detail="SQLite close failed"} :: !cleanup
         | exception (Sqlite3.Error detail | Sqlite3.SqliteError detail) -> cleanup := {operation="close";detail} :: !cleanup);
        ignore (Sys.opaque_identity db)) (fun () ->
          if create then Unix.chmod reader.path 0o600;
          try f db cleanup with (Sqlite3.Error detail | Sqlite3.SqliteError detail) -> Error (Store_unavailable {operation="SQLite";detail})) in
    {result;cleanup_failure=List.rev !cleanup}))

let append_with_io io publication = protect_io (fun () ->
  let reader = publication.reader in
  match Keeper_fs_durable_directory.ensure ~before_prepare:(fun () -> ())
      ~before_directory_fsync:(fun _ -> ()) ~ownership_root:reader.scope.base_path
      (Filename.dirname reader.path) with
  | Error error -> {result=Error (Directory_prepare_failed error);cleanup_failure=[]}
  | Ok _ -> with_database ~io ~create:true reader (fun db cleanup ->
      let* _ = validate_candidate db cleanup in
      let* () = configure db cleanup in
      let* () = exec db "begin append" "BEGIN IMMEDIATE" in
      let body () =
        let* empty = validate_candidate db cleanup in
        let* () = if empty then initialize db cleanup reader.scope else Ok () in
        let* () = validate_schema db cleanup in
        let* store_id,next = metadata db cleanup reader.scope in
        let audited = Mutex.protect publication.collector.audit_mutex (fun () ->
          Hashtbl.find_opt publication.collector.audited reader.path = Some store_id) in
        let* () = if audited then Ok () else
          full_audit db cleanup reader.scope next |> Result.map (fun _ -> ()) in
        let* () = tail_boundary db cleanup next in
        let* previous = statement db cleanup "lookup UUID"
          "SELECT seq,event_uuid,recorded_at,payload FROM observations WHERE event_uuid=?" (fun stmt ->
            let* () = bind db stmt [Sqlite3.Data.TEXT publication.observation.uuid] in
            match Sqlite3.step stmt with
            | Sqlite3.Rc.DONE -> Ok None
            | Sqlite3.Rc.ROW -> let* record = decode_row reader.scope stmt in
                let* () = done_ db stmt "UUID uniqueness" in Ok (Some record)
            | rc -> Error (sqlite_failure db "lookup UUID" rc)) in
        let* result = match previous with
          | Some record when record.observation=publication.observation -> Ok (Replayed record)
          | Some _ -> Error (Conflicting_uuid publication.observation.uuid)
          | None when next>max_sequence -> Error Sequence_exhausted
          | None ->
              let record = {seq=Int64.to_int next;recorded_at=Unix.gettimeofday ();
                observation=publication.observation} in
              let* () = if Float.is_finite record.recorded_at then Ok () else corrupt "invalid local timestamp" in
              let* () = statement db cleanup "insert observation"
                "INSERT INTO observations(seq,event_uuid,recorded_at,payload) VALUES(?,?,?,?)" (fun stmt ->
                  let* () = bind db stmt [Sqlite3.Data.INT next;TEXT record.observation.uuid;
                    FLOAT record.recorded_at;TEXT (Yojson.Safe.to_string (Task.to_json record.observation))] in
                  done_ db stmt "insert observation") in
              let* () = statement db cleanup "advance sequence"
                "UPDATE metadata SET next_sequence=? WHERE singleton=1" (fun stmt ->
                  let* () = bind db stmt [Sqlite3.Data.INT (Int64.succ next)] in
                  done_ db stmt "advance sequence") in
              Ok (Appended record) in
        let* () = commit_transaction io db in
        Mutex.protect publication.collector.audit_mutex (fun () ->
          Hashtbl.replace publication.collector.audited reader.path store_id);
        Ok result in
      match body () with
      | Ok _ as result -> result
      | Error _ as result -> rollback db cleanup; result
      | exception exn -> rollback db cleanup; raise exn))

let append publication = append_with_io sqlite_io publication

type receiver = { receiver_generation : string; session_id : string }
type process_issue = { receiver : receiver option; issue : issue }
type issue_snapshot = { process_epoch : string; issues : process_issue list }
let process_epoch = Random_id.uuid_v7 ()
let issue_mutex = Mutex.create ()
let process_issues : ((string * string), process_issue list) Hashtbl.t = Hashtbl.create 8
let issue_snapshot ~base_path ~keeper_name =
  let* key = context ~base_path ~keeper_name in
  Ok (Mutex.protect issue_mutex (fun () ->
    let issues = match Hashtbl.find_opt process_issues key with
      | None -> [] | Some values -> List.rev values in
    {process_epoch;issues}))
let record_process_issue t receiver issue =
  match t.context with
  | Error _ -> () (* Invalid workspace cannot be indexed as authenticated scope. *)
  | Ok key -> Mutex.protect issue_mutex (fun () ->
      let previous = match Hashtbl.find_opt process_issues key with None -> [] | Some xs -> xs in
      Hashtbl.replace process_issues key ({receiver;issue}::previous))

let with_health t f = Mutex.protect t.health_mutex f
let observe t ~attempt bound =
  let outcome,receiver = match prepare t ~attempt bound with
    | Error error -> {result=Error error;cleanup_failure=[]},None
    | Ok publication -> append publication,
        Some {receiver_generation=publication.reader.scope.receiver_generation;
              session_id=publication.reader.scope.session_id} in
  let error = match outcome.result with Ok _ -> None | Error error -> Some error in
  (match error,outcome.cleanup_failure with
   | None,[] -> ()
   | _ ->
       let issue = {event_uuid=bound.observation.uuid;error;cleanup_failure=outcome.cleanup_failure} in
       with_health t (fun () -> t.issues <- issue :: t.issues);
       record_process_issue t receiver issue);
  outcome
let health t = with_health t (fun () -> List.rev t.issues)
let report ~keeper_name outcome =
  (match outcome.result with
   | Ok _ -> ()
   | Error error -> Log.Keeper.warn ~keeper_name "native task persistence failed: %s" (error_to_string error));
  List.iter (fun failure -> Log.Keeper.warn ~keeper_name
    "native task cleanup failed (primary outcome retained): %s" (cleanup_failure_to_string failure)) outcome.cleanup_failure

let read ?after reader = with_database ~create:false reader (fun db cleanup ->
  let* () = exec db "begin read snapshot" "BEGIN" in
  let body () =
    let* () = validate_schema db cleanup in
    let* store_id,next = metadata db cleanup reader.scope in
    let through_sequence = Int64.to_int (Int64.pred next) in
    let* boundary = match after with
      | None -> Ok 0
      | Some cursor when cursor.store_id<>store_id -> Error Cursor_store_mismatch
      | Some cursor when cursor.after_sequence>through_sequence -> Error Cursor_ahead
      | Some cursor -> Ok cursor.after_sequence in
    let* all = full_audit db cleanup reader.scope next in
    let records = List.filter (fun record -> record.seq>boundary) all in
    let* () = exec db "end read snapshot" "COMMIT" in
    Ok {validation={store_id;through_sequence};records} in
  match body () with
  | Ok _ as result -> result
  | Error _ as result -> rollback db cleanup; result
  | exception exn -> rollback db cleanup; raise exn)

type discovery_entry = { receiver : receiver; state : (validation, error) result }
let decode_component encoded =
  let nibble = function
    | '0'..'9' as c -> Some (Char.code c - Char.code '0')
    | 'a'..'f' as c -> Some (Char.code c - Char.code 'a' + 10)
    | _ -> None in
  if encoded="" || String.length encoded mod 2<>0 then None else
  let bytes = Bytes.create (String.length encoded / 2) in
  let rec loop i =
    if i=Bytes.length bytes then Some (Bytes.to_string bytes) else
    match nibble encoded.[2*i],nibble encoded.[2*i+1] with
    | Some a,Some b -> Bytes.set bytes i (Char.chr (16*a+b)); loop (i+1)
    | _ -> None in loop 0
let discover ~base_path ~keeper_name = protect_io (fun () ->
  let result =
    let* base_path,keeper_name = context ~base_path ~keeper_name in
    let root = Filename.concat (Common.masc_dir_from_base_path ~base_path)
      ("native-task-journals/v2/" ^ component keeper_name) in
    Eio_guard.run_in_systhread ~label:"native-task-discovery" (fun () ->
      let directories path =
        match Unix.lstat path with
        | {Unix.st_kind=Unix.S_DIR;_} -> Ok (Array.to_list (Sys.readdir path) |> List.sort String.compare)
        | _ -> corrupt "managed receiver directory is not a directory"
        | exception Unix.Unix_error (Unix.ENOENT,_,_) -> Ok [] in
      let* generations = directories root in
      List.fold_left (fun result name ->
        let* acc = result in
        match decode_component name with
        | None -> Ok acc
        | Some receiver_generation ->
            let* files = directories (Filename.concat root name) in
            List.fold_left (fun result file ->
              let* acc = result in
              if not (Filename.check_suffix file ".sqlite3") then Ok acc else
              match decode_component (Filename.chop_suffix file ".sqlite3") with
              | None -> Ok acc
              | Some session_id ->
                  let receiver = {receiver_generation;session_id} in
                  let reader = reader_for {base_path;keeper_name;receiver_generation;session_id} in
                  let outcome = read reader in
                  let state = match outcome.result,outcome.cleanup_failure with
                    | Ok snapshot,[] -> Ok snapshot.validation
                    | Error error,_ -> Error error
                    | Ok _,failure::_ -> Error (Store_unavailable
                        {operation="discovery cleanup";detail=cleanup_failure_to_string failure}) in
                  Ok ({receiver;state}::acc)) (Ok acc) files) (Ok []) generations
      |> Result.map List.rev) in
  let result = Result.bind result (fun durable ->
    let* snapshot = issue_snapshot ~base_path ~keeper_name in
    Ok (List.fold_left (fun entries (entry : process_issue) ->
      match entry.receiver with
      | None -> entries
      | Some receiver when List.exists (fun (entry : discovery_entry) -> entry.receiver=receiver) entries -> entries
      | Some receiver -> entries @ [{receiver;state=Error Missing_store}]) durable snapshot.issues)) in
  {result;cleanup_failure=[]})

module For_testing = struct
  let append_with_io ~commit ~close publication = append_with_io {commit;close} publication
end
