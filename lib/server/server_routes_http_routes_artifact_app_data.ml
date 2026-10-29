open Server_utils
open Server_auth
module Http = Http_server_eio
module Data = Artifact_app_data
module Store = Artifact_app_data_store
let error_response error =
  let response status code extra =
    `Assoc (["error", `String (Store.error_message error); "code", `String code] @ extra), status in
  match error with
  | Store.Artifact_error error -> Server_routes_http_routes_published_artifacts.error_response error
  | Invalid _ -> response `Bad_request "invalid_artifact_app_data" []
  | Conflict current -> response `Conflict "artifact_app_data_conflict" ["current", Data.to_json current]
  | Request_collision -> response `Conflict "artifact_app_data_request_collision" []
  | Unavailable _ -> response `Service_unavailable "artifact_app_data_unavailable" []
  | Commit_uncertain attempted -> response `Service_unavailable "artifact_app_data_commit_uncertain"
      ["attempted", Data.to_json attempted; "recovery", `String "Read application inputs before retrying."]
let respond ?(status = `OK) request reqd json =
  Http.Response.json_value ~status
    ~extra_headers:(["cache-control", "private, no-store"] @ cors_headers (get_origin request)) json reqd
let refuse request reqd error = let json, status = error_response error in respond ~status request reqd json
let decode_request ~config body =
  let open Result.Syntax in
  let* json = match Yojson.Safe.from_string body with
    | json -> Ok json
    | exception Yojson.Json_error _ -> Error (error_response (Store.Invalid "invalid application input JSON")) in
  let* json = match Workspace.validate_expected_workspace ~config json with
    | Ok json -> Ok json
    | Error Workspace.Invalid_workspace_precondition ->
      Error (Server_refusal.json ~code:"invalid_workspace_precondition" "invalid expected_workspace precondition", `Bad_request)
    | Error Workspace.Workspace_precondition_failed ->
      Error (Server_refusal.json ~code:"workspace_precondition_failed" "workspace precondition failed", `Conflict) in
  Data.request_of_json json |> Result.map_error (fun message -> error_response (Store.Invalid message))
let add_routes router = router
  |> Server_route.prefix_get (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/artifact-app-data/" (fun state actor request reqd ->
    let base_path = (Mcp_server.workspace_config state).base_path in
    match extract_path_param ~prefix:"/api/v1/artifact-app-data/" (Http.Request.path request), query_param request "revision" with
    | Some artifact_id, Some revision ->
      (match int_of_string_opt revision with
       | Some revision ->
         (match Eio_unix.run_in_systhread (fun () -> Store.read ~base_path ~actor { Data.artifact_id; revision }) with
          | Ok current -> respond request reqd (Data.to_json current) | Error error -> refuse request reqd error)
       | None -> refuse request reqd (Store.Invalid "revision must be a positive integer"))
    | _ -> refuse request reqd (Store.Invalid "artifact id and revision required"))
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/artifact-app-data" (fun state actor request reqd ->
    let config = Mcp_server.workspace_config state in
    Http.Request.read_body_async reqd (fun body ->
      match decode_request ~config body with
      | Error (json, status) -> respond ~status request reqd json
      | Ok change ->
        match Eio_unix.run_in_systhread (fun () -> Store.set ~base_path:config.base_path ~actor change) with
        | Ok current -> respond request reqd (Data.to_json current)
        | Error error -> refuse request reqd error))
