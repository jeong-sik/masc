open Server_utils
open Server_auth
module Http = Http_server_eio
module Store = Artifact_draft_store
module Engine = Artifact_document_engine
open Result.Syntax

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
let respond ?cors ?(status = `OK) request reqd json =
  let cors = match cors with Some headers -> headers | None -> public_read_cors_headers request in
  Http.Response.json_value ~status
    ~extra_headers:(["cache-control", "private, no-store"] @ cors) json reqd
let refuse request reqd error = let json, status = error_response error in respond ~status request reqd json
let checkpoint_error_response error =
  let conflict code extra =
    `Assoc (["error", `String (Store.checkpoint_error_message error); "code", `String code] @ extra), `Conflict in
  match error with
  | Store.Draft_error error -> error_response error
  | Sequence_conflict { expected; actual } ->
    conflict "artifact_draft_sequence_conflict" ["expected_sequence", `Int expected; "current_sequence", `Int actual]
  | Draft_snapshot_changed -> conflict "artifact_draft_snapshot_changed" []
  | Published_content_mismatch -> conflict "artifact_draft_published_content_mismatch" []
  | Published_base_mismatch -> conflict "artifact_draft_published_base_mismatch" []
  | Published_format_mismatch -> conflict "artifact_draft_published_format_mismatch" []

let decode_request ~config ~body =
  let open Result.Syntax in
  let* json = match Yojson.Safe.from_string body with
    | json -> Ok json
    | exception Yojson.Json_error _ -> Error (error_response (Store.Invalid "invalid shared draft JSON")) in
  let* json = Server_routes_http_routes_published_artifacts.validate_body_workspace ~config json in
  Artifact_draft.command_of_json json
  |> Result.map_error (fun message -> error_response (Store.Invalid message))

let parse_checkpoint json =
  let* fields = match json with
    | `Assoc fields when List.length fields = 3 &&
        List.sort String.compare (List.map fst fields) = ["expected_sequence"; "revision"; "target"] -> Ok fields
    | _ -> Error "expected target, expected_sequence and revision fields" in
  let* target = Artifact_draft.target_of_json (List.assoc "target" fields) in
  let integer ~minimum name = match List.assoc name fields with
    | `Int value when value >= minimum && Int64.of_int value <= 9_007_199_254_740_991L -> Ok value
    | _ -> Error (name ^ " must be a safe integer") in
  let* expected_sequence = integer ~minimum:0 "expected_sequence" in
  let* revision = integer ~minimum:1 "revision" in
  Ok (target, expected_sequence, revision)

let read ~base_path ~artifact_id =
  match Store.read ~base_path ~artifact_id () with
  | Error error -> error_response error
  | Ok view -> Store.view_to_json view, `OK

let execute ~config ~actor ~body =
  match decode_request ~config ~body with
  | Error response -> response
  | Ok command ->
    match Store.execute ~base_path:config.base_path ~actor command with
    | Error error -> error_response error
    | Ok view -> Store.view_to_json view, `OK

let checkpoint ~config ~actor ~body =
  let parsed =
    let* json = match Yojson.Safe.from_string body with
      | json -> Ok json
      | exception Yojson.Json_error _ -> Error (error_response (Store.Invalid "invalid shared draft checkpoint JSON")) in
    let* json = Server_routes_http_routes_published_artifacts.validate_body_workspace ~config json in
    parse_checkpoint json |> Result.map_error (fun message -> error_response (Store.Invalid message)) in
  match parsed with
  | Error response -> response
  | Ok (target, expected_sequence, revision) ->
    match Store.checkpoint ~base_path:config.base_path ~actor ~target ~expected_sequence ~revision () with
    | Error error -> checkpoint_error_response error
    | Ok outcome ->
      let kind, view = match outcome with
        | Store.Checkpointed view -> "checkpointed", view
        | Already_current view -> "already_current", view in
      `Assoc ["checkpoint", `String kind; "document", Store.view_to_json view], `OK

let respond_result ?cors request reqd (json, status) = respond ?cors ~status request reqd json
let add_routes router = router
  |> Server_route.prefix_get (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/artifact-drafts/" (fun state _actor request reqd ->
    let base_path = (Mcp_server.workspace_config state).base_path in
    match extract_path_param ~prefix:"/api/v1/artifact-drafts/" (Http.Request.path request) with
    | None -> refuse request reqd (Store.Invalid "artifact id required")
    | Some artifact_id -> respond_result request reqd (read ~base_path ~artifact_id))
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/artifact-drafts" (fun state actor request reqd ->
    let config = Mcp_server.workspace_config state in
    let cors = public_read_cors_headers request in
    Http.Request.read_body_async reqd (fun body ->
      respond_result ~cors request reqd (execute ~config ~actor ~body)))
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/artifact-draft-checkpoints" (fun state actor request reqd ->
    let config = Mcp_server.workspace_config state in
    let cors = public_read_cors_headers request in
    Http.Request.read_body_async reqd (fun body ->
      respond_result ~cors request reqd (checkpoint ~config ~actor ~body)))
