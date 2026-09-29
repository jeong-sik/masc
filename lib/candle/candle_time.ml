type t = Ptime.t

let of_ptime instant = Ptime.truncate ~frac_s:0 instant
let to_ptime instant = instant
let compare = Ptime.compare
let equal = Ptime.equal
let to_rfc3339 instant = Ptime.to_rfc3339 ~space:false ~frac_s:0 ~tz_offset_s:0 instant

let of_rfc3339 text =
  match Ptime.of_rfc3339 ~strict:true text with
  | Error _ -> Error (Printf.sprintf "%S is not an RFC 3339 timestamp" text)
  | Ok (parsed, _offset, _consumed) ->
    let instant = of_ptime parsed in
    let canonical = to_rfc3339 instant in
    if String.equal canonical text
    then Ok instant
    else
      Error
        (Printf.sprintf "%S is not the ledger's UTC whole-second form (%s)" text canonical)
;;

let to_yojson instant = `String (to_rfc3339 instant)

let of_yojson json = Result.bind (Candle_json.as_string json) of_rfc3339
