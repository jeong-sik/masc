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
      413 — artifact exceeds the 32 MiB whole-response limit
      503 — stored artifact unreadable

    Uploads arrive as raw bytes (board file sharing; the TUI compose flow
    posts attachment bodies here and keeps the returned content address):

      POST /api/v1/artifacts

    The request body is the stored bytes. The store keeps bytes under their
    digest and nothing else, so the request's [Content-Type] is not read: a
    board post says what a file is with its attachment kind.

    Response (201): JSON envelope
      { "sha256": ..., "bytes": <int> }

    Errors:
      400 — empty body, or a body shorter than its Content-Length
      401/403 — missing or under-privileged credential
      413 — body above the 32 MiB artifact limit
      500 — durable write failed

    The upload reads its body against the artifact limit, not the general
    request cap ([MASC_MAX_BODY_BYTES]): what may be stored is what the
    download routes can serve, whatever the cap for other requests is.

    The JSON routes ([GET /api/v1/artifacts/<sha256>] and this upload) are
    HTTP/1 only: the H2 gateway serves only the raw-bytes
    [GET /api/v1/artifact-bytes/<sha256>], so the upload has no H2
    registration either. *)

open Server_utils
open Server_auth

module Http = Http_server_eio

let is_valid_sha256 value = Result.is_ok (Tool_blob_store.validate_sha256 value)

let artifact_read_permission = Masc_domain.CanAdmin

(* Writing into the store is held to the same bar as reading exact bytes out
   of it. A name of its own so the route does not read as a read. *)
let artifact_upload_permission = Masc_domain.CanAdmin

(* Whole responses are materialised by both HTTP backends. Bound their
   largest single allocation before serving any bytes. *)
let maximum_artifact_response_bytes = Tool_blob_store.max_served_bytes

let artifact_bytes ~base_path ~sha256 =
  Eio_unix.run_in_systhread (fun () ->
    Tool_blob_store.fetch_bounded
      (Tool_blob_store.create ~base_path)
      ~sha256
      ~max_bytes:maximum_artifact_response_bytes)
;;

let too_large_response actual maximum =
  `Assoc
    [ "error", `String "artifact too large for HTTP download"
    ; "bytes", `Int actual
    ; "maximum_bytes", `Int maximum
    ]
;;

(* [put_durable] takes a media type for the reference it returns; the store
   itself persists none. This is the type every stored blob is served as. *)
let stored_media_type = "application/octet-stream"

type upload_refusal =
  | Empty_upload
  | Truncated_upload of { declared : int; received : int }
  | Upload_too_large of { maximum : int }
  | Upload_store_failed

