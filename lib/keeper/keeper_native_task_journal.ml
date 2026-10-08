module Task = Runtime_native_tasks

let ( let* ) = Result.bind

type source =
  | Operation of Keeper_chat_operation.Operation_id.t
  | Autonomous_turn of Ids.Turn_ref.t

type error =
  | Invalid_scope of string
  | Invalid_observation of string
  | Corrupt of { line : int; detail : string }
  | Conflicting_uuid of string
  | Sequence_exhausted
  | Io_failed of exn
  | Directory_prepare_failed of Keeper_fs_durable_directory.failure
  | Append_failed of Fs_compat.durable_append_error
  | Read_failed of Fs_compat.Private_jsonl_rows.error

type record = { seq : int; recorded_at : float; observation : Task.t }
type commit = Appended of record | Replayed of record
type 'a outcome =
  { result : ('a, error) result
  ; cleanup_failure : Fs_compat.private_jsonl_operation_failure option
  }
type issue =
  { event_uuid : string
  ; error : error option
  ; cleanup_failure : Fs_compat.private_jsonl_operation_failure option
  }
type scope =
  { base_path : string; keeper_name : string
  ; receiver_generation : string; session_id : string }
type reader = { scope : scope; path : string }
type publication = { reader : reader; observation : Task.t }
type t =
  { context : (string * string, error) result
  ; source : source
  ; redact_text : string -> string
  ; health_mutex : Mutex.t
  ; mutable issues : issue list
  }

let error_to_string = function
  | Invalid_scope detail -> "invalid native task scope: " ^ detail
  | Invalid_observation detail -> "invalid bound native task: " ^ detail
  | Corrupt {line; detail} -> Printf.sprintf "native task journal row %d: %s" line detail
  | Conflicting_uuid uuid -> "native task UUID conflict: " ^ uuid
  | Sequence_exhausted -> "native task sequence exceeds JSON safe integer precision"
  | Io_failed exn -> "native task journal I/O: " ^ Printexc.to_string exn
  | Directory_prepare_failed (Keeper_fs_durable_directory.Operation_failed (exn, _)) ->
      "native task directory preparation: " ^ Printexc.to_string exn
  | Directory_prepare_failed (Directory_chain_failed error) ->
      (match error with
       | Non_directory_ancestor {path} -> "native task non-directory ancestor: " ^ path
       | Outside_ownership_root {ownership_root; path} ->
           "native task directory outside " ^ ownership_root ^ ": " ^ path
       | Missing_root {path} -> "native task workspace missing: " ^ path
       | Creation_not_observed {path} -> "native task directory creation not observed: " ^ path)
  | Append_failed error -> Fs_compat.durable_append_error_to_string error
  | Read_failed error -> Fs_compat.Private_jsonl_rows.error_to_string error

let context ~base_path ~keeper_name =
  if String.equal keeper_name "" then Error (Invalid_scope "empty Keeper name")
  else
    try Ok (Keeper_registry_types.canonical_base_path_exn base_path, keeper_name)
    with Invalid_argument detail -> Error (Invalid_scope detail)

let create ~base_path ~keeper_name ~source ~redact_text =
  { context = context ~base_path ~keeper_name; source; redact_text
  ; health_mutex = Mutex.create (); issues = [] }

(* Whole-byte hexadecimal encoding, including punctuation, has one inverse.
   IDs are never trimmed, sanitized or interpreted as filesystem paths. *)
let component value =
  let encoded = Buffer.create (2 * String.length value) in
  String.iter (fun c -> Buffer.add_string encoded (Printf.sprintf "%02x" (Char.code c))) value;
  Buffer.contents encoded

let reader_for scope =
  let path = Filename.concat (Common.masc_dir_from_base_path ~base_path:scope.base_path) "native-task-journals/v1" in
  let path = Filename.concat path (component scope.keeper_name) in
  let path = Filename.concat path (component scope.receiver_generation) in
  let path = Filename.concat path (component scope.session_id ^ ".jsonl") in
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
  Ok {reader; observation}

let scope_json scope = `Assoc
  ["base_path", `String scope.base_path; "keeper_name", `String scope.keeper_name;
   "receiver_generation", `String scope.receiver_generation; "session_id", `String scope.session_id]

let record_json scope record = `Assoc
  ["schema", `String "masc.native_task_journal.v1"; "scope", scope_json scope;
   "seq", `Int record.seq; "recorded_at", `Float record.recorded_at;
   "observation", Task.to_json record.observation]

let fields ~names = function
  | `Assoc xs ->
      let keys = List.map fst xs in
      if List.length keys <> List.length names
         || List.sort String.compare keys <> List.sort String.compare names
      then Error "missing, duplicate or unknown object fields" else Ok xs
  | _ -> Error "expected object"

let string = function `String value -> Ok value | _ -> Error "expected string"
let timestamp = function
  | `Float value when Float.is_finite value -> Ok value
  | `Int value -> Ok (float_of_int value)
  | _ -> Error "expected finite recorded_at number"

let decode_record expected json =
  let* row = fields ~names:["schema";"scope";"seq";"recorded_at";"observation"] json in
  let* schema = string (List.assoc "schema" row) in
  let* () = if schema = "masc.native_task_journal.v1" then Ok () else Error "unknown journal schema" in
  let* scope = fields ~names:["base_path";"keeper_name";"receiver_generation";"session_id"]
      (List.assoc "scope" row) in
  let* base_path = string (List.assoc "base_path" scope) in
  let* keeper_name = string (List.assoc "keeper_name" scope) in
  let* receiver_generation = string (List.assoc "receiver_generation" scope) in
  let* session_id = string (List.assoc "session_id" scope) in
  let scope = {base_path; keeper_name; receiver_generation; session_id} in
  let* () = if scope = expected then Ok () else Error "row belongs to another receiver scope" in
  let* seq = Runtime_json_integer.of_json (List.assoc "seq" row) in
  let* () = if seq > 0 then Ok () else Error "sequence must be positive" in
  let* recorded_at = timestamp (List.assoc "recorded_at" row) in
  let* observation = Task.of_json (List.assoc "observation" row) in
  let origin = observation.origin in
  let* () =
    if origin.keeper_name = scope.keeper_name
       && origin.invocation.receiver_generation = scope.receiver_generation
       && origin.invocation.session_id = scope.session_id
    then Ok () else Error "observation contradicts receiver scope" in
  Ok {seq; recorded_at; observation}

(* Called inside the Fs transaction: pure, no Eio effects. The complete history
   is checked before a duplicate can be acknowledged. *)
let decode_rows scope bytes =
  let uuids = Hashtbl.create 16 in
  let rec loop line reversed = function
    | [""] -> Ok (List.rev reversed, uuids)
    | [] -> Error (Corrupt {line; detail="missing final newline"})
    | row :: rest ->
        let decoded =
          try decode_record scope (Yojson.Safe.from_string row)
          with Yojson.Json_error detail -> Error detail in
        (match decoded with
         | Error detail -> Error (Corrupt {line; detail})
         | Ok record when record.seq <> line ->
             Error (Corrupt {line; detail="noncontiguous sequence"})
         | Ok record when Hashtbl.mem uuids record.observation.uuid ->
             Error (Corrupt {line; detail="duplicate committed event UUID"})
         | Ok record ->
             Hashtbl.add uuids record.observation.uuid record;
             loop (line + 1) (record :: reversed) rest)
  in loop 1 [] (String.split_on_char '\n' bytes)

let decide publication recorded_at bytes =
  match decode_rows publication.reader.scope bytes with
  | Error error -> None, Error error
  | Ok (records, uuids) ->
      (match Hashtbl.find_opt uuids publication.observation.uuid with
       | Some record when record.observation = publication.observation -> None, Ok (Replayed record)
       | Some _ -> None, Error (Conflicting_uuid publication.observation.uuid)
       | None ->
           let seq = List.length records + 1 in
           match Runtime_json_integer.of_json (`Int seq) with
           | Error _ -> None, Error Sequence_exhausted
           | Ok _ ->
               let record = {seq; recorded_at; observation=publication.observation} in
               Some (Yojson.Safe.to_string (record_json publication.reader.scope record) ^ "\n"),
               Ok (Appended record))

