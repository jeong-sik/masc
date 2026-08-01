type parse_error = Invalid_rfc3339

let parse_rfc3339 ?(strict = true) value =
  match Ptime.of_rfc3339 ~strict value with
  | Ok (timestamp, _, _) -> Ok (Ptime.to_float_s timestamp)
  | Error _ -> Error Invalid_rfc3339
;;

let parse_rfc3339_opt ?(strict = true) value =
  match parse_rfc3339 ~strict value with
  | Ok timestamp -> Some timestamp
  | Error Invalid_rfc3339 -> None
;;
