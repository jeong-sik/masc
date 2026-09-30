module Http = Http_server_eio
module Item = Keeper_portrait_item

let prefix = Server_dashboard_http_keeper_api_types.keeper_api_prefix
let permission = Masc_domain.CanReadState

let route path =
  if not (String.starts_with ~prefix path) then None
  else
    let rest =
      String.sub path (String.length prefix) (String.length path - String.length prefix)
    in
    match String.split_on_char '/' rest with
    | [ name; "items" ] when not (String.equal name "") -> Some name
    | _ -> None
;;

let catalog_entry_json (entry : Candle_shop.catalog_entry) =
  let price =
    match entry.price with
    | Candle_config.Unpriced -> [ "price_status", `String "unpriced" ]
    | Candle_config.Priced amount ->
      [ "price_status", `String "priced"; "price_milli", `String (string_of_int amount) ]
  in
  `Assoc
    ([ "id", `String (Item.id entry.item)
     ; "slot", `String (Item.slot_id (Item.slot entry.item))
     ] @ price)
;;

let ready_json (account : Candle_shop.account) catalog =
  `Assoc
    [ "status", `String "ready"
    ; "keeper", `String account.keeper
    ; "balance_milli", `String (string_of_int account.balance_milli)
    ; "owned_items", `List (List.map (fun item -> `String (Item.id item)) account.owned_items)
    ; "catalog", `List (List.map catalog_entry_json catalog)
    ]
;;

let error_json detail = `Assoc [ "error", `String detail ]

let handle_get state request reqd name =
  let config = Mcp_server.workspace_config state in
  let base_path = config.Workspace.base_path in
  let respond ?(status = `OK) json =
    Http.Response.json_value ~request ~status json reqd
  in
  match Keeper_id.Keeper_name.of_string name with
  | Error detail -> respond ~status:`Bad_request (error_json detail)
  | Ok keeper ->
    (match Server_dashboard_http_keeper_portrait.keeper_present config name () with
     | Error detail -> respond ~status:`Service_unavailable (error_json detail)
     | Ok false -> respond ~status:`Not_found (error_json "Keeper not found")
     | Ok true ->
       match Candle_status.configured ~base_path with
       | Candle_config.Off ->
         respond (`Assoc [ "status", `String "off"; "keeper", `String name ])
       | Candle_config.Disabled { reason } ->
         respond (`Assoc
           [ "status", `String "disabled"
           ; "keeper", `String name
           ; "reason", `String reason ])
       | Candle_config.Enabled _ ->
         (match Candle_shop.account ~now:Time_compat.now ~base_path ~keeper with
          | Error error ->
            respond ~status:`Service_unavailable
              (error_json (Candle_shop.error_to_string error))
          | Ok account ->
            match Candle_shop.catalog ~base_path with
            | Ok catalog -> respond (ready_json account catalog)
            | Error error ->
              respond ~status:`Service_unavailable
                (error_json (Candle_shop.error_to_string error))))
;;
