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
