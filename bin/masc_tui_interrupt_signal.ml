type interrupt_signal =
  | Signalled of { turn_id : int option }
  | Not_signalled of
      { reason : string
      ; detail : string option
      }

let decode_interrupt_signal ~expected_request_id json =
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
  let echoed_request_id = string_of "request_id" in
  if echoed_request_id <> Some expected_request_id
  then
    Error
      (Printf.sprintf
         "interrupt response request_id mismatch: expected %s, received %s"
         expected_request_id
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
