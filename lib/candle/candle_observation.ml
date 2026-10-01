type t =
  | Off
  | Disabled of { reason : string }
  | Ready of Candle_balance.supply

let ( let* ) = Result.bind

let amount_of_json = function
  | `String amount
    when amount <> ""
         && (String.length amount = 1 || amount.[0] <> '0')
         && String.for_all (function '0' .. '9' -> true | _ -> false) amount ->
    Ok amount
  | _ -> Error "Candle amount must be a canonical nonnegative decimal string"

let balance_of_json = function
  | `Null -> Ok None
  | value -> Result.map Option.some (amount_of_json value)

let to_json = function
  | Off -> `Assoc ["status", `String "off"]
  | Disabled {reason} -> `Assoc ["status", `String "disabled"; "reason", `String reason]
  | Ready supply ->
    `Assoc ["status", `String "ready";
      "issued_milli", `String supply.issued_milli;
      "burned_milli", `String supply.burned_milli;
      "circulating_milli", `String supply.circulating_milli]

let of_json json =
  let context = "Candle observation" in
  let* fields = Candle_json.object_fields ~context json in
  let* status, fields = Candle_json.field ~context "status" Candle_json.as_string fields in
  let* value, fields = match status with
    | "off" -> Ok (Off, fields)
    | "disabled" ->
      let* reason, fields = Candle_json.field ~context "reason" Candle_json.as_string fields in
      if String.trim reason = "" then Error "Candle disabled reason must not be empty"
      else Ok (Disabled {reason}, fields)
    | "ready" ->
      let* issued_milli, fields = Candle_json.field ~context "issued_milli" amount_of_json fields in
      let* burned_milli, fields = Candle_json.field ~context "burned_milli" amount_of_json fields in
      let* circulating_milli, fields = Candle_json.field ~context "circulating_milli" amount_of_json fields in
      if Z.equal (Z.of_string issued_milli)
          (Z.add (Z.of_string burned_milli) (Z.of_string circulating_milli))
      then Ok (Ready {issued_milli;burned_milli;circulating_milli}, fields)
      else Error "Candle supply does not conserve issued currency"
    | _ -> Error "Unknown Candle observation status" in
  let* () = Candle_json.finish ~context fields in
  Ok value
