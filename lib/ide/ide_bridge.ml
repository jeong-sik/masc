open Result.Syntax
type event_kind = Tool
let event_kind_to_string = function Tool -> "tool"
let event_kind_of_string = function "tool" -> Some Tool | _ -> None

let field name fields =
  match List.filter (fun (key, _) -> String.equal key name) fields with
  | [ _, value ] -> Ok value
  | [] | _ :: _ :: _ -> Error "canonical tool event has missing or duplicate fields"

let string name fields =
  let* value = field name fields in
  match value with
  | `String value when String.trim value <> "" -> Ok value
  | `String _ | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _ ->
    Error "canonical tool event has an invalid string field"

let number name fields =
  let* value = field name fields in
  match value with
  | `Float value when Float.is_finite value -> Ok value
  | `Int value -> Ok (Float.of_int value)
  | `Float _ | `Null | `Bool _ | `Intlit _ | `String _ | `Assoc _ | `List _ ->
    Error "canonical tool event has an invalid numeric field"

let event_of_row row =
  let* fields = match row with
    | `Assoc fields -> Ok fields
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
      Error "canonical tool event must be an object" in
  let* observation = Tool_observation.of_row row in
  let* observation = match observation with
    | Some observation -> Ok observation
    | None -> Error "canonical tool event has no producer observation" in
  let* addressed = match Tool_observation.addressed observation with
    | Some addressed -> Ok addressed
    | None -> Error "canonical tool event is not addressed" in
  let* execution_id = string "execution_id" fields in
  let* keeper = string "keeper" fields in
  let* tool = string "tool" fields in
  let* wire_outcome = string "wire_outcome" fields in
  let* () = match wire_outcome with
    | "ok" | "error" | "unknown" -> Ok ()
    | _ -> Error "canonical tool event has an invalid wire outcome" in
  let* duration = number "duration_ms" fields in
  let* timestamp = number "ts" fields in
  let* () =
    if duration >= 0. && duration < Float.of_int max_int
       && Float.abs timestamp < Int64.to_float Int64.max_int /. 1000.
    then Ok () else Error "canonical tool event numeric field is out of range" in
  let* output = field "output" fields in
  let output = match output with `String text -> text | value -> Yojson.Safe.to_string value in
  let summary = String_util.utf8_safe ~max_bytes:200 ~suffix:"" output |> String_util.to_string in
  let typed_outcome = match observation.declared_progress with
    | None -> wire_outcome
    | Some declared -> Tool_observation.declared_progress_word declared in
  Ok (`Assoc
    [ "type", `String "tool"
    ; "event_id", `String execution_id
    ; "tool_name", `String tool
    ; "keeper_id", `String keeper
    ; "turn_id", Ids.Turn_ref.to_yojson observation.turn_ref
    ; "outcome", `String wire_outcome
    ; "typed_outcome", `String typed_outcome
    ; "latency_ms", `Int (int_of_float duration)
    ; "summary", `String summary
    ; "file_path", `String (Agent_observation.Code_address.path addressed.address)
    ; "timestamp_ms", `Intlit (Int64.to_string (Int64.of_float (timestamp *. 1000.)))
    ])

let events_of_rows rows =
  List.fold_left (fun acc row ->
    let* acc = acc in let* event = event_of_row row in Ok (event :: acc)) (Ok []) rows
  |> Result.map List.rev
