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
  | Some (`Int value) when value >= 0 -> Ok value
  | Some _ | None -> Error (Invalid_field key)

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
               let* observation_id = text fields "uuid" in
               let* attempt = count fields "attempt" in
               let* max_retries = count fields "max_retries" in
               let* retry_delay_ms = count fields "retry_delay_ms" in
               let* status = field fields "error_status" in
               let* error_status = match status with
                 | None | Some `Null -> Ok None
                 | Some (`Int status) when status >= 0 -> Ok (Some status)
                 | Some _ -> Error (Invalid_field "error_status") in
               Ok (Some {observation_id;attempt;max_retries;retry_delay_ms;error_status})
         | Some (`String _) | None -> Ok None
         | Some _ -> Error (Invalid_field "subtype"))
  | _ -> Error (Invalid_field "frame")
