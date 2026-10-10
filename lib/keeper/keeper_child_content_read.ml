module Journal = Keeper_child_content_journal
module Child = Keeper_child_content
let ( let* ) = Result.bind

type receiver = { receiver_generation : string; session_id : string; client_uuid : string }
type scope = { keeper_name : string; receiver : receiver }
type cursor = { store_id : string; after_sequence : int }
type error_code =
  | Store_missing | Invalid_scope | Invalid_observation | Cursor_store_mismatch | Cursor_ahead
  | Store_corrupt | Conflicting_observation | Sequence_exhausted | Io_failed
  | Directory_prepare_failed | Store_unavailable | Commit_unconfirmed | Invalid_query | Invalid_keeper
type coverage = Unavailable
type record = { seq : int; recorded_at : float; observation : Child.view }
type storage = Audited of cursor | Failed of error_code
type entry = { receiver : receiver; storage : storage }
type hint_storage = Unchecked of cursor | Hint_failed of error_code
type hint_entry = { receiver : receiver; hint : hint_storage }
type records = { scope : scope; records : record list; next_cursor : cursor;
  cleanup_failures : string list; coverage : coverage }
type receivers = { keeper_name : string; receivers : entry list;
  cleanup_failures : string list; coverage : coverage }
type hints = { keeper_name : string; hints : hint_entry list;
  cleanup_failures : string list; coverage : coverage }
type failure = { error : error_code; coverage : coverage }
type response = Records of records | Receivers of receivers | Hints of hints | Failure of failure
type decode_error = Invalid_shape of string | Invalid_number of string
  | Invalid_child of Child.error | Scope_mismatch | Cursor_mismatch
  | Sequence_mismatch | Duplicate_observation | Duplicate_receiver | Unexpected_response
let decode_error_to_string = function
  | Invalid_shape detail -> "invalid Child read shape: " ^ detail
  | Invalid_number detail -> "invalid Child read number: " ^ detail
  | Invalid_child error -> "invalid Child read observation: " ^ Child.error_to_string error
  | Scope_mismatch -> "Child read scope mismatch"
  | Cursor_mismatch -> "Child read incarnation/cursor mismatch"
  | Sequence_mismatch -> "Child read suffix sequence mismatch"
  | Duplicate_observation -> "duplicate Child observation key"
  | Duplicate_receiver -> "duplicate Child invocation receiver"
  | Unexpected_response -> "unexpected Child read response"
let error_code_of_journal = function
  | Journal.Missing_store -> Store_missing
  | Invalid_scope _ -> Invalid_scope | Invalid_observation _ -> Invalid_observation
  | Cursor_store_mismatch -> Cursor_store_mismatch | Cursor_ahead -> Cursor_ahead
  | Corrupt _ -> Store_corrupt | Conflicting_observation _ -> Conflicting_observation
  | Sequence_exhausted -> Sequence_exhausted | Io_failed _ -> Io_failed
  | Directory_prepare_failed _ -> Directory_prepare_failed
  | Store_unavailable _ -> Store_unavailable | Commit_unconfirmed _ -> Commit_unconfirmed
let code_to_string = function
  | Store_missing -> "store_missing" | Invalid_scope -> "invalid_scope"
  | Invalid_observation -> "invalid_observation" | Cursor_store_mismatch -> "cursor_store_mismatch"
  | Cursor_ahead -> "cursor_ahead" | Store_corrupt -> "store_corrupt"
  | Conflicting_observation -> "conflicting_observation" | Sequence_exhausted -> "sequence_exhausted"
  | Io_failed -> "io_failed" | Directory_prepare_failed -> "directory_prepare_failed"
  | Store_unavailable -> "store_unavailable" | Commit_unconfirmed -> "commit_unconfirmed"
  | Invalid_query -> "invalid_query" | Invalid_keeper -> "invalid_keeper"
