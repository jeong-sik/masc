module Item = Keeper_portrait_item

let ( let* ) = Result.bind

type operation =
  | Balance
  | Catalog
  | Purchase
  | Equip

type failure =
  | Bad_arguments of string
  | Invalid_keeper of string
  | Shop_failed of Candle_shop.error
  | Equip_failed of Candle_equipment.error

let account_json (account : Candle_shop.account) =
  `Assoc
    [ "keeper", `String account.keeper
    ; "balance_milli", `String (string_of_int account.balance_milli)
    ; ( "owned_items"
      , `List (List.map (fun item -> `String (Item.id item)) account.owned_items) )
    ]
;;

let entry_json (entry : Candle_shop.catalog_entry) =
  `Assoc
    ([ "id", `String (Item.id entry.item)
     ; "slot", `String (Item.slot_id (Item.slot entry.item))
     ]
     @
     match entry.price with
     | Candle_config.Unpriced -> [ "price_status", `String "unpriced" ]
     | Candle_config.Priced amount ->
       [ "price_status", `String "priced"; "price_milli", `String (string_of_int amount) ])
;;

let shop result = Result.map_error (fun error -> Shop_failed error) result
let input result = Result.map_error (fun error -> Bad_arguments error) result

let run ~operation ~base_path ~keeper_name ~args =
  let* keeper =
    Keeper_id.Keeper_name.of_string keeper_name
    |> Result.map_error (fun detail -> Invalid_keeper detail)
  in
  let context = "Candle tool" in
  let* fields = input (Candle_json.object_fields ~context args) in
  match operation with
  | Balance ->
    let* () = input (Candle_json.finish ~context fields) in
    let* account = shop (Candle_shop.account ~now:Time_compat.now ~base_path ~keeper) in
    Ok (account_json account)
  | Catalog ->
    let* () = input (Candle_json.finish ~context fields) in
    let* catalog = shop (Candle_shop.catalog ~base_path) in
    Ok (`Assoc [ "items", `List (List.map entry_json catalog) ])
  | Equip ->
    let* slot_id, fields = input (Candle_json.field ~context "slot" Candle_json.as_string fields) in
    let* id, fields = input (Candle_json.field ~context "item" Candle_json.as_string fields) in
    let* () = input (Candle_json.finish ~context fields) in
    let* slot = match Item.slot_of_id slot_id with
      | Some slot -> Ok slot | None -> Error (Bad_arguments "Unknown portrait slot") in
    let* choice = match id with
      | "default" -> Ok Candle_event.Default
      | id -> (match Item.of_id id with
        | Some item -> Ok (Candle_event.Item item)
        | None -> Error (Bad_arguments ("Unknown portrait item " ^ id))) in
    let* receipt = Candle_equipment.equip ~now:Time_compat.now ~base_path ~keeper ~slot ~choice
      |> Result.map_error (fun error -> Equip_failed error) in
    Ok (`Assoc ["keeper", `String keeper_name; "changed", `Bool receipt.changed;
      "equipment", Keeper_portrait_equipment.to_json receipt.equipment])
  | Purchase ->
    let* id, fields =
      input (Candle_json.field ~context "item" Candle_json.as_string fields)
    in
    let* () = input (Candle_json.finish ~context fields) in
    let* item =
      match Item.of_id id with
      | Some item -> Ok item
      | None -> Error (Bad_arguments (Printf.sprintf "Unknown portrait item %S" id))
    in
    let* receipt =
      shop (Candle_shop.purchase ~now:Time_compat.now ~base_path ~keeper ~item)
    in
    Ok
      (`Assoc
          [ "account", account_json receipt.account
          ; "item", `String (Item.id receipt.item)
          ; "amount_milli", `String (string_of_int receipt.amount_milli)
          ; "purchased_at", Candle_time.to_yojson receipt.purchased_at
          ])
;;

let error_info = function
  | Bad_arguments detail -> "invalid_arguments", Tool_result.Workflow_rejection, detail
  | Invalid_keeper detail -> "invalid_keeper", Tool_result.Policy_rejection, detail
  | Equip_failed error ->
    let code, class_ = match error with
      | Candle_equipment.Unavailable _ -> "equipment_unavailable", Tool_result.Dependency_unavailable
      | Candle_equipment.Invalid_ledger _ -> "account_invalid", Tool_result.Runtime_failure
      | Candle_equipment.Refused _ -> "equipment_refused", Tool_result.Workflow_rejection in
    code, class_, Candle_equipment.error_to_string error
  | Shop_failed error ->
    let code, class_ =
      match error with
      | Candle_shop.Off -> "candle_off", Tool_result.Dependency_unavailable
      | Candle_shop.Disabled _ -> "candle_disabled", Tool_result.Dependency_unavailable
      | Candle_shop.Unpriced _ -> "unpriced_item", Tool_result.Workflow_rejection
      | Candle_shop.Account_invalid _ -> "account_invalid", Tool_result.Runtime_failure
      | Candle_shop.Ledger_unavailable _ ->
        "ledger_unavailable", Tool_result.Dependency_unavailable
      | Candle_shop.Invalid_time _ -> "invalid_time", Tool_result.Runtime_failure
      | Candle_shop.Purchase_refused (Candle_balance.Already_owned _) ->
        "already_owned", Tool_result.Workflow_rejection
      | Candle_shop.Purchase_refused (Candle_balance.Insufficient_balance _) ->
        "insufficient_balance", Tool_result.Workflow_rejection
      | Candle_shop.Purchase_refused
          ( Candle_balance.Missing_half_life
          | Candle_balance.Clock_reversed _
          | Candle_balance.Invalid_half_life _
          | Candle_balance.Decay_failed _
          | Candle_balance.Unowned_equipment _
          | Candle_balance.Wrong_equipment_slot _
          | Candle_balance.Negative_purchase _
          | Candle_balance.Duplicate_payment _
          | Candle_balance.Balance_overflow _ ) ->
        "invalid_purchase", Tool_result.Runtime_failure
    in
    code, class_, Candle_shop.error_to_string error
;;

let handle ~operation ~base_path ~keeper_name ~tool_name ~start_time ~args =
  match run ~operation ~base_path ~keeper_name ~args with
  | Ok data -> Tool_result.make_ok ~tool_name ~start_time ~data ()
  | Error error ->
    let code, class_, detail = error_info error in
    Tool_result.make_err
      ~tool_name
      ~start_time
      ~class_
      ~data:(`Assoc [ "error_code", `String code; "error", `String detail ])
      detail
;;
