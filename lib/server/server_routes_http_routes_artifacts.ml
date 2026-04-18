(** Tool blob store HTTP surface.

    Lazy-fetch endpoint for the dashboard. Tool outputs externalized by
    [Tool_bridge.maybe_externalize] live in
    [${MASC_BASE_PATH}/.masc/tool_blobs/<sha[0..1]>/<sha>]; the dashboard
    UI displays the sentinel marker preview by default and fetches full
    bytes on demand via:

      GET /api/v1/artifacts/<sha256>

    Response (200): JSON envelope
      { "sha256": ..., "bytes": <int>, "mime": "text/plain",
        "content": "<the bytes>" }

    Errors:
      400 — malformed sha256 (not 64 hex chars)
      404 — sha256 not in store
      503 — base path unresolvable (store unavailable) *)

open Server_utils
open Server_auth

module Http = Http_server_eio

let is_valid_sha256 (s : string) : bool =
  String.length s = 64
  && String.for_all
       (fun c ->
         (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'))
       s

let blob_response ~sha256 =
  match Env_config_core.base_path_opt () with
  | None ->
      ( `Assoc
          [
            ("error", `String "tool blob store unavailable");
            ( "reason",
              `String "MASC_BASE_PATH not set; no store root resolvable" );
          ],
        `Service_unavailable )
  | Some base_path ->
      let store = Tool_blob_store.create ~base_path in
      (match Tool_blob_store.fetch store ~sha256 with
       | None ->
           ( `Assoc
               [
                 ("error", `String "not found");
                 ("sha256", `String sha256);
               ],
             `Not_found )
       | Some bytes ->
           ( `Assoc
               [
                 ("sha256", `String sha256);
                 ("bytes", `Int (String.length bytes));
                 ("mime", `String "text/plain");
                 ("content", `String bytes);
               ],
             `OK ))

let add_routes router =
  router
  |> Http.Router.prefix_get "/api/v1/artifacts/" (fun request reqd ->
       with_public_read
         (fun _state _req reqd ->
           let path = Http.Request.path request in
           match extract_path_param ~prefix:"/api/v1/artifacts/" path with
           | None ->
               respond_public_read_json ~status:`Bad_request request reqd
                 (Yojson.Safe.to_string
                    (`Assoc [ ("error", `String "sha256 path parameter required") ]))
           | Some raw when not (is_valid_sha256 raw) ->
               respond_public_read_json ~status:`Bad_request request reqd
                 (Yojson.Safe.to_string
                    (`Assoc
                      [
                        ("error", `String "invalid sha256");
                        ( "reason",
                          `String "expected 64-char lowercase hex" );
                      ]))
           | Some sha256 ->
               let json, status = blob_response ~sha256 in
               respond_public_read_json ~status request reqd
                 (Yojson.Safe.to_string json))
         request reqd)
