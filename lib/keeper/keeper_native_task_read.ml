module Journal = Keeper_native_task_journal
module Task = Runtime_native_tasks
let ( let* ) = Result.bind

type error_code =
  | Store_missing | Invalid_scope | Cursor_store_mismatch | Cursor_ahead
  | Store_corrupt | Conflicting_uuid | Sequence_exhausted | Io_failed
  | Directory_prepare_failed | Store_unavailable | Commit_unconfirmed
  | Invalid_query | Invalid_keeper

type decode_error =
  | Invalid_shape of string | Invalid_number of string | Invalid_observation of string
  | Scope_mismatch | Cursor_mismatch | Sequence_mismatch | Duplicate_event_uuid
  | Duplicate_receiver | Unexpected_response
let decode_error_to_string = function
  | Invalid_shape detail -> "invalid task read shape: " ^ detail
  | Invalid_number detail -> "invalid task read number: " ^ detail
  | Invalid_observation detail -> "invalid task read observation: " ^ detail
  | Scope_mismatch -> "task read receiver scope mismatch"
  | Cursor_mismatch -> "task read cursor mismatch"
  | Sequence_mismatch -> "task read suffix sequence mismatch"
  | Duplicate_event_uuid -> "duplicate task read event UUID"
  | Duplicate_receiver -> "duplicate task read receiver"
  | Unexpected_response -> "unexpected task read response kind"

type receiver = { receiver_generation : string; session_id : string }
type scope = { keeper_name : string; receiver : receiver }
type cursor = { store_id : string; after_sequence : int }
type record = { seq : int; recorded_at : float; observation : Task.t }
type issue =
  { receiver : receiver option; event_uuid : string; error : error_code option
  ; cleanup_failures : string list }
type health =
  | Unavailable of error_code
  | Process_only of { process_epoch : string; issues : issue list }
type storage = Audited of cursor | Failed of error_code
type entry = { receiver : receiver; storage : storage }
type records =
  { scope : scope; records : record list; next_cursor : cursor
  ; cleanup_failures : string list; health : health }
type receivers =
  { keeper_name : string; receivers : entry list
  ; cleanup_failures : string list; health : health }
type hint_storage = Unchecked of cursor | Hint_failed of error_code
type hint_entry = { receiver : receiver; hint : hint_storage }
type hints =
  { keeper_name : string; hints : hint_entry list
  ; cleanup_failures : string list; health : health }
type failure = { error : error_code; health : health option }
type response = Records of records | Receivers of receivers | Hints of hints | Failure of failure

let error_code_of_journal = function
  | Journal.Missing_store -> Store_missing
  | Invalid_scope _ | Invalid_observation _ -> Invalid_scope
  | Cursor_store_mismatch -> Cursor_store_mismatch
  | Cursor_ahead -> Cursor_ahead
  | Corrupt _ -> Store_corrupt
  | Conflicting_uuid _ -> Conflicting_uuid
  | Sequence_exhausted -> Sequence_exhausted
  | Io_failed _ -> Io_failed
  | Directory_prepare_failed _ -> Directory_prepare_failed
  | Store_unavailable _ -> Store_unavailable
  | Commit_unconfirmed _ -> Commit_unconfirmed
let error_name = function
  | Store_missing -> "store_missing" | Invalid_scope -> "invalid_scope"
  | Cursor_store_mismatch -> "cursor_store_mismatch" | Cursor_ahead -> "cursor_ahead"
  | Store_corrupt -> "store_corrupt" | Conflicting_uuid -> "conflicting_uuid"
  | Sequence_exhausted -> "sequence_exhausted" | Io_failed -> "io_failed"
  | Directory_prepare_failed -> "directory_prepare_failed"
  | Store_unavailable -> "store_unavailable" | Commit_unconfirmed -> "commit_unconfirmed"
  | Invalid_query -> "invalid_query" | Invalid_keeper -> "invalid_keeper"
