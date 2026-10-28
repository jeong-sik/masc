open Server_utils
open Server_auth
module Http = Http_server_eio
module Store = Published_artifact_store
type response = { status : Httpun.Status.t; json : Yojson.Safe.t }
type read_result = Private | Response of response

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

let respond ?cors ?(status = `OK) request reqd json =
  let cors = match cors with Some headers -> headers | None -> public_read_cors_headers request in
  Http.Response.json_value ~status
    ~extra_headers:(["cache-control", "private, no-store"] @ cors)
    json reqd

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

let decode_check_request ~config ~body =
  let open Result.Syntax in
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

let decode_share_request ~config ~body =
  let open Result.Syntax in
  let* json = match Yojson.Safe.from_string body with
    | json -> Ok json
    | exception Yojson.Json_error _ ->
      Error (error_response (Store.Invalid "invalid JSON body")) in
  let* json = match Workspace.validate_expected_workspace ~config json with
    | Ok json -> Ok json
    | Error Workspace.Invalid_workspace_precondition ->
      Error (Server_refusal.json ~code:"invalid_workspace_precondition"
        "invalid expected_workspace precondition", `Bad_request)
    | Error Workspace.Workspace_precondition_failed ->
      Error (Server_refusal.json ~code:"workspace_precondition_failed"
        "workspace precondition failed", `Conflict) in
  match json with
  | `Assoc fields ->
    let names = List.map fst fields in
    if List.length names <> List.length (List.sort_uniq String.compare names)
       || List.exists (fun name -> name <> "id" && name <> "shared") names
    then Error (error_response (Store.Invalid "expected id and shared fields"))
    else
      (match List.assoc_opt "id" fields, List.assoc_opt "shared" fields with
       | Some (`String id), Some (`Bool shared) when Published_artifact.valid_id id ->
         Ok (id, shared)
       | _ -> Error (error_response (Store.Invalid "id must be a valid artifact id and shared must be a boolean")))
  | _ -> Error (error_response (Store.Invalid "expected a JSON object"))

(* A shared artifact reads without a token and a private one only with the admin
   token. The route is registered [Public_read]; this checks the token when the
   request carries one. *)
let capability_read handler state request reqd =
  let base_path = (Mcp_server.workspace_config state).base_path in
  match authorize_optional_token_bound_permission_request
          ~base_path ~permission:Masc_domain.CanAdmin request with
  | Error err -> respond_auth_error request reqd err
  | Ok actor ->
      match check_agent_rate_limit
              ~quota:(read_request_quota request.Httpun.Request.meth)
              request reqd with
      | Ok () -> handler state actor request reqd
      | Error () -> ()

let revision_param request =
  match query_param request "revision" with
  | None -> Ok None
  | Some text ->
    match int_of_string_opt text with
    | Some n when n > 0 -> Ok (Some n)
    | Some _ | None -> Error (Store.Invalid "revision must be a positive integer")

let response_of_pair (json, status) = { status; json }
let ok json = { status = `OK; json }
let artifact_error error = response_of_pair (error_response error)
let check_error error = response_of_pair (check_error_response error)

let list ~base_path =
  match Eio_unix.run_in_systhread (fun () -> Store.list ~base_path) with
  | Error error -> artifact_error error
  | Ok listing -> ok (`Assoc
      ["artifacts", `List listing.artifacts;
       "diagnostics", `List (List.map (fun (id, message) ->
         `Assoc ["id", `String id; "error", `String message]) listing.diagnostics)])

let read ~base_path ~actor ~request =
  match extract_path_param ~prefix:"/api/v1/published-artifacts/" (Http.Request.path request),
        revision_param request with
  | None, _ -> Response (artifact_error (Store.Invalid "artifact id required"))
  | Some _, Error error -> Response (artifact_error error)
  | Some id, Ok revision ->
    match Eio_unix.run_in_systhread (fun () ->
      let open Result.Syntax in
      let* shared = Store.is_shared ~base_path ~id in
      match actor, shared with
      | None, false -> Ok `Unauthorized_private_artifact
      | Some _, _ | None, true ->
        let* (artifact, selected, content) = Store.read ~base_path ~id ~revision in
        Ok (`Allowed (artifact, selected, content, shared))) with
    | Error error -> Response (artifact_error error)
    | Ok `Unauthorized_private_artifact -> Private
    | Ok (`Allowed (artifact, selected, content, shared)) ->
      Response (ok (`Assoc
        ["artifact", Published_artifact.summary_to_json ~id:artifact.id selected;
         "content", `String content;
         "revisions", `List (List.map Published_artifact.revision_to_json artifact.revisions);
         "shared", `Bool shared]))

let publish ~base_path ~actor ~body =
  let parsed = match Yojson.Safe.from_string body with
    | json -> Published_artifact.request_of_json json
    | exception Yojson.Json_error _ -> Error "invalid JSON body" in
  match parsed with
  | Error message -> artifact_error (Store.Invalid message)
  | Ok publication ->
    match Eio_unix.run_in_systhread (fun () -> Store.publish ~base_path ~author:actor publication) with
    | Error error -> artifact_error error
    | Ok (artifact, revision) ->
      { status = `Created; json = Published_artifact.publication_to_json ~id:artifact.id revision }

let list_checks ~base_path =
  match Eio_unix.run_in_systhread (fun () -> Published_artifact_check_store.list ~base_path) with
  | Error error -> check_error error
  | Ok listing -> ok (`Assoc
      ["checks", `List (List.map Published_artifact_check.to_json listing.checks);
       "diagnostics", `List (List.map (fun (file, message) ->
         `Assoc ["file", `String file; "error", `String message]) listing.diagnostics)])

let set_check ~config ~actor ~body =
  match decode_check_request ~config ~body with
  | Error response -> response_of_pair response
  | Ok change ->
    match Eio_unix.run_in_systhread (fun () ->
      Published_artifact_check_store.set ~base_path:config.base_path ~actor change) with
    | Error error -> check_error error
    | Ok check -> ok (`Assoc ["check", Published_artifact_check.to_json check])

let set_share ~config ~body =
  match decode_share_request ~config ~body with
  | Error response -> response_of_pair response
  | Ok (id, shared) ->
    match Eio_unix.run_in_systhread (fun () -> Store.set_shared ~base_path:config.base_path ~id ~shared) with
    | Error error -> artifact_error error
    | Ok shared -> ok (`Assoc ["id", `String id; "shared", `Bool shared])

let respond_operation ?cors request reqd response =
  respond ?cors ~status:response.status request reqd response.json

let add_routes router =
  router
  |> Server_route.get (Server_route.Token_permission Masc_domain.CanReadState) "/api/v1/published-artifacts" (fun state _actor request reqd ->
    let base_path = (Mcp_server.workspace_config state).base_path in
    respond_operation request reqd (list ~base_path))
  |> Server_route.prefix_get Server_route.Public_read "/api/v1/published-artifacts/" (capability_read (fun state actor request reqd ->
    let base_path = (Mcp_server.workspace_config state).base_path in
    match read ~base_path ~actor ~request with
    | Response response -> respond_operation request reqd response
    | Private ->
      respond_auth_error request reqd
        (Masc_domain.Auth
           (Masc_domain.Auth_error.Unauthorized
              { reason = Missing_token
              ; message = "Authentication required unless external sharing is enabled for this artifact."
              }))))
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanBroadcast) "/api/v1/published-artifacts" (fun state actor request reqd ->
    let base_path = (Mcp_server.workspace_config state).base_path in
    let cors = public_read_cors_headers request in
    Http.Request.read_body_async reqd (fun body ->
      respond_operation ~cors request reqd (publish ~base_path ~actor ~body)))
  |> Server_route.get (Server_route.Token_permission Masc_domain.CanReadState) "/api/v1/published-artifact-checks" (fun state _actor request reqd ->
    let base_path = (Mcp_server.workspace_config state).base_path in
    respond_operation request reqd (list_checks ~base_path))
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/published-artifact-checks" (fun state actor request reqd ->
    let config = Mcp_server.workspace_config state in
    let cors = public_read_cors_headers request in
    Http.Request.read_body_async reqd (fun body ->
      respond_operation ~cors request reqd (set_check ~config ~actor ~body)))
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/published-artifact-shares" (fun state _actor request reqd ->
    let config = Mcp_server.workspace_config state in
    let cors = public_read_cors_headers request in
    Http.Request.read_body_async reqd (fun body ->
      respond_operation ~cors request reqd (set_share ~config ~body)))