let code_of_string = function
  | "store_missing" -> Ok Store_missing | "invalid_scope" -> Ok Invalid_scope
  | "invalid_observation" -> Ok Invalid_observation | "cursor_store_mismatch" -> Ok Cursor_store_mismatch
  | "cursor_ahead" -> Ok Cursor_ahead | "store_corrupt" -> Ok Store_corrupt
  | "conflicting_observation" -> Ok Conflicting_observation | "sequence_exhausted" -> Ok Sequence_exhausted
  | "io_failed" -> Ok Io_failed | "directory_prepare_failed" -> Ok Directory_prepare_failed
  | "store_unavailable" -> Ok Store_unavailable | "commit_unconfirmed" -> Ok Commit_unconfirmed
  | "invalid_query" -> Ok Invalid_query | "invalid_keeper" -> Ok Invalid_keeper
  | _ -> Error (Invalid_shape "unknown error code")
let failure error = Failure {error;coverage=Unavailable}
let cleanup_of_journal failures =
  List.map (fun (failure:Journal.cleanup_failure) -> failure.operation) failures
let receiver_of_journal (receiver:Journal.receiver) : receiver =
  {receiver_generation=receiver.receiver_generation;session_id=receiver.session_id;client_uuid=receiver.client_uuid}
(* The page label comes from the opened store, not from the caller: a caught-up
   empty suffix has no row whose origin could expose a mislabelled scope. *)
let records_of_journal ~redact_text ~scope ~(snapshot:Journal.snapshot) ~cleanup_failures =
  let store_scope:scope={keeper_name=snapshot.keeper_name;receiver=receiver_of_journal snapshot.receiver} in
  if scope<>store_scope then failure Invalid_scope else
  Records {scope;records=List.map (fun (row:Journal.record) ->
    {seq=row.seq;recorded_at=row.recorded_at;observation=Child.redact redact_text row.observation}) snapshot.records;
    next_cursor={store_id=snapshot.validation.store_id;after_sequence=snapshot.validation.through_sequence};
    cleanup_failures=cleanup_of_journal cleanup_failures;coverage=Unavailable}
let receivers_of_journal ~keeper_name ~entries ~cleanup_failures =
  Receivers {keeper_name;receivers=List.map (fun (entry:Journal.discovery_entry) ->
    {receiver=receiver_of_journal entry.receiver;storage=match entry.state with
      | Error error -> Failed (error_code_of_journal error)
      | Ok validation -> Audited {store_id=validation.store_id;after_sequence=validation.through_sequence}}) entries;
    cleanup_failures=cleanup_of_journal cleanup_failures;coverage=Unavailable}
let hints_of_journal ~keeper_name ~entries ~cleanup_failures =
  Hints {keeper_name;hints=List.map (fun (entry:Journal.hint_entry) ->
    {receiver=receiver_of_journal entry.receiver;hint=match entry.state with
      | Error error -> Hint_failed (error_code_of_journal error)
      | Ok hint -> Unchecked {store_id=hint.store_id;after_sequence=hint.through_sequence}}) entries;
    cleanup_failures=cleanup_of_journal cleanup_failures;coverage=Unavailable}
let receiver_json (receiver:receiver) = `Assoc ["receiver_generation",`String receiver.receiver_generation;
  "session_id",`String receiver.session_id;"client_uuid",`String receiver.client_uuid]
