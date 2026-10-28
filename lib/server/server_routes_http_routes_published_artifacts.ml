open Server_utils
open Server_auth
module Http = Http_server_eio
module Store = Published_artifact_store
module Share = Published_artifact_share

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

let share_error_response error =
  let status, code, extra = match error with
    | Store.Share_invalid _ -> `Bad_request, "invalid_artifact_share", []
    | Store.Share_missing -> `Not_found, "artifact_not_found", []
    | Store.Share_operation_reused -> `Conflict, "artifact_share_operation_reused", []
    | Store.Share_unavailable _ -> `Service_unavailable, "artifact_share_unavailable", []
    | Store.Share_commit_uncertain receipt ->
      `Service_unavailable, "artifact_share_commit_uncertain",
      ["attempted_receipt", Share.receipt_to_json receipt;
       "recovery", `String "Retry the identical operation for its settled result."] in
  `Assoc (("error", `String (Store.share_error_message error)) :: ("code", `String code) :: extra), status

let refuse_share request reqd error =
  let json, status = share_error_response error in respond ~status request reqd json

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
  let* () = match json with
    | `Assoc fields when List.length (List.filter (fun (name, _) -> String.equal name "expected_workspace") fields) = 1 -> Ok ()
    | _ -> Error (Server_refusal.json ~code:"invalid_workspace_precondition"
        "expected_workspace is required for a share change", `Bad_request) in
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
    if List.sort String.compare (List.map fst fields) <>
       ["expected_artifact_revision"; "expected_artifact_sha256"; "expected_version"; "id"; "operation_id"; "shared"]
    then Error (error_response (Store.Invalid "expected artifact identity, publication and share version, and operation id"))
    else
      (match List.assoc "id" fields, List.assoc "shared" fields,
             List.assoc "operation_id" fields, List.assoc "expected_version" fields,
             List.assoc "expected_artifact_revision" fields, List.assoc "expected_artifact_sha256" fields with
       | `String id, `Bool requested, `String operation_id, `Int expected_version,
         `Int expected_artifact_revision, `String expected_artifact_sha256
         when Published_artifact.valid_id id && Share.valid_operation_id operation_id && Share.valid_version expected_version
           && Share.valid_version expected_artifact_revision && expected_artifact_revision > 0
           && Share.valid_sha256 expected_artifact_sha256 ->
         Ok (id, { Share.operation_id; expected_version; requested; expected_artifact_revision; expected_artifact_sha256 })
       | _ -> Error (error_response (Store.Invalid "invalid artifact share operation")))
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

let add_routes router =
  router
  |> Server_route.get (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/published-artifacts" (fun state _actor request reqd ->
    let base_path = (Mcp_server.workspace_config state).base_path in
    match Eio_unix.run_in_systhread (fun () -> Store.list ~base_path) with
    | Error error -> refuse request reqd error
    | Ok listing ->
      respond request reqd (`Assoc
        ["artifacts", `List listing.artifacts;
         "diagnostics", `List (List.map (fun (id, message) ->
           `Assoc ["id", `String id; "error", `String message]) listing.diagnostics)]))
  |> Server_route.prefix_get Server_route.Public_read "/api/v1/published-artifacts/" (capability_read (fun state actor request reqd ->
    let base_path = (Mcp_server.workspace_config state).base_path in
    match extract_path_param ~prefix:"/api/v1/published-artifacts/" (Http.Request.path request),
          revision_param request with
    | None, _ -> refuse request reqd (Store.Invalid "artifact id required")
    | Some _, Error error -> refuse request reqd error
    | Some id, Ok revision ->
      match Eio_unix.run_in_systhread (fun () ->
        let open Result.Syntax in
        let* snapshot = Store.read_share ~base_path ~id |> Result.map_error (fun error -> `Share error) in
        match actor, snapshot.Share.shared with
        | None, false -> Ok `Unauthorized_private_artifact
        | Some _, _ | None, true ->
          let* (artifact, selected, content) = Store.read ~base_path ~id ~revision
            |> Result.map_error (fun error -> `Artifact error) in
          Ok (`Allowed (artifact, selected, content, snapshot))) with
      | Error (`Share error) -> refuse_share request reqd error
      | Error (`Artifact error) -> refuse request reqd error
      | Ok `Unauthorized_private_artifact ->
        respond_auth_error request reqd
          (Masc_domain.Auth
             (Masc_domain.Auth_error.Unauthorized
                { reason = Missing_token
                ; message = "Authentication required unless external sharing is enabled for this artifact."
                }))
      | Ok (`Allowed (artifact, selected, content, snapshot)) ->
        respond request reqd (`Assoc
          ["artifact", Published_artifact.summary_to_json ~id:artifact.id selected;
           "content", `String content;
           "revisions", `List (List.map Published_artifact.revision_to_json artifact.revisions);
           "shared", `Bool snapshot.shared; "share_version", `Int snapshot.version])))
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/published-artifacts" (fun state actor request reqd ->
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
            (Published_artifact.publication_to_json ~id:artifact.id revision)))
  |> Server_route.get (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/published-artifact-checks" (fun state _actor request reqd ->
    let base_path = (Mcp_server.workspace_config state).base_path in
    match Eio_unix.run_in_systhread (fun () -> Published_artifact_check_store.list ~base_path) with
    | Error error -> refuse_check request reqd error
    | Ok listing -> respond request reqd (`Assoc
      ["checks", `List (List.map Published_artifact_check.to_json listing.checks);
       "diagnostics", `List (List.map (fun (file, message) ->
         `Assoc ["file", `String file; "error", `String message]) listing.diagnostics)]))
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/published-artifact-checks" (fun state actor request reqd ->
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
          (`Assoc ["check", Published_artifact_check.to_json check])))
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/published-artifact-shares" (fun state _actor request reqd ->
    let config = Mcp_server.workspace_config state in
    let base_path = config.base_path in
    Http.Request.read_body_async reqd (fun body ->
      match decode_share_request ~config ~body with
      | Error (json, status) -> respond ~status request reqd json
      | Ok (id, change) ->
        match Eio_unix.run_in_systhread (fun () ->
          let open Result.Syntax in
          let* receipt = Store.change_share ~base_path ~id change in
          let* current = Store.read_share ~base_path ~id in
          Ok (receipt, current)) with
        | Error error -> refuse_share request reqd error
        | Ok (receipt, current) ->
          let status = match receipt.Share.outcome with Share.Applied _ -> `OK | Share.Conflict _ -> `Conflict in
          respond ~status request reqd (`Assoc ["id", `String id;
            "receipt", Share.receipt_to_json receipt; "current", Share.snapshot_to_json current])))
