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

type account_observation =
  | Account_off
  | Account_disabled of string
  | Account_ready of account * catalog_entry list

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

let fold view =
  Candle_balance.of_events (Candle_ledger.events view)
  |> Result.map_error (fun error -> Account_invalid error)
;;

let account ~base_path ~keeper =
  let* (_ : Candle_config.policy) = policy ~base_path in
  let* view =
    Candle_ledger.read ~base_path
    |> Result.map_error (fun error ->
      Ledger_unavailable (Candle_ledger.read_error_to_string error))
  in
  let* balance = fold view in
  Ok (account_of balance (Keeper_id.Keeper_name.to_string keeper))
;;

let catalog ~base_path =
  let* policy = policy ~base_path in
  Ok
    (List.map
       (fun item -> { item; price = Candle_config.price policy item })
       Keeper_portrait_item.all)
;;

let account_observation_of_balance ~policy ~balance ~keeper =
  Account_ready
    (account_of balance keeper,
     List.map (fun item -> { item; price = Candle_config.price policy item })
       Keeper_portrait_item.all)
;;

let observe_account ~base_path ~keeper =
  match Candle_status.configured ~base_path with
  | Candle_config.Off -> Ok Account_off
  | Candle_config.Disabled { reason } -> Ok (Account_disabled reason)
  | Candle_config.Enabled policy ->
    let* view = Candle_ledger.read ~base_path
      |> Result.map_error (fun error ->
        Ledger_unavailable (Candle_ledger.read_error_to_string error)) in
    let* balance = fold view in
    Ok (account_observation_of_balance ~policy ~balance
      ~keeper:(Keeper_id.Keeper_name.to_string keeper))
;;

let account_revision = function
  | Account_off -> None
  | Account_disabled reason ->
    Some (Digestif.SHA256.(digest_string ("disabled\000" ^ reason) |> to_hex))
  | Account_ready (account, catalog) ->
    let owned = List.map (fun item -> `String (Keeper_portrait_item.id item)) account.owned_items in
    let catalog = List.map (fun entry ->
      let price = match entry.price with
        | Candle_config.Unpriced -> `Null
        | Candle_config.Priced amount -> `String (string_of_int amount) in
      `List [`String (Keeper_portrait_item.id entry.item); price]) catalog in
    let contents = `List [ `String (string_of_int account.balance_milli); `List owned; `List catalog ] in
    Some (Digestif.SHA256.(digest_string ("ready\000" ^ Yojson.Safe.to_string contents) |> to_hex))
;;

let purchase ~now ~base_path ~keeper ~item =
  let* policy = policy ~base_path in
  let* amount_milli =
    match Candle_config.price policy item with
    | Candle_config.Unpriced -> Error (Unpriced item)
    | Candle_config.Priced amount -> Ok amount
  in
  let* purchased_at =
    Candle_stamp.at ~now |> Result.map_error (fun error -> Invalid_time error)
  in
  let keeper = Keeper_id.Keeper_name.to_string keeper in
  Candle_ledger.update ~base_path (fun view ->
    let* balance = fold view in
    let* balance =
      Candle_balance.purchase balance ~keeper ~item ~amount_milli
      |> Result.map_error (fun error -> Purchase_refused error)
    in
    let event =
      { Candle_event.at = purchased_at
      ; body = Candle_event.Purchased { keeper; item; amount_milli }
      }
    in
    Ok
      ( [ event ]
      , { account = account_of balance keeper; item; amount_milli; purchased_at } ))
  |> Result.map_error (function
    | Candle_ledger.Refused error -> error
    | ( Candle_ledger.Read_failed _
      | Candle_ledger.Event_unwritable _
      | Candle_ledger.Write_failed _
      | Candle_ledger.Write_locked _ ) as error ->
      Ledger_unavailable (Candle_ledger.update_error_to_string error_to_string error))
;;
