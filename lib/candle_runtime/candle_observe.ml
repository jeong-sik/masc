type t = Off | Disabled of string | Ready of Candle_balance.t

let read ~base_path =
  match Candle_status.configured ~base_path with
  | Candle_config.Off -> Off
  | Candle_config.Disabled {reason} -> Disabled reason
  | Candle_config.Enabled _ ->
    match Candle_ledger.read ~base_path with
    | Error error -> Disabled (Candle_ledger.read_error_to_string error)
    | Ok view ->
      match Candle_balance.of_events (Candle_ledger.events view) with
      | Error error -> Disabled (Candle_balance.error_to_string error)
      | Ok state -> Ready state

let summary = function
  | Off -> Candle_observation.Off
  | Disabled reason -> Candle_observation.Disabled {reason}
  | Ready state -> Candle_observation.Ready (Candle_balance.supply state)

let balance observation ~keeper = match observation with
  | Off | Disabled _ -> None
  | Ready state -> Some (string_of_int (Candle_balance.balance state ~keeper))

let equipment observation ~keeper = match observation with
  | Off -> Ok (Keeper_portrait_look.equipment_of_name keeper)
  | Disabled reason -> Error ("Candle is disabled: " ^ reason)
  | Ready state -> Ok (Candle_balance.equipment state ~keeper)
