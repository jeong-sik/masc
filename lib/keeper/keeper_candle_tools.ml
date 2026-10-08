module Item = Keeper_portrait_item

let ( let* ) = Result.bind

type operation =
  | Balance
  | Catalog
  | Purchase
  | Equip
  | Gift

(* The one place a misc tool name is read as a Candle operation. Every misc
   operation is named so a new Candle tool, or any new misc tool, has to be
   answered here before the dispatchers that read it compile. *)
let operation_of_misc : Tool_schemas_misc.misc_operation -> operation option = function
  | Tool_schemas_misc.Misc_candle_balance -> Some Balance
  | Tool_schemas_misc.Misc_candle_catalog -> Some Catalog
  | Tool_schemas_misc.Misc_candle_purchase -> Some Purchase
  | Tool_schemas_misc.Misc_candle_equip -> Some Equip
  | Tool_schemas_misc.Misc_candle_gift -> Some Gift
  | Tool_schemas_misc.Misc_lane_declaration_read
  | Tool_schemas_misc.Misc_lane_declaration_save
  | Tool_schemas_misc.Misc_lane_updates
  | Tool_schemas_misc.Misc_lane_attach
  | Tool_schemas_misc.Misc_lane_inspect
  | Tool_schemas_misc.Misc_lane_observe
  | Tool_schemas_misc.Misc_lane_slice
  | Tool_schemas_misc.Misc_lane_detach
  | Tool_schemas_misc.Misc_lane_evidence
  | Tool_schemas_misc.Misc_lane_act
  | Tool_schemas_misc.Misc_lane_action_status
  | Tool_schemas_misc.Misc_ask
  | Tool_schemas_misc.Misc_ask_status
  | Tool_schemas_misc.Misc_ask_withdraw
  | Tool_schemas_misc.Misc_config
  | Tool_schemas_misc.Misc_dashboard
  | Tool_schemas_misc.Misc_gc
  | Tool_schemas_misc.Misc_keeper_waiting_inventory
  | Tool_schemas_misc.Misc_tool_help
  | Tool_schemas_misc.Misc_web_fetch
  | Tool_schemas_misc.Misc_web_search
  | Tool_schemas_misc.Misc_browser_tabs
  | Tool_schemas_misc.Misc_browser_read
  | Tool_schemas_misc.Misc_browser_session
  | Tool_schemas_misc.Misc_browser_goto
  | Tool_schemas_misc.Misc_browser_act
  | Tool_schemas_misc.Misc_browser_interact
  | Tool_schemas_misc.Misc_browser_instruct
  | Tool_schemas_misc.Misc_msx_load
  | Tool_schemas_misc.Misc_msx_eject
  | Tool_schemas_misc.Misc_msx_save
  | Tool_schemas_misc.Misc_msx_restore
  | Tool_schemas_misc.Misc_msx_change_disk
  | Tool_schemas_misc.Misc_msx_screen
  | Tool_schemas_misc.Misc_msx_press
  | Tool_schemas_misc.Misc_msx_step
  | Tool_schemas_misc.Misc_msx_step_until_change
  | Tool_schemas_misc.Misc_msx_peek
  | Tool_schemas_misc.Misc_msx_ram_diff
  | Tool_schemas_misc.Misc_msx_meta
  | Tool_schemas_misc.Misc_msx_checkpoint_info
  | Tool_schemas_misc.Misc_portrait_read
  | Tool_schemas_misc.Misc_dos_load
  | Tool_schemas_misc.Misc_dos_meta
  | Tool_schemas_misc.Misc_dos_eject
  | Tool_schemas_misc.Misc_dos_screen
  | Tool_schemas_misc.Misc_dos_step
  | Tool_schemas_misc.Misc_dos_press
  | Tool_schemas_misc.Misc_dos_click
  | Tool_schemas_misc.Misc_dos_type
  | Tool_schemas_misc.Misc_dos_peek
  | Tool_schemas_misc.Misc_dos_pass
  | Tool_schemas_misc.Misc_dos_save
  | Tool_schemas_misc.Misc_dos_restore ->
    None
;;

type failure =
  | Bad_arguments of string
  | Invalid_keeper of string
  | Shop_failed of Candle_shop.error
  | Equip_failed of Candle_equipment.error
  | Gift_failed of Candle_gift.error

