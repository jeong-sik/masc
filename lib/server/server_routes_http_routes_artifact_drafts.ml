open Server_utils
open Server_auth
module Http = Http_server_eio
module Store = Artifact_draft_store
module Engine = Artifact_document_engine

let error_response error =
  let response status code extra =
    `Assoc (["error", `String (Store.error_message error); "code", `String code] @ extra), status in
  match error with
  | Store.Artifact_error error -> Server_routes_http_routes_published_artifacts.error_response error
  | Invalid _ -> response `Bad_request "invalid_artifact_draft" []
  | Missing -> response `Not_found "artifact_draft_not_found" []
  | Generation_conflict target -> response `Conflict "artifact_draft_generation_conflict" ["current_target", Artifact_draft.target_to_json target]
  | Discussion_conflict _ -> response `Conflict "artifact_discussion_conflict" []
  | Transform_error { kind = Engine.Invalid_request; _ } -> response `Bad_request "invalid_artifact_draft" []
  | Transform_error { kind = Invalid_document; _ } -> response `Bad_request "invalid_artifact_draft_document" []
  | Transform_error { kind = Invalid_selection; _ } -> response `Bad_request "invalid_artifact_draft_selection" []
  | Transform_error { kind = Changed_selection; _ } -> response `Conflict "artifact_draft_selection_changed" []
  | Transform_error { kind = Unavailable; _ } | Unavailable _ -> response `Service_unavailable "artifact_draft_unavailable" []
  | Commit_uncertain draft -> response `Service_unavailable "artifact_draft_commit_uncertain"
      ["target", Artifact_draft.target_to_json draft.target; "attempted_sequence", `Int draft.sequence;
       "recovery", `String "Read the shared draft before retrying the edit."]
let respond ?(status = `OK) request reqd json =
  Http.Response.json_value ~status
    ~extra_headers:(["cache-control", "private, no-store"] @ cors_headers (get_origin request)) json reqd
let refuse request reqd error = let json, status = error_response error in respond ~status request reqd json
let decode_request ~config ~body =
  let open Result.Syntax in
  let* json = match Yojson.Safe.from_string body with
    | json -> Ok json
    | exception Yojson.Json_error _ -> Error (error_response (Store.Invalid "invalid shared draft JSON")) in
  let* json = Server_routes_http_routes_published_artifacts.validate_body_workspace ~config json in
  Artifact_draft.command_of_json json
  |> Result.map_error (fun message -> error_response (Store.Invalid message))
let add_routes router = router
  |> Server_route.prefix_get (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/artifact-drafts/" (fun state _actor request reqd ->
    let base_path = (Mcp_server.workspace_config state).base_path in
    match extract_path_param ~prefix:"/api/v1/artifact-drafts/" (Http.Request.path request) with
    | None -> refuse request reqd (Store.Invalid "artifact id required")
    | Some artifact_id ->
      match Store.read ~base_path ~artifact_id () with
      | Error error -> refuse request reqd error
      | Ok view -> respond request reqd (Store.view_to_json view))
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/artifact-drafts" (fun state actor request reqd ->
    let config = Mcp_server.workspace_config state in
    let base_path = config.base_path in
    Http.Request.read_body_async reqd (fun body ->
      match decode_request ~config ~body with
      | Error (json, status) -> respond ~status request reqd json
      | Ok command ->
        match Store.execute ~base_path ~actor command with
        | Error error -> refuse request reqd error
        | Ok view -> respond request reqd (Store.view_to_json view)))