let transaction_outcome map_error = function
  | Fs_compat.Private_file_succeeded result -> {result; cleanup_failure=None}
  | Private_file_succeeded_with_cleanup_failure {value=result; cleanup_failure} ->
      {result; cleanup_failure=Some cleanup_failure}
  | Private_file_failed error -> {result=Error (map_error error); cleanup_failure=None}
  | Private_file_failed_with_cleanup_failure {error; cleanup_failure} ->
      {result=Error (map_error error); cleanup_failure=Some cleanup_failure}

let protect_io f =
  try f () with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> {result=Error (Io_failed exn); cleanup_failure=None}

let append publication = protect_io (fun () ->
  match Keeper_fs_durable_directory.ensure
      ~before_prepare:(fun () -> ()) ~before_directory_fsync:(fun _ -> ())
      ~ownership_root:publication.reader.scope.base_path
      (Filename.dirname publication.reader.path) with
  | Error error -> {result=Error (Directory_prepare_failed error);cleanup_failure=None}
  | Ok _lease ->
      Fs_compat.recover_and_update_private_jsonl_durable_locked_result publication.reader.path
        (decide publication (Unix.gettimeofday ()))
      |> transaction_outcome (fun error -> Append_failed error))

let with_health t f =
  Mutex.lock t.health_mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock t.health_mutex) f

