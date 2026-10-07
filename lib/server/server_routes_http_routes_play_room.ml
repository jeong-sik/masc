open Server_auth
module Http = Http_server_eio
let path = "/api/v1/play/room"
let response ~viewer = function
  | Ok snapshot -> `OK, Play_room.snapshot_json ~viewer snapshot
  | Error error ->
    let status, code = match error with
      | Play_room.Invalid_request _ -> `Bad_request, "invalid_room_request"
      | Conflict _ -> `Conflict, "room_message_conflict"
      | Unavailable _ -> `Service_unavailable, "room_unavailable" in
    status, Server_refusal.json ~code (Play_room.error_message error)
let respond ~viewer request reqd result =
  let status, json = response ~viewer result in
  respond_json_value_with_cors ~status request reqd json
let before request =
  match Uri.query (Uri.of_string request.Httpun.Request.target) with
  | [] -> Ok None
  | ["before", [value]] -> (match int_of_string_opt value with
      | Some n when n > 0 -> Ok (Some n)
      | None | Some _ -> Error (Play_room.Invalid_request "before must be a positive message id"))
  | _ -> Error (Play_room.Invalid_request "only one before query parameter is accepted")
let read ~base_path request =
  Result.bind (before request) (fun before ->
    Play_room.read ~base_path ~now:(Time_compat.now ()) ~before)
let perform ~base_path ~who body =
  let action =
    try Play_room.parse_action (Yojson.Safe.from_string body)
    with Yojson.Json_error _ -> Error (Play_room.Invalid_request "body must be JSON")
  in
  Result.bind action (fun action ->
    Play_room.perform ~base_path ~who ~speaker:Play_room.Participant
      ~now:(Time_compat.now ()) action)
let add_routes router =
  router
  |> Http.Router.get path (fun request reqd ->
    with_token_permission_auth ~permission:Masc_domain.CanPlayMachine (fun state name request reqd ->
      let config = Mcp_server.workspace_config state in
      respond ~viewer:name request reqd (read ~base_path:config.base_path request)) request reqd)
  |> Http.Router.post path (fun request reqd ->
    with_token_permission_auth ~permission:Masc_domain.CanPlayMachine (fun state name request reqd ->
      let config = Mcp_server.workspace_config state in
      Http.Request.read_body_async reqd (fun body ->
        respond ~viewer:name request reqd
          (perform ~base_path:config.base_path ~who:name body))) request reqd)
