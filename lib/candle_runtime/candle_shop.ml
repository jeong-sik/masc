let ( let* ) = Result.bind

type account =
  { keeper : string
  ; balance_milli : int
  ; owned_items : Keeper_portrait_item.t list
  }

type catalog_entry =
  { item : Keeper_portrait_item.t
  ; price : Candle_config.price
  }

type receipt =
  { account : account
  ; item : Keeper_portrait_item.t
  ; amount_milli : int
  ; purchased_at : Candle_time.t
  }

type error =
  | Off
  | Disabled of string
  | Unpriced of Keeper_portrait_item.t
  | Account_invalid of Candle_balance.error
  | Purchase_refused of Candle_balance.error
  | Ledger_unavailable of string
  | Invalid_time of string

let error_to_string = function
  | Off -> "Candle is off"
  | Disabled detail -> "Candle is disabled: " ^ detail
  | Unpriced item -> "No price is configured for " ^ Keeper_portrait_item.id item
  | Account_invalid error ->
    "Candle ledger account is invalid: " ^ Candle_balance.error_to_string error
  | Purchase_refused error -> Candle_balance.error_to_string error
  | Ledger_unavailable detail -> detail
  | Invalid_time detail -> detail
;;

let policy ~base_path =
  match Candle_status.configured ~base_path with
  | Candle_config.Off -> Error Off
  | Candle_config.Disabled { reason } -> Error (Disabled reason)
  | Candle_config.Enabled policy -> Ok policy
;;

let account_of balance keeper =
  { keeper
  ; balance_milli = Candle_balance.balance balance ~keeper
  ; owned_items = Candle_balance.owned balance ~keeper
  }
;;

let account ~now ~base_path ~keeper =
  let* view = Candle_status.current_view ~now ~base_path
    |> Result.map_error (function
      | Candle_status.Off -> Off
      | Candle_status.Disabled reason -> Disabled reason
      | Candle_status.Invalid_time detail -> Invalid_time detail
      | Candle_status.Invalid_ledger error -> Account_invalid error
      | Candle_status.Ledger_unavailable detail -> Ledger_unavailable detail) in
  Ok (account_of view.balance (Keeper_id.Keeper_name.to_string keeper))
;;

let catalog ~base_path =
  let* policy = policy ~base_path in
  Ok
    (List.map
       (fun item -> { item; price = Candle_config.price policy item })
       Keeper_portrait_item.all)
;;

let purchase ~now ~base_path ~keeper ~item =
  let* (_ : Candle_config.policy) = policy ~base_path in
  let keeper = Keeper_id.Keeper_name.to_string keeper in
  Candle_ledger.update ~base_path (fun view ->
    let* current_policy = policy ~base_path in
    let* amount_milli = match Candle_config.price current_policy item with
      | Candle_config.Unpriced -> Error (Unpriced item)
      | Candle_config.Priced amount -> Ok amount in
    let* purchased_at = Candle_stamp.at ~now |> Result.map_error (fun detail -> Invalid_time detail) in
    let* prepared = Candle_status.prepare ~at:purchased_at ~half_life:current_policy.half_life (Candle_ledger.events view)
      |> Result.map_error (fun error -> Account_invalid error) in
    let balance = prepared.balance in
    let* balance =
      Candle_balance.purchase balance ~at:purchased_at ~keeper ~item ~amount_milli
      |> Result.map_error (fun error -> Purchase_refused error)
    in
    let event =
      { Candle_event.at = purchased_at
      ; body = Candle_event.Purchased { keeper; item; amount_milli }
      }
    in
    Ok
      ( prepared.policy_events @ [ event ]
      , { account = account_of balance keeper; item; amount_milli; purchased_at } ))
  |> Result.map_error (function
    | Candle_ledger.Refused error -> error
    | ( Candle_ledger.Read_failed _
      | Candle_ledger.Event_unwritable _
      | Candle_ledger.Write_failed _
      | Candle_ledger.Write_locked _ ) as error ->
      Ledger_unavailable (Candle_ledger.update_error_to_string error_to_string error))
;;
