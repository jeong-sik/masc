module Child = Keeper_child_content
let ( let* ) = Result.bind

type error =
  | Invalid_scope of string | Invalid_observation of string | Missing_store
  | Corrupt of { seq : int; detail : string } | Conflicting_observation of string
  | Sequence_exhausted | Cursor_store_mismatch | Cursor_ahead | Io_failed of exn
  | Directory_prepare_failed of Keeper_fs_durable_directory.failure
  | Store_unavailable of { operation : string; detail : string }
  | Commit_unconfirmed of string
type cleanup_failure = { operation : string; detail : string }
type record = { seq : int; recorded_at : float; observation : Child.view }
type commit = Appended of record | Replayed of record
type 'a outcome = { result : ('a, error) result; cleanup_failure : cleanup_failure list }
type issue = { observation_id : string; ordinal : int; channel : Runtime_claude_code.content_channel; error : error option; cleanup_failure : cleanup_failure list }
type scope = { base_path : string; keeper_name : string; receiver_generation : string; session_id : string; client_uuid : string }
type reader = { scope : scope; path : string }
type t =
  { context : (string * string, error) result; source : Keeper_native_task_journal.source; redact_text : string -> string
  ; health_mutex : Mutex.t; mutable issues : issue list
  ; audit_mutex : Mutex.t; audited : (string, string) Hashtbl.t }
type publication = { reader : reader; observation : Child.view; collector : t }
type cursor = { store_id : string; after_sequence : int }
type validation = { store_id : string; through_sequence : int }
type snapshot = { validation : validation; records : record list }

let error_to_string = function
  | Invalid_scope s -> "invalid child content scope: " ^ s
  | Invalid_observation s -> "invalid received child content: " ^ s
  | Missing_store -> "child content store is missing"
  | Corrupt {seq;detail} -> Printf.sprintf "child content store row %d: %s" seq detail
  | Conflicting_observation s -> "child content observation conflict: " ^ s
  | Sequence_exhausted -> "child content sequence exceeds JSON safe precision"
  | Cursor_store_mismatch -> "child content cursor belongs to a different store incarnation"
  | Cursor_ahead -> "child content cursor is beyond this snapshot"
  | Io_failed exn -> "child content I/O: " ^ Printexc.to_string exn
  | Directory_prepare_failed _ -> "child content directory preparation failed"
  | Store_unavailable {operation;detail} -> operation ^ ": " ^ detail
  | Commit_unconfirmed detail -> "child content commit outcome unconfirmed: " ^ detail
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

let keeper_directory ~base_path ~keeper_name =
  Filename.concat
    (Filename.concat (Common.masc_dir_from_base_path ~base_path) "child-content-journals/v1")
    (component keeper_name)

let reader_for scope =
  let path = keeper_directory ~base_path:scope.base_path ~keeper_name:scope.keeper_name in
  let path = Filename.concat path (component scope.receiver_generation) in
  let path = Filename.concat path (component scope.session_id) in
  let path = Filename.concat path (component scope.client_uuid ^ ".sqlite3") in
  {scope; path}

let open_reader ~base_path ~keeper_name ~receiver_generation ~session_id ~client_uuid =
  let* base_path, keeper_name = context ~base_path ~keeper_name in
  if String.equal receiver_generation "" || String.equal session_id "" || String.equal client_uuid "" then
    Error (Invalid_scope "empty invocation component")
  else Ok (reader_for {base_path; keeper_name; receiver_generation; session_id; client_uuid})

let path reader = reader.path
let reader_of_publication publication = publication.reader

let prepare t ~attempt decision =
  let* base_path,keeper_name = t.context in
  let* publication = Child.prepare ~keeper_name ~source:t.source ~attempt
      ~redact_text:t.redact_text decision
    |> Result.map_error (fun error -> Invalid_observation (Child.error_to_string error)) in
  let observation = Child.view publication in
  let invocation = observation.origin.invocation in
  let reader = reader_for {base_path;keeper_name;
    receiver_generation=invocation.receiver_generation;session_id=invocation.session_id;
    client_uuid=invocation.client_uuid} in
  Ok {reader;observation;collector=t}

