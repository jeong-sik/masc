type t =
  | Off
  | Disabled of string
  | Ready of { policy : Candle_config.policy; balance : Candle_balance.t; events : Candle_event.t list }

let read ~now ~base_path =
  match Candle_status.observed_view ~now ~base_path with
  | Ok view -> Ready {policy=view.policy;balance=view.balance;events=view.events}
  | Error Candle_status.Off -> Off
  | Error (Candle_status.Disabled reason) -> Disabled reason
  | Error error -> Disabled (Candle_status.error_to_string error)

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

let disabled_account_revision reason =
  Digestif.SHA256.(digest_string ("disabled\000" ^ reason) |> to_hex)

let ready_account_revision ~events ~policy ~balance ~keeper =
  let relevant (event : Candle_event.t) = match event.body with
    | Candle_event.Half_life_set _ -> true
    | Candle_event.Paid payment -> List.exists (fun (allocation : Candle_payment.allocation) ->
        String.equal allocation.keeper keeper) payment.allocations
    | Candle_event.Purchased purchase -> String.equal purchase.keeper keeper
    | Candle_event.Equipped choice -> String.equal choice.keeper keeper
    | Candle_event.Snapshot _ | Candle_event.Payout_owed _ | Candle_event.Candidates _
    | Candle_event.Unattributed _ | Candle_event.Payout_failed _ -> false in
  let facts = events |> List.filter relevant |> List.map Candle_event.to_yojson in
  let half_life = match policy.Candle_config.half_life with
    | Candle_decay.Off -> `String "off"
    | Candle_decay.Hours hours -> `Int hours in
  let owned = Candle_balance.owned balance ~keeper
    |> List.map (fun item -> `String (Keeper_portrait_item.id item)) in
  let catalog = Keeper_portrait_item.all |> List.map (fun item ->
    let price = match Candle_config.price policy item with
      | Candle_config.Unpriced -> `Null
      | Candle_config.Priced amount -> `String (string_of_int amount) in
    `List [`String (Keeper_portrait_item.id item); price]) in
  let account = `List [
    half_life;
    `List facts;
    `List owned;
    `List catalog;
  ] in
  Digestif.SHA256.(digest_string ("ready\000" ^ Yojson.Safe.to_string account) |> to_hex)

let account_revision observation ~keeper = match observation with
  | Off -> None
  | Disabled reason -> Some (disabled_account_revision reason)
  | Ready {policy;balance;events} -> Some (ready_account_revision ~events ~policy ~balance ~keeper)
