type t =
  { observation_id : string
  ; attempt : int
  ; max_retries : int
  ; retry_delay_ms : int
  ; error_status : int option
  }

type error = Invalid_field of string | Conflicting_field of string | Other_session

let ( let* ) = Result.bind

let field fields key =
  match List.filter_map (fun (name, value) -> if name = key then Some value else None) fields with
  | [] -> Ok None
  | [value] -> Ok (Some value)
  | _ :: _ :: _ -> Error (Conflicting_field key)

let text fields key =
  let* value = field fields key in
  match value with
  | Some (`String value) when String.trim value <> "" -> Ok value
  | Some _ | None -> Error (Invalid_field key)

let count fields key =
  let* value = field fields key in
  match value with
  | Some value ->
      (match Runtime_json_integer.of_json value with
       | Ok value when value >= 0 -> Ok value
       | Ok _ | Error _ -> Error (Invalid_field key))
  | None -> Error (Invalid_field key)

let report fields ~identity_field =
  let* observation_id = text fields identity_field in
  let* attempt = count fields "attempt" in
  let* max_retries = count fields "max_retries" in
  let* retry_delay_ms = count fields "retry_delay_ms" in
  let* status = field fields "error_status" in
  let* error_status = match status with
    | None | Some `Null -> Ok None
    | Some _ -> count fields "error_status" |> Result.map Option.some in
  Ok {observation_id;attempt;max_retries;retry_delay_ms;error_status}

let decode ~expected_session_id = function
  | `Assoc fields ->
      let* kind = text fields "type" in
      if kind <> "system" then Ok None
      else
        let* subtype = field fields "subtype" in
        (match subtype with
         | Some (`String "api_retry") ->
             let* session_id = text fields "session_id" in
             if session_id <> expected_session_id then Error Other_session
             else
               report fields ~identity_field:"uuid" |> Result.map Option.some
         | Some (`String _) | None -> Ok None
         | Some _ -> Error (Invalid_field "subtype"))
  | _ -> Error (Invalid_field "frame")

let to_json report = `Assoc [
  "observation_id", `String report.observation_id;
  "attempt", `Int report.attempt; "max_retries", `Int report.max_retries;
  "retry_delay_ms", `Int report.retry_delay_ms;
  "error_status", (match report.error_status with None -> `Null | Some status -> `Int status)]

let of_json = function
  | `Assoc fields ->
      let allowed = ["observation_id";"attempt";"max_retries";"retry_delay_ms";"error_status"] in
      if List.exists (fun (key,_) -> not (List.mem key allowed)) fields then
        Error (Invalid_field "unexpected report field")
      else report fields ~identity_field:"observation_id"
  | _ -> Error (Invalid_field "report")

let error_to_string = function
  | Invalid_field field -> "invalid provider retry field: " ^ field
  | Conflicting_field field -> "duplicate provider retry field: " ^ field
  | Other_session -> "provider retry belongs to another session"