let account_json (account : Candle_shop.account) =
  `Assoc
    [ "keeper", `String account.keeper
    ; "balance_milli", `String (string_of_int account.balance_milli)
    ; ( "owned_items"
      , `List (List.map (fun item -> `String (Item.id item)) account.owned_items) )
    ]
;;

let shop result = Result.map_error (fun error -> Shop_failed error) result
let input result = Result.map_error (fun error -> Bad_arguments error) result

let optional_field ~context key decode fields =
  match List.partition (fun (name, _) -> String.equal name key) fields with
  | [], _ -> Ok (None, fields)
  | [ (_, value) ], rest ->
    (match decode value with
     | Ok parsed -> Ok (Some parsed, rest)
     | Error detail -> Error (context ^ ": " ^ detail))
  | _ :: _ :: _, _ -> Error (Printf.sprintf "%s: duplicate %s" context key)
;;

let optional_string ~context key fields =
  optional_field ~context key Candle_json.as_string fields
;;

let as_non_negative_int = function
  | `Int amount when amount >= 0 -> Ok amount
  | `Int amount -> Error (Printf.sprintf "expected a non-negative integer, got %d" amount)
  | `Intlit text -> Error (Printf.sprintf "expected a non-negative integer, got %s" text)
  | `Null | `Bool _ | `Float _ | `String _ | `List _ | `Assoc _ ->
    Error "expected a non-negative integer"
;;

let optional_int ~context key fields =
  optional_field ~context key as_non_negative_int fields
;;

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
    Ok (`Assoc [ "items", `List (List.map Candle_shop.catalog_entry_to_yojson catalog) ])
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
  | Gift ->
    let* to_name, fields =
      input (Candle_json.field ~context "to" Candle_json.as_non_blank fields)
    in
    let* amount_milli, fields = input (optional_int ~context "amount_milli" fields) in
    let* item_id, fields = input (optional_string ~context "item" fields) in
    let* reason, fields = input (optional_string ~context "reason" fields) in
    let* () = input (Candle_json.finish ~context fields) in
    let* to_keeper =
      Keeper_id.Keeper_name.of_string to_name
      |> Result.map_error (fun detail -> Invalid_keeper detail)
    in
    let* kind =
      match amount_milli, item_id, reason with
      | Some amount_milli, None, Some reason ->
        Ok (Candle_gift.Money { amount_milli; reason })
      | Some _, None, None ->
        Error (Bad_arguments "a money gift needs a reason naming the occasion")
      | None, Some id, None ->
        (match Item.of_id id with
         | Some item -> Ok (Candle_gift.Item item)
         | None -> Error (Bad_arguments (Printf.sprintf "Unknown portrait item %S" id)))
      | None, Some _, Some _ ->
        Error (Bad_arguments "an item gift takes no reason")
      | Some _, Some _, _ ->
        Error (Bad_arguments "give amount_milli or item, never both")
      | None, None, _ ->
        Error (Bad_arguments "a gift needs amount_milli or item")
    in
    let* receipt =
      Candle_gift.gift ~now:Time_compat.now ~base_path ~from_keeper:keeper ~to_keeper ~kind
      |> Result.map_error (fun error -> Gift_failed error)
    in
    let kind_json =
      match receipt.Candle_gift.kind with
      | Candle_gift.Money { amount_milli; reason } ->
        [ "kind", `String "money"
        ; "amount_milli", `String (string_of_int amount_milli)
        ; "reason", `String reason
        ]
      | Candle_gift.Item item ->
        [ "kind", `String "item"; "item", `String (Item.id item) ]
    in
    Ok
      (`Assoc
          ([ "from_keeper", `String receipt.from_keeper
           ; "to_keeper", `String receipt.to_keeper
           ; "from_balance_milli", `String (string_of_int receipt.from_balance_milli)
           ; "to_balance_milli", `String (string_of_int receipt.to_balance_milli)
           ; "gifted_at", Candle_time.to_yojson receipt.gifted_at
           ]
           @ kind_json))
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
          | Candle_balance.Invalid_grant _
          | Candle_balance.Duplicate_grant _
          | Candle_balance.Invalid_gift _
          | Candle_balance.Duplicate_gift _
          | Candle_balance.Unowned_gift _
          | Candle_balance.Balance_overflow _ ) ->
        "invalid_purchase", Tool_result.Runtime_failure
    in
    code, class_, Candle_shop.error_to_string error
  | Gift_failed error ->
    let code, class_ =
      match error with
      | Candle_gift.Off -> "candle_off", Tool_result.Dependency_unavailable
      | Candle_gift.Disabled _ -> "candle_disabled", Tool_result.Dependency_unavailable
      | Candle_gift.Invalid_gift _ -> "invalid_gift", Tool_result.Workflow_rejection
      | Candle_gift.Account_invalid _ -> "account_invalid", Tool_result.Runtime_failure
      | Candle_gift.Ledger_unavailable _ ->
        "ledger_unavailable", Tool_result.Dependency_unavailable
      | Candle_gift.Invalid_time _ -> "invalid_time", Tool_result.Runtime_failure
      | Candle_gift.Gift_refused (Candle_balance.Insufficient_balance _) ->
        "insufficient_balance", Tool_result.Workflow_rejection
      | Candle_gift.Gift_refused (Candle_balance.Duplicate_gift _) ->
        "duplicate_gift", Tool_result.Workflow_rejection
      | Candle_gift.Gift_refused (Candle_balance.Unowned_gift _) ->
        "unowned_gift", Tool_result.Workflow_rejection
      | Candle_gift.Gift_refused (Candle_balance.Already_owned _) ->
        "already_owned", Tool_result.Workflow_rejection
      | Candle_gift.Gift_refused
          ( Candle_balance.Missing_half_life
          | Candle_balance.Clock_reversed _
          | Candle_balance.Invalid_half_life _
          | Candle_balance.Decay_failed _
          | Candle_balance.Unowned_equipment _
          | Candle_balance.Wrong_equipment_slot _
          | Candle_balance.Negative_purchase _
          | Candle_balance.Duplicate_payment _
          | Candle_balance.Invalid_grant _
          | Candle_balance.Duplicate_grant _
          | Candle_balance.Invalid_gift _
          | Candle_balance.Balance_overflow _ ) ->
        "invalid_gift_ledger", Tool_result.Runtime_failure
    in
    code, class_, Candle_gift.error_to_string error
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