let upload_refusal_response = function
  | Empty_upload -> `Assoc [ "error", `String "empty upload" ], `Bad_request
  | Truncated_upload { declared; received } ->
    ( `Assoc
        [ "error", `String "upload ended before its Content-Length"
        ; "declared_bytes", `Int declared
        ; "received_bytes", `Int received
        ]
    , `Bad_request )
  | Upload_too_large { maximum } ->
    ( `Assoc
        [ "error", `String "upload too large for the artifact store"
        ; "maximum_bytes", `Int maximum
        ]
    , `Payload_too_large )
  | Upload_store_failed ->
    `Assoc [ "error", `String "artifact upload failed" ], `Internal_server_error
;;

(* [declared] is the request's Content-Length when it carried one. The body
   reader hands over whatever arrived before the connection ended, so a
   transfer cut short would otherwise be stored as a file of its own. *)
let store_upload ~base_path ~declared ~bytes =
  let received = String.length bytes in
  match declared with
  | Some declared when declared <> received ->
    Error (Truncated_upload { declared; received })
  | Some _ | None ->
    if received = 0
    then Error Empty_upload
    else (
      match
        Eio_unix.run_in_systhread (fun () ->
          Tool_blob_store.put_durable
            (Tool_blob_store.create ~base_path)
            ~bytes
            ~mime:stored_media_type)
      with
      | reference -> Ok reference
      | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
      | exception Sys_error message ->
        Log.Misc.error "artifact upload store failed: %s" message;
        Error Upload_store_failed)
;;

let blob_response ~base_path ~sha256 =
  let store = Tool_blob_store.create ~base_path in
  match
    Tool_blob_store.fetch_bounded
      store ~sha256 ~max_bytes:maximum_artifact_response_bytes
  with
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
  | Error (Tool_blob_store.Too_large { actual; maximum; _ }) ->
      too_large_response actual maximum, `Payload_too_large
  | Error
      ((Tool_blob_store.Invalid_sha256 _
       | Tool_blob_store.Owned_read_failed _
       | Tool_blob_store.Invalid_max_bytes _
       | Tool_blob_store.Integrity_mismatch _) as error) ->
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
  |> Server_route.prefix_get (Server_route.Token_permission artifact_read_permission) "/api/v1/artifacts/" (fun state _agent_name request reqd ->
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
                      Eio_unix.run_in_systhread (fun () ->
                        blob_response ~base_path ~sha256:raw)
                    in
                    respond_json_value_with_cors ~status request reqd json))
  |> Server_route.prefix_get (Server_route.Token_permission artifact_read_permission) "/api/v1/artifact-bytes/" (fun state _agent_name request reqd ->
           let base_path = (Mcp_server.workspace_config state).base_path in
           let path = Http.Request.path request in
           match extract_path_param ~prefix:"/api/v1/artifact-bytes/" path with
           | None ->
             respond_json_value_with_cors ~status:`Bad_request request reqd
               (`Assoc [ "error", `String "sha256 path parameter required" ])
           | Some sha256 ->
             (match Tool_blob_store.validate_sha256 sha256 with
              | Error invalid ->
                respond_json_value_with_cors ~status:`Bad_request request reqd
                  (`Assoc [ "error", `String (Tool_blob_store.invalid_sha256_to_string invalid) ])
              | Ok () ->
                (match artifact_bytes ~base_path ~sha256 with
                 | Ok (Some bytes) ->
                   Http.Response.bytes ~content_type:"application/octet-stream"
                     ~headers:
                       ([ "cache-control", "no-store"
                        ; "x-content-type-options", "nosniff"
                        ; "content-disposition", "attachment; filename=artifact-" ^ sha256 ^ ".bin"
                        ] @ cors_headers (get_origin request))
                     bytes reqd
                 | Ok None ->
                   respond_json_value_with_cors ~status:`Not_found request reqd
                     (`Assoc [ "error", `String "not found" ])
                 | Error (Tool_blob_store.Too_large { actual; maximum; _ }) ->
                   respond_json_value_with_cors ~status:`Payload_too_large request reqd
                     (too_large_response actual maximum)
                 | Error
                     ((Tool_blob_store.Invalid_sha256 _
                      | Tool_blob_store.Owned_read_failed _
                      | Tool_blob_store.Invalid_max_bytes _
                      | Tool_blob_store.Integrity_mismatch _) as error) ->
                   Log.Misc.error "tool blob raw read failed sha256=%s cause=%s"
                     sha256 (Tool_blob_store.fetch_error_to_string error);
                   respond_json_value_with_cors ~status:`Service_unavailable request reqd
                     (`Assoc [ "error", `String "tool blob read failed" ]))))
  |> Server_route.post (Server_route.Token_permission artifact_upload_permission) "/api/v1/artifacts" (fun state agent_name request reqd ->
           let base_path = (Mcp_server.workspace_config state).base_path in
           let declared =
             Option.bind (Http.Request.header request "content-length") int_of_string_opt
           in
           let refuse refusal =
             let json, status = upload_refusal_response refusal in
             respond_json_value_with_cors ~status request reqd json
           in
           Http.Request.read_body_async_with_limit reqd
             ~max_bytes:maximum_artifact_response_bytes
             ~on_body:(fun bytes ->
               match store_upload ~base_path ~declared ~bytes with
               | Error refusal -> refuse refusal
               | Ok reference ->
                 Log.Misc.info "artifact upload by %s: %s (%d bytes)"
                   agent_name reference.Tool_output.sha256 reference.Tool_output.bytes;
                 respond_json_value_with_cors ~status:`Created request reqd
                   (`Assoc
                      [ "sha256", `String reference.Tool_output.sha256
                      ; "bytes", `Int reference.Tool_output.bytes
                      ]))
             ~on_error:(function
               | `Too_large maximum -> refuse (Upload_too_large { maximum })
               | `Internal exn ->
                 Log.Misc.error "artifact upload failed: %s" (Printexc.to_string exn);
                 refuse Upload_store_failed))
