module Http = Http_server_eio
module Capture = World_configuration_capture
module Bundle = World_configuration_bundle

let error_status = function
  | Capture.Invalid_base_path _ -> `Bad_request
  | Config_root_unavailable _ | Read_failed _ | Invalid_bundle _ -> `Code 422
  | Configuration_lock_failed _ -> `Conflict

let add_routes router =
  router
  |> Server_route.get (Server_route.Token_permission Masc_domain.CanAdmin)
    "/api/v1/world/configuration/export" (fun state _agent _request reqd ->
      let base_path = (Mcp_server.workspace_config state).Workspace.base_path in
      let result = Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
        Capture.capture ~base_path) in
      let status, body = Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ (fun () ->
        match result with
        | Error error ->
          error_status error,
          Yojson.Safe.to_string (`Assoc
            [ "ok", `Bool false; "error", `String (Capture.error_to_string error) ])
        | Ok receipt ->
          `OK, Yojson.Safe.to_string (`Assoc
            [ "ok", `Bool true
            ; "scope", `String "authored_configuration_documents"
            ; "bundle", Bundle.to_yojson receipt.bundle
            ; "lock_warnings", `List
                (List.map Runtime.config_lock_warning_to_yojson receipt.lock_warnings)
            ])) in
      Http.Response.with_scoped_headers
        (("cache-control", "no-store") :: Http.Response.scoped_headers ())
        (fun () ->
          Http.Response.bytes ~status ~content_type:Http.Response.json_content_type body reqd))
