type interrupt_signal =
  | Signalled of { turn_id : int option }
  | Not_signalled of
      { reason : string
      ; detail : string option
      }

let decode_signal ~identity_field ~expected_identity json =
  let field name =
    match json with
    | `Assoc fields -> List.assoc_opt name fields
    | _ -> None
  in
  let string_of name =
    match field name with
    | Some (`String value) -> Some value
    | Some _ | None -> None
  in
  let turn_id =
    match field "turn_id" with
    | Some (`Int value) -> Some value
    | Some _ | None -> None
  in
  let echoed_request_id = string_of identity_field in
  if echoed_request_id <> Some expected_identity
  then
    Error
      (Printf.sprintf
         "interrupt response %s mismatch: expected %s, received %s"
         identity_field expected_identity
         (Option.value ~default:"<missing>" echoed_request_id))
  else
  match field "signalled" with
  | Some (`Bool true) -> Ok (Signalled { turn_id })
  | Some (`Bool false) ->
      Ok
        (Not_signalled
           { reason = Option.value ~default:"unstated" (string_of "reason")
           ; detail = string_of "detail"
           })
  | Some _ | None -> Error "interrupt response has no signalled flag"

let decode_interrupt_signal ~expected_request_id json =
  decode_signal ~identity_field:"request_id" ~expected_identity:expected_request_id json

let decode_observed_interrupt_signal ~expected_token json =
  decode_signal ~identity_field:"interrupt_token" ~expected_identity:expected_token json