let observation_key (observation : Child.view) =
  Yojson.Safe.to_string (`List [ `String observation.observation_id;
    `Int observation.ordinal;
    `String (match observation.channel with
      | Runtime_claude_code.Text_content -> "text" | Thinking_content -> "thinking") ])


let schema = "masc.child_content_journal.v1"
let application_id = 1296255043
let max_sequence = 9007199254740991L
let metadata_sql = "CREATE TABLE metadata(singleton INTEGER PRIMARY KEY CHECK(singleton=1), schema TEXT NOT NULL, store_id TEXT NOT NULL, base_path TEXT NOT NULL, keeper_name TEXT NOT NULL, receiver_generation TEXT NOT NULL, session_id TEXT NOT NULL, client_uuid TEXT NOT NULL, next_sequence INTEGER NOT NULL CHECK(next_sequence>0))"
let observations_sql = "CREATE TABLE observations(seq INTEGER PRIMARY KEY CHECK(seq>0), observation_key TEXT NOT NULL UNIQUE, recorded_at REAL NOT NULL, payload TEXT NOT NULL)"
let immutable_rows_sql = "CREATE TRIGGER immutable_observations BEFORE UPDATE ON observations BEGIN SELECT RAISE(ABORT,'immutable observation'); END"
let no_delete_sql = "CREATE TRIGGER no_delete_observations BEFORE DELETE ON observations BEGIN SELECT RAISE(ABORT,'immutable observation'); END"
let immutable_scope_sql = "CREATE TRIGGER immutable_scope BEFORE UPDATE OF singleton,schema,store_id,base_path,keeper_name,receiver_generation,session_id,client_uuid ON metadata BEGIN SELECT RAISE(ABORT,'immutable scope'); END"
let objects = ["metadata",metadata_sql;"observations",observations_sql;
  "immutable_observations",immutable_rows_sql;"no_delete_observations",no_delete_sql;
  "immutable_scope",immutable_scope_sql] |> List.sort compare
let corrupt ?(seq=0) detail = Error (Corrupt {seq;detail})
let sqlite_failure db operation rc = Store_unavailable
  {operation;detail=Sqlite3.Rc.to_string rc ^ ": " ^ Sqlite3.errmsg db}
let sql_error ~operation ~detail = Store_unavailable {operation;detail}
let cleanup_report cleanup ~operation ~detail = cleanup := {operation;detail} :: !cleanup
let exec db operation sql = Keeper_sqlite_observation_io.exec ~error:sql_error db ~operation sql
let statement db cleanup operation sql f =
  Keeper_sqlite_observation_io.statement ~error:sql_error
    ~on_cleanup:(cleanup_report cleanup) db ~operation sql f
let bind db stmt values = Keeper_sqlite_observation_io.bind ~error:sql_error db stmt values
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
  if id=Int64.of_int application_id && version=1L && observed=objects then Ok ()
  else corrupt "unknown or damaged child content store schema"
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
  let* () = exec db "version store" "PRAGMA user_version=1" in
  statement db cleanup "initialize scope"
    "INSERT INTO metadata VALUES(1,?,?,?,?,?,?,?,1)" (fun stmt ->
      let* () = bind db stmt (List.map (fun s -> Sqlite3.Data.TEXT s)
        [schema;Random_id.uuid_v7 ();scope.base_path;scope.keeper_name;
         scope.receiver_generation;scope.session_id;scope.client_uuid]) in
      done_ db stmt "initialize scope")
