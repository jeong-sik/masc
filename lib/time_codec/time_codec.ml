type parse_error = Invalid_rfc3339

let parse_ptime ?(strict = true) value =
  match Ptime.of_rfc3339 ~strict value with
  | Ok (timestamp, _, _) -> Ok timestamp
  | Error _ -> Error Invalid_rfc3339
;;

let parse_rfc3339 ?(strict = true) value =
  Result.map Ptime.to_float_s (parse_ptime ~strict value)
;;

let parse_rfc3339_whole_seconds ?(strict = true) value =
  Result.map
    (fun timestamp -> Ptime.to_float_s (Ptime.truncate ~frac_s:0 timestamp))
    (parse_ptime ~strict value)
;;

let parse_rfc3339_opt ?(strict = true) value =
  match parse_rfc3339 ~strict value with
  | Ok timestamp -> Some timestamp
  | Error Invalid_rfc3339 -> None
;;
