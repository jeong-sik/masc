let amount_text amount =
  let padded = if String.length amount < 4 then String.make (4 - String.length amount) '0' ^ amount else amount in
  let split = String.length padded - 3 in
  String.sub padded 0 split ^ "." ^ String.sub padded split 3

let summary_lines = function
  | None | Some (Ok Candle_observation.Off) -> []
  | Some (Error detail) -> ["Candle unavailable: " ^ detail]
  | Some (Ok (Candle_observation.Disabled {reason})) -> ["Candle disabled: " ^ reason]
  | Some (Ok (Candle_observation.Ready supply)) ->
    ["Candle issued: " ^ amount_text supply.issued_milli;
     "Candle burned: " ^ amount_text supply.burned_milli;
     "Candle circulating: " ^ amount_text supply.circulating_milli]

let balance_text reading amount = match reading with
  | None -> Some "not yet read"
  | Some (Ok Candle_observation.Off) -> None
  | Some (Error detail) -> Some ("unavailable: " ^ detail)
  | Some (Ok (Candle_observation.Disabled {reason})) -> Some ("disabled: " ^ reason)
  | Some (Ok (Candle_observation.Ready _)) ->
    Some (match amount with Some value -> amount_text value ^ " Candle" | None -> "unavailable")

let compact_status = function
  | None | Some (Ok Candle_observation.Off) -> None
  | Some (Error _) -> Some "Candle unavailable: ?:Candle details"
  | Some (Ok (Candle_observation.Disabled _)) -> Some "Candle disabled: ?:Candle details"
  | Some (Ok (Candle_observation.Ready _)) -> Some "Candle ready: ?:Candle details"