let metadata db cleanup expected = statement db cleanup "scope"
    "SELECT singleton,schema,store_id,base_path,keeper_name,receiver_generation,session_id,client_uuid,next_sequence FROM metadata" (fun stmt ->
  match Sqlite3.step stmt with
  | Sqlite3.Rc.ROW ->
      let* singleton = integer (Sqlite3.column stmt 0) in
      let* identity = text (Sqlite3.column stmt 1) in
      let* store_id = text (Sqlite3.column stmt 2) in
      let* base_path = text (Sqlite3.column stmt 3) in
      let* keeper_name = text (Sqlite3.column stmt 4) in
      let* receiver_generation = text (Sqlite3.column stmt 5) in
      let* session_id = text (Sqlite3.column stmt 6) in
      let* client_uuid = text (Sqlite3.column stmt 7) in
      let* next = integer (Sqlite3.column stmt 8) in
      let* () = done_ db stmt "scope singleton" in
      if singleton<>1L || identity<>schema || String.trim store_id=""
         || {base_path;keeper_name;receiver_generation;session_id;client_uuid}<>expected then
        corrupt "store belongs to another receiver scope or has invalid identity"
      else if next<1L || next>Int64.succ max_sequence then corrupt "invalid next sequence"
      else Ok (store_id,next)
  | Sqlite3.Rc.DONE -> corrupt "missing store metadata"
  | rc -> Error (sqlite_failure db "scope" rc))
