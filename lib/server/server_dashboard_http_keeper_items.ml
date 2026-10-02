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

let ready_json ~keeper (view : Candle_status.view) =
  let catalog = List.map (fun item ->
    { Candle_shop.item; price=Candle_config.price view.policy item }) Item.all in
  `Assoc
    [ "status", `String "ready"
    ; "keeper", `String keeper
    ; "account_revision", `String (Candle_observe.ready_account_revision
        ~events:view.events ~policy:view.policy ~balance:view.balance ~keeper)
    ; "balance_milli", `String (string_of_int (Candle_balance.balance view.balance ~keeper))
    ; "owned_items", `List (List.map (fun item -> `String (Item.id item))
        (Candle_balance.owned view.balance ~keeper))
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
    let workspace_matches = match Server_utils.query_param request "expected_workspace" with
      | None -> Ok true
      | Some expected when String.trim expected = "" -> Error "expected workspace must not be blank"
      | Some expected ->
        (* Health owns this canonical identity. Capture it from this handler's
           configuration before reading any Keeper or Candle account. *)
        let paths = Server_base_path_diagnostics.detect
          ~effective_base_path:base_path ~effective_masc_root:(Workspace.masc_dir config) () in
        Ok (String.equal expected paths.effective_base_path) in
    (match workspace_matches with
     | Error detail -> respond ~status:`Bad_request (error_json detail)
     | Ok false -> respond ~status:`Conflict (error_json "Server workspace changed; refresh its identity before reading Item accounts")
     | Ok true ->
    match Server_dashboard_http_keeper_portrait.keeper_present config name () with
     | Error detail -> respond ~status:`Service_unavailable (error_json detail)
     | Ok false -> respond ~status:`Not_found (error_json "Keeper not found")
     | Ok true ->
       match Candle_status.observed_view ~now:Time_compat.now ~base_path with
       | Error Candle_status.Off ->
         respond (`Assoc [ "status", `String "off"; "keeper", `String name;
           "account_revision", `Null ])
       | Error ((Candle_status.Disabled raw_reason) as error) ->
         let reason = Candle_status.error_to_string error in
         respond (`Assoc [ "status", `String "disabled"; "keeper", `String name;
           "reason", `String reason;
           "account_revision", `String (Candle_observe.disabled_account_revision raw_reason) ])
       | Error ((Candle_status.Invalid_time _ | Candle_status.Invalid_ledger _
           | Candle_status.Ledger_unavailable _) as error) ->
         respond ~status:`Service_unavailable (error_json (Candle_status.error_to_string error))
       | Ok view -> respond (ready_json ~keeper:(Keeper_id.Keeper_name.to_string keeper) view))
;;
