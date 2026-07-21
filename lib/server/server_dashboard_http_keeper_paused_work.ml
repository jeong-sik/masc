module Http = Http_server_eio
module Operator = Keeper_paused_work_operator

let suffix = Server_dashboard_http_keeper_api_types.keeper_suffix_paused_work

let keeper_name req =
  Server_dashboard_http_keeper_api_types.extract_keeper_name_for_suffix
    (Http.Request.path req)
    suffix
;;

let error_json message = `Assoc [ "ok", `Bool false; "error", `String message ]

let handle_get state req reqd =
  let name = keeper_name req in
  if String.equal name ""
  then Http.Response.json_value ~status:`Bad_request (error_json "keeper name is required") reqd
  else
    let config = Mcp_server.workspace_config state in
    match Operator.inventory_json config ~keeper_name:name with
    | Ok json -> Http.Response.json_value ~compress:true ~request:req json reqd
    | Error error ->
      let status =
        match error with
        | Operator.Inventory_meta_missing -> `Not_found
        | Operator.Inventory_meta_read_failed _
        | Operator.Inventory_queue_read_failed _ -> `Service_unavailable
      in
      Http.Response.json_value
        ~status
        ~request:req
        (error_json (Operator.inventory_error_to_string error))
        reqd
;;

let http_status = function
  | `Bad_request -> `Bad_request
  | `Not_found -> `Not_found
  | `Conflict -> `Conflict
  | `Unavailable -> `Service_unavailable
;;

let handle_post state req reqd body =
  let name = keeper_name req in
  if String.equal name ""
  then Http.Response.json_value ~status:`Bad_request (error_json "keeper name is required") reqd
  else
    let parsed =
      try
        Yojson.Safe.from_string body
        |> Operator.request_of_yojson
        |> Result.map_error (fun detail -> Operator.Invalid_request detail)
      with
      | Yojson.Json_error detail ->
        Error (Operator.Invalid_request ("invalid json: " ^ detail))
    in
    match parsed with
    | Error error ->
      Http.Response.json_value
        ~status:(http_status (Operator.error_class error))
        ~request:req
        (error_json (Operator.error_to_string error))
        reqd
    | Ok request ->
      let config = Mcp_server.workspace_config state in
      (match Operator.execute config ~keeper_name:name request with
       | Error error ->
         Log.Dashboard.warn
           "paused-work operator action failed: keeper=%s error=%s"
           name
           (Operator.error_to_string error);
         Http.Response.json_value
           ~status:(http_status (Operator.error_class error))
           ~request:req
           (error_json (Operator.error_to_string error))
           reqd
       | Ok outcome ->
         Log.Dashboard.info
           "paused-work operator action committed: keeper=%s projection_complete=%b"
           name
           (Operator.outcome_projection_complete outcome);
         Server_dashboard_http_keeper_api_lifecycle_post.invalidate_keeper_execution_surfaces
           ~config
           ();
         Http.Response.json_value
           ~status:
             (if Operator.outcome_projection_complete outcome then `OK else `Accepted)
           ~compress:true
           ~request:req
           (Operator.outcome_to_yojson outcome)
           reqd)
;;