let decode_row scope stmt =
  let* seq64 = integer (Sqlite3.column stmt 0) in
  let* seq =
    let as_int = Int64.to_int seq64 in
    if Int64.equal (Int64.of_int as_int) seq64 then
      Runtime_json_integer.of_json (`Int as_int)
      |> Result.map_error (fun detail -> Corrupt {seq=0;detail})
    else Error (Corrupt {seq=0;detail="sequence outside the OCaml int range"}) in
  let* key = text (Sqlite3.column stmt 1) in
  let* recorded_at = match Sqlite3.column stmt 2 with
    | Sqlite3.Data.FLOAT f when Float.is_finite f -> Ok f
    | _ -> corrupt ~seq:seq "invalid timestamp" in
  let* payload = text (Sqlite3.column stmt 3) in
  let* observation =
    try Child.of_json (Yojson.Safe.from_string payload)
        |> Result.map_error (fun detail -> Corrupt {seq;detail=Child.error_to_string detail})
    with Yojson.Json_error detail -> corrupt ~seq:seq detail in
  let origin = observation.origin in
  if seq<=0 || observation_key observation<>key || origin.keeper_name<>scope.keeper_name
     || origin.invocation.receiver_generation<>scope.receiver_generation
     || origin.invocation.session_id<>scope.session_id
     || origin.invocation.client_uuid<>scope.client_uuid then
    corrupt ~seq:seq "observation contradicts row key or receiver scope"
  else Ok {seq;recorded_at;observation}
let full_audit db cleanup scope next =
  let* integrity = scalar db cleanup "PRAGMA quick_check" |> fun result -> Result.bind result text in
  let* () = if integrity="ok" then Ok () else corrupt integrity in
  statement db cleanup "audit history"
    "SELECT seq,observation_key,recorded_at,payload FROM observations ORDER BY seq" (fun stmt ->
      let keys = Hashtbl.create 16 in
      let rec loop expected acc = match Sqlite3.step stmt with
        | Sqlite3.Rc.DONE ->
            if expected=next then Ok (List.rev acc) else corrupt "metadata does not follow history"
        | Sqlite3.Rc.ROW ->
            let* row = decode_row scope stmt in
            if Int64.of_int row.seq<>expected || Hashtbl.mem keys (observation_key row.observation) then
              corrupt ~seq:row.seq "noncontiguous sequence or duplicate observation key"
            else (Hashtbl.add keys (observation_key row.observation) (); loop (Int64.succ expected) (row::acc))
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
  Keeper_sqlite_observation_io.commit ~error:sql_error
    ~unconfirmed:(fun detail -> Commit_unconfirmed detail) ~show_error:error_to_string
    ~commit:io.commit db
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
  let cleanup = ref [] in
  let result =
    Keeper_sqlite_observation_io.with_database ~label:"child-content-sqlite"
      ~before_open:(fun () -> regular_file ~create reader.path) ~error:sql_error
      ~on_cleanup:(cleanup_report cleanup) ~close:io.close ~create ~path:reader.path
      (fun db -> f db cleanup) in
  {result;cleanup_failure=List.rev !cleanup})

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
        let* previous = statement db cleanup "lookup observation key"
          "SELECT seq,observation_key,recorded_at,payload FROM observations WHERE observation_key=?" (fun stmt ->
            let* () = bind db stmt [Sqlite3.Data.TEXT (observation_key publication.observation)] in
            match Sqlite3.step stmt with
            | Sqlite3.Rc.DONE -> Ok None
            | Sqlite3.Rc.ROW -> let* record = decode_row reader.scope stmt in
                let* () = done_ db stmt "observation uniqueness" in Ok (Some record)
            | rc -> Error (sqlite_failure db "lookup observation key" rc)) in
        let* result = match previous with
          | Some record when record.observation=publication.observation -> Ok (Replayed record)
          | Some _ -> Error (Conflicting_observation (observation_key publication.observation))
          | None when next>max_sequence -> Error Sequence_exhausted
          | None ->
              let record = {seq=Int64.to_int next;recorded_at=Unix.gettimeofday ();
                observation=publication.observation} in
              let* () = if Float.is_finite record.recorded_at then Ok () else corrupt "invalid local timestamp" in
              let* () = statement db cleanup "insert observation"
                "INSERT INTO observations(seq,observation_key,recorded_at,payload) VALUES(?,?,?,?)" (fun stmt ->
                  let* () = bind db stmt [Sqlite3.Data.INT next;TEXT (observation_key record.observation);
                    FLOAT record.recorded_at;TEXT (Yojson.Safe.to_string (Child.to_json record.observation))] in
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

let read ?after reader = with_database ~create:false reader (fun db cleanup ->
  let* () = exec db "begin read snapshot" "BEGIN" in
  let body () =
    let* () = validate_schema db cleanup in
    let* store_id,next = metadata db cleanup reader.scope in
    let through_sequence = Int64.to_int (Int64.pred next) in
    let* boundary = match (after : cursor option) with
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

let observe t ~attempt decision =
  let outcome = match prepare t ~attempt decision with
    | Error error -> {result=Error error;cleanup_failure=[]}
    | Ok publication -> append publication in
  let error = match outcome.result with Ok _ -> None | Error error -> Some error in
  (match error,outcome.cleanup_failure with
   | None,[] -> ()
   | _ ->
       let content = match decision with
         | Keeper_claude_task_binding.Child_bound bound -> bound.content
         | Child_rejected {content;_} -> content in
       let ordinal = match content.block with
         | Runtime_claude_code.Assistant_block {ordinal;_} -> ordinal
         | Partial_block {index;_} -> index in
       let issue = {observation_id=content.observation_id;ordinal;channel=content.channel;
         error;cleanup_failure=outcome.cleanup_failure} in
       Mutex.protect t.health_mutex (fun () -> t.issues <- issue :: t.issues));
  outcome
let health t = Mutex.protect t.health_mutex (fun () -> List.rev t.issues)
let report ~keeper_name outcome =
  (match outcome.result with
   | Ok _ -> ()
   | Error error -> Log.Keeper.warn ~keeper_name "child content persistence failed: %s" (error_to_string error));
  List.iter (fun failure -> Log.Keeper.warn ~keeper_name
    "child content cleanup failed (primary outcome retained): %s"
    (cleanup_failure_to_string failure)) outcome.cleanup_failure
type receiver = { receiver_generation : string; session_id : string; client_uuid : string }
type change_hint = { store_id : string; through_sequence : int }
let read_hint reader = with_database ~create:false reader (fun db cleanup ->
  let* () = exec db "begin hint snapshot" "BEGIN" in
  let body () =
    let* () = validate_schema db cleanup in
    let* store_id,next = metadata db cleanup reader.scope in
    let* () = tail_boundary db cleanup next in
    let* () = exec db "end hint snapshot" "COMMIT" in
    Ok ({store_id;through_sequence=Int64.to_int (Int64.pred next)} : change_hint) in
  match body () with
  | Ok _ as result -> result
  | Error _ as result -> rollback db cleanup; result
  | exception exn -> rollback db cleanup; raise exn)

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

let discover_states_with ~observe ~before_read ~after_read ~base_path ~keeper_name =
  protect_io (fun () ->
    let result =
      let* base_path,keeper_name = context ~base_path ~keeper_name in
      let root = keeper_directory ~base_path ~keeper_name in
      Eio_guard.run_in_systhread ~label:"child-content-discovery" (fun () ->
        let directories ~missing_allowed path =
          match Fs_compat.read_owned_directory_if_present ~owner_uid:(Unix.geteuid ())
              ~before_read ~after_read ~ownership_root:base_path path with
          | Ok (Some names) -> Ok names
          | Ok None when missing_allowed -> Ok []
          | Ok None -> Error (Store_unavailable {operation="discover directory";
              detail="previously enumerated invocation directory is missing"})
          | Error error -> Error (Store_unavailable {operation="discover directory";
              detail=Fs_compat.owned_regular_file_read_error_to_string error}) in
        let* generations = directories ~missing_allowed:true root in
        List.fold_left (fun result generation_name ->
          let* acc = result in
          match decode_component generation_name with
          | None -> Ok acc
          | Some receiver_generation ->
              let generation_path = Filename.concat root generation_name in
              let* sessions = directories ~missing_allowed:false generation_path in
              List.fold_left (fun result session_name ->
                let* acc = result in
                match decode_component session_name with
                | None -> Ok acc
                | Some session_id ->
                    let session_path = Filename.concat generation_path session_name in
                    let* clients = directories ~missing_allowed:false session_path in
                    List.fold_left (fun result file ->
                      let* acc = result in
                      if not (Filename.check_suffix file ".sqlite3") then Ok acc else
                      match decode_component (Filename.chop_suffix file ".sqlite3") with
                      | None -> Ok acc
                      | Some client_uuid ->
                          let receiver = {receiver_generation;session_id;client_uuid} in
                          let reader = reader_for {base_path;keeper_name;
                            receiver_generation;session_id;client_uuid} in
                          Ok ((receiver,observe reader)::acc)) (Ok acc) clients)
                (Ok acc) sessions) (Ok []) generations |> Result.map List.rev) in
    {result;cleanup_failure=[]})
let discovery_result project outcome =
  match outcome.result,outcome.cleanup_failure with
  | Ok value,[] -> Ok (project value)
  | Error error,_ -> Error error
  | Ok _,_::_ -> Error (Store_unavailable {operation="discovery cleanup";
      detail="store read cleanup failed"})
type discovery_entry = { receiver : receiver; state : (validation,error) result }
type hint_entry = { receiver : receiver; state : (change_hint,error) result }
let discover_with ~before_read ~after_read ~base_path ~keeper_name =
  let outcome = discover_states_with ~before_read ~after_read ~base_path ~keeper_name
    ~observe:(fun reader -> discovery_result (fun (snapshot:snapshot) -> snapshot.validation) (read reader)) in
  {result=Result.map (List.map (fun (receiver,state) -> ({receiver;state}:discovery_entry))) outcome.result;
   cleanup_failure=outcome.cleanup_failure}
let discover_hints_with ~before_read ~after_read ~base_path ~keeper_name =
  let outcome = discover_states_with ~before_read ~after_read ~base_path ~keeper_name
    ~observe:(fun reader -> discovery_result Fun.id (read_hint reader)) in
  {result=Result.map (List.map (fun (receiver,state) -> ({receiver;state}:hint_entry))) outcome.result;
   cleanup_failure=outcome.cleanup_failure}
let discover ~base_path ~keeper_name =
  discover_with ~before_read:(fun _ -> ()) ~after_read:(fun _ -> ()) ~base_path ~keeper_name
let discover_hints ~base_path ~keeper_name =
  discover_hints_with ~before_read:(fun _ -> ()) ~after_read:(fun _ -> ()) ~base_path ~keeper_name
module For_testing = struct
  let append_with_io ~commit ~close publication = append_with_io {commit;close} publication
  let discover = discover_with
  let discover_hints = discover_hints_with
end