let scope_json (scope:scope) = `Assoc ["keeper_name",`String scope.keeper_name;"receiver",receiver_json scope.receiver]
let cursor_json (cursor:cursor) = `Assoc ["store_id",`String cursor.store_id;"after_sequence",`Int cursor.after_sequence]
let receipt_json kind (cursor:cursor) = `Assoc ["kind",`String kind;"store_id",`String cursor.store_id;
  "through_sequence",`Int cursor.after_sequence]
let failed_json code = `Assoc ["kind",`String "failed";"error",`String (code_to_string code)]
let coverage_fields Unavailable = ["persistence_failure_history",`String "unavailable";
  "provider_completeness",`String "unknown";"liveness",`String "unknown"]
let cleanup_json values = `List (List.map (fun value -> `String value) values)
let envelope schema coverage fields = `Assoc (("schema",`String schema)::coverage_fields coverage @ fields)
let to_json = function
  | Records page -> envelope "masc.child_content.records.v1" page.coverage
      ["scope",scope_json page.scope;"records",`List (List.map (fun (row:record) ->
        `Assoc ["seq",`Int row.seq;"recorded_at",`Float row.recorded_at;
          "observation",Child.to_json row.observation]) page.records);
       "next_cursor",cursor_json page.next_cursor;
       "validation",`Assoc ["kind",`String "audited";"through_sequence",`Int page.next_cursor.after_sequence];
       "cleanup_failures",cleanup_json page.cleanup_failures]
  | Receivers page -> envelope "masc.child_content.receivers.v1" page.coverage
      ["keeper_name",`String page.keeper_name;"receivers",`List (List.map (fun (entry:entry) ->
        `Assoc ["receiver",receiver_json entry.receiver;"storage",match entry.storage with
          | Audited cursor -> receipt_json "audited" cursor | Failed code -> failed_json code]) page.receivers);
       "cleanup_failures",cleanup_json page.cleanup_failures]
  | Hints page -> envelope "masc.child_content.hints.v1" page.coverage
      ["keeper_name",`String page.keeper_name;"hints",`List (List.map (fun (entry:hint_entry) ->
        `Assoc ["receiver",receiver_json entry.receiver;"hint",match entry.hint with
          | Unchecked cursor -> receipt_json "unchecked" cursor | Hint_failed code -> failed_json code]) page.hints);
       "cleanup_failures",cleanup_json page.cleanup_failures]
  | Failure page -> envelope "masc.child_content.error.v1" page.coverage
      ["error",`String (code_to_string page.error)]

let fields allowed = function
  | `Assoc values ->
      let names=List.map fst values in
      if List.length names<>List.length (List.sort_uniq String.compare names)
        || List.sort String.compare names<>List.sort String.compare allowed
      then Error (Invalid_shape "missing, duplicate or unknown object member") else Ok values
  | _ -> Error (Invalid_shape "expected object")
let member name values =
  match List.assoc_opt name values with Some value -> Ok value | None -> Error (Invalid_shape "missing member")
let string = function `String value -> Ok value | _ -> Error (Invalid_shape "expected string")
let nonempty value = if value="" then Error (Invalid_shape "empty identity") else Ok value
let text_member name values = let* value=member name values in string value
let identity name values = let* value=text_member name values in nonempty value
let integer json = Runtime_json_integer.of_json json |> Result.map_error (fun detail -> Invalid_number detail)
let nonnegative json = let* value=integer json in
  if value<0 then Error (Invalid_number "negative sequence or ordinal") else Ok value
let int_member name values = let* value=member name values in nonnegative value
let finite = function
  | `Float value when Float.is_finite value -> Ok value
  | `Int value -> Ok (float_of_int value)
  | `Intlit value -> (match float_of_string_opt value with
      | Some value when Float.is_finite value -> Ok value | _ -> Error (Invalid_number "nonfinite timestamp"))
  | _ -> Error (Invalid_number "expected finite timestamp")
let list decode = function
  | `List values ->
      let rec loop acc = function
        | [] -> Ok (List.rev acc)
        | value::rest -> let* value=decode value in loop (value::acc) rest in
      loop [] values
  | _ -> Error (Invalid_shape "expected array")
let decode_receiver json =
  let* values=fields ["receiver_generation";"session_id";"client_uuid"] json in
  let* receiver_generation=identity "receiver_generation" values in
  let* session_id=identity "session_id" values in let* client_uuid=identity "client_uuid" values in
  Ok {receiver_generation;session_id;client_uuid}
let decode_scope json =
  let* values=fields ["keeper_name";"receiver"] json in let* keeper_name=identity "keeper_name" values in
  let* receiver_json=member "receiver" values in let* receiver=decode_receiver receiver_json in Ok {keeper_name;receiver}
let valid_cursor (cursor:cursor) =
  if String.trim cursor.store_id="" then Error (Invalid_shape "empty store incarnation") else
  let* _=nonnegative (`Int cursor.after_sequence) in Ok ()
let decode_cursor json =
  let* values=fields ["store_id";"after_sequence"] json in let* store_id=identity "store_id" values in
  let* after_sequence=int_member "after_sequence" values in
  let cursor={store_id;after_sequence} in let* ()=valid_cursor cursor in Ok cursor
let decode_receipt expected json =
  let* values=fields ["kind";"store_id";"through_sequence"] json in
  let* kind=text_member "kind" values in
  if kind<>expected then Error (Invalid_shape "wrong receipt authority") else
  let* store_id=identity "store_id" values in let* after_sequence=int_member "through_sequence" values in
  let cursor={store_id;after_sequence} in let* ()=valid_cursor cursor in Ok cursor
let decode_storage success json =
  let* kind=match json with `Assoc values -> text_member "kind" values
    | _ -> Error (Invalid_shape "expected storage object") in
  if kind="failed" then
    let* values=fields ["kind";"error"] json in let* code=text_member "error" values in
    let* code=code_of_string code in Ok (Error code)
  else let* cursor=decode_receipt success json in Ok (Ok cursor)
let decode_record json =
  let* values=fields ["seq";"recorded_at";"observation"] json in let* seq=int_member "seq" values in
  let* ()=if seq=0 then Error Sequence_mismatch else Ok () in
  let* timestamp=member "recorded_at" values in let* recorded_at=finite timestamp in
  let* raw=member "observation" values in
  let* observation=Child.of_json raw |> Result.map_error (fun error -> Invalid_child error) in
  Ok {seq;recorded_at;observation}
let validate_rows (scope:scope) (cursor:cursor) rows =
  let keys=Hashtbl.create 16 in
  let rec loop previous = function
    | [] -> (match previous with None -> Ok () | Some seq ->
        if seq=cursor.after_sequence then Ok () else Error Sequence_mismatch)
    | (row:record)::rest ->
        let origin=row.observation.origin and observation=row.observation in
        if origin.keeper_name<>scope.keeper_name
          || origin.invocation.receiver_generation<>scope.receiver.receiver_generation
          || origin.invocation.session_id<>scope.receiver.session_id
          || origin.invocation.client_uuid<>scope.receiver.client_uuid then Error Scope_mismatch else
        let key=(observation.observation_id,observation.ordinal,observation.channel) in
        if Hashtbl.mem keys key then Error Duplicate_observation
        else if row.seq>cursor.after_sequence
          || (match previous with None -> false | Some seq -> row.seq<>seq+1) then Error Sequence_mismatch
        else (Hashtbl.add keys key ();loop (Some row.seq) rest) in
  loop None rows
let base_fields = ["schema";"persistence_failure_history";"provider_completeness";"liveness"]
let decode_envelope schema extra json =
  let* values=fields (base_fields @ extra) json in
  let* actual=text_member "schema" values in let* coverage=text_member "persistence_failure_history" values in
  let* completeness=text_member "provider_completeness" values in let* liveness=text_member "liveness" values in
  if actual<>schema || coverage<>"unavailable" || completeness<>"unknown" || liveness<>"unknown"
  then Error (Invalid_shape "unknown schema or coverage") else Ok values
let cleanup_member values = let* json=member "cleanup_failures" values in list string json
let decode_records json =
  let* values=decode_envelope "masc.child_content.records.v1"
    ["scope";"records";"next_cursor";"validation";"cleanup_failures"] json in
  let* json_scope=member "scope" values in let* scope=decode_scope json_scope in
  let* json_cursor=member "next_cursor" values in let* next_cursor=decode_cursor json_cursor in
  let* raw=member "validation" values in let* validation=fields ["kind";"through_sequence"] raw in
  let* kind=text_member "kind" validation in let* through=int_member "through_sequence" validation in
  let* ()=if kind<>"audited" || through<>next_cursor.after_sequence then Error Cursor_mismatch else Ok () in
  let* rows=member "records" values in let* records=list decode_record rows in
  let* ()=validate_rows scope next_cursor records in let* cleanup_failures=cleanup_member values in
  Ok (Records {scope;records;next_cursor;cleanup_failures;coverage=Unavailable})
let decode_entry json =
  let* values=fields ["receiver";"storage"] json in let* raw=member "receiver" values in
  let* receiver=decode_receiver raw in let* raw=member "storage" values in
  let* storage=decode_storage "audited" raw in
  Ok ({receiver;storage=(match storage with Ok cursor -> Audited cursor | Error code -> Failed code)}:entry)
let decode_hint_entry json =
  let* values=fields ["receiver";"hint"] json in let* raw=member "receiver" values in
  let* receiver=decode_receiver raw in let* raw=member "hint" values in
  let* hint=decode_storage "unchecked" raw in
  Ok ({receiver;hint=(match hint with Ok cursor -> Unchecked cursor | Error code -> Hint_failed code)}:hint_entry)
let distinct_receivers receivers =
  if List.length receivers=List.length (List.sort_uniq compare receivers) then Ok () else Error Duplicate_receiver
let decode_receivers json =
  let* values=decode_envelope "masc.child_content.receivers.v1" ["keeper_name";"receivers";"cleanup_failures"] json in
  let* keeper_name=identity "keeper_name" values in let* raw=member "receivers" values in
  let* receivers=list decode_entry raw in
  let* ()=distinct_receivers (List.map (fun (entry:entry) -> entry.receiver) receivers) in
  let* cleanup_failures=cleanup_member values in
  Ok (Receivers {keeper_name;receivers;cleanup_failures;coverage=Unavailable})
let decode_hints json =
  let* values=decode_envelope "masc.child_content.hints.v1" ["keeper_name";"hints";"cleanup_failures"] json in
  let* keeper_name=identity "keeper_name" values in let* raw=member "hints" values in
  let* hints=list decode_hint_entry raw in
  let* ()=distinct_receivers (List.map (fun (entry:hint_entry) -> entry.receiver) hints) in
  let* cleanup_failures=cleanup_member values in
  Ok (Hints {keeper_name;hints;cleanup_failures;coverage=Unavailable})
let of_json json =
  let* schema=match json with `Assoc values -> text_member "schema" values
    | _ -> Error (Invalid_shape "expected response object") in
  match schema with
  | "masc.child_content.records.v1" -> decode_records json
  | "masc.child_content.receivers.v1" -> decode_receivers json
  | "masc.child_content.hints.v1" -> decode_hints json
  | "masc.child_content.error.v1" ->
      let* values=decode_envelope schema ["error"] json in let* code=text_member "error" values in
      let* error=code_of_string code in Ok (failure error)
  | _ -> Error (Invalid_shape "unknown Child read schema")
type records_request = { scope : scope; after : cursor option }
let valid_scope (scope:scope) =
  let* _=nonempty scope.keeper_name in let* _=nonempty scope.receiver.receiver_generation in
  let* _=nonempty scope.receiver.session_id in let* _=nonempty scope.receiver.client_uuid in Ok ()
let records_of_response ~request = function
  | Receivers _ | Hints _ | Failure _ -> Error Unexpected_response
  | Records page ->
      let* ()=valid_scope request.scope in
      let* ()=valid_cursor page.next_cursor in
      let* ()=validate_rows page.scope page.next_cursor page.records in
      if request.scope<>page.scope then Error Scope_mismatch else
      let* boundary=match request.after with
        | None -> Ok 0
        | Some cursor ->
            let* ()=valid_cursor cursor in
            if cursor.store_id<>page.next_cursor.store_id || cursor.after_sequence>page.next_cursor.after_sequence
            then Error Cursor_mismatch else Ok cursor.after_sequence in
      let* ()=match page.records with
        | [] -> if boundary=page.next_cursor.after_sequence then Ok () else Error Sequence_mismatch
        | row::_ -> if row.seq=boundary+1 then Ok () else Error Sequence_mismatch in
      Ok page
let receivers_of_response ~keeper_name = function
  | Receivers page -> if page.keeper_name=keeper_name then Ok page else Error Scope_mismatch
  | Records _ | Hints _ | Failure _ -> Error Unexpected_response
let hints_of_response ~keeper_name = function
  | Hints page -> if page.keeper_name=keeper_name then Ok page else Error Scope_mismatch
  | Records _ | Receivers _ | Failure _ -> Error Unexpected_response