let error_of_name = function
  | "store_missing" -> Ok Store_missing | "invalid_scope" -> Ok Invalid_scope
  | "cursor_store_mismatch" -> Ok Cursor_store_mismatch | "cursor_ahead" -> Ok Cursor_ahead
  | "store_corrupt" -> Ok Store_corrupt | "conflicting_uuid" -> Ok Conflicting_uuid
  | "sequence_exhausted" -> Ok Sequence_exhausted | "io_failed" -> Ok Io_failed
  | "directory_prepare_failed" -> Ok Directory_prepare_failed
  | "store_unavailable" -> Ok Store_unavailable | "commit_unconfirmed" -> Ok Commit_unconfirmed
  | "invalid_query" -> Ok Invalid_query | "invalid_keeper" -> Ok Invalid_keeper
  | _ -> Error (Invalid_shape "unknown error code")
let failure ?health error = Failure {error;health}
let cleanup_of_journal failures =
  List.map (fun (f:Journal.cleanup_failure) -> f.operation) failures
let receiver_of_journal (receiver:Journal.receiver) =
  {receiver_generation=receiver.receiver_generation;session_id=receiver.session_id}
let health_of_journal = function
  | Error error -> Unavailable (error_code_of_journal error)
  | Ok (snapshot:Journal.issue_snapshot) -> Process_only
      {process_epoch=snapshot.process_epoch;
       issues=List.map (fun (entry:Journal.process_issue) ->
         {receiver=Option.map receiver_of_journal entry.receiver;
          event_uuid=entry.issue.event_uuid;
          error=Option.map error_code_of_journal entry.issue.error;
          cleanup_failures=cleanup_of_journal entry.issue.cleanup_failure}) snapshot.issues}
let records_of_journal ~redact_text ~scope ~(snapshot:Journal.snapshot) ~cleanup_failures ~health =
  Records {scope; records=List.map (fun (row:Journal.record) ->
      {seq=row.seq;recorded_at=row.recorded_at;observation=Task.redact redact_text row.observation}) snapshot.records;
    next_cursor={store_id=snapshot.validation.store_id;
      after_sequence=snapshot.validation.through_sequence};
    cleanup_failures=cleanup_of_journal cleanup_failures;health}
let receivers_of_journal ~keeper_name ~entries ~cleanup_failures ~health =
  Receivers {keeper_name; receivers=List.map (fun (entry:Journal.discovery_entry) ->
    {receiver=receiver_of_journal entry.receiver;
     storage=(match entry.state with
      | Error error -> Failed (error_code_of_journal error)
      | Ok validation -> Audited {store_id=validation.store_id;
          after_sequence=validation.through_sequence})}) entries;
    cleanup_failures=cleanup_of_journal cleanup_failures;health}

let hints_of_journal ~keeper_name ~entries ~cleanup_failures ~health =
  Hints {keeper_name; hints=List.map (fun (entry:Journal.hint_entry) ->
    {receiver=receiver_of_journal entry.receiver;
     hint=(match entry.state with
       | Error error -> Hint_failed (error_code_of_journal error)
       | Ok hint -> Unchecked {store_id=hint.store_id;
           after_sequence=hint.through_sequence})}) entries;
    cleanup_failures=cleanup_of_journal cleanup_failures;health}

let unknown_fields =
  ["provider_completeness",`String "unknown";
   "historical_persistence_failures",`String "unknown"]
