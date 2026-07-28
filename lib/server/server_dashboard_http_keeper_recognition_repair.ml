module Http = Http_server_eio
module Operator = Keeper_librarian_recognition_operator

let suffix =
  Server_dashboard_http_keeper_api_types.keeper_suffix_recognition_repair
;;

let error_json message = `Assoc [ "ok", `Bool false; "error", `String message ]

let http_status = function
  | `Bad_request -> `Bad_request
  | `Not_found -> `Not_found
  | `Conflict -> `Conflict
  | `Unavailable -> `Service_unavailable
;;

let handle_post state req reqd body =
  let keeper_name =
    Server_dashboard_http_keeper_api_types.extract_keeper_name_for_suffix
      (Http.Request.path req)
      suffix
  in
  if String.equal keeper_name ""
  then
    Http.Response.json_value
      ~status:`Bad_request
      (error_json "keeper name is required")
      reqd
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
        (Operator.error_to_yojson error)
        reqd
    | Ok request ->
      let config = Mcp_server.workspace_config state in
      (match Operator.execute config ~keeper_name request with
       | Error error ->
         Log.Dashboard.warn
           "recognition publication repair failed: keeper=%s error=%s"
           keeper_name
           (Operator.error_to_string error);
         Http.Response.json_value
           ~status:(http_status (Operator.error_class error))
           ~request:req
           (Operator.error_to_yojson error)
           reqd
       | Ok outcome ->
         Log.Dashboard.info
           "recognition publication repair committed: keeper=%s"
           keeper_name;
         Http.Response.json_value
           ~status:`OK
           ~compress:true
           ~request:req
           (Operator.outcome_to_yojson outcome)
           reqd)
;;
