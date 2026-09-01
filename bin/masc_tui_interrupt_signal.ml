(** What the server did with a request to interrupt a keeper's current turn.

    Extracted from [Masc_tui_http] so the decode contract can be exercised by
    tests: executable modules cannot be linked from the test tree, and this
    decoder plus its variant are pure Yojson work with no HTTP dependency.
    [Masc_tui_http] re-exports both via [include], so callers keep their
    [Masc_tui_http.Signalled] spelling.

    [Signalled] reports that the signal reached the turn switch, and nothing
    more. Whether the fiber then stops is a later event: a turn parked in an
    uncancellable section keeps running, and reading this as the outcome is
    what hid a 63-minute hang (masc #29229). *)
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
