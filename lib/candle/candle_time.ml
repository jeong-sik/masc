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

module Date = struct
  type t = Ptime.date

  let year_length = 4
  let part_length = 2
  let text_length = year_length + 1 + part_length + 1 + part_length

  let is_digits text ~first ~length =
    let rec go index =
      index >= first + length
      ||
      match text.[index] with
      | '0' .. '9' -> go (index + 1)
      | _ -> false
    in
    go first
  ;;

  let of_string text =
    let month_at = year_length + 1 in
    let day_at = month_at + part_length + 1 in
    if String.length text = text_length
       && is_digits text ~first:0 ~length:year_length
       && Char.equal text.[year_length] '-'
       && is_digits text ~first:month_at ~length:part_length
       && Char.equal text.[day_at - 1] '-'
       && is_digits text ~first:day_at ~length:part_length
    then (
      let number first length = int_of_string (String.sub text first length) in
      let date = number 0 year_length, number month_at part_length, number day_at part_length in
      Option.map (fun _ -> date) (Ptime.of_date date))
    else None
  ;;

  let to_string (year, month, day) = Printf.sprintf "%04d-%02d-%02d" year month day
  let equal (year, month, day) (year', month', day') =
    Int.equal year year' && Int.equal month month' && Int.equal day day'
  ;;

  let to_yojson date = `String (to_string date)

  let of_yojson json =
    Result.bind (Candle_json.as_string json) (fun text ->
      match of_string text with
      | Some date -> Ok date
      | None -> Error (Printf.sprintf "%S is not a YYYY-MM-DD calendar date" text))
  ;;
end
