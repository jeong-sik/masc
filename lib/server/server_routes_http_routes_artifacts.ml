(** Tool blob store HTTP surface.

    Lazy-fetch endpoint for the dashboard. Tool outputs externalized by
    [Tool_bridge.maybe_externalize] live in
    [<workspace-base-path>/.masc/tool_blobs/<sha[0..1]>/<sha>]; the dashboard
    UI displays the blob marker preview by default and fetches full
    bytes on demand via:

      GET /api/v1/artifacts/<sha256>

    Response (200): JSON envelope
      { "sha256": ..., "bytes": <int>, "mime": "text/plain",
        "content": "<the bytes>" }

    Errors:
      400 — malformed sha256 (not 64 hex chars)
      404 — sha256 not in store
      503 — stored artifact unreadable *)

open Server_utils
open Server_auth

module Http = Http_server_eio

let is_valid_sha256 value = Result.is_ok (Tool_blob_store.validate_sha256 value)

let artifact_read_permission = Masc_domain.CanAdmin

let blob_response ~base_path ~sha256 =
  let store = Tool_blob_store.create ~base_path in
  match Tool_blob_store.fetch store ~sha256 with
  | Ok None ->
      ( `Assoc
          [
            ("error", `String "not found");
            ("sha256", `String sha256);
          ],
        `Not_found )
  | Ok (Some bytes) ->
      ( `Assoc
          [
            ("sha256", `String sha256);
            ("bytes", `Int (String.length bytes));
            ("mime", `String "text/plain");
            ("content", `String bytes);
          ],
        `OK )
  | Error error ->
      Log.Misc.error
        "tool blob read failed sha256=%s cause=%s"
        sha256
        (Tool_blob_store.fetch_error_to_string error);
      ( `Assoc
          [ ("error", `String "tool blob read failed")
          ; ("sha256", `String sha256)
          ]
      , `Service_unavailable )

let add_routes router =
  router
  |> Http.Router.prefix_get "/api/v1/artifacts/" (fun request reqd ->
       with_token_permission_auth ~permission:artifact_read_permission
         (fun state _agent_name _req reqd ->
           let base_path = (Mcp_server.workspace_config state).base_path in
           let path = Http.Request.path request in
           match extract_path_param ~prefix:"/api/v1/artifacts/" path with
           | None ->
               respond_json_value_with_cors ~status:`Bad_request request reqd
                 (`Assoc [ ("error", `String "sha256 path parameter required") ])
           | Some raw ->
               (match Tool_blob_store.validate_sha256 raw with
                | Error invalid ->
                    respond_json_value_with_cors
                      ~status:`Bad_request
                      request
                      reqd
                      (`Assoc
                         [ ("error", `String "invalid sha256")
                         ; ( "reason",
                             `String
                               (Tool_blob_store.invalid_sha256_to_string invalid)
                           )
                         ])
                | Ok () ->
                    let json, status =
                      blob_response ~base_path ~sha256:raw
                    in
                    respond_json_value_with_cors ~status request reqd json))
         request reqd)
