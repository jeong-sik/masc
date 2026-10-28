open Result.Syntax

type account =
  { keeper : string
  ; balance_milli : int
  ; decayed_milli : Z.t
  ; half_life : Candle_decay.half_life
  ; last_event_at : Candle_time.t option
  ; owned_items : Keeper_portrait_item.t list
  }

type catalog_entry =
  { item : Keeper_portrait_item.t
  ; price : Candle_config.price
  }

let catalog_entry_to_yojson (entry : catalog_entry) =
  `Assoc
    ([ "id", `String (Keeper_portrait_item.id entry.item)
     ; "slot", `String (Keeper_portrait_item.slot_id (Keeper_portrait_item.slot entry.item))
     ]
     @
     match entry.price with
     | Candle_config.Unpriced -> [ "price_status", `String "unpriced" ]
     | Candle_config.Priced amount ->
       [ "price_status", `String "priced"; "price_milli", `String (string_of_int amount) ])

let effective_price_for_balance (policy : Candle_config.policy) balance item =
  let min_active_balance_milli =
    Candle_config.min_active_balance_milli policy.pricing
  in
  let summary =
    Candle_balance.supply_summary ~min_active_balance_milli balance
  in
  Candle_config.effective_price
    policy
    ~total_supply_milli:summary.total_supply_milli
    ~active_keepers:summary.active_keepers
    item
;;

let catalog_for_balance (policy : Candle_config.policy) balance =
  List.map
    (fun item -> { item; price = effective_price_for_balance policy balance item })
    Keeper_portrait_item.all
;;

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
  | Price_changed of
      { item : Keeper_portrait_item.t
      ; expected_milli : int
      ; actual_milli : int
      }
  | Account_invalid of Candle_balance.error
  | Purchase_refused of Candle_balance.error
  | Ledger_unavailable of string
  | Invalid_time of string

let error_to_string = function
  | Off -> "Candle is off"
  | Disabled detail -> "Candle is disabled: " ^ detail
  | Unpriced item -> "No price is configured for " ^ Keeper_portrait_item.id item
  | Price_changed { item; expected_milli; actual_milli } ->
    Printf.sprintf
      "Price of %s is %d milli-Candle, which exceeds expected %d"
      (Keeper_portrait_item.id item)
      actual_milli
      expected_milli
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

let account_of ~fallback_half_life balance keeper =
  let half_life =
    match Candle_balance.half_life balance with
    | Some hl -> hl
    | None -> fallback_half_life
  in
  { keeper
  ; balance_milli = Candle_balance.balance balance ~keeper
  ; decayed_milli = Candle_balance.decayed_milli balance ~keeper
  ; half_life
  ; last_event_at = Candle_balance.last_event_at balance ~keeper
  ; owned_items = Candle_balance.owned balance ~keeper
  }
;;

let status_error = function
  | Candle_status.Off -> Off
  | Candle_status.Disabled reason -> Disabled reason
  | Candle_status.Invalid_time detail -> Invalid_time detail
  | Candle_status.Invalid_ledger error -> Account_invalid error
  | Candle_status.Ledger_unavailable detail -> Ledger_unavailable detail
;;

let account ~now ~base_path ~keeper =
  let* (view : Candle_status.view) =
    Candle_status.current_view ~now ~base_path |> Result.map_error status_error
  in
  Ok
    (account_of
       ~fallback_half_life:view.policy.half_life
       view.balance
       (Keeper_id.Keeper_name.to_string keeper))
;;

let catalog ~now ~base_path =
  let* policy = policy ~base_path in
  match policy.pricing with
  | Candle_config.Fixed ->
    Ok
      (List.map
         (fun item -> { item; price = Candle_config.price policy item })
         Keeper_portrait_item.all)
  | Candle_config.Supply_scaled _ ->
    let* view =
      Candle_status.observed_view ~now ~base_path |> Result.map_error status_error
    in
    Ok (catalog_for_balance view.policy view.balance)
;;

let purchase_with_expected_price ~expected_price_milli ~now ~base_path ~keeper ~item =
  let* (_ : Candle_config.policy) = policy ~base_path in
  let keeper = Keeper_id.Keeper_name.to_string keeper in
  Candle_ledger.update ~base_path (fun view ->
    let* current_policy = policy ~base_path in
    let* (_ : int) = match Candle_config.price current_policy item with
      | Candle_config.Unpriced -> Error (Unpriced item)
      | Candle_config.Priced base -> Ok base in
    let* purchased_at = Candle_stamp.at ~now |> Result.map_error (fun detail -> Invalid_time detail) in
    let* prepared = Candle_status.prepare ~at:purchased_at ~half_life:current_policy.half_life (Candle_ledger.events view)
      |> Result.map_error (fun error -> Account_invalid error) in
    let balance = prepared.balance in
    let* amount_milli =
      match effective_price_for_balance current_policy balance item with
      | Candle_config.Unpriced -> Error (Unpriced item)
      | Candle_config.Priced amount -> Ok amount
    in
    let* () =
      match expected_price_milli with
      | Some expected when amount_milli > expected ->
        Error
          (Price_changed
             { item; expected_milli = expected; actual_milli = amount_milli })
      | Some _ | None -> Ok ()
    in
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
      , { account =
            account_of ~fallback_half_life:current_policy.half_life balance keeper
        ; item
        ; amount_milli
        ; purchased_at
        } ))
  |> Result.map_error (function
    | Candle_ledger.Refused error -> error
    | ( Candle_ledger.Read_failed _
      | Candle_ledger.Event_unwritable _
      | Candle_ledger.Write_failed _
      | Candle_ledger.Write_locked _ ) as error ->
      Ledger_unavailable (Candle_ledger.update_error_to_string error_to_string error))
;;

let purchase ~now ~base_path ~keeper ~item =
  purchase_with_expected_price ~expected_price_milli:None ~now ~base_path ~keeper ~item
;;
