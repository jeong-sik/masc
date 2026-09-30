type t =
  | Off
  | Disabled of string
  | Ready of { policy : Candle_config.policy; balance : Candle_balance.t }

let read ~base_path =
  match Candle_status.configured ~base_path with
  | Candle_config.Off -> Off
  | Candle_config.Disabled {reason} -> Disabled reason
  | Candle_config.Enabled policy ->
    match Candle_ledger.read ~base_path with
    | Error error -> Disabled (Candle_ledger.read_error_to_string error)
    | Ok view ->
      match Candle_balance.of_events (Candle_ledger.events view) with
      | Error error -> Disabled (Candle_balance.error_to_string error)
      | Ok balance -> Ready { policy; balance }

let summary = function
  | Off -> Candle_observation.Off
  | Disabled reason -> Candle_observation.Disabled {reason}
  | Ready { balance; _ } -> Candle_observation.Ready (Candle_balance.supply balance)

let balance observation ~keeper = match observation with
  | Off | Disabled _ -> None
  | Ready { balance; _ } -> Some (string_of_int (Candle_balance.balance balance ~keeper))

let equipment observation ~keeper = match observation with
  | Off -> Ok (Keeper_portrait_look.equipment_of_name keeper)
  | Disabled reason -> Error ("Candle is disabled: " ^ reason)
  | Ready { balance; _ } -> Ok (Candle_balance.equipment balance ~keeper)

let account_revision observation ~keeper = match observation with
  | Off -> None
  | Disabled reason ->
    Some (Digestif.SHA256.(digest_string ("disabled\000" ^ reason) |> to_hex))
  | Ready { policy; balance } ->
    let owned = Candle_balance.owned balance ~keeper
      |> List.map (fun item -> `String (Keeper_portrait_item.id item)) in
    let catalog = Keeper_portrait_item.all |> List.map (fun item ->
      let price = match Candle_config.price policy item with
        | Candle_config.Unpriced -> `Null
        | Candle_config.Priced amount -> `String (string_of_int amount) in
      `List [`String (Keeper_portrait_item.id item); price]) in
    let account = `List [
      `String (string_of_int (Candle_balance.balance balance ~keeper));
      `List owned;
      `List catalog;
    ] in
    Some (Digestif.SHA256.(digest_string ("ready\000" ^ Yojson.Safe.to_string account) |> to_hex))
