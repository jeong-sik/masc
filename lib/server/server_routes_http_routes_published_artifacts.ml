open Server_utils
open Server_auth
module Http = Http_server_eio
module Store = Published_artifact_store

let error_response error =
  let status, code, extra = match error with
    | Store.Invalid _ -> `Bad_request, "invalid_artifact_request", []
    | Store.Missing -> `Not_found, "artifact_not_found", []
    | Store.Conflict { expected; actual } ->
      `Conflict, "artifact_revision_conflict", ["expected_revision", `Int expected; "current_revision", `Int actual]
    | Store.Unavailable _ -> `Service_unavailable, "artifact_unavailable", []
    | Store.Commit_uncertain { id; revision; message = _ } ->
      `Service_unavailable, "artifact_commit_uncertain",
      ["id", `String id; "revision", `Int revision;
       "url", `String (Published_artifact.url ~revision id);
       "recovery", `String "Read this artifact before retrying publication."] in
  `Assoc (("error", `String (Store.error_message error)) :: ("code", `String code) :: extra), status

let respond ?(status = `OK) request reqd json =
  Http.Response.json_value ~status
    ~extra_headers:(["cache-control", "private, no-store"] @ cors_headers (get_origin request))
    json reqd

let refuse request reqd error =
  let json, status = error_response error in respond ~status request reqd json

let check_error_response error =
  let module Checks = Published_artifact_check_store in
  let response status code extra =
    `Assoc (("error", `String (Checks.error_message error)) :: ("code", `String code) :: extra), status in
  match error with
  | Checks.Artifact_error error -> error_response error
  | Checks.Invalid _ -> response `Bad_request "invalid_artifact_check" []
  | Conflict current -> response `Conflict "artifact_check_conflict"
        ["current_check", Option.fold ~none:`Null
          ~some:Published_artifact_check.to_json current]
  | Unavailable _ -> response `Service_unavailable "artifact_check_unavailable" []
  | Commit_uncertain check -> response `Service_unavailable "artifact_check_commit_uncertain"
        ["attempted_check", Published_artifact_check.to_json check;
         "recovery", `String "Refresh artifact checks before retrying."]

let refuse_check request reqd error =
  let json, status = check_error_response error in respond ~status request reqd json

let decode_check_request ~config ~body =
  let ( let* ) = Result.bind in
  let* json = match Yojson.Safe.from_string body with
    | json -> Ok json
    | exception Yojson.Json_error _ ->
      Error (check_error_response (Published_artifact_check_store.Invalid "invalid JSON body")) in
  let* json = match Workspace.validate_expected_workspace ~config json with
    | Ok json -> Ok json
    | Error Workspace.Invalid_workspace_precondition ->
      Error (Server_refusal.json ~code:"invalid_workspace_precondition"
        "invalid expected_workspace precondition", `Bad_request)
    | Error Workspace.Workspace_precondition_failed ->
      Error (Server_refusal.json ~code:"workspace_precondition_failed"
        "workspace precondition failed", `Conflict) in
  Result.map_error (fun message ->
    check_error_response (Published_artifact_check_store.Invalid message))
    (Published_artifact_check.request_of_json json)

let authorized handler request reqd =
  with_token_permission_auth ~permission:Masc_domain.CanAdmin handler request reqd

let revision_param request =
  match query_param request "revision" with
  | None -> Ok None
  | Some text ->
    match int_of_string_opt text with
    | Some n when n > 0 -> Ok (Some n)
    | Some _ | None -> Error (Store.Invalid "revision must be a positive integer")

let add_routes router =
  router
  |> Http.Router.get "/api/v1/published-artifacts" (authorized (fun state _actor request reqd ->
    let base_path = (Mcp_server.workspace_config state).base_path in
    match Eio_unix.run_in_systhread (fun () -> Store.list ~base_path) with
    | Error error -> refuse request reqd error
    | Ok listing ->
      respond request reqd (`Assoc
        ["artifacts", `List listing.artifacts;
         "diagnostics", `List (List.map (fun (id, message) ->
           `Assoc ["id", `String id; "error", `String message]) listing.diagnostics)])))
  |> Http.Router.prefix_get "/api/v1/published-artifacts/" (authorized (fun state _actor request reqd ->
    let base_path = (Mcp_server.workspace_config state).base_path in
    match extract_path_param ~prefix:"/api/v1/published-artifacts/" (Http.Request.path request),
          revision_param request with
    | None, _ -> refuse request reqd (Store.Invalid "artifact id required")
    | Some _, Error error -> refuse request reqd error
    | Some id, Ok revision ->
      match Eio_unix.run_in_systhread (fun () -> Store.read ~base_path ~id ~revision) with
      | Error error -> refuse request reqd error
      | Ok (artifact, selected, content) ->
        respond request reqd (`Assoc
          ["artifact", Published_artifact.summary_to_json ~id:artifact.id selected;
           "content", `String content;
           "revisions", `List (List.map Published_artifact.revision_to_json artifact.revisions)])))
  |> Http.Router.post "/api/v1/published-artifacts" (authorized (fun state actor request reqd ->
    let base_path = (Mcp_server.workspace_config state).base_path in
    Http.Request.read_body_async reqd (fun body ->
      let parsed = match Yojson.Safe.from_string body with
        | json -> Published_artifact.request_of_json json
        | exception Yojson.Json_error _ -> Error "invalid JSON body" in
      match parsed with
      | Error message -> refuse request reqd (Store.Invalid message)
      | Ok publication ->
        match Eio_unix.run_in_systhread (fun () -> Store.publish ~base_path ~author:actor publication) with
        | Error error -> refuse request reqd error
        | Ok (artifact, revision) ->
          respond ~status:`Created request reqd
            (Published_artifact.publication_to_json ~id:artifact.id revision))))
  |> Http.Router.get "/api/v1/published-artifact-checks" (authorized (fun state _actor request reqd ->
    let base_path = (Mcp_server.workspace_config state).base_path in
    match Eio_unix.run_in_systhread (fun () -> Published_artifact_check_store.list ~base_path) with
    | Error error -> refuse_check request reqd error
    | Ok listing -> respond request reqd (`Assoc
      ["checks", `List (List.map Published_artifact_check.to_json listing.checks);
       "diagnostics", `List (List.map (fun (file, message) ->
         `Assoc ["file", `String file; "error", `String message]) listing.diagnostics)])))
  |> Http.Router.post "/api/v1/published-artifact-checks" (authorized (fun state actor request reqd ->
    let config = Mcp_server.workspace_config state in
    let base_path = config.base_path in
    Http.Request.read_body_async reqd (fun body ->
      match decode_check_request ~config ~body with
      | Error (json, status) -> respond ~status request reqd json
      | Ok change ->
        match Eio_unix.run_in_systhread (fun () ->
          Published_artifact_check_store.set ~base_path ~actor change) with
        | Error error -> refuse_check request reqd error
        | Ok check -> respond request reqd
          (`Assoc ["check", Published_artifact_check.to_json check]))))