let observe t ~attempt bound =
  let outcome = protect_io (fun () ->
    match prepare t ~attempt bound with
    | Error error -> {result=Error error; cleanup_failure=None}
    | Ok publication -> append publication) in
  let error = match outcome.result with Ok _ -> None | Error error -> Some error in
  (match error, outcome.cleanup_failure with
   | None, None -> ()
   | _ -> with_health t (fun () ->
       t.issues <- {event_uuid=bound.observation.uuid; error;
         cleanup_failure=outcome.cleanup_failure} :: t.issues));
  outcome

let health t = with_health t (fun () -> List.rev t.issues)

let report ~keeper_name outcome =
  (match outcome.result with
   | Ok (Appended _ | Replayed _) -> ()
   | Error error -> Log.Keeper.warn ~keeper_name "native task persistence failed: %s"
       (error_to_string error));
  Option.iter (fun failure -> Log.Keeper.warn ~keeper_name
    "native task persistence descriptor cleanup failed (primary outcome retained): %s"
    (Fs_compat.private_jsonl_operation_failure_to_string failure)) outcome.cleanup_failure

let read reader = protect_io (fun () ->
  let decode = function
    | Fs_compat.Private_jsonl_rows.Rows_missing -> Ok []
    | Rows_present {rows; _} ->
        decode_rows reader.scope rows |> Result.map fst in
  let read = match Fs_compat.read_private_jsonl_rows_locked_result reader.path with
    | Fs_compat.Private_file_succeeded rows -> Fs_compat.Private_file_succeeded (decode rows)
    | Private_file_succeeded_with_cleanup_failure {value;cleanup_failure} ->
        Private_file_succeeded_with_cleanup_failure {value=decode value;cleanup_failure}
    | Private_file_failed error -> Private_file_failed error
    | Private_file_failed_with_cleanup_failure {error;cleanup_failure} ->
        Private_file_failed_with_cleanup_failure {error;cleanup_failure} in
  transaction_outcome (fun error -> Read_failed error) read)