let error_json code = `Assoc
  (["schema",`String "masc.native_tasks.error.v1";"error",`String (error_name code)] @ unknown_fields)
let receiver_fields (receiver:receiver) =
  ["receiver_generation",`String receiver.receiver_generation;"session_id",`String receiver.session_id]
let cleanup_json failures = `List (List.map (fun operation -> `Assoc
  ["operation",`String operation;"status",`String "cleanup_failed"]) failures)
let health_json = function
  | Unavailable error -> `Assoc ["coverage",`String "unavailable";"error",error_json error]
  | Process_only {process_epoch;issues} -> `Assoc
      ["coverage",`String "issues_observed_in_this_process_only";
       "process_epoch",`String process_epoch;"historical_failure_coverage",`String "unknown";
       "issues",`List (List.map (fun (issue:issue) -> `Assoc
         ["receiver",(match issue.receiver with None -> `Null | Some r -> `Assoc (receiver_fields r));
          "event_uuid",`String issue.event_uuid;
          "error",(match issue.error with None -> `Null | Some e -> error_json e);
          "cleanup_failures",cleanup_json issue.cleanup_failures]) issues)]
let cursor_json (cursor:cursor) = `Assoc
  ["store_id",`String cursor.store_id;"after_sequence",`Int cursor.after_sequence]
let to_json = function
  | Failure {error;health} ->
      let fields = ["schema",`String "masc.native_tasks.error.v1";
        "error",`String (error_name error)] @ unknown_fields in
      `Assoc (match health with None -> fields
        | Some health -> ("observed_persistence_health",health_json health)::fields)
  | Records page -> `Assoc
      (("observed_persistence_health",health_json page.health)::
       (["schema",`String "masc.native_tasks.records.v1";
         "keeper_name",`String page.scope.keeper_name] @ receiver_fields page.scope.receiver @
        ["records",`List (List.map (fun (row:record) -> `Assoc
           ["seq",`Int row.seq;"recorded_at",`Float row.recorded_at;
            "observation",Task.to_json row.observation]) page.records);
         "validation",`Assoc ["kind",`String "full_committed_history";
           "through_sequence",`Int page.next_cursor.after_sequence];
         "next_cursor",cursor_json page.next_cursor] @ unknown_fields @
        ["terminal_without_observation",`String "unknown";
         "cleanup_failures",cleanup_json page.cleanup_failures]))
  | Receivers page -> `Assoc
      (("observed_persistence_health",health_json page.health)::
       (["schema",`String "masc.native_tasks.receivers.v1";
         "keeper_name",`String page.keeper_name;
         "receivers",`List (List.map (fun (entry:entry) ->
           let storage = match entry.storage with
             | Failed error -> error_json error
             | Audited cursor -> `Assoc ["status",`String "audited";
                 "store_id",`String cursor.store_id;"through_sequence",`Int cursor.after_sequence] in
           `Assoc (receiver_fields entry.receiver @ ["storage",storage])) page.receivers)] @
        unknown_fields @ ["cleanup_failures",cleanup_json page.cleanup_failures]))

  | Hints page -> `Assoc
      (["schema",`String "masc.native_tasks.hints.v1";
        "keeper_name",`String page.keeper_name;
        "historical_integrity",`String "unchecked";
        "observed_persistence_health",health_json page.health;
        "cleanup_failures",cleanup_json page.cleanup_failures;
        "hints",`List (List.map (fun (entry:hint_entry) ->
          let hint = match entry.hint with
            | Hint_failed error -> error_json error
            | Unchecked cursor -> `Assoc ["status",`String "unchecked";
                "store_id",`String cursor.store_id;
                "through_sequence",`Int cursor.after_sequence] in
          `Assoc (receiver_fields entry.receiver @ ["hint",hint])) page.hints)]
        @ unknown_fields)

let shape detail = Error (Invalid_shape detail)
let object_fields required optional = function
  | `Assoc fields ->
      let names=List.map fst fields in
      if List.length names<>List.length (List.sort_uniq String.compare names)
         || List.exists (fun name -> not (List.mem name (required @ optional))) names
         || List.exists (fun name -> not (List.mem_assoc name fields)) required
      then shape "missing, unknown or duplicate object field" else Ok fields
  | _ -> shape "expected object"
let string = function `String value -> Ok value | _ -> shape "expected string"
let nonempty json = let* value=string json in if value="" then shape "empty identity" else Ok value
let store_id json =
  let* value=string json in
  if String.trim value="" then shape "empty store incarnation" else Ok value
let fixed expected json =
  let* value=string json in if String.equal value expected then Ok () else shape "unknown schema or discriminator"
let integer json = Runtime_json_integer.of_json json |> Result.map_error (fun e -> Invalid_number e)
let nonnegative json =
  let* value=integer json in if value<0 then Error (Invalid_number "negative host sequence") else Ok value
let timestamp = function
  | `Float value when Float.is_finite value -> Ok value
  | `Int value -> Ok (float_of_int value)
  | `Intlit value ->
      (match float_of_string_opt value with Some value when Float.is_finite value -> Ok value
       | Some _ | None -> Error (Invalid_number "nonfinite timestamp"))
  | _ -> Error (Invalid_number "expected finite timestamp")
let list decode = function
  | `List values ->
      let rec loop reversed = function
        | [] -> Ok (List.rev reversed)
        | value::rest -> let* decoded=decode value in loop (decoded::reversed) rest in
      loop [] values
  | _ -> shape "expected list"
let nullable decode = function `Null -> Ok None | value -> decode value |> Result.map Option.some
let field fields name = List.assoc name fields
let unknown fields =
  let* ()=fixed "unknown" (field fields "provider_completeness") in
  fixed "unknown" (field fields "historical_persistence_failures")
let error_fields=["schema";"error";"provider_completeness";"historical_persistence_failures"]
let decode_error_code json =
  let* fields=object_fields error_fields [] json in
  let* ()=fixed "masc.native_tasks.error.v1" (field fields "schema") in
  let* ()=unknown fields in
  let* name=string (field fields "error") in error_of_name name
let decode_receiver_fields fields =
  let* receiver_generation=nonempty (field fields "receiver_generation") in
  let* session_id=nonempty (field fields "session_id") in
  Ok {receiver_generation;session_id}
let decode_receiver json =
  let* fields=object_fields ["receiver_generation";"session_id"] [] json in
  decode_receiver_fields fields
let decode_cleanup = list (fun json ->
  let* fields=object_fields ["operation";"status"] [] json in
  let* ()=fixed "cleanup_failed" (field fields "status") in string (field fields "operation"))
let decode_issue json =
  let* fields=object_fields ["receiver";"event_uuid";"error";"cleanup_failures"] [] json in
  let* receiver=nullable decode_receiver (field fields "receiver") in
  let* event_uuid=string (field fields "event_uuid") in
  let* error=nullable decode_error_code (field fields "error") in
  let* cleanup_failures=decode_cleanup (field fields "cleanup_failures") in
  Ok {receiver;event_uuid;error;cleanup_failures}
let decode_health json =
  let* fields=object_fields ["coverage"]
      ["error";"process_epoch";"historical_failure_coverage";"issues"] json in
  let* coverage=string (field fields "coverage") in
  match coverage with
  | "unavailable" ->
      let* fields=object_fields ["coverage";"error"] [] json in
      let* error=decode_error_code (field fields "error") in Ok (Unavailable error)
  | "issues_observed_in_this_process_only" ->
      let* fields=object_fields ["coverage";"process_epoch";"historical_failure_coverage";"issues"] [] json in
      let* process_epoch=nonempty (field fields "process_epoch") in
      let* ()=fixed "unknown" (field fields "historical_failure_coverage") in
      let* issues=list decode_issue (field fields "issues") in Ok (Process_only {process_epoch;issues})
  | _ -> shape "unknown health coverage"
let decode_cursor json =
  let* fields=object_fields ["store_id";"after_sequence"] [] json in
  let* store_id=store_id (field fields "store_id") in
  let* after_sequence=nonnegative (field fields "after_sequence") in Ok {store_id;after_sequence}
let decode_record json =
  let* fields=object_fields ["seq";"recorded_at";"observation"] [] json in
  let* seq=nonnegative (field fields "seq") in
  let* ()=if seq=0 then Error Sequence_mismatch else Ok () in
  let* recorded_at=timestamp (field fields "recorded_at") in
  let* observation=Task.of_json (field fields "observation")
      |> Result.map_error (fun e -> Invalid_observation e) in Ok {seq;recorded_at;observation}
let validate_rows (scope:scope) (cursor:cursor) rows =
  let uuids=Hashtbl.create 16 in
  let rec loop previous = function
    | [] -> (match previous with
        | None -> Ok ()
        | Some seq -> if seq=cursor.after_sequence then Ok () else Error Sequence_mismatch)
    | (row:record)::rest ->
        let origin=row.observation.origin in
        if origin.keeper_name<>scope.keeper_name
           || origin.invocation.receiver_generation<>scope.receiver.receiver_generation
           || origin.invocation.session_id<>scope.receiver.session_id then Error Scope_mismatch
        else if Hashtbl.mem uuids row.observation.uuid then Error Duplicate_event_uuid
        else if row.seq>cursor.after_sequence
             || (match previous with None -> false | Some seq -> row.seq<>seq+1)
        then Error Sequence_mismatch
        else (Hashtbl.add uuids row.observation.uuid ();loop (Some row.seq) rest) in
  loop None rows
let decode_records json =
  let* fields=object_fields
    ["schema";"keeper_name";"receiver_generation";"session_id";"records";"validation";"next_cursor";
     "provider_completeness";"historical_persistence_failures";"terminal_without_observation";
     "cleanup_failures";"observed_persistence_health"] [] json in
  let* ()=unknown fields in
  let* ()=fixed "unknown" (field fields "terminal_without_observation") in
  let* keeper_name=nonempty (field fields "keeper_name") in
  let* receiver=decode_receiver_fields fields in
  let scope={keeper_name;receiver} in
  let* records=list decode_record (field fields "records") in
  let* next_cursor=decode_cursor (field fields "next_cursor") in
  let* validation=object_fields ["kind";"through_sequence"] [] (field fields "validation") in
  let* ()=fixed "full_committed_history" (field validation "kind") in
  let* through_sequence=nonnegative (field validation "through_sequence") in
  let* ()=if through_sequence=next_cursor.after_sequence then Ok () else Error Cursor_mismatch in
  let* ()=validate_rows scope next_cursor records in
  let* cleanup_failures=decode_cleanup (field fields "cleanup_failures") in
  let* health=decode_health (field fields "observed_persistence_health") in
  Ok (Records {scope;records;next_cursor;cleanup_failures;health})
let decode_entry json =
  let* fields=object_fields ["receiver_generation";"session_id";"storage"] [] json in
  let* receiver=decode_receiver_fields fields in
  let storage_json=field fields "storage" in
  let* storage_fields=object_fields []
      ("status"::"store_id"::"through_sequence"::error_fields) storage_json in
  let* storage=match List.assoc_opt "status" storage_fields with
    | None -> decode_error_code storage_json |> Result.map (fun code -> Failed code)
    | Some _ ->
        let* fields=object_fields ["status";"store_id";"through_sequence"] [] storage_json in
        let* ()=fixed "audited" (field fields "status") in
        let* store_id=store_id (field fields "store_id") in
        let* after_sequence=nonnegative (field fields "through_sequence") in
        Ok (Audited {store_id;after_sequence}) in
  Ok {receiver;storage}
let decode_receivers json =
  let* fields=object_fields ["schema";"keeper_name";"receivers";"provider_completeness";
    "historical_persistence_failures";"cleanup_failures";"observed_persistence_health"] [] json in
  let* ()=unknown fields in
  let* keeper_name=nonempty (field fields "keeper_name") in
  let* receivers=list decode_entry (field fields "receivers") in
  let seen=Hashtbl.create 16 in
  let rec unique = function
    | [] -> Ok ()
    | (entry:entry)::rest ->
        if Hashtbl.mem seen entry.receiver then Error Duplicate_receiver
        else (Hashtbl.add seen entry.receiver (); unique rest) in
  let* ()=unique receivers in
  let* cleanup_failures=decode_cleanup (field fields "cleanup_failures") in
  let* health=decode_health (field fields "observed_persistence_health") in
  Ok (Receivers {keeper_name;receivers;cleanup_failures;health})
let decode_hints json =
  let* fields=object_fields ["schema";"keeper_name";"hints";"historical_integrity";
    "provider_completeness";"historical_persistence_failures";"cleanup_failures";
    "observed_persistence_health"] [] json in
  let* ()=fixed "masc.native_tasks.hints.v1" (field fields "schema") in
  let* ()=fixed "unchecked" (field fields "historical_integrity") in
  let* ()=unknown fields in
  let* keeper_name=nonempty (field fields "keeper_name") in
  let* hints=list (fun json ->
    let* fields=object_fields ["receiver_generation";"session_id";"hint"] [] json in
    let* receiver=decode_receiver_fields fields in
    let json=field fields "hint" in
    let* hint=match json with
      | `Assoc fields when List.mem_assoc "status" fields ->
          let* fields=object_fields ["status";"store_id";"through_sequence"] [] json in
          let* ()=fixed "unchecked" (field fields "status") in
          let* store_id=store_id (field fields "store_id") in
          let* after_sequence=nonnegative (field fields "through_sequence") in
          Ok (Unchecked {store_id;after_sequence})
      | _ -> decode_error_code json |> Result.map (fun error -> Hint_failed error) in
    Ok {receiver;hint}) (field fields "hints") in
  let seen=Hashtbl.create 16 in
  let rec unique = function
    | [] -> Ok ()
    | (entry:hint_entry)::rest ->
        if Hashtbl.mem seen entry.receiver then Error Duplicate_receiver
        else (Hashtbl.add seen entry.receiver ();unique rest) in
  let* ()=unique hints in
  let* cleanup_failures=decode_cleanup (field fields "cleanup_failures") in
  let* health=decode_health (field fields "observed_persistence_health") in
  Ok (Hints {keeper_name;hints;cleanup_failures;health})

let of_json json =
  let* fields=object_fields ["schema"] ["error";"keeper_name";"receiver_generation";"session_id";
    "records";"validation";"next_cursor";"provider_completeness";"historical_persistence_failures";
    "terminal_without_observation";"cleanup_failures";"observed_persistence_health";"receivers";"hints";"historical_integrity"] json in
  let* schema=string (field fields "schema") in
  match schema with
  | "masc.native_tasks.hints.v1" -> decode_hints json
  | "masc.native_tasks.records.v1" -> decode_records json
  | "masc.native_tasks.receivers.v1" -> decode_receivers json
  | "masc.native_tasks.error.v1" ->
      let* fields=object_fields error_fields ["observed_persistence_health"] json in
      let* ()=unknown fields in
      let* name=string (field fields "error") in
      let* error=error_of_name name in
      let* health=match List.assoc_opt "observed_persistence_health" fields with
        | None -> if error=Invalid_keeper then Ok None else shape "missing error health"
        | Some value -> decode_health value |> Result.map Option.some in
      Ok (Failure {error;health})
  | _ -> shape "unknown response schema"

type records_request = { scope : scope; after : cursor option }
let records_of_response ~request = function
  | Receivers _ | Hints _ | Failure _ -> Error Unexpected_response
  | Records page ->
      let* ()=if page.scope=request.scope then Ok () else Error Scope_mismatch in
      let* boundary=match request.after with
        | None -> Ok 0
        | Some cursor ->
            let* _=nonnegative (`Int cursor.after_sequence) in
            let* _=store_id (`String cursor.store_id) in
            if cursor.store_id=page.next_cursor.store_id
               && cursor.after_sequence<=page.next_cursor.after_sequence
            then Ok cursor.after_sequence else Error Cursor_mismatch in
      let* ()=validate_rows page.scope page.next_cursor page.records in
      let* ()=match page.records with
        | [] -> if boundary=page.next_cursor.after_sequence then Ok () else Error Sequence_mismatch
        | (first:record)::_ -> if first.seq=boundary+1 then Ok () else Error Sequence_mismatch in
      Ok page
let receivers_of_response ~keeper_name = function
  | Records _ | Hints _ | Failure _ -> Error Unexpected_response
  | Receivers page -> if page.keeper_name=keeper_name then Ok page else Error Scope_mismatch

let hints_of_response ~keeper_name = function
  | Hints page -> if page.keeper_name=keeper_name then Ok page else Error Scope_mismatch
  | Records _ | Receivers _ | Failure _ -> Error Unexpected_response
